# The family root included twice, under two labels.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "again" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
