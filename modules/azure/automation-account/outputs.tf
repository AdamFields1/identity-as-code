output "automation_account_id" {
  description = "Resource ID of the Automation account."
  value       = azurerm_automation_account.this.id
}

output "automation_account_name" {
  description = "Name of the Automation account, for the runbooks module."
  value       = azurerm_automation_account.this.name
}

output "resource_group_name" {
  description = "Resource group the account lives in."
  value       = data.azurerm_resource_group.this.name
}

output "location" {
  description = "Region the account and identity were created in."
  value       = local.location
}

output "identity_id" {
  description = "Resource ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.this.id
}

output "identity_name" {
  description = "Name of the user-assigned managed identity, which is also its service principal display name in Entra."
  value       = azurerm_user_assigned_identity.this.name
}

output "identity_principal_id" {
  description = "Object ID of the identity's service principal. This is the principal Graph app roles are granted to."
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "identity_client_id" {
  description = "Client ID of the identity. Runbooks pass it to the Automation identity endpoint as client_id."
  value       = azurerm_user_assigned_identity.this.client_id
}

output "variable_names" {
  description = "Names of the account variables created, by type."
  value = {
    string = keys(azurerm_automation_variable_string.this)
    bool   = keys(azurerm_automation_variable_bool.this)
  }
}
