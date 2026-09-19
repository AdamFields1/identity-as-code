# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never
# by resources directly. Both are declared by every stack under tenants/azure
# as part of the contract in tenants/azure/root.hcl. Under
# subscriptions/<sub-name>/ the root fills subscription_id from that
# directory's locator; the stack passes neither value on, and the modules
# discover the subscription from the provider.
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Entra tenant ID the providers authenticate to. Supplied by tenants/azure/root.hcl from ARM_TENANT_ID, never typed into a cell."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "The subscription this baseline applies to. Required in practice because every resource here is subscription-scoped; supplied by tenants/azure/root.hcl from the subscription.hcl locator above the cell, or from ARM_SUBSCRIPTION_ID for a tenant-wide cell."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# The baseline resource group and the workspace. Two switches decide the
# shape: create_workspace says whether the activity log's workspace is made
# here or found, and baseline_resource_group is the group it is made in.
# The two travel together and the validations say so.
# ---------------------------------------------------------------------------

variable "create_workspace" {
  description = "True creates the Log Analytics workspace in baseline_resource_group (which is then required) with the settings in log_analytics_workspace. False (the default) looks an existing workspace up by name in log_analytics_workspace.resource_group_name and creates neither a workspace nor a resource group."
  type        = bool
  default     = false
}

variable "baseline_resource_group" {
  description = <<-EOT
    The resource group this stack creates to hold the workspace, with an
    optional CanNotDelete lock. Required when create_workspace is true and
    refused otherwise: with an existing workspace there is nothing to put in
    it. See modules/azure/resource-group for the group's own rules.

    name        : the resource group name in Azure. Immutable.
    location    : Azure region, short form (eastus). Immutable. The workspace
                  is created in the same region.
    delete_lock : true adds a CanNotDelete management lock on the group.
                  While it exists nothing in the group, the workspace
                  included, can be deleted by anyone from anywhere,
                  including another cell's plan. Default false.
    tags        : tags on the group, merged over the stack-level tags.
  EOT

  type = object({
    name        = string
    location    = string
    delete_lock = optional(bool, false)
    tags        = optional(map(string), {})
  })
  default = null

  # Both cross-checks with create_workspace live here, and none on
  # create_workspace itself: two variables whose validations refer to each
  # other are a cycle Terraform refuses.
  validation {
    condition     = !var.create_workspace || var.baseline_resource_group != null
    error_message = "create_workspace = true creates the workspace in the baseline resource group, so set baseline_resource_group = { name, location } as well."
  }

  validation {
    condition     = var.baseline_resource_group == null || var.create_workspace
    error_message = "baseline_resource_group is created only to hold the workspace that create_workspace = true creates. With create_workspace = false nothing would be put in it, so omit it, or set create_workspace = true."
  }

  validation {
    condition     = var.baseline_resource_group == null || (can(regex("^[-\\w.()]{1,90}$", var.baseline_resource_group.name)) && !endswith(var.baseline_resource_group.name, "."))
    error_message = "baseline_resource_group.name must be 1 to 90 letters, digits, underscores, hyphens, periods, and parentheses, and must not end in a period."
  }

  validation {
    condition     = var.baseline_resource_group == null || can(regex("^[a-z0-9]{3,40}$", var.baseline_resource_group.location))
    error_message = "baseline_resource_group.location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }
}

variable "log_analytics_workspace" {
  description = <<-EOT
    The Log Analytics workspace the subscription's activity log is sent to.

    name                       : workspace name, 4 to 63 letters, digits, and
                                 hyphens, not starting or ending with a hyphen.
    resource_group_name        : the existing group the workspace is looked up
                                 in. Required when create_workspace is false
                                 and refused when it is true, because a
                                 created workspace lives in
                                 baseline_resource_group.
    retention_in_days          : interactive retention of a created workspace,
                                 30 to 730, default 90. Ignored for a looked-up
                                 workspace.
    daily_quota_gb             : daily ingestion cap of a created workspace.
                                 -1 (default) is no cap; a reached cap drops
                                 the audit trail for the rest of the day.
    internet_ingestion_enabled : public ingestion endpoint of a created
                                 workspace. Default true.
    internet_query_enabled     : public query endpoint of a created workspace.
                                 Default true.
    tags                       : tags on a created workspace, merged over the
                                 stack-level tags.

    See modules/azure/subscription-baseline for what is fixed on a created
    workspace (PerGB2018, local authentication off, prevent_destroy).
  EOT

  type = object({
    name                       = string
    resource_group_name        = optional(string)
    retention_in_days          = optional(number, 90)
    daily_quota_gb             = optional(number, -1)
    internet_ingestion_enabled = optional(bool, true)
    internet_query_enabled     = optional(bool, true)
    tags                       = optional(map(string), {})
  })

  validation {
    condition     = var.create_workspace ? var.log_analytics_workspace.resource_group_name == null : var.log_analytics_workspace.resource_group_name != null
    error_message = "log_analytics_workspace.resource_group_name names the existing group a workspace is looked up in: set it when create_workspace is false, and omit it when create_workspace is true (the workspace is created in baseline_resource_group)."
  }

  validation {
    condition     = var.log_analytics_workspace.resource_group_name == null || length(trimspace(coalesce(var.log_analytics_workspace.resource_group_name, ""))) > 0
    error_message = "log_analytics_workspace.resource_group_name must not be blank when set."
  }
}

variable "activity_log_categories" {
  description = "Activity log categories sent to the workspace. Default is every category: Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth. See modules/azure/subscription-baseline."
  type        = list(string)
  default     = ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"]
}

# ---------------------------------------------------------------------------
# Defender plans and initiatives. Same shapes as the module; the defaults
# are the stack's opinion of a baseline.
# ---------------------------------------------------------------------------

variable "defender_plans" {
  description = "Defender for Cloud plans keyed by resource type (VirtualMachines, StorageAccounts, KeyVaults, ...): { tier = \"Standard\" | \"Free\", subplan, extensions }. Empty (the default) manages no plan; a cell lists the plans it turns on and the ones it holds off. See modules/azure/subscription-baseline for the resource types and the rules."
  type = map(object({
    tier       = optional(string, "Standard")
    subplan    = optional(string)
    extensions = optional(map(map(string)), {})
  }))
  default = {}
}

variable "policy_assignments" {
  description = "Initiative assignments keyed by logical name: { policy_set_display_name, name, display_name, description, enforcement_mode = \"Default\" | \"DoNotEnforce\", non_compliance_message, parameters, excluded_resource_group_names }. The default assigns the Microsoft cloud security benchmark, enforced, with no message; a cell that sets this map replaces the default entirely. See modules/azure/subscription-baseline."
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
  default = {
    microsoft-cloud-security-benchmark = {
      policy_set_display_name = "Microsoft cloud security benchmark"
    }
  }
}

variable "tags" {
  description = "Tags applied to the resource group and the workspace this stack creates."
  type        = map(string)
  default     = {}
}
