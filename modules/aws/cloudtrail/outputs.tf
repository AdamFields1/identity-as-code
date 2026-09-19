output "trails" {
  description = "Map of logical key to { name, arn, home_region, s3_bucket_name, s3_key_prefix, kms_key_arn }. kms_key_arn is null for a trail delivering under SSE-S3."
  value = {
    for k, t in aws_cloudtrail.this : k => {
      name           = t.name
      arn            = t.arn
      home_region    = t.home_region
      s3_bucket_name = t.s3_bucket_name
      s3_key_prefix  = t.s3_key_prefix
      kms_key_arn    = t.kms_key_id
    }
  }
}

output "trail_arns_by_name" {
  description = "Map of trail NAME to ARN, for callers that reference trails by name."
  value       = { for k, t in var.trails : t.name => aws_cloudtrail.this[k].arn }
}
