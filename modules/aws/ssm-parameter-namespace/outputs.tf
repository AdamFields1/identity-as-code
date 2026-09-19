output "namespaces" {
  description = "Map of logical key to { prefix, arn_prefix, placeholder_name, placeholder_arn, kms_key_id }. arn_prefix is the ARN of the namespace itself, the string a policy grants with /* behind it."
  value = {
    for k, p in aws_ssm_parameter.placeholder : k => {
      prefix           = var.namespaces[k].prefix
      arn_prefix       = trimsuffix(p.arn, "/placeholder")
      placeholder_name = p.name
      placeholder_arn  = p.arn
      kms_key_id       = p.key_id
    }
  }
}

output "placeholder_arns_by_prefix" {
  description = "Map of namespace PREFIX to the placeholder parameter's ARN, for callers that reference namespaces by prefix."
  value       = { for k, n in var.namespaces : n.prefix => aws_ssm_parameter.placeholder[k].arn }
}
