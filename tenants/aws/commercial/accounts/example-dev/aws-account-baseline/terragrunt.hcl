# AWS commercial partition, account example-dev: account baseline cell.
#
# Values only. Same stack as ../../example-prod/aws-account-baseline; the
# differences below are the whole story of "what is weaker in dev":
#   - GuardDuty stays off (the stack default). Findings for a developer
#     account are noise nobody triages, and a detector once on cannot be
#     turned off again without lifting prevent_destroy.
#   - no second bucket for the trail bucket's access logs
#   - trail log objects expire after 400 days instead of being kept
# Everything else is the module default: 14-character passwords rotated
# every 90 days, EBS encryption by default, S3 Block Public Access at the
# account, Access Analyzer, and a multi-region validated trail under its own
# key.
#
# The account and the partition are the tree, not values: ../account.hcl and
# ../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). See docs/adr/0017.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-dev/aws-account-baseline/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-baseline"
}

inputs = {
  guardduty = {
    enabled = false
  }

  cloudtrail = {
    bucket_name         = "example-dev-cloudtrail"
    log_expiration_days = 400
  }

  tags = {
    owner       = "platform"
    cost_centre = "cc-1111"
  }
}
