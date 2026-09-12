output "named_location_ids" {
  description = "Map of logical key to named location object ID."
  value       = { for k, l in azuread_named_location.this : k => l.object_id }
}

output "authentication_strength_ids" {
  description = "Map of logical key to authentication strength policy ID."
  value       = { for k, s in azuread_authentication_strength_policy.this : k => s.id }
}

output "policy_ids" {
  description = "Map of logical key to Conditional Access policy object ID."
  value       = { for k, p in azuread_conditional_access_policy.this : k => p.object_id }
}

output "policies" {
  description = "Map of logical key to { object_id, display_name, state }."
  value = {
    for k, p in azuread_conditional_access_policy.this : k => {
      object_id    = p.object_id
      display_name = p.display_name
      state        = p.state
    }
  }
}

output "break_glass_group_id" {
  description = "Object ID of the break-glass exclusion group that every policy excludes."
  value       = local.group_ids[var.break_glass_exclusion_group]
}
