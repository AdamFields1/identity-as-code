# fixture cell: corp pim.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-pim-governance"
}

# Ordering only. No outputs are read from the other cell.
dependencies {
  paths = ["../azure-rbac-roles"]
}

inputs = {
  name = "Platform Operator"
}
