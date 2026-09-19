# fixture cell: no such stack.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/does-not-exist"
}

inputs = {
  name = "example"
}
