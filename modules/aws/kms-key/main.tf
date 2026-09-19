# Customer managed KMS keys, keyed by the caller's logical name.
#
# A key is its policy. Unlike other AWS resources, a KMS key grants nothing
# to its own account unless the key policy says so, and a key whose policy
# names only principals that have since been deleted is unmanageable until
# AWS Support intervenes. The policy built here therefore always starts
# with the account root principal holding kms:*, which is the statement AWS
# itself puts in every default key policy: it lets the account's IAM
# policies grant access to the key, and it means the key can never be
# orphaned by deleting the roles it names. A precondition checks that the
# rendered policy still carries it.
#
# The other statements are the AWS console's default shapes, filled from
# role NAMES: administrators may manage the key (policy, aliases, grants,
# tags, enable, disable, schedule and cancel deletion) but not use it, and
# users may use it (encrypt, decrypt, re-encrypt, data keys, describe) and
# let AWS services create grants on it for resources they manage. The ARNs
# are built from the caller's partition and account id, so the same values
# deploy to any account in commercial or GovCloud (docs/adr/0009). Whether
# a named role exists is checked by KMS when the policy is written, not at
# plan time: a role created in the same plan is allowed, and a misspelt
# name fails the apply with "invalid principals" from KMS.
#
# A few AWS services use a key under their own service principal rather
# than under the caller's role, and a key policy that does not name them
# refuses them whatever IAM says. service_users is an allowlist of those,
# each with the statement AWS documents for it; today it holds CloudWatch
# Logs, whose grant is conditioned on the log group ARN the service presents
# as encryption context, so the key can only ever be used for log groups in
# this account and region. Services that act as the caller (S3, SSM
# Parameter Store) are not on the list because they need nothing here.
#
# CloudTrail is the one service named by resource rather than by service:
# cloudtrail_trail_names lists trails, and the statements the CloudTrail
# documentation requires are scoped with aws:SourceArn to those trails
# wherever the documentation allows a condition, so another account's trail
# cannot borrow the key.
#
# Fixed for every key: symmetric encrypt/decrypt, single region, automatic
# rotation on, and prevent_destroy. Rotation is not a knob because there is
# no reason to turn it off; the period is.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  account_root_arn = "arn:${local.partition}:iam::${local.account_id}:root"

  role_arn_prefix = "arn:${local.partition}:iam::${local.account_id}:role/"

  principals = {
    for key, k in var.keys : key => {
      administrators = [for n in k.administrator_role_names : "${local.role_arn_prefix}${n}"]
      users          = [for n in k.user_role_names : "${local.role_arn_prefix}${n}"]
    }
  }

  # The service allowlist, as the statement each entry renders. Every entry
  # the variable validation accepts has a row here. The condition is what
  # keeps a service grant narrow: CloudWatch Logs must present the ARN of a
  # log group in this account and region as encryption context, so the key
  # cannot be borrowed for a log group anywhere else.
  service_user_grants = {
    logs = {
      sid                = "AllowCloudWatchLogs"
      principal          = "logs.${local.region}.${local.dns_suffix}"
      actions            = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      condition_variable = "kms:EncryptionContext:aws:logs:arn"
      condition_values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # CloudTrail. The service principal is the same name in every partition;
  # a trail's ARN carries its home region, which is the provider's region.
  # CloudTrail encrypts under an encryption context that names the trail, and
  # the documented pattern matches every trail of this account in any region.
  cloudtrail_principal = "cloudtrail.${local.dns_suffix}"

  cloudtrail_trail_arns = {
    for key, k in var.keys : key => [
      for n in k.cloudtrail_trail_names : "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${n}"
    ]
  }

  cloudtrail_context_pattern = "arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"
}

# ---------------------------------------------------------------------------
# Key policies. One document per key; a statement is emitted only when it
# has principals, so a key with no users has no users statement rather than
# an empty one KMS would reject.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "key" {
  for_each = var.keys

  # The statement that keeps the key manageable. Never conditional.
  statement {
    sid       = "EnableRootAccountPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }

  dynamic "statement" {
    for_each = length(local.principals[each.key].administrators) > 0 ? [1] : []

    content {
      sid    = "AllowKeyAdministrators"
      effect = "Allow"
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
        "kms:RotateKeyOnDemand",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = local.principals[each.key].administrators
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.principals[each.key].users) > 0 ? [1] : []

    content {
      sid    = "AllowKeyUsers"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = local.principals[each.key].users
      }
    }
  }

  # Lets a user attach the key to an AWS resource (an EBS volume, an RDS
  # instance) by letting the service create a grant on the user's behalf.
  # The condition stops the user calling the grant operations directly.
  dynamic "statement" {
    for_each = length(local.principals[each.key].users) > 0 ? [1] : []

    content {
      sid       = "AllowAttachmentOfPersistentResources"
      effect    = "Allow"
      actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = local.principals[each.key].users
      }

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # One statement per allowlisted service the key names. The service
  # principal is regional and partition-aware; the condition pins the grant
  # to resources of this account and region.
  dynamic "statement" {
    for_each = { for s in each.value.service_users : s => local.service_user_grants[s] }

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [statement.value.principal]
      }

      condition {
        test     = "ArnLike"
        variable = statement.value.condition_variable
        values   = statement.value.condition_values
      }
    }
  }

  # CloudTrail, three statements from "Configure AWS KMS key policies for
  # CloudTrail" (docs.aws.amazon.com/awscloudtrail), emitted only when the
  # key names trails.
  #
  #   AllowCloudTrailEncryptLogs   GenerateDataKey* for the named trails,
  #                                and only under CloudTrail's own
  #                                encryption context.
  #   AllowCloudTrailDescribeKey   DescribeKey, for the named trails.
  #   AllowCloudTrailDecryptLogs   Decrypt. The documentation requires it
  #                                when the bucket uses an S3 Bucket Key,
  #                                which every SSE-KMS bucket of
  #                                modules/aws/s3-bucket does, and gives it
  #                                without a condition: the call arrives
  #                                through S3 with the bucket's encryption
  #                                context, so neither the trail ARN nor the
  #                                CloudTrail context can be required here.
  dynamic "statement" {
    for_each = length(local.cloudtrail_trail_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "AllowCloudTrailEncryptLogs"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey*"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [local.cloudtrail_principal]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceArn"
        values   = local.cloudtrail_trail_arns[each.key]
      }

      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:aws:cloudtrail:arn"
        values   = [local.cloudtrail_context_pattern]
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.cloudtrail_trail_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "AllowCloudTrailDescribeKey"
      effect    = "Allow"
      actions   = ["kms:DescribeKey"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [local.cloudtrail_principal]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceArn"
        values   = local.cloudtrail_trail_arns[each.key]
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.cloudtrail_trail_arns[each.key]) > 0 ? [1] : []

    content {
      sid       = "AllowCloudTrailDecryptLogs"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = [local.cloudtrail_principal]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Keys and aliases.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  for_each = var.keys

  description             = each.value.description
  deletion_window_in_days = each.value.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.key[each.key].json
  tags                    = each.value.tags

  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  multi_region             = false
  is_enabled               = true

  enable_key_rotation     = true
  rotation_period_in_days = each.value.rotation_period_in_days

  # KMS refuses a policy that would lock the caller out unless this is set.
  # It stays unset: the root statement below keeps the account in, and a
  # policy that KMS thinks locks the caller out is a policy to look at.
  bypass_policy_lockout_safety_check = false

  lifecycle {
    # Destroying a key schedules its deletion, and after the window every
    # object, volume, and secret encrypted under it is unreadable forever.
    # Removing an entry from a cell must not be able to do that; retiring a
    # key is a deliberate change that flips this flag first.
    prevent_destroy = true

    precondition {
      condition     = strcontains(data.aws_iam_policy_document.key[each.key].json, local.account_root_arn)
      error_message = "Key \"${each.key}\": the rendered key policy does not grant the account root principal (${local.account_root_arn}). Without it the key can become unmanageable when the roles it names are deleted; restore the root statement rather than removing it."
    }
  }
}

resource "aws_kms_alias" "this" {
  for_each = var.keys

  name          = "alias/${each.value.alias}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
