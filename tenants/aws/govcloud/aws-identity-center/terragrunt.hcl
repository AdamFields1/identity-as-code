# AWS GovCloud (US) partition cell: IAM Identity Center.
#
# Values only. Same stack as commercial; the differences below are the whole
# story of "what is stricter in GovCloud":
#   - every session is PT1H, including read-only
#   - two permission sets, not four: no PowerUser and no Billing, because the
#     GovCloud organization has no self-service developer accounts and its
#     billing is handled through the linked commercial account
#   - two accounts, not three: no dev
#
# GovCloud is a separate partition (arn:aws-us-gov), a separate organization,
# a separate Identity Center instance, a separate state bucket, and a separate
# OIDC role. None of that appears in this file: the modules read the partition
# from data.aws_partition, so "AdministratorAccess" below becomes
# arn:aws-us-gov:iam::aws:policy/AdministratorAccess here and
# arn:aws:iam::aws:policy/AdministratorAccess in the commercial cell. The
# region is the only value that differs in kind, and the GOV token in every
# group name is checked against it. See docs/adr/0009.
#
# The identity source for this instance is the same corp Entra tenant over
# SAML and SCIM as for commercial: tenants/azure/corp/entra-aws-federation
# holds a second gallery application to which every AWS-GOV-* group is
# assigned. Accounts:
#   111111111111  example-gov-prod
#   333333333333  example-gov-log-archive
# (GovCloud account IDs are distinct from commercial ones in reality; the
# placeholders repeat only because they are placeholders.)
#
# State key (derived by root.hcl): aws/govcloud/aws-identity-center/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/aws-identity-center"
}

inputs = {
  region = "us-gov-west-1"

  permission_sets = {
    platform-admin = {
      name                 = "PlatformAdmin"
      description          = "Full administrative access for platform engineers. One-hour sessions."
      session_duration     = "PT1H"
      aws_managed_policies = ["AdministratorAccess"]
    }

    read-only = {
      name                 = "ReadOnly"
      description          = "Read-only access for investigation, audit, and review. One-hour sessions."
      session_duration     = "PT1H"
      aws_managed_policies = ["ReadOnlyAccess"]
      permissions_boundary = { aws_managed_policy = "ReadOnlyAccess" }
    }
  }

  group_display_names = [
    "AWS-GOV-111111111111-PlatformAdmin",
    "AWS-GOV-111111111111-ReadOnly",
    "AWS-GOV-333333333333-PlatformAdmin",
    "AWS-GOV-333333333333-ReadOnly",
  ]
}
