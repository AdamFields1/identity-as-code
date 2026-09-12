output "zone_ids" {
  description = "Map of logical zone key to Okta network zone ID."
  value       = module.network_zones.zone_ids
}

output "group_ids" {
  description = "Map of group name to ID for every group referenced by a policy in this stack."
  value       = local.group_ids
}

output "session_policy" {
  description = "Sign-on policy ID and rule IDs."
  value = {
    id       = module.session_policy.policy_id
    name     = module.session_policy.policy_name
    rule_ids = module.session_policy.rule_ids
  }
}

output "mfa_policy" {
  description = "MFA enrollment policy ID and rule IDs."
  value = {
    id       = module.mfa_policy.policy_id
    name     = module.mfa_policy.policy_name
    rule_ids = module.mfa_policy.rule_ids
  }
}

output "password_policy" {
  description = "Password policy ID and rule IDs."
  value = {
    id       = module.password_policy.policy_id
    name     = module.password_policy.policy_name
    rule_ids = module.password_policy.rule_ids
  }
}
