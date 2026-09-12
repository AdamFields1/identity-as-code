# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider block, never by
# resources directly. The API token is not a variable: the provider reads
# OKTA_API_TOKEN from the environment so it never touches disk or state.
# ---------------------------------------------------------------------------

variable "okta_org_name" {
  description = "Okta org subdomain, the part before .okta.com or .oktapreview.com."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.okta_org_name))
    error_message = "okta_org_name must be a lowercase subdomain (letters, digits, hyphens)."
  }
}

variable "okta_base_url" {
  description = "Okta base domain: okta.com, oktapreview.com, or okta-emea.com."
  type        = string
  default     = "okta.com"

  validation {
    condition     = contains(["okta.com", "oktapreview.com", "okta-emea.com", "okta.mil"], var.okta_base_url)
    error_message = "okta_base_url must be one of okta.com, oktapreview.com, okta-emea.com, okta.mil."
  }
}

# ---------------------------------------------------------------------------
# Network zones. Same shape as modules/okta/network-zone.
# ---------------------------------------------------------------------------

variable "network_zones" {
  description = "Network zones keyed by logical name. Policy rules reference zones by these keys, never by ID."
  type = map(object({
    name               = string
    type               = string
    usage              = optional(string, "POLICY")
    status             = optional(string, "ACTIVE")
    gateways           = optional(list(string), [])
    proxies            = optional(list(string), [])
    dynamic_locations  = optional(list(string), [])
    asns               = optional(list(string), [])
    dynamic_proxy_type = optional(string)
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Sign-on policy. groups_included holds group NAMES; the stack resolves IDs.
# Rules reference zones by logical key (zones_included / zones_excluded).
# ---------------------------------------------------------------------------

variable "session_policy" {
  description = "Sign-on policy definition. See modules/okta/session-policy for attribute semantics."
  type = object({
    name            = string
    description     = optional(string, "Managed by Terraform. Do not edit in the console.")
    priority        = optional(number)
    status          = optional(string, "ACTIVE")
    groups_included = list(string)

    session_defaults = optional(object({
      idle_minutes      = optional(number, 120)
      lifetime_minutes  = optional(number, 720)
      persistent_cookie = optional(bool, false)
    }), {})

    rules = map(object({
      name                = string
      priority            = number
      status              = optional(string, "ACTIVE")
      access              = optional(string, "ALLOW")
      authtype            = optional(string, "ANY")
      mfa_required        = optional(bool, true)
      mfa_prompt          = optional(string, "SESSION")
      mfa_lifetime        = optional(number, 60)
      mfa_remember_device = optional(bool, false)
      network_connection  = optional(string, "ANYWHERE")
      zones_included      = optional(list(string), [])
      zones_excluded      = optional(list(string), [])
      session_idle        = optional(number)
      session_lifetime    = optional(number)
      session_persistent  = optional(bool)
      users_excluded      = optional(list(string), [])
    }))
  })

  validation {
    condition = alltrue(flatten([
      for r in var.session_policy.rules : [
        for z in concat(r.zones_included, r.zones_excluded) : contains(keys(var.network_zones), z)
      ]
    ]))
    error_message = "Every zone referenced by a session rule must be a key in network_zones."
  }
}

# ---------------------------------------------------------------------------
# MFA enrollment policy.
# ---------------------------------------------------------------------------

variable "mfa_policy" {
  description = "MFA enrollment policy definition. See modules/okta/mfa-policy for attribute semantics."
  type = object({
    name            = string
    description     = optional(string, "Managed by Terraform. Do not edit in the console.")
    priority        = optional(number)
    status          = optional(string, "ACTIVE")
    groups_included = list(string)
    is_oie          = optional(bool, true)

    authenticators = map(object({
      enroll       = string
      consent_type = optional(string, "NONE")
    }))

    rules = map(object({
      name               = string
      priority           = number
      status             = optional(string, "ACTIVE")
      enroll             = optional(string, "LOGIN")
      network_connection = optional(string, "ANYWHERE")
      zones_included     = optional(list(string), [])
      zones_excluded     = optional(list(string), [])
      users_excluded     = optional(list(string), [])
      app_include = optional(list(object({
        type = string
        id   = optional(string)
        name = optional(string)
      })), [])
    }))
  })

  validation {
    condition = alltrue(flatten([
      for r in var.mfa_policy.rules : [
        for z in concat(r.zones_included, r.zones_excluded) : contains(keys(var.network_zones), z)
      ]
    ]))
    error_message = "Every zone referenced by an MFA rule must be a key in network_zones."
  }
}

# ---------------------------------------------------------------------------
# Password policy. Every settings group is optional and inherits the module's
# secure defaults when omitted.
# ---------------------------------------------------------------------------

variable "password_policy" {
  description = "Password policy definition. See modules/okta/password-policy for attribute semantics and defaults."
  type = object({
    name            = string
    description     = optional(string, "Managed by Terraform. Do not edit in the console.")
    priority        = optional(number)
    status          = optional(string, "ACTIVE")
    groups_included = list(string)
    auth_provider   = optional(string, "OKTA")

    complexity = optional(object({
      min_length         = optional(number, 14)
      min_lowercase      = optional(number, 1)
      min_uppercase      = optional(number, 1)
      min_number         = optional(number, 1)
      min_symbol         = optional(number, 1)
      exclude_username   = optional(bool, true)
      exclude_first_name = optional(bool, true)
      exclude_last_name  = optional(bool, true)
      dictionary_lookup  = optional(bool, true)
    }), {})

    age = optional(object({
      max_age_days     = optional(number, 0)
      expire_warn_days = optional(number, 0)
      min_age_minutes  = optional(number, 60)
      history_count    = optional(number, 24)
    }), {})

    lockout = optional(object({
      max_attempts          = optional(number, 10)
      auto_unlock_minutes   = optional(number, 30)
      show_failures         = optional(bool, true)
      notification_channels = optional(list(string), ["EMAIL"])
    }), {})

    recovery = optional(object({
      email               = optional(string, "ACTIVE")
      email_token_minutes = optional(number, 60)
      sms                 = optional(string, "INACTIVE")
      call                = optional(string, "INACTIVE")
      question            = optional(string, "INACTIVE")
      question_min_length = optional(number, 8)
      skip_unlock         = optional(bool, false)
    }), {})

    rules = map(object({
      name               = string
      priority           = number
      status             = optional(string, "ACTIVE")
      password_change    = optional(string, "ALLOW")
      password_reset     = optional(string, "ALLOW")
      password_unlock    = optional(string, "ALLOW")
      network_connection = optional(string, "ANYWHERE")
      zones_included     = optional(list(string), [])
      zones_excluded     = optional(list(string), [])
      users_excluded     = optional(list(string), [])
    }))
  })

  validation {
    condition = alltrue(flatten([
      for r in var.password_policy.rules : [
        for z in concat(r.zones_included, r.zones_excluded) : contains(keys(var.network_zones), z)
      ]
    ]))
    error_message = "Every zone referenced by a password rule must be a key in network_zones."
  }
}
