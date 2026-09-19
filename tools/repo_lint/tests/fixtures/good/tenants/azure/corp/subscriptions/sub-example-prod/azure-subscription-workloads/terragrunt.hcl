# fixture cell: sub workloads.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/azure-subscription-workloads"
}

# Ordering only. No outputs are read from the other cell.
dependencies {
  paths = ["../azure-subscription-baseline"]
}

inputs = {
  name = "rg-example-app"
}
