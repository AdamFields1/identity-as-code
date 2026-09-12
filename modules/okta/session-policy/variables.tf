variable "name" {
  description = "Display name of the sign-on policy."
  type        = string

  validation {
    condition     = length(trimspace(var.name)) > 0
    error_message = "Policy name must not be empty."
  }
}

variable "description" {
  description = "Human readable description shown in the Okta admin console."
  type        = string
  default     = "Managed by Terraform. Do not edit in the console."
}

variable "priority" {
  description = "Policy priority. 1 is evaluated first. Leave null to let Okta append it after existing policies."
  type        = number
  default     = null

  validation {
    condition     = var.priority == null || try(var.priority >= 1, false)
    error_message = "Priority must be a positive integer when set."
  }
}

variable "status" {
  description = "Policy status, ACTIVE or INACTIVE."
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.status)
    error_message = "Status must be ACTIVE or INACTIVE."
  }
}

variable "groups_included" {
  description = "List of Okta group IDs the policy applies to. Resolve names to IDs in the calling stack with the okta_group data source."
  type        = list(string)

  validation {
    condition     = length(var.groups_included) > 0
    error_message = "At least one group ID is required, otherwise the policy applies to nobody."
  }
}

variable "session_defaults" {
  description = <<-EOT
    Session values applied to any rule that does not override them.
    idle_minutes      : maximum idle time before the session expires.
    lifetime_minutes  : absolute maximum session lifetime.
    persistent_cookie : whether the session survives a browser restart.
  EOT

  type = object({
    idle_minutes      = optional(number, 120)
    lifetime_minutes  = optional(number, 720)
    persistent_cookie = optional(bool, false)
  })
  default = {}

  validation {
    condition     = var.session_defaults.idle_minutes >= 1 && var.session_defaults.lifetime_minutes >= 1
    error_message = "Session idle and lifetime values must be at least 1 minute."
  }

  validation {
    condition     = var.session_defaults.idle_minutes <= var.session_defaults.lifetime_minutes
    error_message = "Session idle timeout cannot exceed the session lifetime."
  }
}

variable "rules" {
  description = <<-EOT
    Sign-on rules keyed by a stable logical name. Each rule needs an explicit priority
    because a map has no order. Lower numbers are evaluated first.

    access             : ALLOW or DENY.
    authtype           : ANY, RADIUS, or LDAP_INTERFACE.
    mfa_required       : require a second factor on this rule.
    mfa_prompt         : DEVICE, SESSION, or ALWAYS. Only meaningful when mfa_required is true.
    mfa_lifetime       : minutes an MFA prompt is remembered when mfa_prompt is SESSION.
    mfa_remember_device: allow "remember this device" when mfa_prompt is DEVICE.
    network_connection : ANYWHERE or ZONE. When ZONE, supply zone_ids_included and/or zone_ids_excluded.
    session_*          : per-rule overrides of session_defaults. Null means inherit.
    users_excluded     : user IDs exempt from the rule (break-glass accounts, for example).
  EOT

  type = map(object({
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
    zone_ids_included   = optional(list(string), [])
    zone_ids_excluded   = optional(list(string), [])
    session_idle        = optional(number)
    session_lifetime    = optional(number)
    session_persistent  = optional(bool)
    users_excluded      = optional(list(string), [])
  }))

  validation {
    condition     = length(var.rules) > 0
    error_message = "At least one rule is required. A policy with no rules is never evaluated."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ALLOW", "DENY"], r.access)])
    error_message = "Rule access must be ALLOW or DENY."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ANY", "RADIUS", "LDAP_INTERFACE"], r.authtype)])
    error_message = "Rule authtype must be ANY, RADIUS, or LDAP_INTERFACE."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["DEVICE", "SESSION", "ALWAYS"], r.mfa_prompt)])
    error_message = "Rule mfa_prompt must be DEVICE, SESSION, or ALWAYS."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ANYWHERE", "ZONE"], r.network_connection)])
    error_message = "Rule network_connection must be ANYWHERE or ZONE."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.network_connection != "ZONE" || (length(r.zone_ids_included) + length(r.zone_ids_excluded)) > 0
    ])
    error_message = "Rules with network_connection = ZONE must list at least one included or excluded zone ID."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ACTIVE", "INACTIVE"], r.status)])
    error_message = "Rule status must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = alltrue([for r in var.rules : r.priority >= 1])
    error_message = "Rule priority must be a positive integer."
  }

  validation {
    condition     = length(distinct([for r in var.rules : r.priority])) == length(var.rules)
    error_message = "Rule priorities must be unique within a policy."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.session_idle == null || r.session_lifetime == null || r.session_idle <= r.session_lifetime
    ])
    error_message = "A rule's session_idle cannot exceed its session_lifetime."
  }
}
