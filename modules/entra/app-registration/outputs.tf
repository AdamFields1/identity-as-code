output "applications" {
  description = "Map of logical key to { object_id, client_id, display_name, service_principal_object_id }."
  value = {
    for k, a in azuread_application.this : k => {
      object_id                   = a.object_id
      client_id                   = a.client_id
      display_name                = a.display_name
      service_principal_object_id = azuread_service_principal.this[k].object_id
    }
  }
}

output "client_ids" {
  description = "Map of logical key to application (client) ID."
  value       = { for k, a in azuread_application.this : k => a.client_id }
}

output "service_principal_object_ids" {
  description = "Map of logical key to service principal object ID."
  value       = { for k, sp in azuread_service_principal.this : k => sp.object_id }
}

output "federated_credential_ids" {
  description = "Map of \"app/credential\" key to federated identity credential ID."
  value       = { for k, c in azuread_application_federated_identity_credential.this : k => c.credential_id }
}

output "graph_app_role_assignment_ids" {
  description = "Map of \"app/role\" key to enforced Graph app-role assignment ID."
  value       = { for k, r in azuread_app_role_assignment.graph : k => r.id }
}
