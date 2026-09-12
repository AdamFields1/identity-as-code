output "named_location_ids" {
  description = "Map of logical key to named location object ID."
  value       = module.conditional_access.named_location_ids
}

output "authentication_strength_ids" {
  description = "Map of logical key to authentication strength policy ID."
  value       = module.conditional_access.authentication_strength_ids
}

output "policies" {
  description = "Map of logical key to { object_id, display_name, state }."
  value       = module.conditional_access.policies
}

output "break_glass_group_id" {
  description = "Object ID of the break-glass group excluded from every policy."
  value       = module.conditional_access.break_glass_group_id
}
