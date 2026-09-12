# Entra corp tenant cell: PIM governance.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Three role-assignable groups, one policy each, one directory role each.
# Global Administrator activation requires approval; the other two do not.
# Nobody is a permanent member of any of these groups.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/entra-pim-governance/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-pim-governance"
}

inputs = {
  # -------------------------------------------------------------------------
  # Privileged groups. assignable_to_role is forced true by the stack.
  # Membership is never listed; PIM activation writes it.
  # -------------------------------------------------------------------------
  privileged_groups = {
    pim-global-admin = {
      display_name = "PIM Global Administrators"
      owners       = ["iam.lead@corp.example.com"]
    }

    pim-security-admin = {
      display_name = "PIM Security Administrators"
      owners       = ["iam.lead@corp.example.com"]
    }

    pim-user-admin = {
      display_name = "PIM User Administrators"
      owners       = ["iam.lead@corp.example.com"]
    }
  }

  # -------------------------------------------------------------------------
  # Activation rules. Module defaults are PT4H, MFA, justification, no approval.
  # Only Global Administrator overrides: approval by the IAM approvers group.
  # -------------------------------------------------------------------------
  role_policies = {
    global-admin-member = {
      group_display_name = "PIM Global Administrators"

      activation = {
        require_approval = true
        approver_groups  = ["SEC IAM Approvers"]
      }
    }

    security-admin-member = {
      group_display_name = "PIM Security Administrators"
    }

    user-admin-member = {
      group_display_name = "PIM User Administrators"
    }
  }

  # -------------------------------------------------------------------------
  # Hop 2: group -> directory role.
  # -------------------------------------------------------------------------
  directory_role_eligibilities = {
    global-admin = {
      role_display_name  = "Global Administrator"
      group_display_name = "PIM Global Administrators"
    }

    security-admin = {
      role_display_name  = "Security Administrator"
      group_display_name = "PIM Security Administrators"
    }

    user-admin = {
      role_display_name  = "User Administrator"
      group_display_name = "PIM User Administrators"
    }
  }

  # -------------------------------------------------------------------------
  # Hop 1: person or group -> PIM group. Corp eligibilities are permanent and
  # reviewed through access reviews rather than expiry.
  # -------------------------------------------------------------------------
  group_eligibilities = {
    iam-lead-global-admin = {
      group_display_name = "PIM Global Administrators"
      principal_user     = "iam.lead@corp.example.com"
    }

    iam-engineers-security-admin = {
      group_display_name = "PIM Security Administrators"
      principal_group    = "IAM Engineers"
    }

    service-desk-user-admin = {
      group_display_name = "PIM User Administrators"
      principal_group    = "Service Desk Tier 2"
    }
  }
}
