# Fragment of the workloads catalog cell beside it: the key_vaults map,
# included by terragrunt.hcl as include "key_vaults". One inputs attribute
# and nothing else; the header of terragrunt.hcl says why.

inputs = {
  # -------------------------------------------------------------------------
  # Key vaults. RBAC-only, purge protection, Deny firewall with public access
  # off: the module fixes that. Roles are the Key Vault data-plane menu.
  # -------------------------------------------------------------------------
  key_vaults = {
    app-secrets = {
      name               = "kv-example-app"
      resource_group_key = "app"

      log_analytics_workspace = {
        name                = "law-example-prod-activity"
        resource_group_name = "rg-example-baseline"
      }

      role_assignments = {
        ci-reads = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "ci-deploy" }
          description = "CI reads deployment secrets at release time."
        }
      }
    }
  }
}
