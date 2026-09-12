output "role_definition_ids" {
  description = "Map of logical role key to role definition GUID."
  value       = module.custom_roles.role_definition_ids
}

output "role_definition_resource_ids" {
  description = "Map of logical role key to fully qualified role definition resource ID."
  value       = module.custom_roles.role_definition_resource_ids
}

output "roles" {
  description = "Map of logical role key to { name, role_definition_id, resource_id, scope, assignable_scopes }."
  value       = module.custom_roles.roles
}

output "scope_ids" {
  description = "Map of <type>/<name> to resolved scope ID for every scope a role references."
  value       = module.custom_roles.scope_ids
}
