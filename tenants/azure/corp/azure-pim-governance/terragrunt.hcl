# Azure corp tenant, PIM governance cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# The "Platform Operator" and "Cost Reviewer" roles referenced below are
# defined in ../azure-rbac-roles. That cell must be applied first; the
# dependencies block orders a `terragrunt run --all` and the release workflow
# orders the jobs. See docs/adr/0005.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/azure-pim-governance/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-pim-governance"
}

# Ordering only. No outputs are read from the roles cell; roles are resolved by
# name at plan time, so this block carries no values and no logic.
dependencies {
  paths = ["../azure-rbac-roles"]
}

inputs = {
  # -------------------------------------------------------------------------
  # Tenant baseline. Corp is the workforce tenant: four-hour activation, MFA
  # and justification always, approval only where a policy below asks for it.
  # -------------------------------------------------------------------------
  activation_maximum_duration        = "PT4H"
  require_multifactor_authentication = true
  require_justification              = true
  require_ticket_info                = false
  require_approval                   = false

  eligible_assignment_rules = {
    expiration_required = true
    expire_after        = "P365D"
  }

  active_assignment_rules = {
    expiration_required = true
    expire_after        = "P180D"
  }

  # -------------------------------------------------------------------------
  # Role management policies. One entry per (scope, role) that any
  # eligibility below uses. Owner is the only role that needs an approver.
  # -------------------------------------------------------------------------
  policies = {
    owner-at-root = {
      role_name = "Owner"
      scope     = { type = "management_group", name = "mg-example-root" }
      activation = {
        maximum_duration = "PT1H"
        require_approval = true
        approver_groups  = ["PIM Approvers"]
      }
    }

    contributor-prod = {
      role_name = "Contributor"
      scope     = { type = "subscription", name = "sub-example-prod" }
      activation = {
        require_ticket_info = true
      }
    }

    contributor-nonprod = {
      role_name = "Contributor"
      scope     = { type = "subscription", name = "sub-example-nonprod" }
      activation = {
        maximum_duration = "PT8H"
      }
    }

    platform-operator-at-root = {
      role_name = "Platform Operator"
      scope     = { type = "management_group", name = "mg-example-root" }
    }

    cost-reviewer-at-root = {
      role_name = "Cost Reviewer"
      scope     = { type = "management_group", name = "mg-example-root" }
      activation = {
        require_multifactor_authentication = true
        require_justification              = false
      }
    }

    reader-at-root = {
      role_name = "Reader"
      scope     = { type = "management_group", name = "mg-example-root" }
      eligible_assignment_rules = {
        expiration_required = false
      }
    }
  }

  # -------------------------------------------------------------------------
  # Eligibilities. Groups by display name; the directory of record owns
  # membership. Every (scope, role) here has a policy above.
  # -------------------------------------------------------------------------
  eligibilities = {
    break-glass-owner-at-root = {
      group_display_name = "Break Glass Owners"
      role_name          = "Owner"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Emergency access to the whole estate. Every activation is approved by PIM Approvers and reviewed."
      expiration         = { duration_days = 365 }
    }

    cloud-engineers-contributor-prod = {
      group_display_name = "Cloud Engineers"
      role_name          = "Contributor"
      scope              = { type = "subscription", name = "sub-example-prod" }
      justification      = "Change delivery into production through PIM with a ticket reference."
      expiration         = { duration_days = 180 }
    }

    cloud-engineers-contributor-nonprod = {
      group_display_name = "Cloud Engineers"
      role_name          = "Contributor"
      scope              = { type = "subscription", name = "sub-example-nonprod" }
      justification      = "Day-to-day engineering in non-production."
      expiration         = { duration_days = 365 }
    }

    platform-operators-at-root = {
      group_display_name = "Platform Operators"
      role_name          = "Platform Operator"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Day-two platform operations. Reviewed quarterly by the platform lead."
      expiration         = { duration_days = 365 }
    }

    finops-cost-reviewer-at-root = {
      group_display_name = "FinOps Analysts"
      role_name          = "Cost Reviewer"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Monthly cost review across every subscription."
      expiration         = { duration_days = 365 }
    }

    security-readers-at-root = {
      group_display_name = "Security Operations"
      role_name          = "Reader"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Read-only investigation access across the estate. Permanent by design; the policy for Reader allows it."
      expiration         = { permanent = true }
    }
  }
}
