output "password_policy" {
  description = "The managed password policy as { minimum_password_length, max_password_age_days, password_reuse_prevention, expire_passwords }, or null when password_policy.enabled is false."
  value = var.password_policy.enabled ? {
    minimum_password_length   = aws_iam_account_password_policy.this[0].minimum_password_length
    max_password_age_days     = aws_iam_account_password_policy.this[0].max_password_age
    password_reuse_prevention = aws_iam_account_password_policy.this[0].password_reuse_prevention
    expire_passwords          = aws_iam_account_password_policy.this[0].expire_passwords
  } : null
}

output "ebs_encryption" {
  description = "EBS encryption by default in this region as { enabled, default_kms_key_arn }. default_kms_key_arn is null while the AWS managed aws/ebs key is the default."
  value = {
    enabled             = var.ebs_encryption.enabled
    default_kms_key_arn = one(aws_ebs_default_kms_key.this[*].key_arn)
  }
}

output "s3_public_access_blocked" {
  description = "Whether the account-level S3 Block Public Access setting is managed here with all four blocks on."
  value       = var.s3_public_access_block.enabled
}

output "guardduty_detector" {
  description = "The GuardDuty detector in this region as { id, arn }, or null when guardduty.enabled is false."
  value = var.guardduty.enabled ? {
    id  = aws_guardduty_detector.this[0].id
    arn = aws_guardduty_detector.this[0].arn
  } : null
}

output "access_analyzer" {
  description = "The Access Analyzer in this region as { name, arn }, or null when access_analyzer.enabled is false."
  value = var.access_analyzer.enabled ? {
    name = aws_accessanalyzer_analyzer.this[0].analyzer_name
    arn  = aws_accessanalyzer_analyzer.this[0].arn
  } : null
}

output "partition" {
  description = "AWS partition the account is in (aws, aws-us-gov)."
  value       = data.aws_partition.current.partition
}

output "account_id" {
  description = "The account being hardened, as discovered from the provider's credentials."
  value       = data.aws_caller_identity.current.account_id
}
