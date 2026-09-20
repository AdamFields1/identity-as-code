output "resource_group_name" {
  description = "Name of the application's resource group (rg-<app_name>-<environment>), where the Container Apps environment and the app are usually deployed too."
  value       = module.resource_groups.resource_group_names["app"]
}

output "runtime_identity_name" {
  description = "Name of the runtime identity (id-<app_name>-<environment>), which is also its service principal's display name in Entra: what the container runs as."
  value       = module.identities.identities["runtime"].name
}

output "runtime_identity_id" {
  description = "Resource ID of the runtime identity: what the Container App's identity block and its registries and secrets entries name (README, \"Consuming the outputs\")."
  value       = module.identities.identity_ids["runtime"]
}

output "runtime_identity_client_id" {
  description = "Client ID of the runtime identity: what the application passes to DefaultAzureCredential as its managed identity client ID when the app holds more than one identity. Not a secret."
  value       = module.identities.client_ids["runtime"]
}

output "runtime_identity_principal_id" {
  description = "Service principal object ID of the runtime identity: the principal the AcrPull and Secrets User assignments are made to, and what a grant made outside this repository would name."
  value       = module.identities.principal_ids["runtime"]
}

output "publisher_identity_client_id" {
  description = "Client ID of the publisher identity: what the release workflow passes to azure/login as client-id before it pushes. Not a secret."
  value       = module.identities.client_ids["publisher"]
}

output "publisher_federated_credential_subject" {
  description = "The exact subject Entra will match on the release workflow's OIDC token (repo:<organization>/<repository>:environment:<publisher_github_environment>), for checking against a failed login."
  value       = module.identities.federated_credentials["publisher/github"].subject
}

output "container_registry_name" {
  description = "Name of the application's registry (cr<app_name without hyphens><environment>), what az acr login names."
  value       = module.registries.container_registries["orders-api"].name
}

output "container_registry_login_server" {
  description = "Login server of the registry (<name>.azurecr.io), the host of every image reference and the server the Container App's registries entry names."
  value       = module.registries.login_servers["orders-api"]
}

output "key_vault_name" {
  description = "Name of the application's vault (kv-<app_name>-<environment>)."
  value       = module.key_vaults.key_vaults["secrets"].name
}

output "key_vault_uri" {
  description = "Data-plane URI of the application's vault (https://<name>.vault.azure.net/), the prefix of every keyVaultUrl the Container App's secrets entries name."
  value       = module.key_vaults.vault_uris["secrets"]
}

output "role_assignment_ids" {
  description = "Map of \"<where>/<assignment key>\" to role assignment resource ID for every assignment this stack made: container-registry/orders-api/... and key-vault/secrets/.... All three are data-plane roles; nothing is assigned on the group."
  value = merge(
    { for key, id in module.registries.role_assignment_ids : "container-registry/${key}" => id },
    { for key, id in module.key_vaults.role_assignment_ids : "key-vault/${key}" => id },
  )
}
