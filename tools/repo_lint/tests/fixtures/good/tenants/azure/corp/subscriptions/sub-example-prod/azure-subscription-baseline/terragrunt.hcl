# fixture cell: sub baseline.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/azure-subscription-baseline"
}

inputs = {
  name = "rg-example-baseline"
}
