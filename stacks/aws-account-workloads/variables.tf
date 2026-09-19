# ---------------------------------------------------------------------------
# Region. Consumed by the Terragrunt-generated provider block, never by
# resources directly. Every bucket and key in this cell is created in it.
# For an account cell it arrives from the partition locator
# (tenants/aws/<partition>/partition.hcl) through tenants/aws/root.hcl, so
# the cell does not say it; a cell that sets it wins. Credentials, the
# account, and the partition are not variables: the root gives the provider
# the profile that names the account's deployment role
# (identity-as-code-<account-name>, filled on the runner or the workstation,
# never by a cell) and allowed_account_ids from the account locator, and
# the modules discover the rest with data sources.
# ---------------------------------------------------------------------------

variable "region" {
  description = "Region the provider talks to and every bucket and key in this cell is created in, for example us-east-1 or us-gov-west-1. Supplied by tenants/aws/root.hcl from the partition locator; a cell that sets it wins."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as us-east-1 or us-gov-west-1."
  }
}

# ---------------------------------------------------------------------------
# Tags shared by everything in the cell. An entry's own tags are merged on
# top, so a cell states its owner and cost centre once and a bucket can still
# carry a tag of its own.
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every role, instance profile, key, and bucket in this cell. An entry's own tags are merged on top and win on the same key."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Service roles. Same shape as modules/aws/iam-service-role, plus
# bucket_access, which this stack turns into the role's inline policy so the
# two common shapes (read a bucket, read and write a bucket) need no
# hand-written JSON. Bucket names may be buckets of this cell or buckets that
# already exist in the account; the ARN is built from the name and the
# partition, so nothing has to be looked up.
# ---------------------------------------------------------------------------

variable "service_roles" {
  description = <<-EOT
    IAM roles keyed by logical name. See modules/aws/iam-service-role for every
    attribute except bucket_access, which is this stack's addition:

    bucket_access.read       : bucket NAMES the role may list and read objects from.
    bucket_access.read_write : bucket NAMES the role may also write and delete
                               objects in (read is implied). A writer never gets
                               s3:DeleteObjectVersion: on a versioned bucket a delete
                               is a delete marker, and purging history stays with the
                               lifecycle rule.

    The generated statements are merged with inline_policy when both are set,
    so a role can carry the common shape and one extra statement of its own.
    A bucket named here that is defined in this cell is checked against that
    bucket's allowed_role_names and, when the bucket is encrypted with a key of
    this cell, against that key's user_role_names, so a role that would be denied
    by the bucket policy or the key policy fails the plan instead of the first
    request.
  EOT

  type = map(object({
    name        = string
    description = optional(string, "Managed by Terraform.")
    path        = optional(string, "/")

    trust = object({
      services           = optional(list(string), [])
      account_principals = optional(list(string), [])
      external_id        = optional(string)
      oidc_github = optional(object({
        repository   = string
        branches     = optional(list(string), [])
        environments = optional(list(string), [])
      }))
    })

    aws_managed_policies = optional(list(string), [])

    customer_managed_policies = optional(list(object({
      name = string
      path = optional(string, "/")
    })), [])

    inline_policy = optional(string)

    bucket_access = optional(object({
      read       = optional(list(string), [])
      read_write = optional(list(string), [])
    }), {})

    permissions_boundary = optional(object({
      aws_managed_policy = optional(string)
      customer_managed_policy = optional(object({
        name = string
        path = optional(string, "/")
      }))
    }))

    allow_admin          = optional(bool, false)
    max_session_duration = optional(number, 3600)
    tags                 = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for r in var.service_roles : [
        for n in concat(r.bucket_access.read, r.bucket_access.read_write) : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", n))
      ]
    ]))
    error_message = "bucket_access lists bucket NAMES (3 to 63 lowercase letters, digits, dots, and hyphens), never ARNs and never a wildcard. The stack builds the ARN from the name and the partition, so a bucket of this cell and a bucket that already exists in the account are named the same way."
  }

  validation {
    condition     = alltrue([for r in var.service_roles : length(setintersection(toset(r.bucket_access.read), toset(r.bucket_access.read_write))) == 0])
    error_message = "A bucket appears in both bucket_access.read and bucket_access.read_write of the same role. read_write already implies read; list each bucket once so the diff says which it is."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.service_roles : [
        for b in var.buckets : length(b.allowed_role_names) == 0 || contains(b.allowed_role_names, r.name)
        if contains(concat(r.bucket_access.read, r.bucket_access.read_write), b.name)
      ]
    ]))
    error_message = "A role's bucket_access names a bucket of this cell whose allowed_role_names does not list that role. The bucket policy would deny the role every object action its inline policy allows. Add the role's name to the bucket's allowed_role_names, or remove the bucket from bucket_access."
  }

  validation {
    # try() returns true when the bucket's kms_key names no key of this cell;
    # the buckets validation reports that case with its own message.
    condition = alltrue(flatten([
      for r in var.service_roles : [
        for b in var.buckets : try(contains(var.kms_keys[b.kms_key].user_role_names, "${trimprefix(r.path, "/")}${r.name}"), true)
        if b.kms_key != null && contains(concat(r.bucket_access.read, r.bucket_access.read_write), b.name)
      ]
    ]))
    error_message = "A role's bucket_access names a bucket of this cell that is encrypted with a key of this cell, but the key's user_role_names does not list the role. Reading or writing an object needs the key as well as the bucket, so the role would get AccessDenied from KMS on its first request. Add the role to the key's user_role_names as <path without its leading slash><name>: svc/example-deployer for a role at /svc/, example-deployer for a role at /."
  }
}

# ---------------------------------------------------------------------------
# KMS keys. Same shape as modules/aws/kms-key. Role names may be roles of
# this cell or roles that already exist in the account; a role of this cell
# with a path is written path/name, the form the module takes.
# ---------------------------------------------------------------------------

variable "kms_keys" {
  description = "Customer managed KMS keys keyed by logical name. See modules/aws/kms-key for attribute semantics and defaults. A bucket of this cell names a key by this map's key (buckets.<k>.kms_key); a role of this cell is named in administrator_role_names or user_role_names by its name, with its path in front when it has one (svc/example-deployer)."
  type = map(object({
    alias                    = string
    description              = optional(string, "Managed by Terraform.")
    deletion_window_in_days  = optional(number, 30)
    rotation_period_in_days  = optional(number, 365)
    administrator_role_names = optional(list(string), [])
    user_role_names          = optional(list(string), [])
    tags                     = optional(map(string), {})
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Buckets. Same shape as modules/aws/s3-bucket, plus kms_key, which names a
# key of this cell by its map key; the stack resolves the alias the module
# looks up. kms_key_alias stays for a key that already exists in the account.
# ---------------------------------------------------------------------------

variable "buckets" {
  description = <<-EOT
    S3 buckets keyed by logical name. See modules/aws/s3-bucket for every
    attribute except kms_key, which is this stack's addition:

    kms_key       : the KEY of an entry in kms_keys. The bucket is encrypted with
                    that key (SSE-KMS with a bucket key) and the stack supplies the
                    module with the key's alias. Exactly one of kms_key and
                    kms_key_alias may be set; neither means SSE-S3.
    kms_key_alias : the bare alias (without alias/) of a key that already exists in
                    the account and is managed elsewhere.

    allowed_role_names lists role NAMES, of this cell or already in the account;
    access_logging.target_bucket is the KEY of another bucket in this map, and a
    logging target must be SSE-S3.
  EOT

  type = map(object({
    name               = string
    kms_key            = optional(string)
    kms_key_alias      = optional(string)
    allowed_role_names = optional(list(string), [])

    noncurrent_version_expiration_days     = optional(number, 30)
    abort_incomplete_multipart_upload_days = optional(number, 7)
    expiration_days                        = optional(number)

    access_logging = optional(object({
      target_bucket = string
      prefix        = optional(string)
    }))

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for b in var.buckets : !(b.kms_key != null && b.kms_key_alias != null)])
    error_message = "A bucket sets both kms_key and kms_key_alias. kms_key names a key of this cell by its map key and kms_key_alias names a key that already exists in the account; a bucket is encrypted with one key, so set one of them."
  }

  validation {
    condition     = alltrue([for b in var.buckets : b.kms_key == null || contains(keys(var.kms_keys), coalesce(b.kms_key, "-"))])
    error_message = "A bucket's kms_key is not the key of an entry in this cell's kms_keys. Add the key to kms_keys, or name a key that already exists in the account with kms_key_alias."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.access_logging == null || (
        try(var.buckets[b.access_logging.target_bucket].kms_key, null) == null && try(var.buckets[b.access_logging.target_bucket].kms_key_alias, null) == null
      )
    ])
    error_message = "A bucket that receives access logs must be SSE-S3: the target sets neither kms_key nor kms_key_alias. S3 delivers logs to an SSE-KMS target encrypted with a key the owner may not be able to read."
  }
}
