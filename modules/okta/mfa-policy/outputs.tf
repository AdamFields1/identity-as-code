output "policy_id" {
  description = "ID of the MFA enrollment policy."
  value       = okta_policy_mfa.this.id
}

output "policy_name" {
  description = "Display name of the MFA enrollment policy."
  value       = okta_policy_mfa.this.name
}

output "rule_ids" {
  description = "Map of logical rule key to MFA rule ID."
  value       = { for k, r in okta_policy_rule_mfa.this : k => r.id }
}
