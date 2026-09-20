# The cell is well formed; its fragment holds no inputs (see empty.hcl).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "empty" {
  path = "empty.hcl"
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
