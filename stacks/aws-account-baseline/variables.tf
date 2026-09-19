# ---------------------------------------------------------------------------
# Region. Consumed by the Terragrunt-generated provider block, never by
# resources directly. For an account cell it arrives from the partition
# locator (tenants/aws/<partition>/partition.hcl); a cell that sets it wins.
# The password policy, the S3 public access block, and the trail (which is
# multi-region) are account-wide; EBS encryption by default, GuardDuty, and
# Access Analyzer are regional and land in this region only. Credentials are
# not variables: for an account cell the root gives the provider the shared
# config profile that names the account's deployment role
# (identity-as-code-<account-name>, filled by the workflow or by the
# engineer, never by a cell), so no role ARN enters a plan file, a cell, or
# state.
# ---------------------------------------------------------------------------

variable "region" {
  description = "Region the regional parts of the baseline land in (EBS encryption by default, GuardDuty, Access Analyzer) and the home region of the trail, for example us-east-1 or us-gov-west-1. Also selects the partition: a us-gov-* region is the aws-us-gov partition."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as us-east-1 or us-gov-west-1."
  }
}

# ---------------------------------------------------------------------------
# The switches. Same shapes as modules/aws/account-hardening; every one is
# on by default except GuardDuty, and a cell that says nothing gets the
# strict posture.
# ---------------------------------------------------------------------------

variable "password_policy" {
  description = "IAM account password policy. See modules/aws/account-hardening for attribute semantics; defaults meet CIS AWS Foundations 1.8 and 1.9. enabled defaults to true."
  type = object({
    enabled                        = optional(bool, true)
    minimum_password_length        = optional(number, 14)
    require_uppercase_characters   = optional(bool, true)
    require_lowercase_characters   = optional(bool, true)
    require_numbers                = optional(bool, true)
    require_symbols                = optional(bool, true)
    allow_users_to_change_password = optional(bool, true)
    max_password_age_days          = optional(number, 90)
    password_reuse_prevention      = optional(number, 24)
    hard_expiry                    = optional(bool, false)
  })
  default = {}
}

variable "ebs_encryption" {
  description = "EBS encryption by default for this region, optionally under a customer managed key named by alias (without alias/). See modules/aws/account-hardening. enabled defaults to true."
  type = object({
    enabled       = optional(bool, true)
    kms_key_alias = optional(string)
  })
  default = {}
}

variable "s3_public_access_block" {
  description = "Account-level S3 Block Public Access, all four blocks on. See modules/aws/account-hardening. enabled defaults to true."
  type = object({
    enabled = optional(bool, true)
  })
  default = {}
}

variable "guardduty" {
  description = "GuardDuty detector for this region. enabled defaults to FALSE (see modules/aws/account-hardening for why, and for why turning it off again is refused once it has been on)."
  type = object({
    enabled                      = optional(bool, false)
    finding_publishing_frequency = optional(string, "FIFTEEN_MINUTES")
  })
  default = {}
}

variable "access_analyzer" {
  description = "IAM Access Analyzer with this account as its zone of trust, for this region. See modules/aws/account-hardening. enabled defaults to true."
  type = object({
    enabled = optional(bool, true)
    name    = optional(string, "account-analyzer")
  })
  default = {}
}

# ---------------------------------------------------------------------------
# The trail. One per account: multi-region, log file validation on,
# management events, delivered to a bucket this stack creates through
# modules/aws/s3-bucket and encrypted with a key this stack creates through
# modules/aws/kms-key. Both policies carry the CloudTrail service principal,
# scoped to this trail's ARN, and the modules build that ARN; a cell types
# names only.
# ---------------------------------------------------------------------------

variable "cloudtrail" {
  description = <<-EOT
    The account trail and what it delivers to.

    enabled                           : default true. bucket_name is required when
                                        it is. Turning it off after it has been on
                                        is refused by prevent_destroy on the bucket
                                        and the key; see the README.
    trail_name                        : CloudTrail naming rules. Default
                                        "account-trail".
    bucket_name                       : globally unique name of the bucket the
                                        trail writes to. Required when enabled.
    s3_key_prefix                     : optional key prefix in the bucket, no
                                        leading or trailing slash. Null (default)
                                        writes at the bucket root.
    kms_key_alias                     : alias (without "alias/") of the key this
                                        stack creates for the trail and the bucket.
                                        Default "cloudtrail".
    kms_key_administrator_role_names  : IAM role NAMES in this account that may
                                        manage the key but not use it. Default
                                        none; the account root always can.
    kms_key_user_role_names           : IAM role NAMES in this account that may use
                                        the key, which is what reading the
                                        encrypted log files takes. Default none.
    log_expiration_days               : optional days after which log objects
                                        expire. Null (default) keeps them.
    access_log_bucket_name            : optional globally unique name of a second
                                        bucket that receives the trail bucket's S3
                                        server access logs (CIS AWS Foundations
                                        3.6). Null (default) creates no second
                                        bucket.
    access_log_expiration_days        : days after which access log objects
                                        expire. Default 400.
    management_events_read_write_type : "All" (default), "ReadOnly", or
                                        "WriteOnly".
    exclude_kms_events                : drop AWS KMS management events, which are
                                        high-volume. Default false.
    exclude_rds_data_api_events       : drop Amazon RDS Data API management
                                        events. Default false.
  EOT

  type = object({
    enabled                           = optional(bool, true)
    trail_name                        = optional(string, "account-trail")
    bucket_name                       = optional(string)
    s3_key_prefix                     = optional(string)
    kms_key_alias                     = optional(string, "cloudtrail")
    kms_key_administrator_role_names  = optional(list(string), [])
    kms_key_user_role_names           = optional(list(string), [])
    log_expiration_days               = optional(number)
    access_log_bucket_name            = optional(string)
    access_log_expiration_days        = optional(number, 400)
    management_events_read_write_type = optional(string, "All")
    exclude_kms_events                = optional(bool, false)
    exclude_rds_data_api_events       = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.cloudtrail.enabled || var.cloudtrail.bucket_name != null
    error_message = "cloudtrail.bucket_name is required while cloudtrail.enabled is true (the default): the trail needs a bucket, and bucket names are global, so the cell has to choose one."
  }

  validation {
    condition     = var.cloudtrail.access_log_bucket_name == null || var.cloudtrail.access_log_bucket_name != var.cloudtrail.bucket_name
    error_message = "cloudtrail.access_log_bucket_name must differ from cloudtrail.bucket_name; a bucket cannot receive its own access logs."
  }

  validation {
    condition     = !startswith(var.cloudtrail.kms_key_alias, "alias/") && !startswith(var.cloudtrail.kms_key_alias, "aws/")
    error_message = "cloudtrail.kms_key_alias is the alias name without the \"alias/\" prefix, and cannot start with \"aws/\" because this stack creates the key."
  }

  validation {
    condition     = contains(["All", "ReadOnly", "WriteOnly"], var.cloudtrail.management_events_read_write_type)
    error_message = "cloudtrail.management_events_read_write_type must be All, ReadOnly, or WriteOnly."
  }
}

variable "tags" {
  description = "Resource tags applied to everything this stack creates that can carry them: the trail, the bucket(s), the key, the GuardDuty detector, and the analyzer."
  type        = map(string)
  default     = {}
}
