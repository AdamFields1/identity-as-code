# fixture cell: govcloud idc.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/aws-identity-center"
}

inputs = {
  name   = "AWS-GOV-111111111111-Admin"
  region = "us-gov-west-1"
}
