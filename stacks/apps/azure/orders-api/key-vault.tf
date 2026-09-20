# ---------------------------------------------------------------------------
# The vault. Secrets User for the runtime identity, and nothing for anyone
# else: the people who set secrets bring their own PIM-activated access, and
# the publisher has no business reading them.
# ---------------------------------------------------------------------------

module "key_vaults" {
  source = "../../../../modules/azure/key-vault"

  tags                   = local.tags
  identity_principal_ids = module.identities.principal_ids

  key_vaults = {
    secrets = {
      name                          = local.key_vault_name
      resource_group_name           = local.resource_group_name
      public_network_access_enabled = local.vault_public_network_access_enabled
      allowed_ip_ranges             = var.allowed_ip_ranges
      log_analytics_workspace       = var.log_analytics_workspace

      role_assignments = {
        runtime-reads-secrets = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "runtime" }
          description = "The ${var.app_name} container reads its secrets by name at start-up and at run time. Read only: it cannot list, set, or delete them."
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}
