# orders-api app stack
#
# One deployable unit for one deployment of one application in one account:
# everything a container needs before it can start, and nothing it runs.
# The identities it runs as and starts with, the identity that publishes
# its image, the registry the image lives in, the key that encrypts the
# registry and the logs, the log group it writes to, and the parameter
# namespace it reads its secrets from. Order of dependency:
#
#   roles ---------> key                (the key policy names task and execution)
#     |               |---------------> registry           (encrypted with it;
#     |               |                                     pull: execution,
#     |               |                                     push: publisher)
#     |               |---------------> log group          (encrypted with it)
#     |               |---------------> placeholder param  (SecureString under it)
#     |-------------> registry          (the repository policy names the roles)
#   roles' policies  name the namespace by ARN, built here; the publisher's
#                    names nothing, because push is granted on the repository
#
# This is an app stack, not five catalog entries (docs/adr/0017), because
# the pieces are wired to each other: the key policy names two of the
# roles, the repository policy names two of the roles, the task and
# execution roles' policies name the parameter namespace, and the registry,
# the log group, and the parameter all name the key. Every one of those
# references is to something created in this same plan, which the catalog's
# plan-time name lookups cannot express. Split across cells, the same
# composition would be three or four releases in a fixed order and an
# ARN-shaped value in a cell. It is still only modules: every resource block
# is in modules/aws, and this directory holds the names, the policies, and the
# wiring (README, "Three layers").
#
# Tenant cells (tenants/aws/<partition>/accounts/<account-name>/apps/orders-api/
# terragrunt.hcl) supply values only: the environment name, the GitHub
# organization and repository whose pipeline publishes the image, the
# retention knobs, and tags. The account, the partition, and the region are
# discovered from the provider Terragrunt generated from the cell's
# locators, and every resource name derives from app_name and environment,
# so a cell holds no ARN, no id, and no name that another resource has to
# repeat.
#
# Deliberately NOT managed here: the ECS cluster, service, and task
# definition (the application's deployment pipeline owns those and reads
# this stack's outputs; the README ends with the fragment that does), the
# images themselves (the publisher role pushes them from the named
# repository's pipeline), the values of the secrets under the parameter
# namespace (written by the secrets process, never by Terraform), and any
# bucket: an API's artifact is its image, and a stack that needs object
# storage is payments-api, not this one.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  name_prefix = "${var.app_name}-${var.environment}"

  # The three identities. ECS distinguishes the first two: the task role
  # is what the application's code runs as, the execution role is what the
  # ECS agent uses to pull the image, inject secrets, and ship logs before
  # the container starts. The third is the pipeline's: the role one GitHub
  # repository's jobs assume to push an image, and the only principal that
  # can write to the registry.
  task_role_name      = "${local.name_prefix}-task"
  execution_role_name = "${local.name_prefix}-task-execution"
  publisher_role_name = "${local.name_prefix}-image-publisher"

  # One key for the registry, the log group, and the parameters. Bare
  # alias: the modules add "alias/".
  key_alias = local.name_prefix

  # The repository name. ECR names may contain hyphens, so the repository
  # carries the same name as the roles and the alias; a slash-separated
  # name (orders-api/prod) would also be valid and is not used because
  # nothing else in this stack has a namespace shaped that way.
  repository_name = local.name_prefix

  log_group_name = "/ecs/${var.app_name}/${var.environment}"

  # The parameter namespace. Everything the application reads as a secret
  # lives under this prefix, the two ECS roles are granted the prefix and
  # nothing outside it, and the placeholder the namespace module declares
  # proves the namespace, the key, and the grants work before a real secret
  # exists. The ARN prefix is built here rather than read from that module
  # because the roles' policies need it and the module waits for the key,
  # which waits for the roles.
  parameter_prefix     = "/${var.app_name}/${var.environment}"
  parameter_arn_prefix = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.parameter_prefix}"

  # The GitHub environment the publisher trusts. Null in the cell means
  # the deployment's own name, so the prod cell trusts the repository's
  # prod environment unless it says otherwise.
  publisher_github_environment = coalesce(var.publisher_github_environment, var.environment)
  publisher_github_repository  = "${var.github_organization}/${var.github_repository}"

  # The one subject the publisher's trust matches, in the form the role
  # module renders it (modules/aws/iam-service-role) and GitHub mints it.
  # Built here so the stack can output it next to the role ARN.
  publisher_trust_subject = "repo:${local.publisher_github_repository}:environment:${local.publisher_github_environment}"

  tags = merge(var.tags, {
    Application = var.app_name
    Environment = var.environment
  })

  # The task role's permissions: the namespace and nothing else. No KMS
  # statement, because the key policy grants the role directly
  # (user_role_names below), which is sufficient on its own and keeps the
  # key ARN, unknown until the key exists, out of a document the module
  # validates at plan time. No ECR statement either: the task role runs
  # the application, and the application does not pull its own image.
  task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSecretsUnderNamespace"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [local.parameter_arn_prefix, "${local.parameter_arn_prefix}/*"]
      },
    ]
  })

  # The execution role's extra permission beyond the AWS managed execution
  # policy: reading parameters under the namespace so a task definition can
  # inject them as container secrets. Decrypting them is granted by the key
  # policy, as for the task role. The image pull needs nothing here: the
  # managed policy carries ecr:GetAuthorizationToken, and the repository
  # policy the registry module writes names this role under AllowPull.
  execution_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InjectSecretsUnderNamespace"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = ["${local.parameter_arn_prefix}/*"]
      },
    ]
  })

  # The publisher's own policy is one statement, and it is the one the
  # repository policy cannot carry: ecr:GetAuthorizationToken is a registry
  # action, evaluated against the caller's identity and not against any
  # repository, so it can only be granted on "*". Everything the role does
  # to the repository (the layer uploads and PutImage) is granted by the
  # repository policy the registry module writes, scoped to this one
  # repository, and nothing about the key: ECR encrypts under its own
  # grant. The role therefore holds no ARN at all, which is why its policy
  # can be rendered at plan time in full.
  publisher_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetRegistryToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
    ]
  })
}
