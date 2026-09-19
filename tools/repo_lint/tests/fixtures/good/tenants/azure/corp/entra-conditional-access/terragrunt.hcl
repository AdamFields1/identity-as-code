# fixture cell: corp ca.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/entra-conditional-access"
}

inputs = {
  name = "CA001 Require MFA"
}
