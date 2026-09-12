# Entra subsidiary tenant cell: PIM governance.
#
# Values only. Same stack as corp; the differences below are the whole story of
# "what is stricter in the subsidiary":
#   - PT2H activation instead of the PT4H default
#   - approval required for every group, not only Global Administrator
#   - eligibilities expire after P180D instead of being permanent
#   - two groups, not three: the subsidiary has no user administration function
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/subsidiary/entra-pim-governance/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-pim-governance"
}

inputs = {
  privileged_groups = {
    pim-global-admin = {
      display_name = "PIM Global Administrators"
      owners       = ["iam.lead@sub.example.com"]
    }

    pim-security-admin = {
      display_name = "PIM Security Administrators"
      owners       = ["iam.lead@sub.example.com"]
    }
  }

  role_policies = {
    global-admin-member = {
      group_display_name = "PIM Global Administrators"

      activation = {
        maximum_duration = "PT2H"
        require_approval = true
        approver_groups  = ["SEC IAM Approvers"]
      }

      eligible_assignment = {
        expire_after = "P180D"
      }
    }

    security-admin-member = {
      group_display_name = "PIM Security Administrators"

      activation = {
        maximum_duration = "PT2H"
        require_approval = true
        approver_groups  = ["SEC IAM Approvers"]
      }

      eligible_assignment = {
        expire_after = "P180D"
      }
    }
  }

  directory_role_eligibilities = {
    global-admin = {
      role_display_name  = "Global Administrator"
      group_display_name = "PIM Global Administrators"
    }

    security-admin = {
      role_display_name  = "Security Administrator"
      group_display_name = "PIM Security Administrators"
    }
  }

  group_eligibilities = {
    iam-lead-global-admin = {
      group_display_name = "PIM Global Administrators"
      principal_user     = "iam.lead@sub.example.com"
      duration           = "P180D"
    }

    iam-engineers-security-admin = {
      group_display_name = "PIM Security Administrators"
      principal_group    = "IAM Engineers"
      duration           = "P180D"
    }
  }
}
