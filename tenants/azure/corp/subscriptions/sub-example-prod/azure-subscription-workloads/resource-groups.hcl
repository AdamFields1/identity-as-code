# Fragment of the workloads catalog cell beside it: the resource_groups
# map, included by terragrunt.hcl as include "resource_groups". One inputs
# attribute and nothing else; the header of terragrunt.hcl says why.

inputs = {
  # -------------------------------------------------------------------------
  # Resource groups. Keys are what the other maps name in resource_group_key.
  # -------------------------------------------------------------------------
  resource_groups = {
    app = {
      name        = "rg-example-app"
      delete_lock = true
    }
  }
}
