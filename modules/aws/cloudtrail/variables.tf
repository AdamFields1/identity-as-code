variable "trails" {
  description = <<-EOT
    CloudTrail trails to manage, keyed by a stable logical name (for example
    "account"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. The visible name is "name".

    name              : the trail name: 3 to 128 letters, digits, periods,
                        underscores, and hyphens, starting and ending with a
                        letter or digit, no two separators in a row, not an IP
                        address. Immutable (forces replacement).
    s3_bucket_name    : NAME of the bucket that receives the log files. Its policy
                        must already carry the CloudTrail delivery statements
                        (modules/aws/s3-bucket, cloudtrail_delivery) when the
                        trail is created; CloudTrail checks and refuses otherwise.
    s3_key_prefix     : optional key prefix in the bucket, up to 200 characters,
                        without leading or trailing slash. Must equal the prefix
                        the bucket policy was built with.
    kms_key_arn       : optional ARN of the KMS key that encrypts the log and
                        digest files (SSE-KMS). Null delivers them under SSE-S3.
                        The key's policy must name the trail (modules/aws/kms-key,
                        cloudtrail_trail_names). A key ARN, not an alias:
                        CloudTrail stores the key ARN, and an alias here would
                        plan a change on every run.
    management_events : what the trail records. Data events are not offered.
      read_write_type             : "All" (default), "ReadOnly", or "WriteOnly".
      exclude_kms_events          : drop AWS KMS management events, which are
                                    high-volume. Default false.
      exclude_rds_data_api_events : drop Amazon RDS Data API management events.
                                    Default false.
    tags              : resource tags on the trail.

    Fixed for every trail: every region, global service events included, log
    file validation on, logging started, not an organization trail, no
    CloudWatch Logs or SNS delivery.
  EOT

  type = map(object({
    name           = string
    s3_bucket_name = string
    s3_key_prefix  = optional(string)
    kms_key_arn    = optional(string)

    management_events = optional(object({
      read_write_type             = optional(string, "All")
      exclude_kms_events          = optional(bool, false)
      exclude_rds_data_api_events = optional(bool, false)
    }), {})

    tags = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for t in var.trails :
      can(regex("^[A-Za-z0-9]([._-]?[A-Za-z0-9])*$", t.name)) && length(t.name) >= 3 && length(t.name) <= 128 && !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", t.name))
    ])
    error_message = "Trail names must be 3 to 128 letters, digits, periods, underscores, and hyphens, start and end with a letter or digit, have no two separators in a row, and not look like an IP address."
  }

  validation {
    condition     = length(distinct([for t in var.trails : t.name])) == length(var.trails)
    error_message = "Trail names must be unique within the map; CloudTrail holds one trail per name per account."
  }

  validation {
    condition = alltrue([
      for t in var.trails :
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", t.s3_bucket_name)) && !strcontains(t.s3_bucket_name, "..") && !startswith(t.s3_bucket_name, "arn:")
    ])
    error_message = "s3_bucket_name is a bucket NAME within the S3 naming rules (3 to 63 lowercase letters, digits, dots, and hyphens), never an ARN."
  }

  validation {
    condition = alltrue([
      for t in var.trails : t.s3_key_prefix == null || (
        can(regex("^[A-Za-z0-9!_.*'()/-]{1,200}$", coalesce(t.s3_key_prefix, "x"))) && !startswith(coalesce(t.s3_key_prefix, "x"), "/") && !endswith(coalesce(t.s3_key_prefix, "x"), "/")
      )
    ])
    error_message = "s3_key_prefix must be up to 200 characters without leading or trailing slash, for example audit or audit/prod, the same value the bucket policy was built with."
  }

  validation {
    condition = alltrue([
      for t in var.trails : t.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", coalesce(t.kms_key_arn, "x")))
    ])
    error_message = "kms_key_arn must be a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<key id>), not an alias, an alias ARN, or a bare key id. CloudTrail stores the key ARN, and anything else here would plan a change on every run."
  }

  validation {
    condition     = alltrue([for t in var.trails : contains(["All", "ReadOnly", "WriteOnly"], t.management_events.read_write_type)])
    error_message = "management_events.read_write_type must be All, ReadOnly, or WriteOnly."
  }
}
