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
# only modules: every resource block is in modules/aws, and this directory holds
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
