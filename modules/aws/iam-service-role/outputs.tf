output "roles" {
  description = "Map of logical key to { name, arn, unique_id, path, instance_profile_name, instance_profile_arn }. The instance profile fields are null for roles that do not trust ec2."
  value = {
    for k, r in aws_iam_role.this : k => {
      name                  = r.name
      arn                   = r.arn
      unique_id             = r.unique_id
      path                  = r.path
      instance_profile_name = try(aws_iam_instance_profile.this[k].name, null)
      instance_profile_arn  = try(aws_iam_instance_profile.this[k].arn, null)
    }
  }
}

output "role_arns_by_name" {
  description = "Map of role NAME to ARN, for callers that reference roles by name."
  value       = { for k, r in var.roles : r.name => aws_iam_role.this[k].arn }
}

output "instance_profiles" {
  description = "Map of logical key to { name, arn } for the roles that trust ec2 and therefore have an instance profile."
  value = {
    for k, p in aws_iam_instance_profile.this : k => {
      name = p.name
      arn  = p.arn
    }
  }
}

output "github_oidc_provider_arn" {
  description = "ARN of the account's GitHub Actions OIDC provider, or null when no role uses GitHub trust."
  value       = try(data.aws_iam_openid_connect_provider.github["github"].arn, null)
}

output "partition" {
  description = "AWS partition the roles were created in (aws, aws-us-gov)."
  value       = local.partition
}
