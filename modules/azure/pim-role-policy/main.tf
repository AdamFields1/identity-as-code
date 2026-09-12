# PIM role management policies, one per (scope, role) pair.
#
# Azure creates a role management policy for every role at every scope on its
# own. This resource never creates a new one; on first apply it adopts the
# existing policy and rewrites the rules to match the configuration. That is
# why a plan on a fresh cell shows "create" for every entry but the apply
# changes settings rather than adding objects.
#
# Module-level variables set the tenant baseline (activation window, MFA,
# justification, approval). Each policy entry may override any of them, and a
# null override means "inherit". The effective values are computed once in the
# locals below so the resource body reads as plain attribute assignments.
#
# Scopes and roles are given by name, never by ID. See the rbac-role-definition
# module for the scope resolution pattern; it is repeated here rather than
# shared so each module stays self-contained.

# ---------------------------------------------------------------------------
# Scope resolution.
# ---------------------------------------------------------------------------

locals {
  all_scopes = [for p in var.policies : p.scope]

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
# Role resolution. The data source is given the scope so its id is the fully
# qualified role definition resource ID at that scope, which is what the
# policy resource expects. Built-in and custom roles resolve the same way.
# ---------------------------------------------------------------------------

data "azurerm_role_definition" "this" {
  for_each = var.policies

  name  = each.value.role_name
  scope = local.scope_ids["${each.value.scope.type}/${each.value.scope.name}"]
}

# ---------------------------------------------------------------------------
# Effective settings per policy: entry override if set, module default if not.
# ---------------------------------------------------------------------------

locals {
  effective = {
    for key, p in var.policies : key => {
      scope_id = local.scope_ids["${p.scope.type}/${p.scope.name}"]

      activation = {
        maximum_duration                   = p.activation.maximum_duration != null ? p.activation.maximum_duration : var.activation_maximum_duration
        require_multifactor_authentication = p.activation.require_multifactor_authentication != null ? p.activation.require_multifactor_authentication : var.require_multifactor_authentication
        require_justification              = p.activation.require_justification != null ? p.activation.require_justification : var.require_justification
        require_ticket_info                = p.activation.require_ticket_info != null ? p.activation.require_ticket_info : var.require_ticket_info
        require_approval                   = p.activation.require_approval != null ? p.activation.require_approval : var.require_approval
        approver_group_object_ids          = p.activation.approver_group_object_ids != null ? p.activation.approver_group_object_ids : var.approver_group_object_ids
      }

      eligible = {
        expiration_required = p.eligible_assignment_rules.expiration_required != null ? p.eligible_assignment_rules.expiration_required : var.eligible_assignment_rules.expiration_required
        expire_after        = p.eligible_assignment_rules.expire_after != null ? p.eligible_assignment_rules.expire_after : var.eligible_assignment_rules.expire_after
      }

      active = {
        expiration_required                = p.active_assignment_rules.expiration_required != null ? p.active_assignment_rules.expiration_required : var.active_assignment_rules.expiration_required
        expire_after                       = p.active_assignment_rules.expire_after != null ? p.active_assignment_rules.expire_after : var.active_assignment_rules.expire_after
        require_multifactor_authentication = p.active_assignment_rules.require_multifactor_authentication != null ? p.active_assignment_rules.require_multifactor_authentication : var.active_assignment_rules.require_multifactor_authentication
        require_justification              = p.active_assignment_rules.require_justification != null ? p.active_assignment_rules.require_justification : var.active_assignment_rules.require_justification
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Policies.
# ---------------------------------------------------------------------------

resource "azurerm_role_management_policy" "this" {
  for_each = var.policies

  scope              = local.effective[each.key].scope_id
  role_definition_id = data.azurerm_role_definition.this[each.key].id

  eligible_assignment_rules {
    expiration_required = local.effective[each.key].eligible.expiration_required
    expire_after        = local.effective[each.key].eligible.expiration_required ? local.effective[each.key].eligible.expire_after : null
  }

  active_assignment_rules {
    expiration_required                = local.effective[each.key].active.expiration_required
    expire_after                       = local.effective[each.key].active.expiration_required ? local.effective[each.key].active.expire_after : null
    require_multifactor_authentication = local.effective[each.key].active.require_multifactor_authentication
    require_justification              = local.effective[each.key].active.require_justification
  }

  activation_rules {
    maximum_duration                   = local.effective[each.key].activation.maximum_duration
    require_multifactor_authentication = local.effective[each.key].activation.require_multifactor_authentication
    require_justification              = local.effective[each.key].activation.require_justification
    require_ticket_info                = local.effective[each.key].activation.require_ticket_info
    require_approval                   = local.effective[each.key].activation.require_approval

    # Approval stage only when approval is required. Sending an empty stage
    # with require_approval = false is rejected by the API.
    dynamic "approval_stage" {
      for_each = local.effective[each.key].activation.require_approval ? [1] : []

      content {
        dynamic "primary_approver" {
          for_each = local.effective[each.key].activation.approver_group_object_ids

          content {
            object_id = primary_approver.value
            type      = "Group"
          }
        }
      }
    }
  }

  # Notifications are module-wide and minimal. Only the blocks that are set
  # are sent; Azure keeps its defaults for the rest.
  dynamic "notification_rules" {
    for_each = var.notification_rules != null ? [var.notification_rules] : []

    content {
      dynamic "eligible_assignments" {
        for_each = notification_rules.value.eligible_assignments != null ? [notification_rules.value.eligible_assignments] : []

        content {
          dynamic "admin_notifications" {
            for_each = eligible_assignments.value.admin != null ? [eligible_assignments.value.admin] : []

            content {
              notification_level    = admin_notifications.value.notification_level
              default_recipients    = admin_notifications.value.default_recipients
              additional_recipients = admin_notifications.value.additional_recipients
            }
          }
        }
      }

      dynamic "eligible_activations" {
        for_each = notification_rules.value.eligible_activations != null ? [notification_rules.value.eligible_activations] : []

        content {
          dynamic "admin_notifications" {
            for_each = eligible_activations.value.admin != null ? [eligible_activations.value.admin] : []

            content {
              notification_level    = admin_notifications.value.notification_level
              default_recipients    = admin_notifications.value.default_recipients
              additional_recipients = admin_notifications.value.additional_recipients
            }
          }
        }
      }

      dynamic "active_assignments" {
        for_each = notification_rules.value.active_assignments != null ? [notification_rules.value.active_assignments] : []

        content {
          dynamic "admin_notifications" {
            for_each = active_assignments.value.admin != null ? [active_assignments.value.admin] : []

            content {
              notification_level    = admin_notifications.value.notification_level
              default_recipients    = admin_notifications.value.default_recipients
              additional_recipients = admin_notifications.value.additional_recipients
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.effective[each.key].scope_id != null
      error_message = "Policy \"${each.key}\": subscription \"${each.value.scope.name}\" was not found by display name in this tenant."
    }

    precondition {
      condition     = !local.effective[each.key].activation.require_approval || length(local.effective[each.key].activation.approver_group_object_ids) > 0
      error_message = "Policy \"${each.key}\": require_approval is true but no approver group object IDs are set at the policy or module level."
    }
  }
}
