# Two includes, the second without a label: Terragrunt labels every include
# of a file that has more than one.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include {
  path = "extra.hcl"
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
