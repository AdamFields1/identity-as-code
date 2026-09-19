variable "password_policy" {
  description = <<-EOT
    The IAM account password policy. One per account; it governs the console
    passwords of IAM users (Identity Center users are governed by the identity
    source, docs/adr/0008). Defaults meet CIS AWS Foundations 1.8 and 1.9; a
    cell may tighten them, and the diff shows anything it loosens.

    enabled                        : manage the policy. Default true. false removes
                                     it, and the account falls back to the AWS
                                     default (6 characters, nothing required).
    minimum_password_length        : 14 to 128. Default 14. The floor is CIS 1.8;
                                     a shorter minimum is not a baseline.
    require_uppercase_characters   : default true.
    require_lowercase_characters   : default true.
    require_numbers                : default true.
    require_symbols                : default true.
    allow_users_to_change_password : default true.
    max_password_age_days          : days a password stays valid, 1 to 1095, or 0
                                     for passwords that never expire (what IAM
                                     itself means by 0). Default 90.
    password_reuse_prevention      : previous passwords a user may not reuse,
                                     1 to 24. Default 24 (CIS 1.9).
    hard_expiry                    : an expired password can only be reset by an
                                     administrator. Default false. Needs a
                                     max_password_age_days above 0.
  EOT

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

  validation {
    condition     = var.password_policy.minimum_password_length >= 14 && var.password_policy.minimum_password_length <= 128 && floor(var.password_policy.minimum_password_length) == var.password_policy.minimum_password_length
    error_message = "password_policy.minimum_password_length must be a whole number from 14 to 128. 14 is the CIS AWS Foundations 1.8 floor; a baseline that allows less is not a baseline."
  }

  validation {
    condition     = var.password_policy.max_password_age_days >= 0 && var.password_policy.max_password_age_days <= 1095 && floor(var.password_policy.max_password_age_days) == var.password_policy.max_password_age_days
    error_message = "password_policy.max_password_age_days must be a whole number from 1 to 1095, or 0 for passwords that never expire."
  }

  validation {
    condition     = var.password_policy.password_reuse_prevention >= 1 && var.password_policy.password_reuse_prevention <= 24 && floor(var.password_policy.password_reuse_prevention) == var.password_policy.password_reuse_prevention
    error_message = "password_policy.password_reuse_prevention must be a whole number from 1 to 24, the range IAM accepts."
  }

  validation {
    condition     = !var.password_policy.hard_expiry || var.password_policy.max_password_age_days > 0
    error_message = "password_policy.hard_expiry locks a user out once their password expires, so it needs max_password_age_days above 0; with passwords that never expire it does nothing and would mislead a reviewer."
  }
}

variable "ebs_encryption" {
  description = <<-EOT
    EBS encryption by default, for the region the provider is pointed at. Every
    new volume and snapshot in the region is encrypted whether or not the caller
    asked, under the AWS managed aws/ebs key or the customer managed key named
    here. Unencrypted AMIs shared from other accounts can then no longer be
    launched directly; that is the point.

    enabled       : manage the setting. Default true. false removes the resource,
                    which turns encryption by default off again.
    kms_key_alias : optional alias (without "alias/") of a customer managed key in
                    this account and region to make the default EBS key, looked up
                    by name at plan time. Null (default) keeps the AWS managed
                    aws/ebs key. Removing it later resets the default to aws/ebs.
  EOT

  type = object({
    enabled       = optional(bool, true)
    kms_key_alias = optional(string)
  })
  default = {}

  validation {
    condition = var.ebs_encryption.kms_key_alias == null || (
      can(regex("^[a-zA-Z0-9/_-]{1,250}$", coalesce(var.ebs_encryption.kms_key_alias, "x"))) && !startswith(coalesce(var.ebs_encryption.kms_key_alias, "x"), "alias/")
    )
    error_message = "ebs_encryption.kms_key_alias is the alias name without the \"alias/\" prefix, for example example-ebs; letters, digits, slashes, underscores, and hyphens only. The module adds the prefix and looks the key up in this account and region."
  }

  validation {
    condition     = var.ebs_encryption.kms_key_alias == null || var.ebs_encryption.enabled
    error_message = "ebs_encryption.kms_key_alias names the default key for encryption by default, so it needs ebs_encryption.enabled = true; a default key with encryption by default off does nothing."
  }
}

variable "s3_public_access_block" {
  description = <<-EOT
    The account-level S3 Block Public Access setting. All four blocks are on
    for every bucket in the account, present and future, whatever the bucket's
    own settings say: no public ACL and no public bucket policy can be applied
    anywhere in the account. Account-wide, not regional.

    enabled : manage the setting. Default true. false removes it, and buckets
              fall back to their own settings.
  EOT

  type = object({
    enabled = optional(bool, true)
  })
  default = {}
}

variable "guardduty" {
  description = <<-EOT
    The GuardDuty detector for the region the provider is pointed at. Off by
    default because GuardDuty is priced on the volume of logs it inspects and
    an estate normally enables it from a delegated administrator account rather
    than account by account; a cell turns it on when this account is meant to
    have its own detector.

    enabled                      : create the detector. Default false. Once on,
                                   turning it off is refused by prevent_destroy,
                                   because deleting a detector deletes every
                                   finding it holds; see the README.
    finding_publishing_frequency : how often updated findings are exported:
                                   FIFTEEN_MINUTES (default), ONE_HOUR, or
                                   SIX_HOURS.
  EOT

  type = object({
    enabled                      = optional(bool, false)
    finding_publishing_frequency = optional(string, "FIFTEEN_MINUTES")
  })
  default = {}

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.guardduty.finding_publishing_frequency)
    error_message = "guardduty.finding_publishing_frequency must be FIFTEEN_MINUTES, ONE_HOUR, or SIX_HOURS, the values GuardDuty accepts."
  }
}

variable "access_analyzer" {
  description = <<-EOT
    The IAM Access Analyzer with this account as its zone of trust, for the
    region the provider is pointed at. It reports every resource policy in the
    account that grants access to a principal outside the account.

    enabled : create the analyzer. Default true.
    name    : analyzer name, a letter followed by up to 254 letters, digits,
              underscores, periods, and hyphens. Default "account-analyzer".
  EOT

  type = object({
    enabled = optional(bool, true)
    name    = optional(string, "account-analyzer")
  })
  default = {}

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_.-]{0,254}$", var.access_analyzer.name))
    error_message = "access_analyzer.name must start with a letter and contain only letters, digits, underscores, periods, and hyphens, up to 255 characters."
  }
}

variable "tags" {
  description = "Resource tags applied to every resource here that can carry them (the GuardDuty detector and the analyzer). The password policy and the account-level settings cannot be tagged."
  type        = map(string)
  default     = {}
}
