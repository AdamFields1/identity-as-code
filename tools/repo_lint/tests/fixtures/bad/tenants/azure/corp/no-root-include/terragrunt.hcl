# An include, but not of the family root: only a fragment is included.

include "values" {
  path = "values.hcl"
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}
