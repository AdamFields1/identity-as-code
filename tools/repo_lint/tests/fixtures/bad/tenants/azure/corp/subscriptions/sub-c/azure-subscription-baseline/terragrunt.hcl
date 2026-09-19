# fixture cell: sub-c baseline.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
