output "assignments" {
  description = "Map of group display name to { partition_token, account_id, permission_set_name, permission_set_arn, group_id }."
  value = {
    for name, a in aws_ssoadmin_account_assignment.this : name => {
      partition_token     = local.parsed[name].partition_token
      account_id          = a.target_id
      permission_set_name = local.parsed[name].permission_set_name
      permission_set_arn  = a.permission_set_arn
      group_id            = a.principal_id
    }
  }
}

output "assignment_ids" {
  description = "Map of group display name to account assignment resource ID."
  value       = { for name, a in aws_ssoadmin_account_assignment.this : name => a.id }
}

output "group_ids" {
  description = "Map of group display name to identity store group ID."
  value       = { for name, g in data.aws_identitystore_group.by_display_name : name => g.group_id }
}

output "partition_token" {
  description = "The naming convention token for the partition this module planned against (COM or GOV)."
  value       = local.expected_partition_token
}
