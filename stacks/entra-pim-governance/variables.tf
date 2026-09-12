# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never by
# resources directly. Credentials are not variables: the providers use OIDC
# (use_oidc) so no secret touches disk or state.
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Entra tenant ID (GUID). Not a secret; a tenant ID is discoverable from any of its domains."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "Azure subscription ID for the azurerm provider. Unused by this Entra-only stack but required by the generated provider block."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# Privileged groups. Same shape as modules/entra/security-group minus
# assignable_to_role, which this stack forces to true: every group here exists
# to hold a directory role eligibility, and only role-assignable groups can.
# ---------------------------------------------------------------------------

variable "privileged_groups" {
  description = "Role-assignable groups keyed by logical name. Membership is never listed here; PIM activation writes it."
  type = map(object({
    display_name = string
    description  = optional(string, "PIM-governed privileged group. Membership is written by PIM activation, not by Terraform.")
    owners       = optional(list(string), [])
  }))

  validation {
    condition     = length(var.privileged_groups) > 0
    error_message = "At least one privileged group is required."
  }
}

# ---------------------------------------------------------------------------
# Role management policies. Same shape as modules/entra/pim-role-policy.
# ---------------------------------------------------------------------------

variable "role_policies" {
  description = "PIM for Groups policies keyed by logical name. group_display_name must match a privileged_groups display name. See modules/entra/pim-role-policy."
  type = map(object({
    group_display_name = string
    role               = optional(string, "member")

    activation = optional(object({
      maximum_duration                   = optional(string, "PT4H")
      require_multifactor_authentication = optional(bool, true)
      require_justification              = optional(bool, true)
      require_ticket_info                = optional(bool, false)
      require_approval                   = optional(bool, false)
      approver_groups                    = optional(list(string), [])
    }), {})

    eligible_assignment = optional(object({
      expiration_required = optional(bool, true)
      expire_after        = optional(string, "P365D")
    }), {})

    active_assignment = optional(object({
      expiration_required                = optional(bool, true)
      expire_after                       = optional(string, "P180D")
      require_justification              = optional(bool, true)
      require_multifactor_authentication = optional(bool, true)
    }), {})

    notifications = optional(object({
      admin_notification_level    = optional(string, "All")
      admin_default_recipients    = optional(bool, true)
      admin_additional_recipients = optional(list(string), [])
    }), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for p in var.role_policies : contains([for g in var.privileged_groups : g.display_name], p.group_display_name)
    ])
    error_message = "Every role_policies entry must target a group defined in privileged_groups. This stack governs only the groups it creates."
  }
}

# ---------------------------------------------------------------------------
# Eligibilities. Same shapes as modules/entra/pim-eligibility.
# ---------------------------------------------------------------------------

variable "directory_role_eligibilities" {
  description = "Group to directory role eligibilities keyed by logical name. group_display_name must match a privileged_groups display name."
  type = map(object({
    role_display_name  = string
    group_display_name = string
    directory_scope_id = optional(string, "/")
    justification      = optional(string, "Managed by Terraform. See the identity-as-code repository.")
  }))
  default = {}

  validation {
    condition = alltrue([
      for e in var.directory_role_eligibilities : contains([for g in var.privileged_groups : g.display_name], e.group_display_name)
    ])
    error_message = "Every directory_role_eligibilities entry must name a group defined in privileged_groups."
  }
}

variable "group_eligibilities" {
  description = "User or group to PIM group eligibilities keyed by logical name. group_display_name must match a privileged_groups display name; the principal may be any existing user or group."
  type = map(object({
    group_display_name = string
    principal_user     = optional(string)
    principal_group    = optional(string)
    assignment_type    = optional(string, "member")
    permanent          = optional(bool, true)
    duration           = optional(string)
    justification      = optional(string, "Managed by Terraform. See the identity-as-code repository.")
  }))
  default = {}

  validation {
    condition = alltrue([
      for e in var.group_eligibilities : contains([for g in var.privileged_groups : g.display_name], e.group_display_name)
    ])
    error_message = "Every group_eligibilities entry must target a group defined in privileged_groups."
  }
}
