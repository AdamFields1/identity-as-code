# Partition locator for every cell under tenants/aws/commercial/.
#
# Not a cell: no include, no source, no inputs, and Terragrunt never runs it.
# tenants/aws/root.hcl finds it with find_in_parent_folders("partition.hcl")
# from whichever cell is being planned and uses it for two things: the
# region for a stack that the cell does not set itself, and a guard that an
# account cell sits under a partition it can name. The workflows read it
# too, for the ARN partition of an account cell's deployment role
# (arn:<partition>:iam::<account_id>:role/<TG_AWS_DEPLOY_ROLE_NAME>), which
# they write into the account's profile on the runner. See docs/adr/0017.
#
# partition is the ARN partition, not a display name: "aws" here,
# "aws-us-gov" in ../govcloud/partition.hcl. region is the partition's default
# region for account cells; the Identity Center cell sets its own because that
# region is the address of the instance, and a cell's value wins.

locals {
  partition = "aws"
  region    = "us-east-1"
}
