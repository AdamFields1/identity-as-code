output "group_ids" {
  description = "Map of privileged group key to object ID."
  value       = module.privileged_groups.group_ids
}

output "role_policy_ids" {
  description = "Map of role policy key to role management policy ID."
  value       = module.role_policies.policy_ids
}

output "directory_role_eligibility_ids" {
  description = "Map of directory role eligibility key to schedule request ID."
  value       = module.eligibility.directory_role_eligibility_ids
}

output "group_eligibility_ids" {
  description = "Map of group eligibility key to eligibility schedule ID."
  value       = module.eligibility.group_eligibility_ids
}

output "role_template_ids" {
  description = "Map of directory role display name to template ID for every role referenced."
  value       = module.eligibility.role_template_ids
}
