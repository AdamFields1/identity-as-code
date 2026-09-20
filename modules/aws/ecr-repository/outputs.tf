output "repositories" {
  description = "Map of logical key to { name, arn, registry_id, repository_url, kms_key_arn }. repository_url is what a task definition's image field and a publisher's docker push name start with."
  value = {
    for k, r in aws_ecr_repository.this : k => {
      name           = r.name
      arn            = r.arn
      registry_id    = r.registry_id
      repository_url = r.repository_url
      kms_key_arn    = r.encryption_configuration[0].kms_key
    }
  }
}

output "repository_urls_by_name" {
  description = "Map of repository NAME to repository URL, for callers that reference repositories by name."
  value       = { for k, r in var.repositories : r.name => aws_ecr_repository.this[k].repository_url }
}

output "repository_arns_by_name" {
  description = "Map of repository NAME to ARN, for callers that reference repositories by name."
  value       = { for k, r in var.repositories : r.name => aws_ecr_repository.this[k].arn }
}
