output "policy_ids" {
  description = "Map of logical policy key to the role management policy resource ID."
  value       = { for k, p in azurerm_role_management_policy.this : k => p.id }
}

output "policies" {
  description = "Map of logical policy key to a summary object (name, scope, role_definition_id, activation_maximum_duration, require_approval)."
  value = {
    for k, p in azurerm_role_management_policy.this : k => {
      name                        = p.name
      scope                       = p.scope
      role_definition_id          = p.role_definition_id
      activation_maximum_duration = local.effective[k].activation.maximum_duration
      require_approval            = local.effective[k].activation.require_approval
    }
  }
}

output "role_definition_ids" {
  description = "Map of logical policy key to the fully qualified role definition resource ID the policy was resolved against."
  value       = { for k, r in data.azurerm_role_definition.this : k => r.id }
}

output "scope_ids" {
  description = "Map of \"<type>/<name>\" to the resolved scope resource ID for every scope referenced by a policy."
  value       = local.scope_ids
}
