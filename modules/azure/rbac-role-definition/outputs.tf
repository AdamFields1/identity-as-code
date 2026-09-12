output "role_definition_ids" {
  description = "Map of logical role key to the role definition GUID (the roleDefinitions/<guid> segment)."
  value       = { for k, r in azurerm_role_definition.this : k => r.role_definition_id }
}

output "role_definition_resource_ids" {
  description = "Map of logical role key to the fully qualified role definition resource ID, as required by role assignments and PIM resources."
  value       = { for k, r in azurerm_role_definition.this : k => r.role_definition_resource_id }
}

output "roles" {
  description = "Map of logical role key to a summary object (name, role_definition_id, resource_id, scope, assignable_scopes)."
  value = {
    for k, r in azurerm_role_definition.this : k => {
      name               = r.name
      role_definition_id = r.role_definition_id
      resource_id        = r.role_definition_resource_id
      scope              = r.scope
      assignable_scopes  = r.assignable_scopes
    }
  }
}

output "scope_ids" {
  description = "Map of \"<type>/<name>\" to the resolved scope resource ID for every scope referenced by a role. Useful for cross-checking a plan."
  value       = local.scope_ids
}
