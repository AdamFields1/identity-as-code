# Account-level hardening that exists once per account, or once per account
# and region, and takes a switch rather than a map: there is one password
# policy, one S3 Block Public Access setting, one EBS encryption default, one
# GuardDuty detector, and one Access Analyzer per region. Each is behind an
# enabled flag whose default is on, except GuardDuty (see the variable), and
# each switch removes its resource when turned off, with the effect the
# provider documents: the password policy reverts to the AWS default, S3
# public access is no longer blocked account-wide, EBS encryption by default
# is turned off, and the default EBS key resets to aws/ebs. The reviewer sees
# each of those as a destroy in the plan.
#
# Two of the five are account-wide (the password policy, S3 Block Public
# Access) and three are regional (the EBS default, GuardDuty, Access
# Analyzer). The module does not iterate regions: it hardens the region the
# provider is pointed at, and a second region is a second cell of the stack
# that composes it.
#
# GuardDuty is the one resource here that holds data. Deleting a detector
# deletes its findings, so the detector is prevent_destroy: turning the
# switch off after it has been on fails the plan until the flag is lifted in
# a dedicated change, the same rule modules/aws/s3-bucket and
# modules/aws/kms-key apply to buckets and keys.
#
# Everything account- and partition-specific is discovered. The one lookup
# by name is the optional EBS default key, resolved from its alias at plan
# time so a misspelt alias fails the plan with the name in the error.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# IAM account password policy. IAM holds one per account and replaces it
# whole on every write, so an existing policy is taken over, not merged.
# ---------------------------------------------------------------------------

resource "aws_iam_account_password_policy" "this" {
  count = var.password_policy.enabled ? 1 : 0

  minimum_password_length        = var.password_policy.minimum_password_length
  require_uppercase_characters   = var.password_policy.require_uppercase_characters
  require_lowercase_characters   = var.password_policy.require_lowercase_characters
  require_numbers                = var.password_policy.require_numbers
  require_symbols                = var.password_policy.require_symbols
  allow_users_to_change_password = var.password_policy.allow_users_to_change_password
  password_reuse_prevention      = var.password_policy.password_reuse_prevention
  hard_expiry                    = var.password_policy.hard_expiry

  # 0 is IAM's own "never expires": the provider then sends no age and IAM
  # reports none back, so the value round-trips without a diff.
  max_password_age = var.password_policy.max_password_age_days
}

# ---------------------------------------------------------------------------
# EBS encryption by default, and optionally which key. Regional.
# ---------------------------------------------------------------------------

resource "aws_ebs_encryption_by_default" "this" {
  count = var.ebs_encryption.enabled ? 1 : 0

  enabled = true
}

data "aws_kms_alias" "ebs" {
  count = var.ebs_encryption.enabled && var.ebs_encryption.kms_key_alias != null ? 1 : 0

  name = "alias/${var.ebs_encryption.kms_key_alias}"
}

resource "aws_ebs_default_kms_key" "this" {
  count = var.ebs_encryption.enabled && var.ebs_encryption.kms_key_alias != null ? 1 : 0

  key_arn = data.aws_kms_alias.ebs[0].target_key_arn

  # A default key only means something once encryption by default is on;
  # ordering the two keeps a first apply from setting a key nothing uses yet.
  depends_on = [aws_ebs_encryption_by_default.this]
}

# ---------------------------------------------------------------------------
# S3 Block Public Access for the account. All four, no knobs. Account-wide.
# ---------------------------------------------------------------------------

resource "aws_s3_account_public_access_block" "this" {
  count = var.s3_public_access_block.enabled ? 1 : 0

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# GuardDuty detector. Regional. Protection plans (S3, EKS, malware, runtime)
# are left at the service defaults for a new detector; each is a feature
# resource with its own cost and belongs in a decision of its own.
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  count = var.guardduty.enabled ? 1 : 0

  enable                       = true
  finding_publishing_frequency = var.guardduty.finding_publishing_frequency
  tags                         = var.tags

  lifecycle {
    # Deleting a detector deletes every finding it holds. Turning the switch
    # off in a cell must not be able to do that; retiring the detector is a
    # deliberate change that lifts this flag first. Suspending it in the
    # console keeps the findings and is the reversible way to stop the bill.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# IAM Access Analyzer, account zone of trust. Regional. Findings are derived
# from the current policies, so the analyzer holds nothing a re-creation
# would not produce again; no prevent_destroy.
# ---------------------------------------------------------------------------

resource "aws_accessanalyzer_analyzer" "this" {
  count = var.access_analyzer.enabled ? 1 : 0

  analyzer_name = var.access_analyzer.name
  type          = "ACCOUNT"
  tags          = var.tags
}
