output "permission_sets" {
  description = "Map of logical key to { name, arn, session_duration }."
  value = {
    for k, ps in aws_ssoadmin_permission_set.this : k => {
      name             = ps.name
      arn              = ps.arn
      session_duration = ps.session_duration
    }
  }
}

output "permission_set_arns_by_name" {
  description = "Map of permission set NAME to ARN, for callers that reference permission sets by name."
  value       = { for k, ps in var.permission_sets : ps.name => aws_ssoadmin_permission_set.this[k].arn }
}

output "instance_arn" {
  description = "ARN of the Identity Center instance the permission sets belong to."
  value       = local.instance_arn
}

output "identity_store_id" {
  description = "Identity store ID of the Identity Center instance."
  value       = local.identity_store_id
}

output "partition" {
  description = "AWS partition the permission sets were created in (aws, aws-us-gov)."
  value       = data.aws_partition.current.partition
}
