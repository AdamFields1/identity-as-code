# fixture cell: prod workloads.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-workloads"
}

inputs = {
  name = "example-prod-artifacts"
}
