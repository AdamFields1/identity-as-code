output "resource_groups" {
  description = "Map of resource group key to { id, name, location, locked }."
  value       = module.resource_groups.resource_groups
}

output "identities" {
  description = "Map of identity key to { id, name, principal_id (what roles are granted to), client_id (what a workflow passes to azure/login), tenant_id, resource_group_name, location }."
  value       = module.identities.identities
}

output "identity_client_ids" {
  description = "Map of identity key to client ID, for whoever fills in the workflow's client-id variable. Not a secret."
  value       = module.identities.client_ids
}

output "federated_credentials" {
  description = "Map of \"<identity key>/<credential key>\" to { id, name, identity_key, issuer, subject, audience }: the exact subject Entra will match against a workflow's token."
  value       = module.identities.federated_credentials
}

output "key_vaults" {
  description = "Map of vault key to { id, name, vault_uri, resource_group_name, location, public_network_access_enabled, diagnostics }."
  value       = module.key_vaults.key_vaults
}

output "key_vault_uris" {
  description = "Map of vault key to the vault's data-plane URI (https://<name>.vault.azure.net/), what a workload configures."
  value       = module.key_vaults.vault_uris
}

output "key_vault_role_assignments" {
  description = "Map of \"<vault key>/<assignment key>\" to { vault_key, role_name, principal_type, principal_name, principal_id }: what was granted to whom on each vault, resolved."
  value       = module.key_vaults.role_assignments
}

output "storage_accounts" {
  description = "Map of account key to { id, name, resource_group_name, location, primary_blob_endpoint, primary_dfs_endpoint, hierarchical_namespace_enabled, public_network_access_enabled, diagnostics }."
  value       = module.storage_accounts.storage_accounts
}

output "storage_containers" {
  description = "Map of \"<account key>/<container key>\" to { id, name, account_key, scope }, where scope is the container's Azure RBAC scope."
  value       = module.storage_accounts.containers
}

output "storage_role_assignments" {
  description = "Map of \"<account key>/<assignment key>\" to { account_key, container_key, role_name, principal_type, principal_name, principal_id, scope }: what was granted to whom, where, resolved."
  value       = module.storage_accounts.role_assignments
}

output "group_object_ids" {
  description = "Map of Entra group display name to object ID, for every group a vault or storage account role assignment named."
  value       = merge(module.key_vaults.group_object_ids, module.storage_accounts.group_object_ids)
}
