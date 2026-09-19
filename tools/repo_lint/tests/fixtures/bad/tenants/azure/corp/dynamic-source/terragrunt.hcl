# fixture cell: dynamic source.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/${local.name}"
}

inputs = {
  name = "example"
}
