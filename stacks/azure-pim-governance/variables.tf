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
# Tenant baseline for every policy. Defaults match modules/azure/pim-role-policy.
# A stricter tenant overrides these once rather than in every policy entry.
# ---------------------------------------------------------------------------

variable "activation_maximum_duration" {
  description = "Longest a single activation may last, as an ISO 8601 time duration such as PT2H or PT4H. Validated by the module."
  type        = string
  default     = "PT4H"
}

variable "require_multifactor_authentication" {
  description = "Require MFA on activation."
  type        = bool
  default     = true
}

variable "require_justification" {
  description = "Require a written justification on activation."
  type        = bool
  default     = true
}

variable "require_ticket_info" {
  description = "Require a ticket number and system on activation."
  type        = bool
  default     = false
}

variable "require_approval" {
  description = "Require an approver to accept each activation. When true, approver_groups must name at least one group."
  type        = bool
  default     = false

  validation {
    condition     = !var.require_approval || length(var.approver_groups) > 0
    error_message = "require_approval is true but approver_groups is empty."
  }
}

variable "approver_groups" {
  description = "Display names of the Entra security groups whose members may approve an activation. The stack resolves them to object IDs; a cell never holds a GUID."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.approver_groups : length(trimspace(g)) > 0])
    error_message = "approver_groups entries must be non-empty display names."
  }
}

variable "eligible_assignment_rules" {
  description = "Baseline for eligible assignments: whether an end date is required and the longest allowed (P15D, P30D, P90D, P180D, P365D)."
  type = object({
    expiration_required = optional(bool, true)
    expire_after        = optional(string, "P365D")
  })
  default = {}
}

variable "active_assignment_rules" {
  description = "Baseline for active (standing) assignments made through PIM."
  type = object({
    expiration_required                = optional(bool, true)
    expire_after                       = optional(string, "P180D")
    require_multifactor_authentication = optional(bool, true)
    require_justification              = optional(bool, true)
  })
  default = {}
}

variable "notification_rules" {
  description = "Optional admin notification settings applied to every policy. Null leaves Azure defaults untouched. See modules/azure/pim-role-policy for the shape."
  type = object({
    eligible_assignments = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
    eligible_activations = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
    active_assignments = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
  })
  default = null
}

# ---------------------------------------------------------------------------
# Policies. Same shape as the module except that per-policy approvers are
# group display names (approver_groups), which this stack resolves.
# ---------------------------------------------------------------------------

variable "policies" {
  description = "Role management policies keyed by logical name, one per (scope, role) pair. Per-entry overrides are optional and inherit the tenant baseline when unset. See modules/azure/pim-role-policy for attribute semantics."
  type = map(object({
    role_name = string

    scope = object({
      type = string
      name = string
    })

    activation = optional(object({
      maximum_duration                   = optional(string)
      require_multifactor_authentication = optional(bool)
      require_justification              = optional(bool)
      require_ticket_info                = optional(bool)
      require_approval                   = optional(bool)
      approver_groups                    = optional(list(string))
    }), {})

    eligible_assignment_rules = optional(object({
      expiration_required = optional(bool)
      expire_after        = optional(string)
    }), {})

    active_assignment_rules = optional(object({
      expiration_required                = optional(bool)
      expire_after                       = optional(string)
      require_multifactor_authentication = optional(bool)
      require_justification              = optional(bool)
    }), {})
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Eligibilities. Same shape as modules/azure/pim-eligible-assignment.
# ---------------------------------------------------------------------------

variable "eligibilities" {
  description = "PIM eligible role assignments keyed by logical name. Groups, roles, and scopes are all given by name. See modules/azure/pim-eligible-assignment for attribute semantics."
  type = map(object({
    group_display_name = string
    role_name          = string

    scope = object({
      type = string
      name = string
    })

    justification = optional(string, "Managed by Terraform. See the identity-as-code repository.")

    expiration = optional(object({
      duration_days = optional(number, 365)
      permanent     = optional(bool, false)
    }), {})
  }))
  default = {}

  # Every (scope, role) an eligibility uses should have a policy in the same
  # cell. Not a hard requirement of Azure, which falls back to the default
  # policy, but a tenant that assigns a role without stating its activation
  # rules has not finished the job.
  validation {
    condition = alltrue([
      for e in var.eligibilities :
      contains([for p in var.policies : "${p.scope.type}/${p.scope.name}|${p.role_name}"], "${e.scope.type}/${e.scope.name}|${e.role_name}")
    ])
    error_message = "Every eligibility must have a matching entry in policies for the same scope and role_name. Add the policy so the activation rules are explicit."
  }
}
