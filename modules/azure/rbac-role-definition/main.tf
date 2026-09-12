# Custom RBAC role definitions, one per map entry.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing a role in the middle of the map never re-addresses its neighbours.
#
# Scopes are given by name, never by ID. A management group is resolved through
# its display name, a subscription through its display name, a resource group
# through its name in the provider's subscription. The lookups below run once
# per distinct scope, so ten roles that all live at the same management group
# cost one API call, not ten.

# ---------------------------------------------------------------------------
# Scope resolution. Every scope referenced by any role, primary or additional,
# is collected into one set per scope type and looked up exactly once.
# ---------------------------------------------------------------------------

locals {
  all_scopes = flatten([
    for role in var.roles : concat([role.assignable_scope], role.additional_assignable_scopes)
  ])

  management_group_names = toset([for s in local.all_scopes : s.name if s.type == "management_group"])
  subscription_names     = toset([for s in local.all_scopes : s.name if s.type == "subscription"])
  resource_group_names   = toset([for s in local.all_scopes : s.name if s.type == "resource_group"])
}

data "azurerm_management_group" "by_display_name" {
  for_each = local.management_group_names

  display_name = each.value
}

# The subscriptions data source filters by prefix, not exact match, so the
# exact match is applied below. one() fails the plan if the prefix is ambiguous.
data "azurerm_subscriptions" "by_display_name" {
  for_each = local.subscription_names

  display_name_prefix = each.value
}

data "azurerm_resource_group" "by_name" {
  for_each = local.resource_group_names

  name = each.value
}

locals {
  subscription_ids = {
    for name, result in data.azurerm_subscriptions.by_display_name :
    name => one([for s in result.subscriptions : s.id if s.display_name == name])
  }

  # Scope key is "<type>/<name>" so a management group and a subscription that
  # happen to share a display name never collide.
  scope_ids = merge(
    { for name, mg in data.azurerm_management_group.by_display_name : "management_group/${name}" => mg.id },
    { for name, id in local.subscription_ids : "subscription/${name}" => id },
    { for name, rg in data.azurerm_resource_group.by_name : "resource_group/${name}" => rg.id },
  )

  resolved_roles = {
    for key, role in var.roles : key => {
      scope_id = local.scope_ids["${role.assignable_scope.type}/${role.assignable_scope.name}"]
      assignable_scope_ids = distinct(concat(
        [local.scope_ids["${role.assignable_scope.type}/${role.assignable_scope.name}"]],
        [for s in role.additional_assignable_scopes : local.scope_ids["${s.type}/${s.name}"]],
      ))
    }
  }
}

# ---------------------------------------------------------------------------
# Role definitions.
# ---------------------------------------------------------------------------

resource "azurerm_role_definition" "this" {
  for_each = var.roles

  name        = each.value.name
  description = each.value.description

  # The definition is created at the primary scope and is assignable there and
  # at every additional scope. Azure requires the creation scope to appear in
  # assignable_scopes, which the local above guarantees.
  scope             = local.resolved_roles[each.key].scope_id
  assignable_scopes = local.resolved_roles[each.key].assignable_scope_ids

  permissions {
    actions          = each.value.actions
    not_actions      = each.value.not_actions
    data_actions     = each.value.data_actions
    not_data_actions = each.value.not_data_actions
  }

  lifecycle {
    # A custom role is referenced by name from PIM policies and eligibilities
    # that live in a different cell and a different state file. Terraform in
    # this cell cannot see those references, so a role that is removed from the
    # map here would be destroyed underneath them: Azure either refuses the
    # delete because assignments still exist, or leaves eligibilities pointing
    # at a definition that no longer resolves. Retiring a role is a two-cell
    # operation (remove the assignments first, then the definition) and the
    # second step must be deliberate, so it requires flipping this flag in a
    # dedicated change rather than happening as a side effect of a map edit.
    prevent_destroy = true

    precondition {
      condition     = local.resolved_roles[each.key].scope_id != null
      error_message = "Role \"${each.key}\": subscription \"${each.value.assignable_scope.name}\" was not found by display name in this tenant."
    }

    precondition {
      condition     = alltrue([for id in local.resolved_roles[each.key].assignable_scope_ids : id != null])
      error_message = "Role \"${each.key}\": one of the additional_assignable_scopes named a subscription that does not exist in this tenant."
    }
  }
}
