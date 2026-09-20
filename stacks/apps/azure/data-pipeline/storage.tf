# ---------------------------------------------------------------------------
# The lake. A hierarchical-namespace account (so versioning is off, which the
# module requires stated rather than assumed), two private containers, and
# Blob Data Contributor for the identity on each container, never on the
# account.
# ---------------------------------------------------------------------------

module "storage" {
  source = "../../../../modules/azure/storage-account"

  tags                   = local.tags
  identity_principal_ids = module.identities.principal_ids

  storage_accounts = {
    lake = {
      name                           = local.storage_account_name
      resource_group_name            = local.resource_group_name
      hierarchical_namespace_enabled = true
      blob_versioning_enabled        = false
      public_network_access_enabled  = local.public_network_access_enabled
      allowed_ip_ranges              = var.allowed_ip_ranges
      log_analytics_workspace        = var.log_analytics_workspace

      containers = {
        raw     = { name = "raw" }
        curated = { name = "curated" }
      }

      role_assignments = {
        pipeline-writes-raw = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "pipeline" }
          container_key = "raw"
          description   = "The ${var.app_name} pipeline lands source data in raw. Container scope: the account's other containers are not its to write."
        }
        pipeline-writes-curated = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "pipeline" }
          container_key = "curated"
          description   = "The ${var.app_name} pipeline writes its output to curated. Container scope: the account's other containers are not its to write."
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}
