# PIM eligible role assignments, one per map entry.
#
# An eligibility says "members of this group may activate this role at this
# scope, for up to the policy's activation window, until this date". It grants
# nothing standing. The policy that governs the activation lives in the
# pim-role-policy module and must be applied first: Azure rejects an
# eligibility whose expiration is longer than the policy allows.
#
# Principals are Entra groups resolved by display name. Users are deliberately
# not supported here; assigning a person directly is a break-glass pattern
# that belongs in a runbook, not in a map that gets copied between tenants.
#
# Scopes and roles are given by name, never by ID. The resolution pattern is
# the same as the other two modules and is repeated so each stays self-contained.

# ---------------------------------------------------------------------------
# Scope resolution.
# ---------------------------------------------------------------------------

locals {
  all_scopes = [for e in var.eligibilities : e.scope]

  management_group_names = toset([for s in local.all_scopes : s.name if s.type == "management_group"])
  subscription_names     = toset([for s in local.all_scopes : s.name if s.type == "subscription"])
  resource_group_names   = toset([for s in local.all_scopes : s.name if s.type == "resource_group"])
}

data "azurerm_management_group" "by_display_name" {
  for_each = local.management_group_names

  display_name = each.value
}

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

  scope_ids = merge(
    { for name, mg in data.azurerm_management_group.by_display_name : "management_group/${name}" => mg.id },
    { for name, id in local.subscription_ids : "subscription/${name}" => id },
    { for name, rg in data.azurerm_resource_group.by_name : "resource_group/${name}" => rg.id },
  )
}

# ---------------------------------------------------------------------------
# Principal resolution. One lookup per distinct group display name.
# security_enabled narrows the match so a Microsoft 365 group with the same
# display name as a security group does not make the lookup ambiguous.
# ---------------------------------------------------------------------------

locals {
  group_display_names = toset([for e in var.eligibilities : e.group_display_name])
}

data "azuread_group" "by_display_name" {
  for_each = local.group_display_names

  display_name     = each.value
  security_enabled = true
}

# ---------------------------------------------------------------------------
# Role resolution at the eligibility's scope, so the resource receives the
# fully qualified role definition ID it expects.
# ---------------------------------------------------------------------------

data "azurerm_role_definition" "this" {
  for_each = var.eligibilities

  name  = each.value.role_name
  scope = local.scope_ids["${each.value.scope.type}/${each.value.scope.name}"]
}

# ---------------------------------------------------------------------------
# Eligibilities.
# ---------------------------------------------------------------------------

resource "azurerm_pim_eligible_role_assignment" "this" {
  for_each = var.eligibilities

  scope              = local.scope_ids["${each.value.scope.type}/${each.value.scope.name}"]
  role_definition_id = data.azurerm_role_definition.this[each.key].id
  principal_id       = data.azuread_group.by_display_name[each.value.group_display_name].object_id
  justification      = each.value.justification

  # A permanent eligibility sends no schedule at all. Sending an expiration
  # block with every field null is not the same thing to the API.
  dynamic "schedule" {
    for_each = each.value.expiration.permanent ? [] : [1]

    content {
      expiration {
        duration_days = each.value.expiration.duration_days
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.scope_ids["${each.value.scope.type}/${each.value.scope.name}"] != null
      error_message = "Eligibility \"${each.key}\": subscription \"${each.value.scope.name}\" was not found by display name in this tenant."
    }
  }
}
