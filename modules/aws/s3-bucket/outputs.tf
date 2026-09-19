output "buckets" {
  description = "Map of logical key to { name, arn, id, region, regional_domain_name, sse_algorithm, kms_key_arn, log_target_bucket_name }. kms_key_arn is null for SSE-S3 buckets; log_target_bucket_name is null when access logging is off."
  value = {
    for k, b in aws_s3_bucket.this : k => {
      name                   = b.bucket
      arn                    = b.arn
      id                     = b.id
      region                 = b.bucket_region
      regional_domain_name   = b.bucket_regional_domain_name
      sse_algorithm          = var.buckets[k].kms_key_alias == null ? "AES256" : "aws:kms"
      kms_key_arn            = try(data.aws_kms_alias.this[var.buckets[k].kms_key_alias].target_key_arn, null)
      log_target_bucket_name = try(var.buckets[local.log_sources[k].target_key].name, null)
    }
  }
}

output "bucket_arns_by_name" {
  description = "Map of bucket NAME to ARN, for callers that reference buckets by name."
  value       = { for k, b in var.buckets : b.name => aws_s3_bucket.this[k].arn }
}

output "allowed_role_arns" {
  description = "Map of role NAME to ARN for every role named in any bucket's allowed_role_names, as resolved in this account."
  value       = { for n, r in data.aws_iam_role.allowed : n => r.arn }
}

output "partition" {
  description = "AWS partition the buckets were created in (aws, aws-us-gov)."
  value       = local.partition
}

output "account_id" {
  description = "Account the buckets were created in, as discovered from the provider's credentials."
  value       = local.account_id
}
