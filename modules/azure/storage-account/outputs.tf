output "storage_accounts" {
  description = "Map of logical key to { id, name, resource_group_name, location, primary_blob_endpoint, primary_dfs_endpoint, hierarchical_namespace_enabled, public_network_access_enabled, diagnostics }."
  value = {
    for key, sa in azurerm_storage_account.this : key => {
      id                             = sa.id
      name                           = sa.name
      resource_group_name            = sa.resource_group_name
      location                       = sa.location
      primary_blob_endpoint          = sa.primary_blob_endpoint
      primary_dfs_endpoint           = sa.primary_dfs_endpoint
      hierarchical_namespace_enabled = sa.is_hns_enabled
      public_network_access_enabled  = sa.public_network_access_enabled
      diagnostics                    = contains(keys(azurerm_monitor_diagnostic_setting.blob), key)
    }
  }
}

output "storage_account_ids" {
  description = "Map of logical key to storage account resource ID, the scope of an account-level role assignment."
  value       = { for key, sa in azurerm_storage_account.this : key => sa.id }
}

output "primary_blob_endpoints" {
  description = "Map of logical key to the account's blob endpoint (https://<name>.blob.core.windows.net/), what a workload configures."
  value       = { for key, sa in azurerm_storage_account.this : key => sa.primary_blob_endpoint }
}

output "containers" {
  description = "Map of \"<account key>/<container key>\" to { id, name, account_key, scope }, where scope is the container's Azure RBAC scope."
  value = {
    for key, c in azurerm_storage_container.this : key => {
      id          = c.id
      name        = c.name
      account_key = local.containers[key].account_key
      scope       = local.container_scopes[key]
    }
  }
}

output "role_assignment_ids" {
  description = "Map of \"<account key>/<assignment key>\" to the role assignment's resource ID."
  value       = { for key, a in azurerm_role_assignment.this : key => a.id }
}

output "role_assignments" {
  description = "Map of \"<account key>/<assignment key>\" to { account_key, container_key, role_name, principal_type, principal_name, principal_id, scope }: what was granted to whom, where, resolved."
  value = {
    for key, a in azurerm_role_assignment.this : key => {
      account_key    = local.role_assignments[key].account_key
      container_key  = local.role_assignments[key].container_key
      role_name      = local.role_assignments[key].role_name
      principal_type = local.role_assignments[key].principal_type
      principal_name = local.role_assignments[key].principal_name
      principal_id   = a.principal_id
      scope          = a.scope
    }
  }
}

output "diagnostic_setting_ids" {
  description = "Map of logical key to the blob service diagnostic setting's resource ID, for the accounts that name a workspace."
  value       = { for key, d in azurerm_monitor_diagnostic_setting.blob : key => d.id }
}

output "group_object_ids" {
  description = "Map of Entra group display name to object ID, for every group a role assignment named."
  value       = { for name, g in data.azuread_group.by_display_name : name => g.object_id }
}
