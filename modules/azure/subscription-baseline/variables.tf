variable "defender_plans" {
  description = <<-EOT
    Microsoft Defender for Cloud plans to manage, keyed by the Defender resource
    type the plan covers (VirtualMachines, StorageAccounts, KeyVaults, ...).
    Defender holds one pricing per resource type per subscription, so the key
    is the plan: it is the Terraform address and the import ID, and it never
    changes.

    tier       : "Standard" (default) turns the plan on for every resource of
                 that type in the subscription, billed per resource from the
                 moment it is on. "Free" turns it off. Declaring a plan as
                 Free is how a cell says "off, on purpose", so the portal is
                 not the record of what is protected.
    subplan    : the sub-plan where the plan offers more than one, for
                 example "P1" or "P2" for VirtualMachines and
                 "DefenderForStorageV2" for StorageAccounts. Null (default)
                 takes the full plan. Refused with tier Free. Changing it
                 replaces the pricing.
    extensions : per-plan features, keyed by the extension name Defender
                 documents for that plan (AgentlessVmScanning,
                 SensitiveDataDiscovery, OnUploadMalwareScanning, ...), each
                 with the extra properties that extension takes, usually none
                 ({}). A Standard plan enables exactly the extensions listed
                 here and turns every other one off; that is the provider's
                 rule, and the reason a cell lists them rather than inherits
                 them. Refused with tier Free.

    A resource type absent from the map is left as the portal has it. Add it
    with tier Free to manage it off.
  EOT

  type = map(object({
    tier       = optional(string, "Standard")
    subplan    = optional(string)
    extensions = optional(map(map(string)), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for type in keys(var.defender_plans) : contains([
        "AI", "Api", "AppServices", "Arm", "CloudPosture", "ContainerRegistry", "Containers", "CosmosDbs", "Dns",
        "KeyVaults", "KubernetesService", "OpenSourceRelationalDatabases", "SqlServers", "SqlServerVirtualMachines",
        "StorageAccounts", "VirtualMachines",
      ], type)
    ])
    error_message = "defender_plans keys are Defender resource types, spelt as the provider spells them: AI, Api, AppServices, Arm, CloudPosture, ContainerRegistry, Containers, CosmosDbs, Dns, KeyVaults, KubernetesService, OpenSourceRelationalDatabases, SqlServers, SqlServerVirtualMachines, StorageAccounts, VirtualMachines."
  }

  validation {
    condition     = alltrue([for plan in var.defender_plans : contains(["Free", "Standard"], plan.tier)])
    error_message = "tier must be \"Standard\" (the plan is on and billed) or \"Free\" (the plan is off)."
  }

  validation {
    condition     = alltrue([for plan in var.defender_plans : plan.subplan == null || plan.tier == "Standard"])
    error_message = "subplan selects a variant of a plan that is on; with tier Free there is no plan to select a variant of, so leave subplan null."
  }

  validation {
    condition     = alltrue([for plan in var.defender_plans : plan.subplan == null || can(regex("^[A-Za-z0-9]{1,32}$", coalesce(plan.subplan, "x")))])
    error_message = "subplan must be letters and digits only, for example P1, P2, or DefenderForStorageV2."
  }

  validation {
    condition     = alltrue([for plan in var.defender_plans : length(plan.extensions) == 0 || plan.tier == "Standard"])
    error_message = "extensions are features of a plan that is on; with tier Free every extension is off, so leave extensions empty."
  }

  validation {
    condition = alltrue(flatten([
      for plan in var.defender_plans : [for name in keys(plan.extensions) : can(regex("^[A-Za-z][A-Za-z0-9]{1,63}$", name))]
    ]))
    error_message = "extensions keys are the extension names Defender documents for the plan, letters and digits only, for example AgentlessVmScanning or SensitiveDataDiscovery."
  }
}

variable "log_analytics_workspace" {
  description = <<-EOT
    The Log Analytics workspace the subscription's activity log is sent to,
    either looked up by name or created here.

    name                       : workspace name, 4 to 63 letters, digits, and
                                 hyphens, not starting or ending with a
                                 hyphen. Immutable once created.
    resource_group_name        : the workspace's resource group, by name. An
                                 existing group when create is false (the
                                 workspace is looked up in it); the group the
                                 workspace is created in when create is true.
    create                     : false (default) looks the workspace up and
                                 creates nothing. True creates it in
                                 resource_group_name at location, with the
                                 settings below.
    location                   : Azure region of a created workspace, in its
                                 short form (eastus). Required when create is
                                 true and refused otherwise: a looked-up
                                 workspace has the location it has.
    retention_in_days          : interactive retention of a created workspace,
                                 30 to 730. Default 90, so the workspace keeps
                                 the activity log at least as long as the
                                 platform's own 90 days.
    daily_quota_gb             : ingestion cap per day of a created workspace.
                                 -1 (default) is no cap. Once a cap is reached
                                 the workspace drops data for the rest of the
                                 day, the audit trail included, so set one
                                 only where losing a day of it is acceptable.
    internet_ingestion_enabled : whether a created workspace accepts data over
                                 its public endpoint. Default true; false
                                 needs a private link scope this module does
                                 not create. The activity log export goes
                                 through the platform and is not affected.
    internet_query_enabled     : whether a created workspace answers queries
                                 over its public endpoint. Default true, same
                                 caveat.
    tags                       : tags on a created workspace, merged over the
                                 module-level tags; the entry wins per key.

    Fixed on a created workspace: the PerGB2018 pricing tier, and local
    (shared key) authentication off, so the workspace is reached with an
    Entra token or not at all.
  EOT

  type = object({
    name                       = string
    resource_group_name        = string
    create                     = optional(bool, false)
    location                   = optional(string)
    retention_in_days          = optional(number, 90)
    daily_quota_gb             = optional(number, -1)
    internet_ingestion_enabled = optional(bool, true)
    internet_query_enabled     = optional(bool, true)
    tags                       = optional(map(string), {})
  })

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$", var.log_analytics_workspace.name))
    error_message = "log_analytics_workspace.name must be 4 to 63 letters, digits, and hyphens, not starting or ending with a hyphen."
  }

  validation {
    condition     = length(trimspace(var.log_analytics_workspace.resource_group_name)) > 0
    error_message = "log_analytics_workspace.resource_group_name must not be empty."
  }

  validation {
    condition     = var.log_analytics_workspace.create == (var.log_analytics_workspace.location != null)
    error_message = "log_analytics_workspace.location is required when create is true (the region the workspace is created in) and must be omitted when create is false (a looked-up workspace has the location it has)."
  }

  validation {
    condition     = var.log_analytics_workspace.location == null || can(regex("^[a-z0-9]{3,40}$", coalesce(var.log_analytics_workspace.location, "x")))
    error_message = "log_analytics_workspace.location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }

  validation {
    condition     = var.log_analytics_workspace.retention_in_days >= 30 && var.log_analytics_workspace.retention_in_days <= 730 && floor(var.log_analytics_workspace.retention_in_days) == var.log_analytics_workspace.retention_in_days
    error_message = "log_analytics_workspace.retention_in_days must be a whole number of days from 30 to 730."
  }

  validation {
    condition     = var.log_analytics_workspace.daily_quota_gb == -1 || var.log_analytics_workspace.daily_quota_gb > 0
    error_message = "log_analytics_workspace.daily_quota_gb must be -1 (no cap) or a positive number of gigabytes per day."
  }
}

variable "activity_log_categories" {
  description = "Activity log categories sent to the workspace. The default is every category: Administrative (every control-plane write and who made it), Security (Defender for Cloud alerts), ServiceHealth, Alert, Recommendation, Policy (evaluations and denials), Autoscale, and ResourceHealth. Narrow it only where the workspace's cost is the concern; Administrative, Security, and Policy are the audit trail."
  type        = list(string)
  default     = ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"]

  validation {
    condition     = length(var.activity_log_categories) > 0
    error_message = "activity_log_categories must name at least one category; a subscription with nothing to export has no baseline cell."
  }

  validation {
    condition     = alltrue([for c in var.activity_log_categories : contains(["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"], c)])
    error_message = "activity_log_categories must be from: Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth."
  }

  validation {
    condition     = length(distinct(var.activity_log_categories)) == length(var.activity_log_categories)
    error_message = "activity_log_categories lists a category twice."
  }
}

variable "policy_assignments" {
  description = <<-EOT
    Azure Policy assignments of policy set definitions (initiatives) at the
    subscription, keyed by a stable logical name. The initiative is named by
    its display name and resolved at plan time; no definition ID is typed
    anywhere.

    policy_set_display_name       : display name of the initiative, exactly as
                                    Azure Policy shows it, for example
                                    "Microsoft cloud security benchmark".
                                    Display names are not unique by contract;
                                    a name that matches more than one
                                    definition fails the lookup, and the plan
                                    with it.
    name                          : the assignment's name in Azure. Defaults
                                    to the map key. 1 to 64 letters, digits,
                                    hyphens, and underscores. Immutable.
    display_name                  : shown in the portal and in compliance
                                    reports. Defaults to the initiative's
                                    display name.
    description                   : recorded on the assignment, up to 512
                                    characters.
    enforcement_mode              : "Default" (default) evaluates and
                                    enforces: a Deny effect denies, a
                                    DeployIfNotExists effect deploys.
                                    "DoNotEnforce" evaluates and reports
                                    only, which is how a new initiative is
                                    assigned first, so its compliance results
                                    can be read before any effect fires.
    non_compliance_message        : text shown with every denial and next to
                                    every non-compliant resource in the
                                    compliance view; the place to say who
                                    owns the exception process. Null (default)
                                    sets none.
    parameters                    : initiative parameters by name, string
                                    values only (the common case: an effect
                                    such as "Audit" or "Deny"). Every name
                                    must be a parameter the initiative
                                    declares; the plan refuses one it does
                                    not, naming the ones it does. A parameter
                                    that takes a list or an object cannot be
                                    set here.
    excluded_resource_group_names : resource groups in this subscription the
                                    assignment does not apply to, by name.
                                    Written as the assignment's not-scopes.
  EOT

  type = map(object({
    policy_set_display_name       = string
    name                          = optional(string)
    display_name                  = optional(string)
    description                   = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    enforcement_mode              = optional(string, "Default")
    non_compliance_message        = optional(string)
    parameters                    = optional(map(string), {})
    excluded_resource_group_names = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for key in keys(var.policy_assignments) : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", key))])
    error_message = "policy_assignments keys are 1 to 64 letters, digits, hyphens, and underscores, because a key is the assignment's name unless name is set."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : a.name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", coalesce(a.name, "x")))])
    error_message = "name must be 1 to 64 letters, digits, hyphens, and underscores."
  }

  validation {
    condition     = length(distinct([for key, a in var.policy_assignments : lower(coalesce(a.name, key))])) == length(var.policy_assignments)
    error_message = "Two entries would create assignments with the same name. Azure holds one assignment per name per scope, so give each entry its own name."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : length(trimspace(a.policy_set_display_name)) > 0 && length(a.policy_set_display_name) <= 128])
    error_message = "policy_set_display_name must be the initiative's display name, 1 to 128 characters."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : a.display_name == null || (length(trimspace(coalesce(a.display_name, "x"))) > 0 && length(coalesce(a.display_name, "")) <= 128)])
    error_message = "display_name must be 1 to 128 characters when set."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : length(a.description) <= 512])
    error_message = "description must be 512 characters or fewer."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : contains(["Default", "DoNotEnforce"], a.enforcement_mode)])
    error_message = "enforcement_mode must be \"Default\" (evaluate and enforce) or \"DoNotEnforce\" (evaluate and report only)."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : a.non_compliance_message == null || length(trimspace(coalesce(a.non_compliance_message, ""))) > 0])
    error_message = "non_compliance_message must not be blank when set; leave it null to set none."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.policy_assignments : [for name in keys(a.parameters) : can(regex("^[A-Za-z0-9_-]{1,128}$", name))]
    ]))
    error_message = "parameters keys are initiative parameter names: letters, digits, hyphens, and underscores."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.policy_assignments : [for rg in a.excluded_resource_group_names : can(regex("^[-\\w.()]{1,90}$", rg)) && !endswith(rg, ".")]
    ]))
    error_message = "excluded_resource_group_names must be resource group names: 1 to 90 letters, digits, underscores, hyphens, periods, and parentheses, not ending in a period."
  }

  validation {
    condition     = alltrue([for a in var.policy_assignments : length(distinct(a.excluded_resource_group_names)) == length(a.excluded_resource_group_names)])
    error_message = "excluded_resource_group_names lists a resource group twice."
  }
}

variable "tags" {
  description = "Tags applied to the workspace this module creates. Defender plans, the diagnostic setting, and policy assignments take no tags. The workspace entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
