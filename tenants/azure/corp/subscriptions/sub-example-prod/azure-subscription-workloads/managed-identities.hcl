# Fragment of the workloads catalog cell beside it: the identities map,
# included by terragrunt.hcl as include "managed_identities". One inputs
# attribute and nothing else; the header of terragrunt.hcl says why.

inputs = {
  # -------------------------------------------------------------------------
  # Identities. The subject is built by the module from organization,
  # repository, and environment; no secret exists. Keys are what a role
  # assignment names in principal.name with type = "identity".
  # -------------------------------------------------------------------------
  identities = {
    ci-deploy = {
      name               = "id-example-app-ci"
      resource_group_key = "app"

      federated_credentials = {
        prod = {
          organization = "example-org"
          repository   = "example-app"
          environment  = "prod"
        }
      }
    }
  }
}
