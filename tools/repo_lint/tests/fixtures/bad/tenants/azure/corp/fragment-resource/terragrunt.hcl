# The cell is well formed; its fragment is not (see values.hcl).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "values" {
  path = "values.hcl"
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
