output "subscription_id" {
  description = "GUID of the subscription the baseline was applied to, discovered from the provider."
  value       = data.azurerm_subscription.current.subscription_id
}

output "defender_plans" {
  description = "Map of Defender resource type to { id, tier, subplan, extensions }, extensions being the names that are on."
  value = {
    for type, plan in azurerm_security_center_subscription_pricing.this : type => {
      id         = plan.id
      tier       = plan.tier
      subplan    = plan.subplan
      extensions = sort(keys(var.defender_plans[type].extensions))
    }
  }
}

output "log_analytics_workspace" {
  description = "The activity log's destination: { id, name, workspace_id, resource_group_name, location, created }, created saying whether this module made it."
  value = {
    id                  = local.workspace_id
    name                = var.log_analytics_workspace.name
    workspace_id        = coalesce(one(azurerm_log_analytics_workspace.this[*].workspace_id), one(data.azurerm_log_analytics_workspace.existing[*].workspace_id))
    resource_group_name = var.log_analytics_workspace.resource_group_name
    location            = coalesce(one(azurerm_log_analytics_workspace.this[*].location), one(data.azurerm_log_analytics_workspace.existing[*].location))
    created             = local.create_workspace
  }
}

output "activity_log_diagnostic_setting_id" {
  description = "ID of the diagnostic setting that sends the activity log to the workspace."
  value       = azurerm_monitor_diagnostic_setting.activity_log.id
}

output "activity_log_categories" {
  description = "Activity log categories the setting sends, sorted."
  value       = sort(var.activity_log_categories)
}

output "policy_assignments" {
  description = "Map of assignment key to { id, name, display_name, policy_set_display_name, policy_set_definition_id, enforcement_mode }."
  value = {
    for key, assignment in azurerm_subscription_policy_assignment.this : key => {
      id                       = assignment.id
      name                     = assignment.name
      display_name             = assignment.display_name
      policy_set_display_name  = local.policy_assignments[key].policy_set_display_name
      policy_set_definition_id = assignment.policy_definition_id
      enforcement_mode         = assignment.enforce ? "Default" : "DoNotEnforce"
    }
  }
}

output "policy_set_definition_ids" {
  description = "Map of initiative display name to policy set definition ID, for every initiative an assignment names."
  value       = { for display_name, definition in data.azurerm_policy_set_definition.this : display_name => definition.id }
}
