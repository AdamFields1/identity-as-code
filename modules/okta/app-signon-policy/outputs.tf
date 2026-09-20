output "policy_ids" {
  description = "Map of policy key to app sign-on policy ID. An app module passes one of these as its authentication_policy."
  value       = { for k, p in okta_app_signon_policy.this : k => p.id }
}

output "policy_names_by_key" {
  description = "Map of policy key to display name."
  value       = { for k, p in okta_app_signon_policy.this : k => p.name }
}

output "phishing_resistant_only" {
  description = "Map of policy key to true when every ALLOW rule requires a phishing-resistant possession factor. Computed from the values, so a stack can check it at plan time before an admin-tier app is pointed at the policy. It is a true statement about the policy because the catch-all is created with DENY."
  value = {
    for k, p in var.policies : k => alltrue([
      for r in p.rules : try(r.constraints.possession.phishing_resistant, "OPTIONAL") == "REQUIRED" if r.access == "ALLOW"
    ])
  }
}

output "rule_ids" {
  description = "Map of policy key to a map of rule key to rule ID."
  value = {
    for pk in keys(var.policies) : pk => {
      for k, r in okta_app_signon_policy_rule.this : local.rules[k].rule_key => r.id if local.rules[k].policy_key == pk
    }
  }
}

output "default_rule_ids" {
  description = "Map of policy key to the ID of the system catch-all rule Okta created with access DENY. Not managed here; exported so an audit can read it."
  value       = { for k, p in okta_app_signon_policy.this : k => p.default_rule_id }
}
