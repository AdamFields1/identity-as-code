output "resource_group_name" {
  description = "Name of the pipeline's resource group (rg-<app_name>-<environment>)."
  value       = module.resource_groups.resource_group_names["app"]
}

output "resource_group_id" {
  description = "Resource ID of the pipeline's resource group, the scope of the identity's Reader assignment."
  value       = module.resource_groups.resource_group_ids["app"]
}

output "identity_name" {
  description = "Name of the pipeline's managed identity, which is also its service principal's display name in Entra."
  value       = module.identities.identities["pipeline"].name
}

output "identity_client_id" {
  description = "Client ID of the pipeline's managed identity: what the workflow passes to azure/login as client-id. Not a secret."
  value       = module.identities.client_ids["pipeline"]
}

output "identity_principal_id" {
  description = "Service principal object ID of the pipeline's managed identity: the principal every role assignment here is made to, and what a grant made outside this repository would name."
  value       = module.identities.principal_ids["pipeline"]
}

output "federated_credential_subject" {
  description = "The exact subject Entra will match on the workflow's OIDC token (repo:<organization>/<repository>:environment:<github_environment>), for checking against a failed login."
  value       = module.identities.federated_credentials["pipeline/github"].subject
}

output "key_vault_name" {
  description = "Name of the pipeline's vault (kv-<app_name>-<environment>)."
  value       = module.key_vaults.key_vaults["secrets"].name
}

output "key_vault_uri" {
  description = "Data-plane URI of the pipeline's vault (https://<name>.vault.azure.net/), what the pipeline configures."
  value       = module.key_vaults.vault_uris["secrets"]
}

output "storage_account_name" {
  description = "Name of the pipeline's data lake account (st<app_name without hyphens><environment>)."
  value       = module.storage.storage_accounts["lake"].name
}

output "storage_dfs_endpoint" {
  description = "Data Lake Storage Gen2 endpoint of the account (https://<name>.dfs.core.windows.net/), what the pipeline configures for directory and file operations."
  value       = module.storage.storage_accounts["lake"].primary_dfs_endpoint
}

output "container_names" {
  description = "Map of container key (raw, curated) to container name in the lake."
  value = {
    raw     = module.storage.containers["lake/raw"].name
    curated = module.storage.containers["lake/curated"].name
  }
}

output "role_assignment_ids" {
  description = "Map of \"<where>/<assignment key>\" to role assignment resource ID for every assignment this stack made to the identity: key-vault/..., storage/lake/..., and resource-group/..."
  value = merge(
    { for key, id in module.key_vaults.role_assignment_ids : "key-vault/${key}" => id },
    { for key, id in module.storage.role_assignment_ids : "storage/${key}" => id },
    { for key, id in module.identity_rbac.assignment_ids : "resource-group/${key}" => id },
  )
}
