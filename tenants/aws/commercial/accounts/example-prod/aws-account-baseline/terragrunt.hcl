# AWS commercial partition, account example-prod: account baseline cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Which account this is, and which partition, is not in this file. The
# account locator beside this cell (../account.hcl) and the partition locator
# above it (../../../partition.hcl) address it: tenants/aws/root.hcl turns
# them into the provider's allowed_account_ids and the profile that names the
# account's deployment role, and the stack discovers the account, the
# partition, and the region from the credentials it is given. region is not set here either; partition.hcl supplies
# us-east-1. See docs/adr/0017.
#
# Every switch in the stack defaults to on except GuardDuty, so this cell
# turns GuardDuty on and otherwise names only what the stack cannot choose
# for it: the bucket the trail writes to and the second bucket that receives
# that bucket's access logs (CIS AWS Foundations 3.6). Password policy, EBS
# encryption by default, S3 Block Public Access, and Access Analyzer keep
# the module defaults. diff this file against
# ../../example-dev/aws-account-baseline/terragrunt.hcl for what is weaker
# in dev.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/aws-account-baseline/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-baseline"
}

inputs = {
  # -------------------------------------------------------------------------
  # GuardDuty. Off in the stack default because a detector, once on, cannot
  # be turned off again without lifting prevent_destroy (its findings would
  # go with it). On in prod, and stays on.
  # -------------------------------------------------------------------------
  guardduty = {
    enabled                      = true
    finding_publishing_frequency = "FIFTEEN_MINUTES"
  }

  # -------------------------------------------------------------------------
  # The trail. Bucket names are global, so the cell chooses them. Log objects
  # are kept (no expiration): the trail is the account's audit record. The
  # access log bucket expires its objects after the stack default of 400
  # days. No role is named as a key user: the account root statement the key
  # module always writes lets an IAM policy grant kms:Decrypt to whichever
  # role reads the logs, and that grant is reviewed with the role.
  # -------------------------------------------------------------------------
  cloudtrail = {
    bucket_name            = "example-prod-cloudtrail"
    access_log_bucket_name = "example-prod-cloudtrail-access-logs"
  }

  tags = {
    owner       = "platform"
    cost_centre = "cc-1111"
  }
}
