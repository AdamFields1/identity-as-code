# ---------------------------------------------------------------------------
# The registry. AcrPull for the runtime identity, AcrPush for the publisher,
# and nothing for anyone else: no admin user, no anonymous pull, and no
# group holds a role here. An operator who must delete an image does so with
# PIM-activated access, or a later change adds an AcrDelete assignment to a
# PIM-governed group here, reviewed as one.
# ---------------------------------------------------------------------------

module "registries" {
  source = "../../../../modules/azure/container-registry"

  tags                   = local.tags
  identity_principal_ids = module.identities.principal_ids

  container_registries = {
    orders-api = {
      name                          = local.container_registry_name
      resource_group_name           = local.resource_group_name
      sku                           = var.registry_sku
      public_network_access_enabled = true
      allowed_ip_ranges             = local.registry_allowed_ip_ranges
      retention_policy_in_days      = var.registry_retention_days
      log_analytics_workspace       = var.log_analytics_workspace

      role_assignments = {
        runtime-pulls = {
          role_name   = "AcrPull"
          principal   = { type = "identity", name = "runtime" }
          description = "The ${var.app_name} container pulls its image at start-up. Pull only: it cannot push, delete, or sign."
        }
        publisher-pushes = {
          role_name   = "AcrPush"
          principal   = { type = "identity", name = "publisher" }
          description = "The ${var.app_name} release workflow pushes the image it built. Push includes pull; it cannot delete or sign, and it holds nothing on the vault or the group."
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}
