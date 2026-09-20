# payments-api app stack
#
# One deployable unit for one deployment of one application in one account:
# the identities it runs as, the key it encrypts with, the bucket it reads
# and writes, the log group it writes to, and the parameter namespace it
# reads its secrets from. Order of dependency:
#
#   roles ---------> key                (the key policy names both roles)
#     |               |---------------> artifacts bucket   (SSE-KMS with the
#     |               |                                     key; objects only
#     |               |                                     for the task role)
#     |               |---------------> log group          (encrypted with it)
#     |               |---------------> placeholder param  (SecureString under it)
#     |-------------> artifacts bucket   (the allowed role is looked up by name)
#   roles' policies  name the bucket and the namespace by ARN, built here
#
# This is an app stack, not five catalog entries (docs/adr/0017), because
# the pieces are wired to each other: the key policy names the two roles,
# the bucket policy names the task role, the task role's policy names the
# bucket and the parameter namespace, and the log group and the parameter
# both name the key. Every one of those references is to something created
# in this same plan, which the catalog's plan-time name lookups cannot
# express. Split across cells, the same composition would be three or four
# releases in a fixed order and an ARN-shaped value in a cell. It is still
# only modules: every resource block is in modules/aws, and this file holds
# the names, the policies, and the wiring (README, "Three layers").
#
# Tenant cells (tenants/aws/<partition>/accounts/<account-name>/apps/payments-api/
# terragrunt.hcl) supply values only: the environment name, the retention,
# and tags. The account, the partition, and the region are discovered from
# the provider Terragrunt generated from the cell's locators, and every
# resource name derives from app_name and environment, so a cell holds no
# ARN, no id, and no name that another resource has to repeat.
#
# Deliberately NOT managed here: the ECS cluster, service, and task
# definition (the application's deployment pipeline owns those and reads
# this stack's outputs), the container registry, the values of the secrets
# under the parameter namespace (written by the secrets process, never by
# Terraform), and any role that uploads artifacts from outside the account.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  name_prefix = "${var.app_name}-${var.environment}"

  # The two identities ECS distinguishes: the task role is what the
  # application's code runs as, the execution role is what the ECS agent
  # uses to pull the image, inject secrets, and ship logs before the
  # container starts.
  task_role_name      = "${local.name_prefix}-task"
  execution_role_name = "${local.name_prefix}-task-execution"

  # One key for the bucket, the log group, and the parameters. Bare alias:
  # the modules add "alias/".
  key_alias = local.name_prefix

  # The account id makes the bucket name globally unique without a random
  # suffix, so the name is predictable from the cell and the locator. The
  # ARN is built here rather than read from the module because the task
  # role's policy needs it and the bucket module waits for the roles.
  bucket_name = "${local.name_prefix}-artifacts-${local.account_id}"
  bucket_arn  = "arn:${local.partition}:s3:::${local.bucket_name}"

  log_group_name = "/ecs/${var.app_name}/${var.environment}"

  # The parameter namespace. Everything the application reads as a secret
  # lives under this prefix, the two roles are granted the prefix and
  # nothing outside it, and the placeholder the namespace module declares
  # proves the namespace, the key, and the grants work before a real secret
  # exists. The ARN prefix is built here rather than read from that module
  # because the roles' policies need it and the module waits for the key,
  # which waits for the roles.
  parameter_prefix     = "/${var.app_name}/${var.environment}"
  parameter_arn_prefix = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.parameter_prefix}"

  tags = merge(var.tags, {
    Application = var.app_name
    Environment = var.environment
  })

  # The task role's permissions: the namespace and the bucket, nothing else.
  # No KMS statement, because the key policy grants the role directly
  # (user_role_names below), which is sufficient on its own and keeps the
  # key ARN, unknown until the key exists, out of a document the module
  # validates at plan time. No delete on objects: versioning and the
  # bucket's lifecycle rule are the only things that remove artifacts.
  task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSecretsUnderNamespace"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [local.parameter_arn_prefix, "${local.parameter_arn_prefix}/*"]
      },
      {
        Sid      = "ListArtifacts"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "ReadWriteArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.bucket_arn}/*"]
      },
    ]
  })

  # The execution role's extra permission beyond the AWS managed execution
  # policy: reading parameters under the namespace so a task definition can
  # inject them as container secrets. Decrypting them is granted by the key
  # policy, as for the task role.
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
}

# ---------------------------------------------------------------------------
# The key. Both roles are users; CloudWatch Logs is a service user so the
# log group below can be encrypted with it. The role ARNs are constructed
# by the module, not looked up, so naming roles created in the same plan
# is allowed, but KMS checks they exist when the policy is written. The
# names are therefore taken from the roles module's output rather than
# from the locals that fed it: the values are the same, and the reference
# is what makes Terraform create the roles before the key. It is a
# reference and not a depends_on on purpose: a reference through a module
# output orders the resources without deferring the key policy's document
# to apply, so a plan shows the full policy.
# ---------------------------------------------------------------------------

module "key" {
  source = "../../../../modules/aws/kms-key"

  keys = {
    app = {
      alias           = local.key_alias
      description     = "Encrypts the ${local.name_prefix} artifacts bucket, log group, and parameters."
      user_role_names = [module.roles.roles["task"].name, module.roles.roles["execution"].name]
      service_users   = ["logs"]
      tags            = local.tags
    }
  }
}

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

# ---------------------------------------------------------------------------
# The bucket. Encrypted with the key by alias and restricted to the task
# role by name, both of which the bucket module resolves with data sources
# at plan time. In this stack both are created in the same plan, so the
# module must wait for them: depends_on defers every lookup in the module
# to apply whenever the key or the roles have pending changes. The cost is
# stated in the README: on the first plan, and on any plan that changes
# the key or a role, the bucket's encryption and policy show as known
# after apply rather than as the values they will have.
# ---------------------------------------------------------------------------

module "artifacts" {
  source = "../../../../modules/aws/s3-bucket"

  buckets = {
    artifacts = {
      name               = local.bucket_name
      kms_key_alias      = local.key_alias
      allowed_role_names = [local.task_role_name]
      tags               = local.tags
    }
  }

  depends_on = [module.key, module.roles]
}

# ---------------------------------------------------------------------------
# The log group. Encrypted with the key, which works only because the key
# policy names the CloudWatch Logs service principal for log groups in this
# account and region (service_users = ["logs"] above); a key without that
# statement is refused by the API when the log group is created. The module
# takes the key's ARN from the key module's output, which is also what
# orders the key before the group. The check that the bucket and the group
# are under the same key is on the log_group_name output (outputs.tf).
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
