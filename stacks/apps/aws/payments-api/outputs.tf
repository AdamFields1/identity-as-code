output "task_role_arn" {
  description = "ARN of the task role, what the application's containers run as. Goes in the task definition's taskRoleArn."
  value       = module.roles.roles["task"].arn
}

output "task_execution_role_arn" {
  description = "ARN of the task execution role, what the ECS agent uses to pull the image, inject the parameters, and ship the logs. Goes in the task definition's executionRoleArn."
  value       = module.roles.roles["execution"].arn
}

output "role_arns_by_name" {
  description = "Map of role NAME to ARN for both roles, for callers that reference roles by name."
  value       = module.roles.role_arns_by_name
}

output "artifacts_bucket_name" {
  description = "Name of the artifacts bucket: <app>-<env>-artifacts-<account id>."
  value       = module.artifacts.buckets["artifacts"].name
}

output "kms_key_alias" {
  description = "Bare alias of the application's key (without alias/), the string another cell in this account would name to share it."
  value       = module.key.keys["app"].alias
}

output "kms_key_arn" {
  description = "ARN of the application's key."
  value       = module.key.keys["app"].arn
}

output "log_group_name" {
  description = "Name of the application's log group, for the awslogs driver's awslogs-group option."
  value       = module.log_group.log_groups["app"].name

  precondition {
    # The point of one key is that everything the application writes is
    # under it. If the bucket's alias were repointed at another key outside
    # Terraform, the bucket module would plan the move; this says in words
    # what the plan would show in ARNs. Unknown on the first plan, and on
    # any plan that defers the bucket module's reads, so checked at apply.
    condition     = module.artifacts.buckets["artifacts"].kms_key_arn == module.key.keys["app"].arn
    error_message = "The ${local.name_prefix} artifacts bucket and log group must be encrypted with the same key (alias/${local.key_alias}). The bucket resolved a different key for that alias; the alias was repointed outside Terraform, or the bucket module read a stale alias. Restore the alias to this stack's key rather than accepting two keys."
  }
}

output "parameter_prefix" {
  description = "Namespace under which the application's parameters live (/<app>/<env>). The task role reads everything under it; the execution role can inject everything under it as a container secret."
  value       = local.parameter_prefix

  precondition {
    # The placeholder and the task role's policy are built from the same
    # prefix; this is the check that an edit to one without the other fails
    # the plan with the reason.
    condition     = strcontains(local.task_policy, "${local.parameter_arn_prefix}/*")
    error_message = "The task role's inline policy no longer grants the parameter namespace ${local.parameter_prefix}/ that the placeholder sits in. The policy and the namespace derive from the same prefix in this stack; restore the ReadSecretsUnderNamespace statement rather than moving the namespace."
  }
}

output "placeholder_parameter_name" {
  description = "Name of the placeholder parameter that reserves the namespace (/<app>/<env>/placeholder). Its value is never a secret; real secrets are siblings of it, written outside Terraform."
  value       = module.parameters.namespaces["app"].placeholder_name
}

output "partition" {
  description = "Partition the stack was deployed in (aws or aws-us-gov)."
  value       = local.partition
}

output "account_id" {
  description = "Account the stack was deployed in, as discovered from the provider's credentials; the account the cell's locator names."
  value       = local.account_id
}
