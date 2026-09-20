# ---------------------------------------------------------------------------
# The roles. Both trust ECS tasks and nothing else. The execution role
# carries the AWS managed policy ECS documents for execution roles
# (image pull, log delivery) plus the namespace read; the task role carries
# only the inline policy built above.
# ---------------------------------------------------------------------------

module "roles" {
  source = "../../../../modules/aws/iam-service-role"

  roles = {
    task = {
      name          = local.task_role_name
      description   = "What ${local.name_prefix} runs as: reads its parameters and reads and writes its artifacts."
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
  }
}
