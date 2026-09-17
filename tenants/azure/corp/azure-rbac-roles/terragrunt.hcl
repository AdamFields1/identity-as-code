# Azure corp tenant, custom role definitions cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/azure-rbac-roles/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-rbac-roles"
}

inputs = {
  # -------------------------------------------------------------------------
  # Custom roles. Keys are stable identifiers; the eligibilities in
  # ../azure-pim-governance refer to these roles by their display name.
  # Scopes are display names, resolved by the module.
  # -------------------------------------------------------------------------
  custom_roles = {
    platform-operator = {
      name        = "Platform Operator"
      description = "Day-two operations on shared platform resources: start, stop, and restart compute, edit NSG rules, run deployments. Cannot change RBAC or policy."

      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }

      actions = [
        "*/read",
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/restart/action",
        "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Compute/virtualMachineScaleSets/manualUpgrade/action",
        "Microsoft.Network/networkSecurityGroups/securityRules/write",
        "Microsoft.Network/networkSecurityGroups/securityRules/delete",
        "Microsoft.Resources/deployments/*",
        "Microsoft.Support/*",
      ]

      not_actions = [
        "Microsoft.Authorization/*/write",
        "Microsoft.Authorization/*/delete",
        "Microsoft.Blueprint/*/write",
        "Microsoft.Blueprint/*/delete",
      ]
    }

    kv-secrets-rotator = {
      name        = "Key Vault Secrets Rotator"
      description = "Read and set secret versions for automated rotation jobs. No key or certificate access, no vault configuration."

      assignable_scope = {
        type = "subscription"
        name = "sub-example-prod"
      }

      additional_assignable_scopes = [
        { type = "subscription", name = "sub-example-nonprod" },
      ]

      actions = [
        "Microsoft.KeyVault/vaults/read",
        "Microsoft.KeyVault/vaults/secrets/read",
      ]

      data_actions = [
        "Microsoft.KeyVault/vaults/secrets/getSecret/action",
        "Microsoft.KeyVault/vaults/secrets/setSecret/action",
        "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
      ]
    }

    cost-reviewer = {
      name        = "Cost Reviewer"
      description = "Read billing, consumption, and advisor data across the estate for the FinOps review. No resource access beyond metadata."

      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }

      actions = [
        "Microsoft.Resources/subscriptions/read",
        "Microsoft.Resources/subscriptions/resourceGroups/read",
        "Microsoft.Consumption/*/read",
        "Microsoft.CostManagement/*/read",
        "Microsoft.Billing/*/read",
        "Microsoft.Advisor/recommendations/read",
      ]
    }

    # -----------------------------------------------------------------------
    # Roles for the runbook identities in ../azure-automation, assigned there
    # by name inside the tier that uses them. No built-in role is this narrow:
    # the PIM writes are otherwise only in User Access Administrator and
    # Owner, and a variable write only in Automation Contributor.
    # docs/adr/0014 and docs/adr/0016.
    #
    # Two PIM roles, because the two writes are not equally dangerous.
    # "PIM Policy Operator" can change how a role is activated; it cannot
    # hand anyone a role. "PIM Policy and Eligibility Operator" adds
    # roleEligibilityScheduleRequests/write, which creates an eligibility as
    # readily as it extends one, so a holder can make any principal eligible
    # for any role at the scope, Owner included. The corp automation cell
    # assigns the first to its pim tier and the second to nobody: it is
    # defined here for the day Invoke-PimEligibilityRenewal is given the
    # Azure plane (includeazureresources = "true"), which is the change that
    # makes that tier Owner-equivalent over the scopes it names.
    # -----------------------------------------------------------------------
    pim-policy-operator = {
      name        = "PIM Policy Operator"
      description = "Automation only. Read and update Azure PIM role management policies (activation duration, MFA, justification, ticket, approval). Cannot create role assignments, eligibilities, or role definitions."

      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }

      actions = [
        "Microsoft.Authorization/roleManagementPolicies/read",
        "Microsoft.Authorization/roleManagementPolicies/write",
        "Microsoft.Authorization/roleManagementPolicies/approvalRule/action",
        "Microsoft.Authorization/roleManagementPolicyAssignments/read",
        "Microsoft.Authorization/roleEligibilityScheduleInstances/read",
      ]
    }

    pim-policy-and-eligibility-operator = {
      name        = "PIM Policy and Eligibility Operator"
      description = "Automation only. Update Azure PIM role management policies and submit role eligibility schedule requests. A request can create an eligibility as well as extend one, so treat a holder as privileged at the scope. Cannot create active role assignments or role definitions."

      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }

      actions = [
        "Microsoft.Authorization/roleManagementPolicies/read",
        "Microsoft.Authorization/roleManagementPolicies/write",
        "Microsoft.Authorization/roleManagementPolicies/approvalRule/action",
        "Microsoft.Authorization/roleManagementPolicyAssignments/read",
        "Microsoft.Authorization/roleEligibilitySchedules/read",
        "Microsoft.Authorization/roleEligibilityScheduleInstances/read",
        "Microsoft.Authorization/roleEligibilityScheduleRequests/read",
        "Microsoft.Authorization/roleEligibilityScheduleRequests/write",
      ]
    }

    automation-variable-writer = {
      name        = "Automation Variable Writer"
      description = "Automation only. Read and write Azure Automation variable assets, for a runbook that keeps its own state in one. No job, runbook, schedule, or credential access."

      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }

      actions = [
        "Microsoft.Automation/automationAccounts/variables/read",
        "Microsoft.Automation/automationAccounts/variables/write",
      ]
    }
  }
}
