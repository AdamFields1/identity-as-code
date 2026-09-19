# fixture cell: commercial idc.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/aws-identity-center"
}

inputs = {
  name   = "AWS-COM-111111111111-Admin"
  region = "us-east-1"
}
