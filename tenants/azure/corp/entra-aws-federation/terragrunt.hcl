# Entra corp tenant cell: AWS IAM Identity Center federation.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Corp is the identity source for both Identity Center instances: commercial
# and GovCloud are separate partitions with separate instances, so there are
# two targets, two gallery applications, two SAML trusts, two SCIM jobs. The
# subsidiary has no entra-aws-federation cell; its people reach AWS through
# corp groups.
#
# aws_groups lists every AWS access group once. Each name is
# AWS-<PARTITION>-<accountId>-<PermissionSetName>; the stack assigns AWS-COM-*
# groups to the commercial application and AWS-GOV-* groups to the GovCloud
# one, which is what provisions them into the matching identity store. The
# AWS cells (tenants/aws/commercial and tenants/aws/govcloud) list the same
# names and turn them into account assignments. The groups themselves exist in
# the directory already; this cell assigns them, it does not create them.
#
# The identifier and reply URLs are the patterns the AWS console shows in the
# Change identity source wizard, with the instance ID replaced by a
# placeholder. SCIM endpoints and tokens are not here: they arrive through
# TF_VAR_scim_credentials (see the stack README).
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/entra-aws-federation/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-aws-federation"
}

inputs = {
  # -------------------------------------------------------------------------
  # Groups. Commercial accounts: 111111111111 prod, 222222222222 dev,
  # 333333333333 log archive. GovCloud accounts: 111111111111 prod,
  # 333333333333 log archive. Membership is managed in the directory and, for
  # the PlatformAdmin groups, through PIM for groups.
  # -------------------------------------------------------------------------
  aws_groups = [
    # Commercial
    "AWS-COM-111111111111-PlatformAdmin",
    "AWS-COM-111111111111-ReadOnly",
    "AWS-COM-111111111111-Billing",
    "AWS-COM-222222222222-PlatformAdmin",
    "AWS-COM-222222222222-PowerUser",
    "AWS-COM-222222222222-ReadOnly",
    "AWS-COM-333333333333-PlatformAdmin",
    "AWS-COM-333333333333-ReadOnly",

    # GovCloud
    "AWS-GOV-111111111111-PlatformAdmin",
    "AWS-GOV-111111111111-ReadOnly",
    "AWS-GOV-333333333333-PlatformAdmin",
    "AWS-GOV-333333333333-ReadOnly",
  ]

  targets = {
    # -----------------------------------------------------------------------
    # Commercial partition.
    # -----------------------------------------------------------------------
    commercial = {
      display_name    = "AWS IAM Identity Center (commercial)"
      partition_token = "COM"
      identifier_uris = ["https://us-east-1.signin.aws.amazon.com/platform/saml/d-0000000000"]
      reply_urls      = ["https://us-east-1.signin.aws.amazon.com/platform/saml/acs/d-0000000000"]
      sign_on_url     = "https://d-0000000000.awsapps.com/start"

      notification_email_addresses = ["iam-alerts@corp.example.com"]

      scim = {
        enabled = true
      }
    }

    # -----------------------------------------------------------------------
    # GovCloud (US) partition. The endpoints are in the aws-us-gov partition's
    # sign-in domain. The Entra tenant is the same commercial tenant;
    # provisioning crosses partitions over SCIM without any change on the
    # Entra side.
    # -----------------------------------------------------------------------
    govcloud = {
      display_name    = "AWS IAM Identity Center (GovCloud)"
      partition_token = "GOV"
      identifier_uris = ["https://us-gov-west-1.signin.amazonaws-us-gov.com/platform/saml/d-0000000000"]
      reply_urls      = ["https://us-gov-west-1.signin.amazonaws-us-gov.com/platform/saml/acs/d-0000000000"]
      sign_on_url     = "https://d-0000000000.awsapps.com/start"

      notification_email_addresses = ["iam-alerts@corp.example.com"]

      scim = {
        enabled = true
      }
    }
  }
}
