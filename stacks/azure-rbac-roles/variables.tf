# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never
# by resources directly. Both are declared by every stack under tenants/azure
# as part of the contract in tenants/azure/root.hcl. The client ID is not a
# variable: the provider reads ARM_CLIENT_ID from the environment and the
# credential itself is a federated token that never touches disk or state.
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
  description = "Default subscription for the azurerm provider. Required here because resource_group scopes are looked up in it. Supplied by tenants/azure/root.hcl from ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# Custom roles. Same shape as modules/azure/rbac-role-definition.
# ---------------------------------------------------------------------------

variable "custom_roles" {
  description = "Custom role definitions keyed by logical name. Scopes are given as { type, name } and resolved by the module. See modules/azure/rbac-role-definition for attribute semantics and validation."
  type = map(object({
    name        = string
    description = string

    actions          = list(string)
    not_actions      = optional(list(string), [])
    data_actions     = optional(list(string), [])
    not_data_actions = optional(list(string), [])

    assignable_scope = object({
      type = string
      name = string
    })

    additional_assignable_scopes = optional(list(object({
      type = string
      name = string
    })), [])
  }))

  validation {
    condition     = length(var.custom_roles) > 0
    error_message = "custom_roles is empty. A tenant with no custom roles should not have an azure-rbac-roles cell at all (the subsidiary tenant is the example)."
  }
}
