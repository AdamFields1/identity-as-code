output "log_groups" {
  description = "Map of logical key to { name, arn, retention_in_days, kms_key_arn }."
  value = {
    for k, g in aws_cloudwatch_log_group.this : k => {
      name              = g.name
      arn               = g.arn
      retention_in_days = g.retention_in_days
      kms_key_arn       = g.kms_key_id
    }
  }
}

output "log_group_arns_by_name" {
  description = "Map of log group NAME to ARN, for callers that reference log groups by name."
  value       = { for k, g in var.log_groups : g.name => aws_cloudwatch_log_group.this[k].arn }
}
