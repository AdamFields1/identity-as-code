# PIM for Groups role management policies.
#
# Entra creates one policy per group per role (member, owner) the moment a group
# is onboarded to PIM. Role-assignable groups are onboarded at creation. This
# resource therefore never creates anything: the provider adopts the existing
# policy on first apply and enforces the rules below from then on. That is why
# there is no prevent_destroy here; "destroying" the resource only stops
# managing the policy, it does not delete it.
#
# Groups and approver groups are resolved by display name so tenant cells never
# contain an object ID.

locals {
  group_names = toset(concat(
    [for p in var.policies : p.group_display_name],
    flatten([for p in var.policies : p.activation.approver_groups]),
  ))
}

data "azuread_group" "by_name" {
  for_each = local.group_names

  display_name     = each.value
  security_enabled = true
}

locals {
  group_ids = { for name, g in data.azuread_group.by_name : name => g.object_id }
}

resource "azuread_group_role_management_policy" "this" {
  for_each = var.policies

  group_id = local.group_ids[each.value.group_display_name]
  role_id  = each.value.role

  activation_rules {
    maximum_duration                   = each.value.activation.maximum_duration
    require_multifactor_authentication = each.value.activation.require_multifactor_authentication
    require_justification              = each.value.activation.require_justification
    require_ticket_info                = each.value.activation.require_ticket_info
    require_approval                   = each.value.activation.require_approval

    dynamic "approval_stage" {
      for_each = each.value.activation.require_approval ? [1] : []
      content {
        dynamic "primary_approver" {
          for_each = toset(each.value.activation.approver_groups)
          content {
            object_id = local.group_ids[primary_approver.value]
            type      = "groupMembers"
          }
        }
      }
    }
  }

  eligible_assignment_rules {
    expiration_required = each.value.eligible_assignment.expiration_required
    expire_after        = each.value.eligible_assignment.expiration_required ? each.value.eligible_assignment.expire_after : null
  }

  active_assignment_rules {
    expiration_required                = each.value.active_assignment.expiration_required
    expire_after                       = each.value.active_assignment.expiration_required ? each.value.active_assignment.expire_after : null
    require_justification              = each.value.active_assignment.require_justification
    require_multifactor_authentication = each.value.active_assignment.require_multifactor_authentication
  }

  # Minimal: administrators are told when someone becomes eligible and when
  # someone activates. Assignee and approver notifications keep Entra defaults.
  notification_rules {
    eligible_assignments {
      admin_notifications {
        notification_level    = each.value.notifications.admin_notification_level
        default_recipients    = each.value.notifications.admin_default_recipients
        additional_recipients = length(each.value.notifications.admin_additional_recipients) > 0 ? each.value.notifications.admin_additional_recipients : null
      }
    }

    eligible_activations {
      admin_notifications {
        notification_level    = each.value.notifications.admin_notification_level
        default_recipients    = each.value.notifications.admin_default_recipients
        additional_recipients = length(each.value.notifications.admin_additional_recipients) > 0 ? each.value.notifications.admin_additional_recipients : null
      }
    }
  }
}
