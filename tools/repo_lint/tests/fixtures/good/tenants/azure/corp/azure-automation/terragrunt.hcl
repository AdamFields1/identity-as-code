# fixture cell: corp automation.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-automation"
}

# Ordering only. No outputs are read from the other cell.
dependencies {
  paths = ["../azure-rbac-roles"]
}

inputs = {
  name = "aa-example-iam"
}
