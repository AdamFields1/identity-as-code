output "task_role_arn" {
  description = "ARN of the task role, what the application's containers run as. Goes in the task definition's taskRoleArn."
  value       = module.roles.roles["task"].arn
}

output "task_execution_role_arn" {
  description = "ARN of the task execution role, what the ECS agent uses to pull the image, inject the parameters, and ship the logs. Goes in the task definition's executionRoleArn."
  value       = module.roles.roles["execution"].arn
}

output "image_publisher_role_arn" {
  description = "ARN of the image publisher role, what the application repository's pipeline assumes through OIDC to push an image. Goes in the workflow's role-to-assume; nothing in this account references it."
  value       = module.roles.roles["publisher"].arn
}

output "image_publisher_trust_subject" {
  description = "The exact subject the publisher's trust matches on the workflow's OIDC token (repo:<organization>/<repository>:environment:<publisher_github_environment>), for checking against a failed AssumeRoleWithWebIdentity. A job outside that environment, on any branch, does not match."
  value       = local.publisher_trust_subject
}

output "role_arns_by_name" {
  description = "Map of role NAME to ARN for all three roles, for callers that reference roles by name."
  value       = module.roles.role_arns_by_name
}

output "repository_name" {
  description = "Name of the image repository: <app>-<env>."
  value       = module.registry.repositories["app"].name
}

output "repository_url" {
  description = "URL of the image repository (<registry id>.dkr.ecr.<region>.<dns suffix>/<app>-<env>), what a task definition's image field and a docker push name start with; the tag goes after a colon."
  value       = module.registry.repositories["app"].repository_url
}

output "repository_arn" {
  description = "ARN of the image repository, for a role policy in another stack that scopes its ecr: actions to this repository."
  value       = module.registry.repositories["app"].arn
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
    # under it. The registry and the log group are both handed the key
    # module's ARN, so they can only disagree if the repository's
    # encryption were changed outside Terraform (which the registry module
    # would plan to revert); this says in words what that plan would show
    # in ARNs. Unknown on the first plan, so checked at apply.
    condition     = module.registry.repositories["app"].kms_key_arn == module.key.keys["app"].arn
    error_message = "The ${local.name_prefix} image repository and log group must be encrypted with the same key (alias/${local.key_alias}). The repository reports a different key; its encryption was changed outside Terraform. Restore this stack's key rather than accepting two keys."
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
