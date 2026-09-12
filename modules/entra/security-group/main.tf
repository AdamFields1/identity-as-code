# Security groups keyed by the caller's logical name. Mail is never enabled and
# security is always enabled: this module exists to create access-control and
# privileged-role groups, not distribution lists.
#
# prevent_destroy is set on every group. A group's object ID is what everything
# else points at: Conditional Access exclusions, PIM policies, Azure RBAC, app
# role assignments. Destroying and recreating a group produces a new object ID
# and silently drops every one of those references. For a break-glass exclusion
# group that means every Conditional Access policy starts applying to the
# break-glass accounts. Requiring an engineer to edit this lifecycle block first
# turns that into an explicit, reviewed decision instead of a side effect of a
# key rename.

locals {
  user_upns   = toset(flatten([for g in var.groups : concat(g.owners, g.member_users)]))
  group_names = toset(flatten([for g in var.groups : g.member_groups]))
}

data "azuread_user" "by_upn" {
  for_each = local.user_upns

  user_principal_name = each.value
}

data "azuread_group" "existing" {
  for_each = local.group_names

  display_name     = each.value
  security_enabled = true
}

locals {
  user_ids  = { for upn, u in data.azuread_user.by_upn : upn => u.object_id }
  group_ids = { for name, g in data.azuread_group.existing : name => g.object_id }

  member_ids = {
    for k, g in var.groups : k => concat(
      [for upn in g.member_users : local.user_ids[upn]],
      [for name in g.member_groups : local.group_ids[name]],
    )
  }
}

resource "azuread_group" "this" {
  for_each = var.groups

  display_name            = each.value.display_name
  description             = each.value.description
  security_enabled        = true
  mail_enabled            = false
  assignable_to_role      = each.value.assignable_to_role
  prevent_duplicate_names = true

  # Null (not an empty set) when the caller lists nobody, so the provider leaves
  # membership and ownership alone. PIM activation writes membership on
  # role-assignable groups; an empty set here would remove every activated
  # member on the next apply.
  owners  = length(each.value.owners) > 0 ? [for upn in each.value.owners : local.user_ids[upn]] : null
  members = length(local.member_ids[each.key]) > 0 ? local.member_ids[each.key] : null

  lifecycle {
    prevent_destroy = true
  }
}
