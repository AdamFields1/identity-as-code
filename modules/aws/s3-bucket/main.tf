# S3 buckets, keyed by the caller's logical name, with the posture fixed and
# the knobs that vary between buckets as values.
#
# Fixed for every bucket, and why:
#
#   - ACLs disabled (BucketOwnerEnforced). Every object belongs to the
#     bucket owner and access is decided by policy alone, so a grant cannot
#     hide in an ACL a reviewer does not read.
#   - All four public access blocks on. No public ACL and no public policy
#     can ever be applied; a policy that would open the bucket fails.
#   - Versioning on. A wrong overwrite or delete is recoverable, and the
#     lifecycle rule below is what keeps that from meaning "keep forever".
#   - TLS required. The bucket policy denies every action over plain HTTP.
#   - force_destroy false and prevent_destroy on the bucket. A bucket holds
#     data this repository cannot recreate; removing one is a deliberate
#     change that flips the flag first, never a side effect of a map edit.
#
# Chosen per bucket: SSE-S3 or a KMS key by alias, an optional set of roles
# that are the only principals allowed to touch objects, the lifecycle
# numbers, optional access logging into another bucket of the same map, and
# tags. A bucket that is named as a logging target gets the log delivery
# grant added to its own policy, so the pair works without either cell
# knowing how S3 log delivery authenticates. A bucket that receives a
# CloudTrail trail's log files names the trail in cloudtrail_delivery and
# gets the two statements the CloudTrail documentation requires, scoped to
# that trail's ARN, so a trail in another account cannot write here.
#
# Everything account- and partition-specific is discovered: bucket ARNs are
# built from data.aws_partition, the log delivery condition from
# data.aws_caller_identity, trail ARNs from those two and data.aws_region,
# and roles and KMS aliases are looked up by name in the account the
# provider is pointed at. A cell holds no ARN and no id.
#
# What is deliberately not here, each a checkov skip with the same reason
# on the resource: cross-region replication (a second bucket in a second
# region is a replication design, not a knob) and event notifications (they
# name a queue or function, which is app-stack wiring, ADR 0017).

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  bucket_arns = { for key, b in var.buckets : key => "arn:${local.partition}:s3:::${b.name}" }

  kms_aliases        = toset([for b in var.buckets : b.kms_key_alias if b.kms_key_alias != null])
  allowed_role_names = toset(flatten([for b in var.buckets : b.allowed_role_names]))

  # Access logging, seen from both ends: what each source sends, and what
  # each target must accept in its policy.
  log_sources = {
    for key, b in var.buckets : key => {
      target_key = b.access_logging.target_bucket
      prefix     = coalesce(b.access_logging.prefix, "${b.name}/")
    }
    if b.access_logging != null
  }

  log_sources_by_target = {
    for key in keys(var.buckets) : key => [
      for source_key, s in local.log_sources : { name = var.buckets[source_key].name, prefix = s.prefix }
      if s.target_key == key
    ]
  }

  # CloudTrail delivery. The service principal is the same name in every
  # partition (the dns_suffix form mirrors log delivery above); a trail's
  # ARN carries its home region, which is the provider's region. CloudTrail
  # writes under [prefix/]AWSLogs/<account>/, so that is all the policy
  # allows.
  cloudtrail_principal = "cloudtrail.${local.dns_suffix}"

  cloudtrail_targets = {
    for key, b in var.buckets : key => {
      trail_arns = [
        for n in b.cloudtrail_delivery.trail_names : "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${n}"
      ]
      object_prefix = b.cloudtrail_delivery.prefix == null ? "" : "${b.cloudtrail_delivery.prefix}/"
    }
    if b.cloudtrail_delivery != null
  }
}

# ---------------------------------------------------------------------------
# Name resolution. A KMS alias or a role that does not exist fails the plan
# with its name in the error, before anything is written.
# ---------------------------------------------------------------------------

data "aws_kms_alias" "this" {
  for_each = local.kms_aliases

  name = "alias/${each.value}"
}

data "aws_iam_role" "allowed" {
  for_each = local.allowed_role_names

  name = each.value
}

# ---------------------------------------------------------------------------
# Buckets.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  # checkov:skip=CKV_AWS_144:Cross-region replication needs a second bucket
  # in a second region, a replication role, and a decision about which
  # region; that is a design for the bucket that needs it, not a default for
  # every catalog bucket, and it belongs in an app stack.
  # checkov:skip=CKV2_AWS_62:Event notifications name a queue, topic, or
  # function as their destination, which is cross-resource wiring the
  # catalog does not express (docs/adr/0017). A bucket that needs them is an
  # app stack.
  for_each = var.buckets

  bucket        = each.value.name
  force_destroy = false
  tags          = each.value.tags

  lifecycle {
    # The bucket holds data nothing in this repository can recreate.
    # Removing it is a deliberate change that flips this flag first, never
    # a side effect of removing an entry from a cell.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  # checkov:skip=CKV_AWS_145:SSE-S3 is the default and SSE-KMS is one value
  # away (kms_key_alias). The default is SSE-S3 because a bucket that
  # receives access logs must be, and because a key is a second resource
  # with its own policy and its own cell (modules/aws/kms-key); a bucket
  # that holds data worth a customer-managed key names its alias.
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = each.value.kms_key_alias == null ? "AES256" : "aws:kms"
      kms_master_key_id = try(data.aws_kms_alias.this[each.value.kms_key_alias].target_key_arn, null)
    }

    # A bucket key cuts KMS requests per object to per bucket. Meaningless
    # for SSE-S3, so it is sent only with a key.
    bucket_key_enabled = each.value.kms_key_alias != null
  }
}

# ---------------------------------------------------------------------------
# Lifecycle. One rule per bucket, applied to every object: abort unfinished
# multipart uploads, expire noncurrent versions, and either expire current
# objects after expiration_days or, when objects are kept, remove the delete
# markers left behind once their versions have expired.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "housekeeping"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = each.value.abort_incomplete_multipart_upload_days
    }

    noncurrent_version_expiration {
      noncurrent_days = each.value.noncurrent_version_expiration_days
    }

    dynamic "expiration" {
      for_each = each.value.expiration_days == null ? [] : [each.value.expiration_days]

      content {
        days = expiration.value
      }
    }

    dynamic "expiration" {
      for_each = each.value.expiration_days == null ? [true] : []

      content {
        expired_object_delete_marker = true
      }
    }
  }

  # Noncurrent version rules are only valid on a versioned bucket, and S3
  # rejects them when the two requests race.
  depends_on = [aws_s3_bucket_versioning.this]
}

# ---------------------------------------------------------------------------
# Bucket policy. Five statements at most:
#
#   DenyInsecureTransport         always. Any action over plain HTTP is
#                                 denied for every principal.
#   DenyDataAccessExceptAllowedRoles  when allowed_role_names is set. Object
#                                 reads, writes, and deletes are denied
#                                 unless aws:PrincipalArn is one of the
#                                 named roles (the role ARN, not the
#                                 session ARN, is what that key carries) or
#                                 the caller is an AWS service principal,
#                                 which is how log delivery still lands.
#                                 Listing keys is deliberately not in the
#                                 deny: the provider reads a bucket with
#                                 HeadBucket, which S3 authorizes as
#                                 s3:ListBucket, so a deny on it would 403
#                                 every refresh by the identity that
#                                 manages the bucket unless that identity
#                                 were named, and the release train plans
#                                 as a read-only role and applies as a
#                                 writer, two identities no cell knows.
#                                 Listing stays with IAM; object data does
#                                 not, and bucket management actions were
#                                 never in the deny.
#   S3ServerAccessLogsPolicy      when another bucket in the map logs here.
#                                 logging.s3 may PutObject under each
#                                 source's prefix, for that source bucket
#                                 and this account only.
#   AWSCloudTrailAclCheck         when cloudtrail_delivery is set: the two
#   AWSCloudTrailWrite            statements "Amazon S3 bucket policy for
#                                 CloudTrail" (docs.aws.amazon.com) gives.
#                                 cloudtrail may read the bucket ACL and
#                                 PutObject under [prefix/]AWSLogs/<this
#                                 account>/, for the named trails only
#                                 (aws:SourceArn) and only with the
#                                 bucket-owner-full-control ACL, which S3
#                                 still accepts under BucketOwnerEnforced.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  for_each = var.buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arns[each.key], "${local.bucket_arns[each.key]}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.allowed_role_names) > 0 ? [1] : []

    content {
      sid    = "DenyDataAccessExceptAllowedRoles"
      effect = "Deny"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
      ]

      # Objects only. The bucket ARN itself is not a resource here because
      # the only actions that take it are listing and management, and
      # listing cannot be denied without denying the provider's own
      # HeadBucket (see the header).
      resources = ["${local.bucket_arns[each.key]}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = [for n in each.value.allowed_role_names : data.aws_iam_role.allowed[n].arn]
      }

      # Service principals carry this key as true; IAM principals as false;
      # anonymous requests do not carry it, and IfExists treats absence as
      # matching, so they are denied too.
      condition {
        test     = "BoolIfExists"
        variable = "aws:PrincipalIsAWSService"
        values   = ["false"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.log_sources_by_target[each.key]) > 0 ? [1] : []

    content {
      sid       = "S3ServerAccessLogsPolicy"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = [for s in local.log_sources_by_target[each.key] : "${local.bucket_arns[each.key]}/${s.prefix}*"]

      principals {
        type        = "Service"
        identifiers = ["logging.s3.${local.dns_suffix}"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = [for s in local.log_sources_by_target[each.key] : "arn:${local.partition}:s3:::${s.name}"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(keys(local.cloudtrail_targets), each.key) ? [1] : []

    content {
      sid       = "AWSCloudTrailAclCheck"
      effect    = "Allow"
      actions   = ["s3:GetBucketAcl"]
      resources = [local.bucket_arns[each.key]]

      principals {
        type        = "Service"
        identifiers = [local.cloudtrail_principal]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceArn"
        values   = local.cloudtrail_targets[each.key].trail_arns
      }
    }
  }

  dynamic "statement" {
    for_each = contains(keys(local.cloudtrail_targets), each.key) ? [1] : []

    content {
      sid       = "AWSCloudTrailWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arns[each.key]}/${local.cloudtrail_targets[each.key].object_prefix}AWSLogs/${local.account_id}/*"]

      principals {
        type        = "Service"
        identifiers = [local.cloudtrail_principal]
      }

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceArn"
        values   = local.cloudtrail_targets[each.key].trail_arns
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.bucket[each.key].json

  # A policy is refused while a public access block is being applied in the
  # same second, and the block is the reason the policy is safe to write.
  depends_on = [aws_s3_bucket_public_access_block.this]

  lifecycle {
    precondition {
      # The TLS floor is the one statement every bucket of the catalog
      # promises. If an edit to this file ever drops it, the plan says so.
      condition     = strcontains(data.aws_iam_policy_document.bucket[each.key].json, "DenyInsecureTransport")
      error_message = "Bucket \"${each.key}\": the rendered policy no longer carries the DenyInsecureTransport statement. Every bucket in this module requires TLS; restore the statement rather than lowering the floor."
    }

    precondition {
      condition     = !contains(keys(local.cloudtrail_targets), each.key) || strcontains(data.aws_iam_policy_document.bucket[each.key].json, "AWSCloudTrailWrite")
      error_message = "Bucket \"${each.key}\" is a CloudTrail delivery target, but the rendered policy carries no AWSCloudTrailWrite statement, so CloudTrail would refuse the trail. The grant is derived from cloudtrail_delivery in this module; this is a module defect, not a cell error."
    }
  }
}

# ---------------------------------------------------------------------------
# Access logging. Enabled on the source after the target's policy carries the
# delivery grant, because S3 checks the target's permissions when logging is
# turned on.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_logging" "this" {
  for_each = local.log_sources

  bucket = aws_s3_bucket.this[each.key].id

  target_bucket = aws_s3_bucket.this[each.value.target_key].id
  target_prefix = each.value.prefix

  depends_on = [aws_s3_bucket_policy.this]

  lifecycle {
    precondition {
      condition     = strcontains(data.aws_iam_policy_document.bucket[each.value.target_key].json, "S3ServerAccessLogsPolicy")
      error_message = "Bucket \"${each.key}\" logs to \"${each.value.target_key}\", but the target's rendered policy carries no S3ServerAccessLogsPolicy statement, so S3 would refuse to deliver. The grant is derived from access_logging in this module; this is a module defect, not a cell error."
    }
  }
}
