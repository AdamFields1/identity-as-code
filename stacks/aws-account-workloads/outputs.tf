output "partition" {
  description = "Partition the account lives in (aws or aws-us-gov), as discovered from the provider's credentials."
  value       = module.kms_keys.partition
}

output "account_id" {
  description = "Account this cell manages, as discovered from the provider's credentials; never typed into the cell."
  value       = module.kms_keys.account_id
}

output "service_roles" {
  description = "Map of role key to { name, arn, unique_id, path, instance_profile_name, instance_profile_arn }. The profile fields are null for roles that do not trust ec2."
  value       = module.service_roles.roles
}

output "role_arns_by_name" {
  description = "Map of role NAME to ARN for every role in this cell."
  value       = module.service_roles.role_arns_by_name
}

output "instance_profiles" {
  description = "Map of role key to { name, arn } for the roles that trust ec2 and therefore carry an instance profile."
  value       = module.service_roles.instance_profiles
}

output "bucket_access_policies" {
  description = "Map of role key to the inline policy JSON this stack generated from bucket_access (merged with the role's own inline_policy when one is set), so a reviewer can read what a role was granted without rendering it by hand."
  value       = { for key, doc in data.aws_iam_policy_document.bucket_access : key => doc.json }
}

output "github_oidc_provider_arn" {
  description = "ARN of the account's GitHub Actions OIDC provider, or null when no role in this cell trusts GitHub."
  value       = module.service_roles.github_oidc_provider_arn
}

output "kms_keys" {
  description = "Map of key key to { key_id, arn, alias, alias_name, alias_arn, administrator_role_names, user_role_names }. The role name lists are what the key policy was written with, after a role of this cell is routed with its path."
  value = {
    for key, k in module.kms_keys.keys : key => merge(k, local.kms_key_role_names[key])
  }
}

output "key_arns_by_alias" {
  description = "Map of bare alias (without alias/) to key ARN for every key in this cell."
  value       = module.kms_keys.key_arns_by_alias
}

output "buckets" {
  description = "Map of bucket key to { name, arn, id, region, regional_domain_name, sse_algorithm, kms_key_alias, kms_key_arn, log_target_bucket_name }. kms_key_alias is the bare alias the bucket is encrypted with, resolved from kms_key or taken from kms_key_alias, and null for SSE-S3."
  value = {
    for key, b in module.buckets.buckets : key => merge(b, { kms_key_alias = local.bucket_kms_aliases[key] })
  }
}

output "bucket_arns_by_name" {
  description = "Map of bucket NAME to ARN for every bucket in this cell."
  value       = module.buckets.bucket_arns_by_name
}
