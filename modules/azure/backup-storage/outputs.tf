output "storage_account_id" {
  description = "Resource ID of the storage account."
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  description = "Name of the storage account, for the backup runbook's storageaccountname parameter."
  value       = azurerm_storage_account.this.name
}

output "container_name" {
  description = "Name of the backup container, for the backup runbook's containername parameter."
  value       = azurerm_storage_container.this.name
}

output "container_scope" {
  description = "Azure RBAC scope of the backup container."
  value       = local.container_scope
}

output "primary_blob_endpoint" {
  description = "Blob service endpoint of the account."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "writer_role_assignment_ids" {
  description = "Map of writer key to the resource ID of that principal's Storage Blob Data Contributor assignment on the container."
  value       = { for key, assignment in azurerm_role_assignment.writer : key => assignment.id }
}

output "management_policy_id" {
  description = "Resource ID of the lifecycle management policy that deletes previous blob versions."
  value       = azurerm_storage_management_policy.this.id
}
