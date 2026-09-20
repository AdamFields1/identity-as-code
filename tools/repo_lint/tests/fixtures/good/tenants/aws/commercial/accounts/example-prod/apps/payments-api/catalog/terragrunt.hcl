# fixture cell: prod payments catalog, in fragments.
#
# Values only. No resources, no provider configuration, no logic. A cell of
# the account catalog stack beside the payments-api app cell, holding what
# that application alone uses. iam-roles.hcl and s3-buckets.hcl each hold
# one inputs attribute; Terragrunt merges them with the inputs below.

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
  source = "../../../../../../../../stacks/aws-account-workloads"
}

# Ordering only. The account catalog applies first.
dependencies {
  paths = ["../../../aws-account-workloads"]
}

inputs = {
  name = "payments-api-catalog"
}
