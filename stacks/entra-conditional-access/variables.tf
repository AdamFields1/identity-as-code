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
# Conditional Access. Same shapes as modules/entra/conditional-access.
# ---------------------------------------------------------------------------

variable "break_glass_exclusion_group" {
  description = "Display name of the emergency access group. Appended to every policy's excluded groups. Required and non-empty."
  type        = string

  validation {
    condition     = length(trimspace(var.break_glass_exclusion_group)) > 0
    error_message = "break_glass_exclusion_group must name the emergency access group. It cannot be empty."
  }
}

variable "named_locations" {
  description = "Named locations keyed by logical name. Policies reference these keys. See modules/entra/conditional-access."
  type = map(object({
    display_name              = string
    ip_ranges                 = optional(list(string), [])
    trusted                   = optional(bool, false)
    countries                 = optional(list(string), [])
    include_unknown_countries = optional(bool, false)
    country_lookup_method     = optional(string, "clientIpAddress")
  }))
  default = {}
}

variable "authentication_strengths" {
  description = "Custom authentication strengths keyed by logical name. Policies reference these keys. See modules/entra/conditional-access."
  type = map(object({
    display_name         = string
    description          = optional(string, "Managed by Terraform.")
    allowed_combinations = list(string)
  }))
  default = {}
}

variable "policies" {
  description = "Conditional Access policies keyed by logical name. Groups, roles, and applications by display name; locations and strengths by key. See modules/entra/conditional-access."
  type = map(object({
    display_name = string
    state        = optional(string, "enabledForReportingButNotEnforced")

    users = optional(object({
      included_users  = optional(list(string), [])
      excluded_users  = optional(list(string), [])
      included_groups = optional(list(string), [])
      excluded_groups = optional(list(string), [])
      included_roles  = optional(list(string), [])
      excluded_roles  = optional(list(string), [])
    }), {})

    applications = optional(object({
      included     = optional(list(string), ["All"])
      excluded     = optional(list(string), [])
      user_actions = optional(list(string), [])
    }), {})

    client_app_types    = optional(list(string), ["all"])
    sign_in_risk_levels = optional(list(string), [])
    user_risk_levels    = optional(list(string), [])

    platforms = optional(object({
      included = list(string)
      excluded = optional(list(string), [])
    }))

    locations = optional(object({
      included = list(string)
      excluded = optional(list(string), [])
    }))

    grant_controls = optional(object({
      operator                = optional(string, "OR")
      built_in_controls       = optional(list(string), [])
      authentication_strength = optional(string)
    }))

    session_controls = optional(object({
      application_enforced_restrictions_enabled = optional(bool)
      cloud_app_security_policy                 = optional(string)
      disable_resilience_defaults               = optional(bool)
      persistent_browser_mode                   = optional(string)
      sign_in_frequency                         = optional(number)
      sign_in_frequency_period                  = optional(string)
      sign_in_frequency_authentication_type     = optional(string)
      sign_in_frequency_interval                = optional(string)
    }))
  }))

  validation {
    condition = alltrue([
      for p in var.policies : p.locations == null || alltrue([
        for l in concat(p.locations.included, p.locations.excluded) :
        contains(["All", "AllTrusted"], l) || contains(keys(var.named_locations), l)
      ])
    ])
    error_message = "Every location referenced by a policy must be All, AllTrusted, or a key in named_locations."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.grant_controls == null || p.grant_controls.authentication_strength == null || contains(keys(var.authentication_strengths), p.grant_controls.authentication_strength)
    ])
    error_message = "Every authentication_strength referenced by a policy must be a key in authentication_strengths."
  }
}
