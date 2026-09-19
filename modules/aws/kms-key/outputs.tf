output "keys" {
  description = "Map of logical key to { key_id, arn, alias, alias_name, alias_arn }. alias is the bare name a bucket cell references; alias_name carries the alias/ prefix."
  value = {
    for k, key in aws_kms_key.this : k => {
      key_id     = key.key_id
      arn        = key.arn
      alias      = var.keys[k].alias
      alias_name = aws_kms_alias.this[k].name
      alias_arn  = aws_kms_alias.this[k].arn
    }
  }
}

output "key_arns_by_alias" {
  description = "Map of alias NAME (without the alias/ prefix) to key ARN, for callers that reference keys by alias."
  value       = { for k, key in var.keys : key.alias => aws_kms_key.this[k].arn }
}

output "key_ids_by_alias" {
  description = "Map of alias NAME (without the alias/ prefix) to key ID."
  value       = { for k, key in var.keys : key.alias => aws_kms_key.this[k].key_id }
}

output "partition" {
  description = "AWS partition the keys were created in (aws, aws-us-gov)."
  value       = local.partition
}

output "account_id" {
  description = "Account the keys were created in, as discovered from the provider's credentials; the account whose root principal every key policy grants."
  value       = local.account_id
}
