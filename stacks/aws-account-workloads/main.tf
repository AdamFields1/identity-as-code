# aws-account-workloads stack
#
# The AWS catalog stack (docs/adr/0017). One deployable unit per account
# that offers three vetted shapes as values, so an account can get a one-off
# service role, KMS key, or S3 bucket without anyone writing Terraform:
#
#   service roles  -->  KMS keys  -->  S3 buckets
#   (who may act)       (a policy       (a policy names roles, the
#                        names roles)    encryption names a key)
#
# The three maps are values a reviewer reads: a role is a trust shape and
# policy names, a key is an alias and role names, a bucket is a name and
# knobs. Every guardrail lives in the module that owns the shape (what it
# refuses, prevent_destroy where destruction is dangerous); this stack owns
# the wiring between the maps and nothing else.
#
# Wiring the stack does so a cell never writes an ARN or a document:
#
#   - A bucket names a key of this cell by its map key (kms_key). The stack
#     hands the bucket module the key's alias, which the module looks up.
#   - A role names buckets (bucket_access.read, bucket_access.read_write).
#     The stack renders the inline policy from the names and the partition,
#     so the two common shapes need no hand-written JSON, and merges it with
#     the role's own inline_policy when one is set.
#   - A key names roles, a bucket names roles, and both may name roles of
#     this cell or roles that already exist in the account. The stack checks
#     the cross-references it can see (a role granted a bucket is on that
#     bucket's allow list and on its key's user list) so a denial shows up in
#     the plan rather than in the first request.
#
# Order of apply, and why each edge exists:
#
#   roles before keys     KMS validates every principal in a key policy when
#                         the policy is written, so a key that names a role of
#                         this cell must be written after the role exists. The
#                         edge is made by reading the role's name back from the
#                         roles module instead of from the cell (see
#                         local.cell_role_kms_names): the value is the same
#                         string, known at plan, and Terraform orders the two
#                         without deferring the key's plan-time reads.
#   roles and keys        The bucket module resolves allowed_role_names and the
#   before buckets        KMS alias with data sources at plan time. A role or
#                         key created in the same plan does not exist yet when
#                         the plan runs, so the bucket module carries a
#                         module-level depends_on on both. Terraform then defers
#                         the bucket module's reads to apply whenever roles or
#                         keys have a change pending, which is what lets a new
#                         account's first cell land roles, keys, and buckets in
#                         one plan. The cost is stated in the README: in such a
#                         plan every bucket's policy and encryption settings
#                         show as an in-place update with values known after
#                         apply, and resolve to the same values at apply. A plan
#                         that touches only buckets reads everything at plan
#                         time as usual.
#
# Account cells (tenants/aws/<partition>/accounts/<account-name>/aws-account-workloads/terragrunt.hcl)
# supply values only. The partition and the account are discovered from the
# credentials the root gives the provider, which it assembles from the
# locator files above the cell; nothing in a cell says where it is.
#
# Deliberately NOT managed here: the deployment roles the provider's profile
# names and the GitHub OIDC provider the role module looks up (platform
# bootstrap), customer managed policies a role attaches by name, permissions
# boundaries, and anything that is one application's composition rather than
# an entry from the menu (an app stack, docs/adr/0017).

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition
}

# ---------------------------------------------------------------------------
# Bucket access policies. One document per role that asks for one, rendered
# from bucket names: a bucket ARN is the name and the partition, so a bucket
# of this cell and a bucket that already exists in the account are granted
# the same way and nothing is looked up. read_write implies read.
#
# What is deliberately not granted: s3:DeleteObjectVersion (a delete on a
# versioned bucket is a delete marker, and purging history stays with the
# bucket's lifecycle rule, which is the recovery story the bucket module
# promises), object ACL actions (ACLs are disabled on every catalog bucket),
# and every bucket management action (a workload reads and writes objects;
# the bucket is managed by this repository).
# ---------------------------------------------------------------------------

locals {
  roles_with_bucket_access = {
    for key, r in var.service_roles : key => {
      read       = sort(distinct(concat(r.bucket_access.read, r.bucket_access.read_write)))
      read_write = sort(distinct(r.bucket_access.read_write))
    }
    if length(r.bucket_access.read) + length(r.bucket_access.read_write) > 0
  }
}

data "aws_iam_policy_document" "bucket_access" {
  for_each = local.roles_with_bucket_access

  # The role's own inline_policy, when it has one, is merged in front of the
  # generated statements so a role can carry the common shape and one extra
  # statement of its own. Sids must be unique across both; the provider says
  # so at plan time if they collide.
  source_policy_documents = var.service_roles[each.key].inline_policy == null ? [] : [var.service_roles[each.key].inline_policy]

  statement {
    sid       = "S3ListReadableBuckets"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"]
    resources = [for n in each.value.read : "arn:${local.partition}:s3:::${n}"]
  }

  statement {
    sid       = "S3ReadObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAttributes"]
    resources = [for n in each.value.read : "arn:${local.partition}:s3:::${n}/*"]
  }

  dynamic "statement" {
    for_each = length(each.value.read_write) > 0 ? [1] : []

    content {
      sid       = "S3WriteObjects"
      effect    = "Allow"
      actions   = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
      resources = [for n in each.value.read_write : "arn:${local.partition}:s3:::${n}/*"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.read_write) > 0 ? [1] : []

    content {
      sid       = "S3ListMultipartUploads"
      effect    = "Allow"
      actions   = ["s3:ListBucketMultipartUploads"]
      resources = [for n in each.value.read_write : "arn:${local.partition}:s3:::${n}"]
    }
  }
}

# ---------------------------------------------------------------------------
# Service roles first. Everything else may name them.
# ---------------------------------------------------------------------------

module "service_roles" {
  source = "../../modules/aws/iam-service-role"

  roles = {
    for key, r in var.service_roles : key => {
      name        = r.name
      description = r.description
      path        = r.path
      trust       = r.trust

      aws_managed_policies      = r.aws_managed_policies
      customer_managed_policies = r.customer_managed_policies
      inline_policy             = contains(keys(local.roles_with_bucket_access), key) ? data.aws_iam_policy_document.bucket_access[key].json : r.inline_policy
      permissions_boundary      = r.permissions_boundary

      allow_admin          = r.allow_admin
      max_session_duration = r.max_session_duration
      tags                 = merge(var.tags, r.tags)
    }
  }
}

# ---------------------------------------------------------------------------
# KMS keys, after the roles their policies name.
#
# The kms-key module takes role names as <path without its leading slash><name>
# and builds the ARN itself, so a role of this cell is named in a cell the
# same way it would be if it already existed. For those roles the name is
# read back from the roles module rather than from the cell: same string,
# but now the key policy depends on the role and is written after it, which
# is the order KMS requires. A name that is not a role of this cell is passed
# through untouched and KMS checks it at apply, as the module documents.
# ---------------------------------------------------------------------------

locals {
  cell_role_kms_names = {
    for key, r in var.service_roles :
    "${trimprefix(r.path, "/")}${r.name}" => "${trimprefix(module.service_roles.roles[key].path, "/")}${module.service_roles.roles[key].name}"
  }

  # The role names each key policy is written with, after routing. Also in
  # the kms_keys output, so "who may use this key" is readable next to it.
  kms_key_role_names = {
    for key, k in var.kms_keys : key => {
      administrator_role_names = [for n in k.administrator_role_names : lookup(local.cell_role_kms_names, n, n)]
      user_role_names          = [for n in k.user_role_names : lookup(local.cell_role_kms_names, n, n)]
    }
  }
}

module "kms_keys" {
  source = "../../modules/aws/kms-key"

  keys = {
    for key, k in var.kms_keys : key => {
      alias                    = k.alias
      description              = k.description
      deletion_window_in_days  = k.deletion_window_in_days
      rotation_period_in_days  = k.rotation_period_in_days
      administrator_role_names = local.kms_key_role_names[key].administrator_role_names
      user_role_names          = local.kms_key_role_names[key].user_role_names
      tags                     = merge(var.tags, k.tags)
    }
  }
}

# ---------------------------------------------------------------------------
# Buckets last. A bucket that names a key of this cell gets that key's alias;
# everything else passes through. The depends_on is what lets a bucket name a
# role or key created in the same plan (see the header for what it costs).
# ---------------------------------------------------------------------------

locals {
  # The alias each bucket is encrypted with: resolved from kms_key, taken
  # from kms_key_alias, or null for SSE-S3. Also in the buckets output.
  bucket_kms_aliases = {
    for key, b in var.buckets : key => b.kms_key == null ? b.kms_key_alias : var.kms_keys[b.kms_key].alias
  }
}

module "buckets" {
  source = "../../modules/aws/s3-bucket"

  buckets = {
    for key, b in var.buckets : key => {
      name               = b.name
      kms_key_alias      = local.bucket_kms_aliases[key]
      allowed_role_names = b.allowed_role_names

      noncurrent_version_expiration_days     = b.noncurrent_version_expiration_days
      abort_incomplete_multipart_upload_days = b.abort_incomplete_multipart_upload_days
      expiration_days                        = b.expiration_days

      access_logging = b.access_logging
      tags           = merge(var.tags, b.tags)
    }
  }

  depends_on = [module.service_roles, module.kms_keys]
}
