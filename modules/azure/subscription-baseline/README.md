# modules/azure/subscription-baseline

Manages the hardening a subscription should have before it holds a workload:
the Microsoft Defender for Cloud plans that are on (and the ones declared off),
one diagnostic setting that sends the subscription's activity log to a Log
Analytics workspace looked up by name or created here, and Azure Policy
assignments of initiatives named by display name, each with an enforcement
mode and a non-compliance message. Everything is scoped to the one
subscription the provider is pointed at.

## Design notes

- **The subscription is discovered, never typed.** `data.azurerm_subscription`
  reads the provider's own subscription, which `tenants/azure/root.hcl`
  addresses from the `subscription.hcl` locator above the cell
  ([ADR 0017](../../../docs/adr/0017-three-kinds-of-stack.md)). Its ID is the
  scope of the diagnostic setting and of every assignment, and no cell holds
  it.
- **A Defender plan is keyed by its resource type.** Defender holds one
  pricing per resource type per subscription, so `VirtualMachines`,
  `StorageAccounts`, and the rest are the map keys, the Terraform addresses,
  and the import IDs. A plan turned on in the portal is invisible until the
  bill arrives; a plan declared here is a line in a cell, and a plan declared
  `Free` is a line too, so off is a decision and not an absence. A resource
  type absent from the map is left as the portal has it.
- **Extensions are exactly what is listed.** The provider enables the
  extensions a plan declares and disables every other one, so a cell that
  turns a plan on lists the features it wants (`AgentlessVmScanning`,
  `SensitiveDataDiscovery`, `OnUploadMalwareScanning`, ...) by the names the
  Defender documentation gives for that plan. Sub-plans and extensions are
  refused on a `Free` plan, where they would be silently ignored.
- **The activity log is the only record of who changed what.** Azure keeps it
  for 90 days and then deletes it. The diagnostic setting sends the
  categories a cell names (all eight by default) to the workspace; there are
  no ingestion charges for the activity log, only retention charges past
  90 days.
- **The workspace is looked up or created, with one posture.** With
  `create = false` the workspace is resolved by name in its resource group
  and nothing is created. With `create = true` it is created in the group and
  region the caller passes, on the PerGB2018 tier, with local (shared key)
  authentication off and `retention_in_days` defaulting to 90 so the
  workspace keeps the activity log at least as long as the platform does. A
  daily ingestion cap is offered and off by default, because a cap that is
  reached drops the audit trail for the rest of the day. The created
  workspace is `prevent_destroy`: it is the retained activity log, and a
  deleted workspace is purged with everything in it 14 days later.
- **Initiatives are named by display name.** `data.azurerm_policy_set_definition`
  resolves the display name to the definition ID at plan time. Display names
  are not unique by contract; a name that matches more than one definition
  fails the lookup, and the plan with it, rather than assigning the wrong one.
- **Enforcement mode is the Azure concept, in Azure's words.** `Default`
  evaluates and enforces; `DoNotEnforce` evaluates and reports only, which
  is how a new initiative is assigned first so its compliance results can be
  read before any effect fires. The provider's `enforce` bool is derived.
- **Parameters are checked against the initiative.** `parameters` is a map
  of parameter name to string value, the common case being an effect such as
  `Audit` or `Deny`. A precondition compares the names against the parameter
  document the initiative declares and refuses one it does not, naming the
  ones it does. Parameters that take lists or objects cannot be set here; an
  initiative that needs one is an app stack's business.
- **Assigning is not remediating.** No managed identity is offered on an
  assignment, so an initiative whose definitions have `DeployIfNotExists` or
  `Modify` effects is assigned to report and not to act, and Azure may refuse
  the assignment outright for such an initiative. The Microsoft cloud
  security benchmark, the default the stack assigns, audits and does not
  remediate. Remediation identities and the role assignments they need are
  a different shape with a different blast radius.
- **Exclusions are resource group names.** `excluded_resource_group_names`
  become the assignment's not-scopes under the subscription; a cell never
  holds a scope ID.
- **The workspace's resource group is passed, not looked up.** A caller that
  creates the group in the same plan (`modules/azure/resource-group`) passes
  the group's name and location from that module's outputs, so the
  dependency is through the inputs and no data source is deferred to apply.
  That is why, unlike `key-vault`, `managed-identity`, and `storage-account`,
  this module takes a `location` instead of defaulting to the group's.

## What the apply identity needs

Reading the subscription and the built-in initiatives needs nothing beyond
Reader. Writing a Defender plan is `Microsoft.Security/pricings/write`
(Security Admin). The diagnostic setting is
`Microsoft.Insights/diagnosticSettings/write` at the subscription (Monitoring
Contributor) plus read on the workspace. A created workspace needs
Log Analytics Contributor, or Contributor, on its resource group. A policy
assignment is `Microsoft.Authorization/policyAssignments/write` (Resource
Policy Contributor). Owner covers all of it and is more than any of it
needs; Contributor covers none of the four writes except the workspace.

Two things a first apply should confirm: that the API returns a plan's
extensions as sent, so a plan with `extensions = {}` does not show the
default-enabled extensions of that plan as a diff on the next plan (list
them if it does); and that a subscription-scoped diagnostic setting is
returned without a `log_analytics_destination_type`, which the resource
leaves unset.

## Usage

```hcl
module "baseline" {
  source = "../../modules/azure/subscription-baseline"

  defender_plans = {
    CloudPosture    = {}
    KeyVaults       = {}
    Arm             = {}
    VirtualMachines = { subplan = "P2", extensions = { AgentlessVmScanning = {}, MdeDesignatedSubscription = {} } }
    StorageAccounts = { subplan = "DefenderForStorageV2", extensions = { OnUploadMalwareScanning = { CapGBPerMonthPerStorageAccount = "5000" }, SensitiveDataDiscovery = {} } }
    Dns             = { tier = "Free" }
  }

  log_analytics_workspace = {
    name                = "law-example-prod-activity"
    resource_group_name = "rg-example-baseline"
    create              = true
    location            = "eastus"
    retention_in_days   = 365
  }

  policy_assignments = {
    microsoft-cloud-security-benchmark = {
      policy_set_display_name = "Microsoft cloud security benchmark"
      non_compliance_message  = "This resource does not meet the Microsoft cloud security benchmark. The platform security team owns exceptions."
    }
    allowed-locations-report-only = {
      policy_set_display_name       = "Example locations initiative"
      enforcement_mode              = "DoNotEnforce"
      parameters                    = { effect = "Audit" }
      excluded_resource_group_names = ["rg-example-sandbox"]
    }
  }

  tags = { owner = "platform-security" }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `defender_plans` | `map(object)` | `{}` | Defender plans keyed by resource type: `tier`, `subplan`, `extensions`. See `variables.tf`. |
| `log_analytics_workspace` | `object` | n/a | The activity log's destination: `name`, `resource_group_name`, `create`, `location`, `retention_in_days`, `daily_quota_gb`, `internet_ingestion_enabled`, `internet_query_enabled`, `tags`. |
| `activity_log_categories` | `list(string)` | all eight | Activity log categories the setting sends. |
| `policy_assignments` | `map(object)` | `{}` | Initiative assignments keyed by logical name: `policy_set_display_name`, `name`, `display_name`, `description`, `enforcement_mode`, `non_compliance_message`, `parameters`, `excluded_resource_group_names`. |
| `tags` | `map(string)` | `{}` | Tags on the created workspace; the entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `subscription_id` | GUID of the subscription, discovered. |
| `defender_plans` | Resource type to `{ id, tier, subplan, extensions }`. |
| `log_analytics_workspace` | `{ id, name, workspace_id, resource_group_name, location, created }`. |
| `activity_log_diagnostic_setting_id` | ID of the subscription's diagnostic setting. |
| `activity_log_categories` | Categories sent, sorted. |
| `policy_assignments` | Key to `{ id, name, display_name, policy_set_display_name, policy_set_definition_id, enforcement_mode }`. |
| `policy_set_definition_ids` | Initiative display name to definition ID. |

## Import

```hcl
import {
  to = module.baseline.azurerm_security_center_subscription_pricing.this["VirtualMachines"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Security/pricings/VirtualMachines"
}

import {
  to = module.baseline.azurerm_log_analytics_workspace.this[0]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-baseline/providers/Microsoft.OperationalInsights/workspaces/law-example-prod-activity"
}

import {
  to = module.baseline.azurerm_monitor_diagnostic_setting.activity_log
  id = "/subscriptions/00000000-0000-0000-0000-000000000000|activity-log"
}

import {
  to = module.baseline.azurerm_subscription_policy_assignment.this["microsoft-cloud-security-benchmark"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/policyAssignments/microsoft-cloud-security-benchmark"
}
```

A subscription that already exports its activity log under another setting
name keeps that setting; import it under this module's name only if it is
this module's setting, and otherwise expect a second, duplicate export
until the old one is removed. A workspace adopted with `create = true` must
already have local authentication off, or the plan turns it off.
