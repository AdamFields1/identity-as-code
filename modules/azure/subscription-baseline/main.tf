# Subscription baseline: Defender for Cloud plans, the activity log export,
# and initiative assignments, for the one subscription the provider is
# pointed at.
#
# Three things every subscription should have before it holds a workload,
# and that nothing else in this repository declares:
#
#   - Which Defender for Cloud plans are on. A plan is one pricing object
#     per resource type per subscription; the map key is the resource type,
#     the value is the tier and the plan's sub-plan and extensions. A plan
#     turned on from the portal is invisible until the bill arrives; a plan
#     declared here is a line in a cell, and a plan declared Free is a line
#     too, so "off" is a decision and not an absence.
#   - Where the activity log goes. Azure keeps a subscription's activity log
#     for 90 days and then deletes it, and the activity log is the only
#     record of who created or changed a resource. One diagnostic setting
#     on the subscription sends the categories a cell names to a Log
#     Analytics workspace, looked up by name or created here when the
#     subscription has none.
#   - Which initiatives it is held to. An assignment names a policy set
#     definition by display name, resolved at plan time to its ID, with an
#     enforcement mode and a non-compliance message. Assigning is not
#     remediating: this module offers no managed identity on an
#     assignment, so an initiative whose definitions deploy or modify
#     resources is assigned to report and not to act.
#
# What is resolved and never typed: the subscription (data.azurerm_subscription
# on the provider's own subscription, which the Terragrunt root addresses
# from the tree), the workspace when it exists, and every initiative.
#
# prevent_destroy on the created workspace: it holds the activity log the
# subscription no longer has after 90 days. A workspace is soft-deleted for
# 14 days and then purged with everything in it; removing the entry or
# renaming the workspace must never be able to do that as a side effect.
# Nothing else here is data: a Defender plan turned off is turned on again
# with the next apply, a diagnostic setting is recreated in seconds, and an
# assignment removed stops an evaluation. Each of those shows in the plan
# as a destroy and is reviewed as one.
#
# The resource group a created workspace lives in is not created here and
# not looked up either: the stack passes its name and location, so a group
# created in the same plan (modules/azure/resource-group) is an ordinary
# dependency through the inputs and no data read has to wait for apply.

data "azurerm_subscription" "current" {}

locals {
  # "/subscriptions/<id>": the scope of the diagnostic setting, the policy
  # assignments, and the not-scopes below.
  subscription_scope = data.azurerm_subscription.current.id

  create_workspace = var.log_analytics_workspace.create

  # Exactly one of the two lists has an element.
  workspace_id = coalesce(
    one(azurerm_log_analytics_workspace.this[*].id),
    one(data.azurerm_log_analytics_workspace.existing[*].id),
  )

  policy_set_display_names = toset([for a in var.policy_assignments : a.policy_set_display_name])

  policy_assignments = {
    for key, a in var.policy_assignments : key => {
      name                    = coalesce(a.name, key)
      display_name            = coalesce(a.display_name, a.policy_set_display_name)
      description             = a.description
      policy_set_display_name = a.policy_set_display_name
      enforce                 = a.enforcement_mode == "Default"
      non_compliance_message  = a.non_compliance_message
      parameter_names         = sort(keys(a.parameters))

      # Azure Policy's parameter document: { "<name>": { "value": <value> } }.
      parameters = length(a.parameters) == 0 ? null : jsonencode({ for name, value in a.parameters : name => { value = value } })

      not_scopes = length(a.excluded_resource_group_names) == 0 ? null : [
        for rg in a.excluded_resource_group_names : "${local.subscription_scope}/resourceGroups/${rg}"
      ]
    }
  }

  # The parameters each initiative declares, from the definition's own
  # parameter document, for the precondition on the assignment. An
  # initiative with no parameters returns no document.
  declared_parameters = {
    for display_name, definition in data.azurerm_policy_set_definition.this :
    display_name => sort(keys(try(jsondecode(definition.parameters), {})))
  }
}

# ---------------------------------------------------------------------------
# Defender for Cloud plans. One pricing per resource type.
# ---------------------------------------------------------------------------

resource "azurerm_security_center_subscription_pricing" "this" {
  for_each = var.defender_plans

  resource_type = each.key
  tier          = each.value.tier
  subplan       = each.value.subplan

  # The provider enables exactly the extensions declared and disables the
  # rest, so the list in the cell is the list that is on.
  dynamic "extension" {
    for_each = each.value.extensions
    content {
      name                            = extension.key
      additional_extension_properties = length(extension.value) == 0 ? null : extension.value
    }
  }
}

# ---------------------------------------------------------------------------
# The workspace: looked up, or created with one posture.
# ---------------------------------------------------------------------------

data "azurerm_log_analytics_workspace" "existing" {
  count = local.create_workspace ? 0 : 1

  name                = var.log_analytics_workspace.name
  resource_group_name = var.log_analytics_workspace.resource_group_name
}

resource "azurerm_log_analytics_workspace" "this" {
  count = local.create_workspace ? 1 : 0

  name                = var.log_analytics_workspace.name
  resource_group_name = var.log_analytics_workspace.resource_group_name
  location            = var.log_analytics_workspace.location
  tags                = merge(var.tags, var.log_analytics_workspace.tags)

  # Pay per gigabyte, the only tier a new workspace can have.
  sku               = "PerGB2018"
  retention_in_days = var.log_analytics_workspace.retention_in_days
  daily_quota_gb    = var.log_analytics_workspace.daily_quota_gb

  internet_ingestion_enabled = var.log_analytics_workspace.internet_ingestion_enabled
  internet_query_enabled     = var.log_analytics_workspace.internet_query_enabled

  # No shared keys. The activity log arrives through the platform, agents
  # and the ingestion API authenticate with Entra, and a query is a role
  # assignment on the workspace or on the resource the data came from.
  local_authentication_enabled    = false
  allow_resource_only_permissions = true

  lifecycle {
    # The workspace is the retained activity log. Removing the entry, or
    # changing name, resource group, or location, would otherwise plan its
    # deletion and, 14 days later, the purge of every record in it.
    # Retiring it is a change that lifts this flag first.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# The activity log export. One setting on the subscription, the workspace as
# its only destination.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "activity-log"
  target_resource_id         = local.subscription_scope
  log_analytics_workspace_id = local.workspace_id

  dynamic "enabled_log" {
    for_each = toset(var.activity_log_categories)
    content {
      category = enabled_log.value
    }
  }
}

# ---------------------------------------------------------------------------
# Initiative assignments. The definition is resolved by display name; the
# assignment carries the enforcement mode, the message, and the parameters.
# ---------------------------------------------------------------------------

data "azurerm_policy_set_definition" "this" {
  for_each = local.policy_set_display_names

  display_name = each.value
}

resource "azurerm_subscription_policy_assignment" "this" {
  for_each = local.policy_assignments

  name                 = each.value.name
  subscription_id      = local.subscription_scope
  policy_definition_id = data.azurerm_policy_set_definition.this[each.value.policy_set_display_name].id

  display_name = each.value.display_name
  description  = each.value.description
  enforce      = each.value.enforce
  parameters   = each.value.parameters
  not_scopes   = each.value.not_scopes

  dynamic "non_compliance_message" {
    for_each = each.value.non_compliance_message == null ? [] : [each.value.non_compliance_message]
    content {
      content = non_compliance_message.value
    }
  }

  lifecycle {
    precondition {
      condition = alltrue([
        for name in each.value.parameter_names : contains(local.declared_parameters[each.value.policy_set_display_name], name)
      ])
      error_message = "policy_assignments[\"${each.key}\"] sets a parameter that \"${each.value.policy_set_display_name}\" does not declare. Given: ${join(", ", each.value.parameter_names)}. Declared: ${length(local.declared_parameters[each.value.policy_set_display_name]) == 0 ? "none" : join(", ", local.declared_parameters[each.value.policy_set_display_name])}."
    }
  }
}
