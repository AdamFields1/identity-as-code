# AWS commercial partition cell: IAM Identity Center.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# The identity source for this instance is Entra ID over SAML, with users and
# groups provisioned by SCIM. Both are configured by the corp Entra tenant's
# entra-aws-federation cell (tenants/azure/corp/entra-aws-federation), which
# assigns every AWS-COM-* group to the commercial gallery application. SCIM
# creates each one in this instance's identity store under the same display
# name. A group not assigned there does not exist here and the plan says so.
#
# The group name is the assignment: AWS-COM-<accountId>-<PermissionSetName>
# grants <PermissionSetName> in <accountId>. This cell therefore lists the
# permission sets and the group names, and nothing else. Accounts:
#   111111111111  example-prod
#   222222222222  example-dev
#   333333333333  example-log-archive
#
# Region is the address of the instance. It is the only thing in this file
# that says "commercial" in words; the COM token in every group name says it
# again and the module checks the two agree.
#
# State key (derived by root.hcl): aws/commercial/aws-identity-center/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/aws-identity-center"
}

inputs = {
  region = "us-east-1"

  # -------------------------------------------------------------------------
  # Permission sets. Session duration is set per set and is the security
  # control: admin is one hour, everything else four. Policies are names; the
  # module builds partition-aware ARNs.
  # -------------------------------------------------------------------------
  permission_sets = {
    platform-admin = {
      name                 = "PlatformAdmin"
      description          = "Full administrative access for platform engineers. One-hour sessions by design."
      session_duration     = "PT1H"
      aws_managed_policies = ["AdministratorAccess"]
    }

    power-user = {
      name                 = "PowerUser"
      description          = "Build and operate workloads without touching IAM. Boundary keeps it that way."
      session_duration     = "PT4H"
      aws_managed_policies = ["PowerUserAccess"]
      permissions_boundary = { aws_managed_policy = "PowerUserAccess" }
    }

    read-only = {
      name                 = "ReadOnly"
      description          = "Read-only access for investigation, audit, and review."
      session_duration     = "PT4H"
      aws_managed_policies = ["ReadOnlyAccess", "AWSSupportAccess"]
    }

    billing = {
      name                 = "Billing"
      description          = "Cost Explorer and billing console. Payment methods and billing preferences stay read-only."
      session_duration     = "PT2H"
      aws_managed_policies = ["job-function/Billing"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid      = "NoBillingChanges"
          Effect   = "Deny"
          Action   = ["aws-portal:ModifyBilling", "aws-portal:ModifyPaymentMethods", "aws-portal:ModifyAccount"]
          Resource = "*"
        }]
      })
    }
  }

  # -------------------------------------------------------------------------
  # Groups. One assignment each. Every name here also appears in the corp
  # entra-aws-federation cell's aws_groups list; that is what provisions it.
  # -------------------------------------------------------------------------
  group_display_names = [
    "AWS-COM-111111111111-PlatformAdmin",
    "AWS-COM-111111111111-ReadOnly",
    "AWS-COM-111111111111-Billing",
    "AWS-COM-222222222222-PlatformAdmin",
    "AWS-COM-222222222222-PowerUser",
    "AWS-COM-222222222222-ReadOnly",
    "AWS-COM-333333333333-PlatformAdmin",
    "AWS-COM-333333333333-ReadOnly",
  ]
}
