output "instance_arn" {
  description = "ARN of the Identity Center instance this cell manages."
  value       = module.permission_sets.instance_arn
}

output "identity_store_id" {
  description = "Identity store ID of the instance; the SCIM target for the Entra federation stack."
  value       = module.permission_sets.identity_store_id
}

output "partition" {
  description = "Partition the instance lives in (aws or aws-us-gov)."
  value       = module.permission_sets.partition
}

output "permission_sets" {
  description = "Map of permission set key to { name, arn, session_duration }."
  value       = module.permission_sets.permission_sets
}

output "assignments" {
  description = "Map of group display name to { partition_token, account_id, permission_set_name, permission_set_arn, group_id }."
  value       = module.account_assignments.assignments
}

output "group_ids" {
  description = "Map of group display name to identity store group ID."
  value       = module.account_assignments.group_ids
}
