# Partition locator for every cell under tenants/aws/commercial/.
#
# Not a cell: no include, no source, no inputs, and Terragrunt never runs it.

locals {
  partition = "aws"
  region    = "us-east-1"
}
