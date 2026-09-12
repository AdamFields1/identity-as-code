# Two kinds of PIM eligibility, both expressed by name:
#
#   1. A role-assignable group is made eligible for an Entra directory role
#      (azuread_directory_role_eligibility_schedule_request). Members of the
#      group activate the role through PIM under the role's activation policy.
#
#   2. Users or groups are made eligible for membership (or ownership) of a
#      PIM-enabled group (azuread_privileged_access_group_eligibility_schedule).
#      Activation writes the membership under the group's role management policy
#      (see modules/entra/pim-role-policy).
#
# Together they form the two-hop model: a person is eligible for the group, the
# group is eligible for the role. Nobody holds a standing directory role.
#
# The directory role is resolved from the built-in role templates, so a role does
# not have to be activated in the tenant before it can be referenced, and the
# template ID is the role definition ID that the schedule request expects.

locals {
  group_names = toset(concat(
    [for e in var.directory_role_eligibilities : e.group_display_name],
    [for e in var.group_eligibilities : e.group_display_name],
    [for e in var.group_eligibilities : e.principal_group if e.principal_group != null],
  ))

  user_upns = toset([for e in var.group_eligibilities : e.principal_user if e.principal_user != null])
}

data "azuread_directory_role_templates" "all" {}

data "azuread_group" "by_name" {
  for_each = local.group_names

  display_name     = each.value
  security_enabled = true
}

data "azuread_user" "by_upn" {
  for_each = local.user_upns

  user_principal_name = each.value
}

locals {
  role_template_ids = {
    for t in data.azuread_directory_role_templates.all.role_templates : t.display_name => t.object_id
  }
  group_ids = { for name, g in data.azuread_group.by_name : name => g.object_id }
  user_ids  = { for upn, u in data.azuread_user.by_upn : upn => u.object_id }
}

# ---------------------------------------------------------------------------
# Group -> directory role.
# ---------------------------------------------------------------------------

resource "azuread_directory_role_eligibility_schedule_request" "this" {
  for_each = var.directory_role_eligibilities

  role_definition_id = local.role_template_ids[each.value.role_display_name]
  principal_id       = local.group_ids[each.value.group_display_name]
  directory_scope_id = each.value.directory_scope_id
  justification      = each.value.justification

  lifecycle {
    precondition {
      condition     = contains(keys(local.role_template_ids), each.value.role_display_name)
      error_message = "role_display_name must be a built-in Entra directory role name exactly as shown in the portal, for example \"Global Administrator\"."
    }
  }
}

# ---------------------------------------------------------------------------
# User or group -> PIM-enabled group.
# ---------------------------------------------------------------------------

resource "azuread_privileged_access_group_eligibility_schedule" "this" {
  for_each = var.group_eligibilities

  group_id        = local.group_ids[each.value.group_display_name]
  principal_id    = each.value.principal_user != null ? local.user_ids[each.value.principal_user] : local.group_ids[each.value.principal_group]
  assignment_type = each.value.assignment_type
  justification   = each.value.justification

  # A duration implies a time-bound eligibility; otherwise it is permanent.
  permanent_assignment = each.value.duration == null ? each.value.permanent : false
  duration             = each.value.duration
}
