# Partition locator for every cell under tenants/aws/govcloud/.
#
# Not a cell: no include, no source, no inputs, and Terragrunt never runs it.

locals {
  partition = "aws-us-gov"
  region    = "us-gov-west-1"
}
