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
# is in modules/aws, and this file holds the names, the policies, and the
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

# ---------------------------------------------------------------------------
# The key. The task and execution roles are users; CloudWatch Logs is a
# service user so the log group below can be encrypted with it. The
# publisher is not a user: ECR encrypts and decrypts layers under the grant
# it creates for the repository's creator, so a role that pushes needs
# nothing on the key. The role ARNs are constructed by the module, not
# looked up, so naming roles created in the same plan is allowed, but KMS
# checks they exist when the policy is written. The names are therefore
# taken from the roles module's output rather than from the locals that fed
# it: the values are the same, and the reference is what makes Terraform
# create the roles before the key. It is a reference and not a depends_on
# on purpose: a reference through a module output orders the resources
# without deferring the key policy's document to apply, so a plan shows the
# full policy.
# ---------------------------------------------------------------------------

module "key" {
  source = "../../../../modules/aws/kms-key"

  keys = {
    app = {
      alias           = local.key_alias
      description     = "Encrypts the ${local.name_prefix} image repository, log group, and parameters."
      user_role_names = [module.roles.roles["task"].name, module.roles.roles["execution"].name]
      service_users   = ["logs"]
      tags            = local.tags
    }
  }
}

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

# ---------------------------------------------------------------------------
# The registry. One repository, encrypted with the key by ARN, with the
# execution role allowed to pull and the publisher allowed to push (push
# includes pull; nobody may delete). The module builds the principal ARNs
# from names and looks nothing up, but ECR validates every principal when
# the repository policy is written, so the names are taken from the roles
# module's output for the same reason the key does it: the reference makes
# Terraform create the roles first, and the policy document is still shown
# in full at plan. The key's ARN comes from the key module's output, which
# is also what orders the key before the repository. The check that the
# registry and the log group are under the same key is on the
# log_group_name output (outputs.tf).
# ---------------------------------------------------------------------------

module "registry" {
  source = "../../../../modules/aws/ecr-repository"

  repositories = {
    app = {
      name                 = local.repository_name
      kms_key_arn          = module.key.keys["app"].arn
      keep_tagged_count    = var.image_retention_count
      untagged_expiry_days = var.untagged_image_expiry_days
      pull_role_names      = [module.roles.roles["execution"].name]
      push_role_names      = [module.roles.roles["publisher"].name]
      tags                 = local.tags
    }
  }
}

# ---------------------------------------------------------------------------
# The log group. Encrypted with the key, which works only because the key
# policy names the CloudWatch Logs service principal for log groups in this
# account and region (service_users = ["logs"] above); a key without that
# statement is refused by the API when the log group is created. The module
# takes the key's ARN from the key module's output, which is also what
# orders the key before the group.
# ---------------------------------------------------------------------------

module "log_group" {
  source = "../../../../modules/aws/log-group"

  log_groups = {
    app = {
      name              = local.log_group_name
      retention_in_days = var.log_retention_days
      kms_key_arn       = module.key.keys["app"].arn
      tags              = local.tags
    }
  }
}

# ---------------------------------------------------------------------------
# The parameter namespace. One SecureString placeholder under the prefix,
# encrypted with the key, whose value the module writes once and never
# manages again. The placeholder must never hold a real value: the
# application's real secrets are siblings under the same prefix, written by
# the secrets process, and this stack neither declares nor reads them, so
# no secret passes through a plan, a cell, or a commit (the module README
# says what a refresh would otherwise put in state). The prefix is the same
# local the task role's policy was rendered from; the parameter_prefix
# output (outputs.tf) carries the check that the two still agree.
# ---------------------------------------------------------------------------

module "parameters" {
  source = "../../../../modules/aws/ssm-parameter-namespace"

  namespaces = {
    app = {
      prefix      = local.parameter_prefix
      description = "Reserves ${local.parameter_prefix}/ for ${local.name_prefix} and proves the key and the roles' grants end to end. Real secrets are siblings of this parameter, written outside Terraform; this value is never a secret."
      kms_key_id  = module.key.keys["app"].key_id
      tags        = local.tags
    }
  }
}
