# Fragment of the workloads catalog cell beside it: the storage_accounts
# map, included by terragrunt.hcl as include "storage_accounts". One inputs
# attribute and nothing else; the header of terragrunt.hcl says why.

inputs = {
  # -------------------------------------------------------------------------
  # Storage accounts. No shared keys, TLS 1.2, private containers, Deny
  # firewall: the module fixes that. The writer is scoped to one container;
  # the readers are a PIM-governed group named as it appears in Entra.
  # -------------------------------------------------------------------------
  storage_accounts = {
    app-artifacts = {
      name               = "stexampleapp"
      resource_group_key = "app"

      containers = {
        releases = { name = "releases" }
      }

      log_analytics_workspace = {
        name                = "law-example-prod-activity"
        resource_group_name = "rg-example-baseline"
      }

      role_assignments = {
        ci-writes-releases = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "ci-deploy" }
          container_key = "releases"
          description   = "CI publishes release artifacts and nothing else."
        }

        engineers-read = {
          role_name   = "Storage Blob Data Reader"
          principal   = { type = "group", name = "Cloud Engineers" }
          description = "Engineers read artifacts; the group is PIM-governed."
        }
      }
    }
  }
}
