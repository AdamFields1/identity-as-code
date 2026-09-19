# fixture cell: corp roles.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-rbac-roles"
}

inputs = {
  name = "Platform Operator"
}
