output "policy_id" {
  description = "ID of the password policy."
  value       = okta_policy_password.this.id
}

output "policy_name" {
  description = "Display name of the password policy."
  value       = okta_policy_password.this.name
}

output "rule_ids" {
  description = "Map of logical rule key to password rule ID."
  value       = { for k, r in okta_policy_rule_password.this : k => r.id }
}
