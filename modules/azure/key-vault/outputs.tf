output "key_vaults" {
  description = "Map of logical key to { id, name, vault_uri, resource_group_name, location, public_network_access_enabled, diagnostics }."
  value = {
    for key, kv in azurerm_key_vault.this : key => {
      id                            = kv.id
      name                          = kv.name
      vault_uri                     = kv.vault_uri
      resource_group_name           = kv.resource_group_name
      location                      = kv.location
      public_network_access_enabled = kv.public_network_access_enabled
      diagnostics                   = contains(keys(azurerm_monitor_diagnostic_setting.this), key)
    }
  }
}

output "key_vault_ids" {
  description = "Map of logical key to vault resource ID, the scope of every role assignment on it."
  value       = { for key, kv in azurerm_key_vault.this : key => kv.id }
}

output "vault_uris" {
  description = "Map of logical key to the vault's data-plane URI (https://<name>.vault.azure.net/), what a workload configures."
  value       = { for key, kv in azurerm_key_vault.this : key => kv.vault_uri }
}

output "role_assignment_ids" {
  description = "Map of \"<vault key>/<assignment key>\" to the role assignment's resource ID."
  value       = { for key, a in azurerm_role_assignment.this : key => a.id }
}

output "role_assignments" {
  description = "Map of \"<vault key>/<assignment key>\" to { vault_key, role_name, principal_type, principal_name, principal_id }: what was granted to whom, resolved."
  value = {
    for key, a in azurerm_role_assignment.this : key => {
      vault_key      = local.role_assignments[key].vault_key
      role_name      = local.role_assignments[key].role_name
      principal_type = local.role_assignments[key].principal_type
      principal_name = local.role_assignments[key].principal_name
      principal_id   = a.principal_id
    }
  }
}

output "diagnostic_setting_ids" {
  description = "Map of logical key to the diagnostic setting's resource ID, for the vaults that name a workspace."
  value       = { for key, d in azurerm_monitor_diagnostic_setting.this : key => d.id }
}

output "group_object_ids" {
  description = "Map of Entra group display name to object ID, for every group a role assignment named."
  value       = { for name, g in data.azuread_group.by_display_name : name => g.object_id }
}
