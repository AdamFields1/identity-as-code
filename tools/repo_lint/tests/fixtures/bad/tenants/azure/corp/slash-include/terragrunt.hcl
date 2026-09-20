# A fragment include whose path leaves the cell's directory.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "shared" {
  path = "../shared/values.hcl"
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
