# fixture cell: a directory name a workflow could not use.
#
# The file is a well-formed cell; only its directory name is wrong, so the
# one finding it earns is path-characters.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
