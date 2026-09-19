output "subscription_id" {
  description = "GUID of the subscription the baseline was applied to, discovered from the provider."
  value       = module.baseline.subscription_id
}

output "baseline_resource_group" {
  description = "The group this stack created, as { id, name, location, locked }, or null when the workspace was looked up and no group was created."
  value       = one(values(module.resource_groups.resource_groups))
}

output "baseline_resource_group_lock_id" {
  description = "ID of the CanNotDelete lock on the baseline group, or null when delete_lock is off or there is no group."
  value       = one(values(module.resource_groups.lock_ids))
}

output "log_analytics_workspace" {
  description = "The activity log's destination: { id, name, workspace_id, resource_group_name, location, created }."
  value       = module.baseline.log_analytics_workspace
}

output "activity_log_diagnostic_setting_id" {
  description = "ID of the diagnostic setting that sends the subscription's activity log to the workspace."
  value       = module.baseline.activity_log_diagnostic_setting_id
}

output "activity_log_categories" {
  description = "Activity log categories the setting sends, sorted."
  value       = module.baseline.activity_log_categories
}

output "defender_plans" {
  description = "Map of Defender resource type to { id, tier, subplan, extensions }."
  value       = module.baseline.defender_plans
}

output "policy_assignments" {
  description = "Map of assignment key to { id, name, display_name, policy_set_display_name, policy_set_definition_id, enforcement_mode }."
  value       = module.baseline.policy_assignments
}

output "policy_set_definition_ids" {
  description = "Map of initiative display name to policy set definition ID, for every initiative a cell names."
  value       = module.baseline.policy_set_definition_ids
}
