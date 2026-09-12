# azure-pim-governance stack
#
# One deployable unit that composes the two PIM modules into a coherent tenant
# baseline. Order of dependency:
#
#   role management policies  -->  eligible assignments
#
# The order is not cosmetic. Azure rejects an eligibility whose expiration is
# longer than the policy for that (scope, role) allows, and rejects a permanent
# eligibility unless the policy has expiration_required = false. The policy
# must therefore be written before the eligibility that relies on it, and
# nothing in the eligibility resource references a policy attribute, so the
# graph has no natural edge. depends_on supplies it.
#
# Tenant cells (tenants/azure/<tenant>/azure-pim-governance/terragrunt.hcl)
# supply values only. This stack owns all wiring: approver group name to object
# ID lookups and the module composition itself. Scope and role name resolution
# happens inside the modules.
#
# Deliberately NOT managed here: custom role definitions (stacks/azure-rbac-roles,
# referenced by name), Entra directory roles and PIM for groups (the
# entra-pim-governance stack), groups and their membership (the directory of
# record owns those), and active or standing role assignments of any kind.

# ---------------------------------------------------------------------------
# Approver group lookups. One data source per distinct display name across
# the tenant baseline and every per-policy override.
# ---------------------------------------------------------------------------

locals {
  all_approver_group_names = toset(concat(
    var.approver_groups,
    flatten([for p in var.policies : coalesce(p.activation.approver_groups, [])]),
  ))
}

data "azuread_group" "approvers" {
  for_each = local.all_approver_group_names

  display_name     = each.value
  security_enabled = true
}

locals {
  approver_group_object_ids = { for name, g in data.azuread_group.approvers : name => g.object_id }
}

# ---------------------------------------------------------------------------
# Role management policies first.
# ---------------------------------------------------------------------------

module "pim_role_policy" {
  source = "../../modules/azure/pim-role-policy"

  activation_maximum_duration        = var.activation_maximum_duration
  require_multifactor_authentication = var.require_multifactor_authentication
  require_justification              = var.require_justification
  require_ticket_info                = var.require_ticket_info
  require_approval                   = var.require_approval
  approver_group_object_ids          = [for name in var.approver_groups : local.approver_group_object_ids[name]]

  eligible_assignment_rules = var.eligible_assignment_rules
  active_assignment_rules   = var.active_assignment_rules
  notification_rules        = var.notification_rules

  policies = {
    for key, p in var.policies : key => {
      role_name = p.role_name
      scope     = p.scope

      activation = {
        maximum_duration                   = p.activation.maximum_duration
        require_multifactor_authentication = p.activation.require_multifactor_authentication
        require_justification              = p.activation.require_justification
        require_ticket_info                = p.activation.require_ticket_info
        require_approval                   = p.activation.require_approval
        approver_group_object_ids          = p.activation.approver_groups == null ? null : [for name in p.activation.approver_groups : local.approver_group_object_ids[name]]
      }

      eligible_assignment_rules = p.eligible_assignment_rules
      active_assignment_rules   = p.active_assignment_rules
    }
  }
}

# ---------------------------------------------------------------------------
# Eligible assignments, only after every policy is in place.
# ---------------------------------------------------------------------------

module "pim_eligible_assignment" {
  source = "../../modules/azure/pim-eligible-assignment"

  eligibilities = var.eligibilities

  depends_on = [module.pim_role_policy]
}
