output "assignment_ids" {
  description = "Map of logical assignment key to role assignment resource ID."
  value       = { for k, a in azurerm_role_assignment.this : k => a.id }
}

output "assignments" {
  description = "Map of logical assignment key to a summary object (scope, role_name, role_definition_id, conditioned)."
  value = {
    for k, a in azurerm_role_assignment.this : k => {
      scope              = a.scope
      role_name          = var.assignments[k].role_name
      role_definition_id = a.role_definition_id
      conditioned        = var.assignments[k].condition != null
    }
  }
}

output "scope_ids" {
  description = "Map of logical assignment key to the resolved scope resource ID."
  value       = local.scope_ids
}

output "conditions" {
  description = "Map of logical assignment key to the condition text as sent, with every token replaced. Null where the entry has no condition."
  value       = local.conditions
}
