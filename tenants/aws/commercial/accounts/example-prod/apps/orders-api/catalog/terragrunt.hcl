# AWS commercial partition, account example-prod: the orders-api app's
# catalog cell.
#
# Values only. No resources, no provider configuration, no logic. This is a
# cell of the account catalog stack (stacks/aws-account-workloads), the same
# stack as ../../../aws-account-workloads, placed beside the orders-api app
# cell because what it holds belongs to that application alone. It is the
# first of the two doors a resource an app needs comes through when it does
# not live in the app's own stack (docs/adr/0017): a catalog shape, owned by
# the app team, in a state file of its own.
#
# What this cell holds: the orders team's load-test runner role, the results
# bucket it writes, and the bucket that receives the results bucket's access
# logs. The runner and the results bucket used to be two team-tagged entries
# in the account catalog. They live here because they are app-owned and no
# identity of the orders-api stack touches them: the runner is the only
# reader and writer, the app's task roles never read the results, and no
# entry of the account catalog is shared with them. Moving them out leaves
# the account catalog holding what is shared (the reference data bucket and
# its publisher) and gives the orders team a cell to diff that is theirs.
#
# Three rules make an app-scoped catalog cell:
#   - It holds only what the application alone uses, and its tags name the
#     application's owner, so the catalog says who every entry is for. An
#     entry another team or another app reads belongs in the account
#     catalog (../../../aws-account-workloads), not here.
#   - It never names a resource the app stack creates. The direction rule of
#     the account catalog applies unchanged: this cell is applied before
#     ../terragrunt.hcl, so an allow list naming the orders-api task role
#     would fail the first release. The app cell may name a bucket of this
#     cell by name; this cell names nothing of the app.
#   - It depends on the account catalog. The dependencies block below orders
#     this cell after ../../../aws-account-workloads, so a key or bucket of
#     the account's that an entry here names by alias or by name exists when
#     this cell is applied.
#
# The cell is written as fragments so it reads like the console: this file
# holds the includes, the source, the dependency, and the cell's tags;
# iam-roles.hcl holds service_roles and s3-buckets.hcl holds buckets, each
# an inputs block with one map and the comments that explain its entries.
# Terragrunt merges every include's inputs into one map, so the stack sees
# the same inputs it would from a single file. A fragment is not a cell: no
# include, no source, and Terragrunt never runs it on its own.
#
# One consequence of the stack's rules: a bucket may log access only to a
# bucket of the same cell, so the results bucket cannot log to the account
# catalog's example-prod-access-logs, and this cell carries an access-log
# bucket of its own. And one harmless side effect of the placement: when
# the parent app cell (../terragrunt.hcl) runs, Terragrunt copies its
# directory into that cell's working copy, this folder included (never the
# catalog's .terragrunt-cache). Terraform ignores a subdirectory, so nothing
# is planned twice.
#
# The account and the partition are the tree, not values: ../../../account.hcl
# and ../../../../../partition.hcl address this cell through
# tenants/aws/root.hcl, which also supplies region (us-east-1). Nothing here
# is an ID, an ARN, or a policy document: the role and the buckets name each
# other by name or by map key, and the stack builds every ARN from the
# partition it discovers.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/apps/orders-api/catalog/terraform.tfstate

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

# The account catalog applies first. Nothing here names one of its entries
# today, but the order is the rule, not the current contents: an entry of
# this cell that names a key of the account's by alias or a bucket of the
# account's by name must find it already there.
dependencies {
  paths = ["../../../aws-account-workloads"]
}

inputs = {
  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
