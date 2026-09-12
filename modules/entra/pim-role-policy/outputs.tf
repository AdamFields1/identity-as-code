output "policy_ids" {
  description = "Map of logical key to role management policy ID."
  value       = { for k, p in azuread_group_role_management_policy.this : k => p.id }
}

output "policies" {
  description = "Map of logical key to { id, group_id, role, display_name }."
  value = {
    for k, p in azuread_group_role_management_policy.this : k => {
      id           = p.id
      group_id     = p.group_id
      role         = p.role_id
      display_name = p.display_name
    }
  }
}
