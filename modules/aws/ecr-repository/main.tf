# ECR repositories, keyed by the caller's logical name.
#
# A repository holds the images a workload starts from, and three things
# decide whether the image a task runs is the image a pipeline built. All
# three are fixed here rather than offered as knobs:
#
#   - Tags are immutable. A tag names one image forever; a build that wants
#     to publish again publishes under a new tag. A mutable "latest" is a
#     name whose meaning changes underneath the task definition that
#     references it, and a task definition that pins a digest is the honest
#     alternative, so mutability is not offered.
#   - Scan on push. Every image is scanned as it lands, so a finding is
#     attached to the build that introduced it and not to the incident that
#     found it.
#   - Encryption is a customer managed key, named by ARN, and it is
#     required: a repository under the service's own key has no key policy
#     anyone reviews. It is an ARN and not an alias for the reason
#     modules/aws/log-group takes one: the API stores and reports the key
#     ARN, and an alias here would plan a change on every run. ECR creates a
#     grant on the key on behalf of whoever creates the repository, so the
#     deploying identity needs kms:CreateGrant, kms:RetireGrant, and
#     kms:DescribeKey on it, which the key's root statement lets IAM grant.
#
# What is bounded is how many images a repository keeps. Two lifecycle
# rules do that: untagged images (the layer sets a later build superseded)
# expire after untagged_expiry_days, and beyond keep_tagged_count images the
# oldest expire whatever their tag. The count rule uses tagStatus "any" so
# a release tag does not exempt an image from the count; a prefix rule that
# counted only "v" tags would let untagged and oddly tagged images pile up
# outside it. ECR requires the "any" rule to carry the highest priority, so
# it is evaluated last.
#
# Who may pull and who may push are role NAMES, and the module builds each
# ARN from the caller's partition and account id as modules/aws/kms-key
# does, so the same values deploy to any account in either partition
# (docs/adr/0009). Nothing is looked up: whether a named role exists is
# checked by ECR when the policy is written, so a role created in the same
# plan is allowed and a misspelt name fails the apply. The policy grants
# pull to pullers and pull plus push to pushers; BatchDeleteImage is granted
# to nobody, because expiring images is the lifecycle policy's job and a
# publisher that can delete can erase the image a task is running. When
# both lists are empty no policy resource exists and access is decided by
# IAM alone. ecr:GetAuthorizationToken is a registry action that no
# repository policy can grant; the stack puts it in each role's own policy.
#
# force_delete is false and every repository is prevent_destroy: images are
# build artifacts a pipeline can rebuild, but the tags that task definitions
# reference cannot be recreated with the same digests, and a name change is
# a replacement that empties the repository.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  role_arn_prefix = "arn:${local.partition}:iam::${local.account_id}:role/"

  principals = {
    for key, r in var.repositories : key => {
      pull = [for n in r.pull_role_names : "${local.role_arn_prefix}${n}"]
      push = [for n in r.push_role_names : "${local.role_arn_prefix}${n}"]
    }
  }

  # Repositories that name at least one role. Only these get a policy
  # resource; the others are governed by IAM alone.
  repositories_with_policy = {
    for key, r in var.repositories : key => r
    if length(r.pull_role_names) + length(r.push_role_names) > 0
  }

  pull_actions = [
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchCheckLayerAvailability",
    "ecr:DescribeImages",
    "ecr:DescribeRepositories",
    "ecr:ListImages",
  ]

  push_actions = [
    "ecr:PutImage",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
  ]
}

# ---------------------------------------------------------------------------
# Repositories.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  tags                 = each.value.tags

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = each.value.kms_key_arn
  }

  lifecycle {
    # The tags in this repository are what task definitions reference, and
    # a rebuilt image does not carry the same digest. Retiring a workload
    # is a deliberate change that flips this flag first, never a side
    # effect of removing an entry from a map. A name change is a
    # replacement and is refused for the same reason.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Lifecycle policies. Two rules per repository, in the order ECR requires:
#
#   1  untagged images expire untagged_expiry_days after they were pushed.
#   2  beyond keep_tagged_count images, the oldest expire whatever their
#      tag. tagStatus "any" must be the last rule, so it is priority 2.
# ---------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${each.value.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = each.value.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest ${each.value.keep_tagged_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = each.value.keep_tagged_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Repository policies. One document per repository that names a role, with
# at most two statements, each emitted only when it has principals:
#
#   AllowPull   the pull actions, for pull_role_names.
#   AllowPush   the pull actions and the push actions, for push_role_names.
#
# No Resource element: a repository policy applies to the repository it is
# attached to, and ECR fills it in.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "repository" {
  for_each = local.repositories_with_policy

  dynamic "statement" {
    for_each = length(local.principals[each.key].pull) > 0 ? [1] : []

    content {
      sid     = "AllowPull"
      effect  = "Allow"
      actions = local.pull_actions

      principals {
        type        = "AWS"
        identifiers = local.principals[each.key].pull
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.principals[each.key].push) > 0 ? [1] : []

    content {
      sid     = "AllowPush"
      effect  = "Allow"
      actions = concat(local.pull_actions, local.push_actions)

      principals {
        type        = "AWS"
        identifiers = local.principals[each.key].push
      }
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = local.repositories_with_policy

  repository = aws_ecr_repository.this[each.key].name
  policy     = data.aws_iam_policy_document.repository[each.key].json

  lifecycle {
    precondition {
      # Deleting is the lifecycle policy's job. If an edit to this file ever
      # grants it to a principal, the plan says so.
      condition     = !strcontains(data.aws_iam_policy_document.repository[each.key].json, "ecr:BatchDeleteImage")
      error_message = "Repository \"${each.key}\": the rendered policy grants ecr:BatchDeleteImage. No role this module names may delete images; expiring them is the lifecycle policy's job. Remove the action rather than widening the grant."
    }
  }
}
