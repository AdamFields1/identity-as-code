# fixture cell: bad source.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../modules/azure/unlisted-module"
}

inputs = {
  name = "example"
}
