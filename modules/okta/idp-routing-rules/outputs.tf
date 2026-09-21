output "rules" {
  description = "Map of logical key to { id, name, priority, status }."
  value = {
    for k, r in okta_policy_rule_idp_discovery.this : k => {
      id       = r.id
      name     = r.name
      priority = r.priority
      status   = r.status
    }
  }
}

output "rule_ids" {
  description = "Map of logical key to routing rule ID. Import addresses are <policy_id>/<rule_id>."
  value       = { for k, r in okta_policy_rule_idp_discovery.this : k => r.id }
}
