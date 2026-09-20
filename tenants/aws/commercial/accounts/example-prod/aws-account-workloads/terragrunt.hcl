# AWS commercial partition, account example-prod: workloads catalog cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module or an app stack
# (docs/adr/0017), never in a looser entry here.
#
# The account and the partition are the tree, not values: ../account.hcl and
# ../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). Nothing below is an ID, an ARN, or
# a policy document: roles, keys, and buckets name each other by name or by
# map key, and the stack builds every ARN from the partition it discovers.
#
# The cell is written as fragments so it reads like the console: this file
# holds the includes, the source, and the tags, and each map lives in the
# sibling file named for it (iam-roles.hcl, kms-keys.hcl, s3-buckets.hcl),
# an inputs attribute and nothing else. Terragrunt merges every include's
# inputs into one map, so the stack sees the same values it would see from
# one file.
#
# What this cell holds, and how the entries refer to each other:
#   - three roles: the example application's EC2 instances (an instance
#     profile is created because the trust is ec2), and its CI deployer,
#     trusted from one GitHub repository's main branch and production
#     environment through the account's OIDC provider; and the data
#     platform's reference data publisher, trusted from a second
#     repository's production environment through the same provider
#   - one key, whose users are the example application's two roles
#   - four buckets: the artifacts and the configuration the deployer
#     publishes and the instances read, both encrypted with the key and
#     closed to every other role; the reference data the publisher writes
#     and app stacks read; and the bucket the other three log access to
# The stack checks the wiring at plan: a role granted a bucket is on that
# bucket's allow list and, where the bucket is under a key of this cell, on
# that key's user list. A role or bucket that is not is a refused plan, not
# an AccessDenied at the first request.
#
# One pair of entries belongs to an application team rather than to the
# example application, and it shows one of the two doors a resource an app
# needs comes through when it does not live in the app's own stack. The
# reference data bucket is shared and consumed: its publisher is a role of
# this cell, and its readers are named in their own stacks (the orders-api
# task role, through that stack's reference_bucket_names knob), each of
# which builds the bucket ARN from the name and grants itself the read. It
# stays here because more than one application reads it. The other door is
# the app-scoped catalog cell: the orders team's load-test runner and its
# results bucket used to live here under the team's owner tag, and moved to
# ../apps/orders-api/catalog because that application alone uses them, so
# the entries sit beside the app they serve and carry only its owner. The
# direction rule in one sentence: within an account the baseline is applied
# first, then this cell, then the app stacks, so an app stack may name a
# bucket of this cell by name, and an entry here never names a role an app
# stack creates.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/aws-account-workloads/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "iam_roles" {
  path = "iam-roles.hcl"
}

include "kms_keys" {
  path = "kms-keys.hcl"
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
