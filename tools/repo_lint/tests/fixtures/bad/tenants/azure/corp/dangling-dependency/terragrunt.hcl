# fixture cell: a dependency path that resolves to no cell.
#
# The shape is otherwise correct. The dependencies block names a directory
# that does not exist, which is what a cell left behind by a moved neighbour
# looks like: the path was right before the move and one level short after.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

dependencies {
  paths = ["../azure-subscription-baseline"]
}

inputs = {
  name = "example"
}
