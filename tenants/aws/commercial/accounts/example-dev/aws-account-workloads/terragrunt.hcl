# AWS commercial partition, account example-dev: workloads catalog cell.
#
# Values only. Same stack as ../../example-prod/aws-account-workloads, with
# the smallest menu a workload account can have: one role for the example
# application's EC2 instances and one bucket they read and write. What prod
# has that dev does not, and why:
#   - no CI deployer role: developers publish to the bucket with their own
#     Identity Center access (AWS-COM-222222222222-PowerUser)
#   - no customer managed key: the bucket is SSE-S3
#   - no allow list on the bucket, for the same reason as the first point;
#     the TLS-only statement, versioning, and the public access blocks are
#     the module's and still apply
#   - no access logging, and objects expire after 90 days
#
# The account and the partition are the tree, not values: ../account.hcl and
# ../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). See docs/adr/0017.
#
# The cell is written as fragments so it reads like the console: this file
# holds the includes, the source, and the tags, and each map lives in the
# sibling file named for it (iam-roles.hcl, s3-buckets.hcl), an inputs
# attribute and nothing else. Terragrunt merges every include's inputs into
# one map, so the stack sees the same values it would see from one file.
# No kms-keys.hcl, because this cell has no key.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-dev/aws-account-workloads/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "iam_roles" {
  path = "iam-roles.hcl"
}

include "s3_buckets" {
  path = "s3-buckets.hcl"
}

terraform {
  source = "../../../../../../stacks/aws-account-workloads"
}

inputs = {
  tags = {
    owner       = "example-app"
    cost_centre = "cc-2222"
  }
}
