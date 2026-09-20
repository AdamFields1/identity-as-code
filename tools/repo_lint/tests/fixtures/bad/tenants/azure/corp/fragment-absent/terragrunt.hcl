# A fragment include naming a sibling file that does not exist.

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
