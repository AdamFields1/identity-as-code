variable "buckets" {
  description = <<-EOT
    S3 buckets to manage, keyed by a stable logical name (for example
    "artifacts"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. The bucket name is "name".

    name                                   : the bucket name, globally unique, 3 to 63
                                             lowercase letters, digits, dots, and hyphens.
                                             Immutable (forces replacement, which
                                             prevent_destroy refuses).
    kms_key_alias                          : optional KMS key alias WITHOUT the "alias/"
                                             prefix. Null (default) encrypts with SSE-S3
                                             (AES256); set, the bucket encrypts with that
                                             key (SSE-KMS with a bucket key), looked up by
                                             alias in this account. A bucket that receives
                                             access logs must stay SSE-S3.
    allowed_role_names                     : optional IAM role NAMES, looked up in this
                                             account. When non-empty, the bucket policy
                                             denies object reads, writes, and deletes to
                                             every principal except these roles and AWS
                                             service principals. Listing keys and bucket
                                             management stay with IAM (the provider reads
                                             a bucket through s3:ListBucket, so a deny on
                                             it would fail every refresh), so the
                                             deploying identity manages the bucket and
                                             sees key names without being listed, and
                                             cannot read an object.
    noncurrent_version_expiration_days     : days after an object version becomes
                                             noncurrent that it is deleted. Default 30.
    abort_incomplete_multipart_upload_days : days after which an unfinished multipart
                                             upload is aborted and its parts freed.
                                             Default 7.
    expiration_days                        : optional days after which current objects
                                             expire. Null (default) keeps objects until
                                             they are deleted, and the lifecycle rule
                                             then removes expired delete markers instead.
    access_logging                         : optional server access logging.
      target_bucket                        : the KEY of another bucket in this map that
                                             receives the logs. The target's policy gets
                                             the log delivery grant automatically.
      prefix                               : object key prefix in the target, default
                                             "<this bucket's name>/".
    cloudtrail_delivery                    : optional CloudTrail log delivery. The bucket
                                             policy gets the two statements CloudTrail
                                             requires (GetBucketAcl on the bucket, and
                                             PutObject under [prefix/]AWSLogs/<this
                                             account>/ with bucket-owner-full-control),
                                             scoped to the named trails' ARNs.
      trail_names                          : CloudTrail trail NAMES in this account and
                                             region; the module builds their ARNs.
      prefix                               : optional key prefix the trail is configured
                                             with (its s3_key_prefix), without leading or
                                             trailing slash. Null (default) means the
                                             trail writes at the bucket root.
    tags                                   : resource tags on the bucket.

    Fixed for every bucket: ACLs disabled (BucketOwnerEnforced), all four public
    access blocks on, versioning enabled, TLS required by policy, force_destroy
    false, and prevent_destroy on the bucket.
  EOT

  type = map(object({
    name               = string
    kms_key_alias      = optional(string)
    allowed_role_names = optional(list(string), [])

    noncurrent_version_expiration_days     = optional(number, 30)
    abort_incomplete_multipart_upload_days = optional(number, 7)
    expiration_days                        = optional(number)

    access_logging = optional(object({
      target_bucket = string
      prefix        = optional(string)
    }))

    cloudtrail_delivery = optional(object({
      trail_names = list(string)
      prefix      = optional(string)
    }))

    tags = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for b in var.buckets :
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b.name)) && !strcontains(b.name, "..") && !startswith(b.name, "xn--") && !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", b.name))
    ])
    error_message = "Bucket names must be 3 to 63 lowercase letters, digits, dots, and hyphens, start and end with a letter or digit, not contain \"..\", not start with \"xn--\", and not look like an IP address."
  }

  validation {
    condition     = length(distinct([for b in var.buckets : b.name])) == length(var.buckets)
    error_message = "Bucket names must be unique within the map; S3 holds one bucket per name."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.kms_key_alias == null || (
        can(regex("^[a-zA-Z0-9/_-]{1,250}$", coalesce(b.kms_key_alias, "x"))) && !startswith(coalesce(b.kms_key_alias, "x"), "alias/")
      )
    ])
    error_message = "kms_key_alias is the alias name without the \"alias/\" prefix, for example example-data or aws/s3; letters, digits, slashes, underscores, and hyphens only. The module adds the prefix."
  }

  validation {
    condition = alltrue(flatten([
      for b in var.buckets : [for n in b.allowed_role_names : can(regex("^[\\w+=,.@-]{1,64}$", n))]
    ]))
    error_message = "allowed_role_names holds IAM role NAMES (1 to 64 characters of letters, digits, and + = , . @ _ -), never ARNs and never \"*\". The roles are looked up in this account and the policy is built from their ARNs."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.noncurrent_version_expiration_days >= 1 && floor(b.noncurrent_version_expiration_days) == b.noncurrent_version_expiration_days
    ])
    error_message = "noncurrent_version_expiration_days must be a whole number of at least 1. Versioning keeps every overwritten and deleted object, so this rule is what bounds the bucket's growth."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.abort_incomplete_multipart_upload_days >= 1 && floor(b.abort_incomplete_multipart_upload_days) == b.abort_incomplete_multipart_upload_days
    ])
    error_message = "abort_incomplete_multipart_upload_days must be a whole number of at least 1."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.expiration_days == null || (coalesce(b.expiration_days, 1) >= 1 && floor(coalesce(b.expiration_days, 1)) == coalesce(b.expiration_days, 1))
    ])
    error_message = "expiration_days must be a whole number of at least 1 when set."
  }

  validation {
    condition = alltrue([
      for key, b in var.buckets : b.access_logging == null || (
        contains(keys(var.buckets), try(b.access_logging.target_bucket, "")) && try(b.access_logging.target_bucket, "") != key
      )
    ])
    error_message = "access_logging.target_bucket must be the key of another bucket in this map. A bucket cannot log to itself (S3 would loop), and a bucket outside this map is app-stack wiring, not a catalog value."
  }

  validation {
    condition = alltrue([
      for key, b in var.buckets : try(var.buckets[b.access_logging.target_bucket].access_logging, null) == null
    ])
    error_message = "A bucket that receives access logs must not itself have access_logging set; S3 recommends against chaining log delivery."
  }

  validation {
    condition = alltrue([
      for key, b in var.buckets : try(var.buckets[b.access_logging.target_bucket].kms_key_alias, null) == null
    ])
    error_message = "A bucket that receives access logs must be encrypted with SSE-S3 (kms_key_alias = null). S3 delivers logs to an SSE-KMS target encrypted with a key the owner may not be able to read."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : try(b.access_logging.prefix, null) == null || can(regex("^[A-Za-z0-9!_.*'()/-]{1,512}/$", coalesce(try(b.access_logging.prefix, null), "x/")))
    ])
    error_message = "access_logging.prefix must be a key prefix ending in a slash, for example logs/, so log objects land under a folder rather than sharing a name prefix with other objects."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : b.cloudtrail_delivery == null || (
        length(try(b.cloudtrail_delivery.trail_names, [])) > 0 && alltrue([
          for n in try(b.cloudtrail_delivery.trail_names, []) :
          can(regex("^[A-Za-z0-9]([._-]?[A-Za-z0-9])*$", n)) && length(n) >= 3 && length(n) <= 128 && !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", n))
        ])
      )
    ])
    error_message = "cloudtrail_delivery.trail_names holds at least one CloudTrail trail NAME: 3 to 128 letters, digits, periods, underscores, and hyphens, starting and ending with a letter or digit, no two separators in a row, not an IP address, never an ARN. The module builds each trail's ARN from the caller's partition, region, and account."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : try(b.cloudtrail_delivery.prefix, null) == null || (
        can(regex("^[A-Za-z0-9!_.*'()/-]{1,200}$", coalesce(try(b.cloudtrail_delivery.prefix, null), "x"))) && !startswith(coalesce(try(b.cloudtrail_delivery.prefix, null), "x"), "/") && !endswith(coalesce(try(b.cloudtrail_delivery.prefix, null), "x"), "/")
      )
    ])
    error_message = "cloudtrail_delivery.prefix is the trail's s3_key_prefix as CloudTrail takes it: up to 200 characters, without leading or trailing slash, for example audit or audit/prod. The module adds the slash between it and AWSLogs/."
  }
}
