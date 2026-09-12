output "policy_ids" {
  description = "Map of logical policy key to role management policy resource ID."
  value       = module.pim_role_policy.policy_ids
}

output "policies" {
  description = "Map of logical policy key to { name, scope, role_definition_id, activation_maximum_duration, require_approval }."
  value       = module.pim_role_policy.policies
}

output "eligibility_ids" {
  description = "Map of logical eligibility key to PIM eligible role assignment resource ID."
  value       = module.pim_eligible_assignment.eligibility_ids
}

output "eligibilities" {
  description = "Map of logical eligibility key to { scope, role_definition_id, principal_id, group_display_name, permanent }."
  value       = module.pim_eligible_assignment.eligibilities
}

output "approver_group_object_ids" {
  description = "Map of approver group display name to object ID for every group referenced by a policy."
  value       = local.approver_group_object_ids
}

output "group_object_ids" {
  description = "Map of eligible group display name to object ID for every group referenced by an eligibility."
  value       = module.pim_eligible_assignment.group_object_ids
}
