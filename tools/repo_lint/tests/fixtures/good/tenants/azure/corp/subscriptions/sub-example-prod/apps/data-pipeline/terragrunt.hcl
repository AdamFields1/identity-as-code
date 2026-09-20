# fixture cell: sub app.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/azure/data-pipeline"
}

inputs = {
  name = "sales-etl"
}
