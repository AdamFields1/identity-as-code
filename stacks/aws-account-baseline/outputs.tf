output "account_id" {
  description = "The account this cell hardened, as discovered from the deployment role's credentials."
  value       = module.account_hardening.account_id
}

output "partition" {
  description = "Partition the account is in (aws or aws-us-gov)."
  value       = module.account_hardening.partition
}

output "password_policy" {
  description = "The managed password policy as { minimum_password_length, max_password_age_days, password_reuse_prevention, expire_passwords }, or null when it is off."
  value       = module.account_hardening.password_policy
}

output "ebs_encryption" {
  description = "EBS encryption by default in this region as { enabled, default_kms_key_arn }."
  value       = module.account_hardening.ebs_encryption
}

output "s3_public_access_blocked" {
  description = "Whether the account-level S3 Block Public Access setting is managed with all four blocks on."
  value       = module.account_hardening.s3_public_access_blocked
}

output "guardduty_detector" {
  description = "The GuardDuty detector in this region as { id, arn }, or null when it is off."
  value       = module.account_hardening.guardduty_detector
}

output "access_analyzer" {
  description = "The Access Analyzer in this region as { name, arn }, or null when it is off."
  value       = module.account_hardening.access_analyzer
}

output "trail" {
  description = "The account trail as { name, arn, home_region, bucket_name, bucket_arn, kms_key_arn, kms_key_alias, access_log_bucket_name }, or null when cloudtrail.enabled is false. access_log_bucket_name is null when no access log bucket was asked for."
  value = var.cloudtrail.enabled ? {
    name                   = module.trail.trails["account"].name
    arn                    = module.trail.trails["account"].arn
    home_region            = module.trail.trails["account"].home_region
    bucket_name            = module.trail_bucket.buckets["trail"].name
    bucket_arn             = module.trail_bucket.buckets["trail"].arn
    kms_key_arn            = module.trail_key.keys["trail"].arn
    kms_key_alias          = module.trail_key.keys["trail"].alias
    access_log_bucket_name = module.trail_bucket.buckets["trail"].log_target_bucket_name
  } : null
}
