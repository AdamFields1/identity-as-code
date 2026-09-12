output "group_ids" {
  description = "Map of security group key to object ID."
  value       = module.security_groups.group_ids
}

output "applications" {
  description = "Map of application key to { object_id, client_id, display_name, service_principal_object_id }."
  value       = module.app_registrations.applications
}

output "client_ids" {
  description = "Map of application key to application (client) ID, for consumers that configure sign-in."
  value       = module.app_registrations.client_ids
}

output "federated_credential_ids" {
  description = "Map of \"app/credential\" key to federated identity credential ID."
  value       = module.app_registrations.federated_credential_ids
}
