output "policy_id" {
  description = "ID of the sign-on policy."
  value       = okta_policy_signon.this.id
}

output "policy_name" {
  description = "Display name of the sign-on policy."
  value       = okta_policy_signon.this.name
}

output "rule_ids" {
  description = "Map of logical rule key to sign-on rule ID."
  value       = { for k, r in okta_policy_rule_signon.this : k => r.id }
}
