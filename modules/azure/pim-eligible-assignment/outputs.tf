output "eligibility_ids" {
  description = "Map of logical eligibility key to the PIM eligible role assignment resource ID."
  value       = { for k, e in azurerm_pim_eligible_role_assignment.this : k => e.id }
}

output "eligibilities" {
  description = "Map of logical eligibility key to a summary object (scope, role_definition_id, principal_id, group_display_name, permanent)."
  value = {
    for k, e in azurerm_pim_eligible_role_assignment.this : k => {
      scope              = e.scope
      role_definition_id = e.role_definition_id
      principal_id       = e.principal_id
      group_display_name = var.eligibilities[k].group_display_name
      permanent          = var.eligibilities[k].expiration.permanent
    }
  }
}

output "group_object_ids" {
  description = "Map of group display name to object ID for every group referenced by an eligibility."
  value       = { for name, g in data.azuread_group.by_display_name : name => g.object_id }
}

output "scope_ids" {
  description = "Map of \"<type>/<name>\" to the resolved scope resource ID for every scope referenced by an eligibility."
  value       = local.scope_ids
}
