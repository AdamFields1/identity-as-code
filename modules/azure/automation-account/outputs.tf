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

output "identities" {
  description = "Map of tier key to the identity's id, name, principal_id (the principal Graph app roles are granted to), and client_id (what a runbook passes to the Automation identity endpoint). The single-identity form has one entry, keyed \"default\"."
  value = {
    for key, identity in azurerm_user_assigned_identity.this : key => {
      id           = identity.id
      name         = identity.name
      principal_id = identity.principal_id
      client_id    = identity.client_id
    }
  }
}

output "identity_id" {
  description = "Resource ID of the \"default\" identity, or null when the account has tiers and none is keyed \"default\"."
  value       = try(azurerm_user_assigned_identity.this["default"].id, null)
}

output "identity_name" {
  description = "Name of the \"default\" identity, which is also its service principal display name in Entra, or null when there is no such key."
  value       = try(azurerm_user_assigned_identity.this["default"].name, null)
}

output "identity_principal_id" {
  description = "Object ID of the \"default\" identity's service principal, or null when there is no such key. Per-tier values are in identities."
  value       = try(azurerm_user_assigned_identity.this["default"].principal_id, null)
}

output "identity_client_id" {
  description = "Client ID of the \"default\" identity, or null when there is no such key. Per-tier values are in identities."
  value       = try(azurerm_user_assigned_identity.this["default"].client_id, null)
}

output "variable_names" {
  description = "Names of the account variables created, by type."
  value = {
    string = keys(azurerm_automation_variable_string.this)
    bool   = keys(azurerm_automation_variable_bool.this)
  }
}
