# fixture cell: prod payments.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/apps/aws/payments-api"
}

inputs = {
  name = "payments-api"
}
