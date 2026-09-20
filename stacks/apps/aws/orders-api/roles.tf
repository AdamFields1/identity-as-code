# ---------------------------------------------------------------------------
# The roles. The task and execution roles trust ECS tasks of this account
# and nothing else; the execution role carries the AWS managed policy ECS
# documents for execution roles (image pull, log delivery) plus the
# namespace read, and the task role carries only the inline policy built
# above. The publisher trusts one deployment environment of one GitHub
# repository through the account's OIDC provider, for the AWS minimum
# session, and carries the one registry action a repository policy cannot
# grant. The push itself is granted on the repository, below. No branch is
# listed: a token's subject carries the ref or the environment, never both,
# so a branch beside the environment would be a second door that skips the
# environment's protection rules, not a second lock. Which branches may
# deploy to the environment is the environment's own deployment-branch
# rule on GitHub.
# ---------------------------------------------------------------------------

module "roles" {
  source = "../../../../modules/aws/iam-service-role"

  roles = {
    task = {
      name          = local.task_role_name
      description   = "What ${local.name_prefix} runs as: reads its parameters."
      trust         = { services = ["ecs-tasks"] }
      inline_policy = local.task_policy
      tags          = local.tags
    }

    execution = {
      name                 = local.execution_role_name
      description          = "What the ECS agent uses to start ${local.name_prefix}: pull the image, inject the parameters, ship the logs."
      trust                = { services = ["ecs-tasks"] }
      aws_managed_policies = ["service-role/AmazonECSTaskExecutionRolePolicy"]
      inline_policy        = local.execution_policy
      tags                 = local.tags
    }

    publisher = {
      name        = local.publisher_role_name
      description = "What the ${local.publisher_github_repository} pipeline assumes to push the ${local.name_prefix} image: one environment of one repository."
      trust = {
        oidc_github = {
          repository   = local.publisher_github_repository
          environments = [local.publisher_github_environment]
        }
      }
      inline_policy        = local.publisher_policy
      max_session_duration = 3600
      tags                 = local.tags
    }
  }
}
