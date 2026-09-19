output "identities" {
  description = "Map of logical key to { id, name, principal_id (the object ID roles are granted to), client_id (what a workflow passes to azure/login), tenant_id, resource_group_name, location }."
  value = {
    for key, identity in azurerm_user_assigned_identity.this : key => {
      id                  = identity.id
      name                = identity.name
      principal_id        = identity.principal_id
      client_id           = identity.client_id
      tenant_id           = identity.tenant_id
      resource_group_name = identity.resource_group_name
      location            = identity.location
    }
  }
}

output "principal_ids" {
  description = "Map of logical key to the identity's service principal object ID. This is the shape the key-vault and storage-account modules take as identity_principal_ids."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.principal_id }
}

output "client_ids" {
  description = "Map of logical key to the identity's client ID, for the workflow's client-id input. Not a secret."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.client_id }
}

output "identity_ids" {
  description = "Map of logical key to the identity's resource ID, for a resource that attaches the identity (identity_ids on an Automation account, a Function App, and the like)."
  value       = { for key, identity in azurerm_user_assigned_identity.this : key => identity.id }
}

output "federated_credentials" {
  description = "Map of \"<identity key>/<credential key>\" to { id, name, identity_key, issuer, subject, audience }: the exact subject Entra will match, for checking against the workflow's token."
  value = {
    for key, credential in azurerm_federated_identity_credential.this : key => {
      id           = credential.id
      name         = credential.name
      identity_key = local.federated_credentials[key].identity_key
      issuer       = credential.issuer
      subject      = credential.subject
      audience     = credential.audience[0]
    }
  }
}
