variable "policies" {
  description = <<-EOT
    App sign-on (authentication) policies keyed by a stable logical name (for
    example "standard-workforce"). The key is part of the Terraform resource
    address and is what an app module names as its authentication policy, so
    renaming a key moves the resource in state and re-points every app on it.
    Change the visible name with "name".

    name                 : display name in the Okta admin console. Unique across
                           the map.
    description          : shown next to the policy in the console.
    allow_single_factor  : must be true for any ALLOW rule whose factor_mode is
                           1FA. Default false.
    single_factor_reason : why single-factor access is acceptable for this policy.
                           Required, and non-empty, when allow_single_factor is
                           true; meaningless otherwise.

    rules                : rules keyed by a logical name. Maps have no order, so a
                           rule carries a priority; lower numbers are evaluated
                           first and priorities are unique within a policy. A rule
                           left without one is appended by Okta after the rules
                           that have one.
      name                        : rule display name.
      priority                    : evaluation order, a positive integer.
      access                      : ALLOW or DENY.
      factor_mode                 : 1FA or 2FA. Default 2FA. Ignored on DENY.
      re_authentication_frequency : ISO 8601 duration after which the user must
                                    authenticate again regardless of activity.
                                    PT0S is every sign-in attempt, PT43800H is
                                    once per session. Default PT12H. Ignored on
                                    DENY.
      constraints                 : authenticator constraints an ALLOW demands.
                                    Ignored on DENY.
        possession                : phishing_resistant, hardware_protected,
                                    device_bound, and user_presence are each
                                    REQUIRED or OPTIONAL (the default); types
                                    narrows the possession authenticator to a
                                    list from app, email, phone, security_key,
                                    federated.
        knowledge                 : types narrows the knowledge authenticator to a
                                    list from password, security_question;
                                    re_authentication_frequency is an ISO 8601
                                    duration for the knowledge factor alone.
      network_connection          : ANYWHERE (default), ZONE, ON_NETWORK, or
                                    OFF_NETWORK.
      network_zone_names          : zone NAMES, looked up in the org, required
                                    when network_connection is ZONE and refused
                                    otherwise.
      device_is_managed           : match only devices a device management system
                                    manages. Okta evaluates this on registered
                                    devices only, so true implies
                                    device_is_registered = true.
      device_is_registered        : match only devices enrolled in Okta Verify.
      group_names                 : group NAMES the rule applies to, looked up in
                                    the org. Empty means every user the policy
                                    covers.
  EOT

  type = map(object({
    name                 = string
    description          = optional(string, "Managed by Terraform. Do not edit in the console.")
    allow_single_factor  = optional(bool, false)
    single_factor_reason = optional(string)

    rules = map(object({
      name                        = string
      priority                    = optional(number)
      access                      = string
      factor_mode                 = optional(string, "2FA")
      re_authentication_frequency = optional(string, "PT12H")

      constraints = optional(object({
        possession = optional(object({
          phishing_resistant = optional(string, "OPTIONAL")
          hardware_protected = optional(string, "OPTIONAL")
          device_bound       = optional(string, "OPTIONAL")
          user_presence      = optional(string, "OPTIONAL")
          types              = optional(list(string))
        }))
        knowledge = optional(object({
          types                       = optional(list(string))
          re_authentication_frequency = optional(string)
        }))
      }))

      network_connection   = optional(string, "ANYWHERE")
      network_zone_names   = optional(list(string), [])
      device_is_managed    = optional(bool)
      device_is_registered = optional(bool)
      group_names          = optional(list(string), [])
    }))
  }))

  validation {
    condition     = alltrue([for p in var.policies : length(trimspace(p.name)) > 0])
    error_message = "Policy name must not be empty."
  }

  validation {
    condition     = length(distinct([for p in var.policies : p.name])) == length(var.policies)
    error_message = "Policy names must be unique. Okta shows them side by side and an app module picks one by key, so two policies with one name is a trap for the reviewer."
  }

  validation {
    condition     = alltrue([for p in var.policies : !p.allow_single_factor || try(length(trimspace(p.single_factor_reason)) > 0, false)])
    error_message = "allow_single_factor = true requires a non-empty single_factor_reason. The reason is the review record for why one factor is enough on this policy; the flag alone says nothing."
  }

  validation {
    condition     = alltrue([for p in var.policies : p.single_factor_reason == null || p.allow_single_factor])
    error_message = "single_factor_reason only applies when allow_single_factor is true. A reason with no flag would read as if single factor were allowed when it is not."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : length(trimspace(r.name)) > 0]]))
    error_message = "Rule name must not be empty."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : contains(["ALLOW", "DENY"], r.access)]]))
    error_message = "Rule access must be ALLOW or DENY."
  }

  validation {
    condition     = alltrue([for p in var.policies : length([for r in p.rules : r if r.access == "ALLOW"]) > 0])
    error_message = "Each policy needs at least one ALLOW rule. The catch-all is created with DENY, so a policy with no ALLOW rule denies everyone: that is a deactivation of the app, not a sign-on policy, and an app is deactivated by setting its status."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : contains(["1FA", "2FA"], r.factor_mode)]]))
    error_message = "Rule factor_mode must be 1FA or 2FA."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [for r in p.rules : !(r.access == "ALLOW" && r.factor_mode == "1FA") || p.allow_single_factor]
    ]))
    error_message = "An ALLOW rule with factor_mode = 1FA is refused unless the policy sets allow_single_factor = true with a single_factor_reason. Single-factor access to an application is a decision, not a default: the flag puts the words single factor in the diff, next to the reason."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules :
        can(regex("^P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?$", r.re_authentication_frequency)) && can(regex("[0-9]", r.re_authentication_frequency)) && !endswith(r.re_authentication_frequency, "T")
      ]
    ]))
    error_message = "Rule re_authentication_frequency must be an ISO 8601 duration of days, hours, minutes, and seconds, for example PT0S, PT12H, P1D, or PT43800H."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : [
          for v in [coalesce(try(r.constraints.knowledge.re_authentication_frequency, null), "PT0S")] :
          can(regex("^P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?$", v)) && can(regex("[0-9]", v)) && !endswith(v, "T")
        ]
      ]
    ]))
    error_message = "constraints.knowledge.re_authentication_frequency must be an ISO 8601 duration of days, hours, minutes, and seconds when set, for example PT2H."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : [
          for v in [
            try(r.constraints.possession.phishing_resistant, "OPTIONAL"),
            try(r.constraints.possession.hardware_protected, "OPTIONAL"),
            try(r.constraints.possession.device_bound, "OPTIONAL"),
            try(r.constraints.possession.user_presence, "OPTIONAL"),
          ] : contains(["REQUIRED", "OPTIONAL"], v)
        ]
      ]
    ]))
    error_message = "constraints.possession phishing_resistant, hardware_protected, device_bound, and user_presence must each be REQUIRED or OPTIONAL."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : [
          for t in coalesce(try(r.constraints.possession.types, null), []) : contains(["app", "email", "phone", "security_key", "federated"], t)
        ]
      ]
    ]))
    error_message = "constraints.possession.types entries must be app, email, phone, security_key, or federated. The allowlist is the Okta authenticator type enum; anything else is a typo the API would reject after the plan."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : [
          for t in coalesce(try(r.constraints.knowledge.types, null), []) : contains(["password", "security_question"], t)
        ]
      ]
    ]))
    error_message = "constraints.knowledge.types entries must be password or security_question."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : contains(["ANYWHERE", "ZONE", "ON_NETWORK", "OFF_NETWORK"], r.network_connection)]]))
    error_message = "Rule network_connection must be ANYWHERE, ZONE, ON_NETWORK, or OFF_NETWORK."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : r.network_connection != "ZONE" || length(r.network_zone_names) > 0]]))
    error_message = "Rules with network_connection = ZONE must list at least one zone in network_zone_names. A ZONE condition with no zones matches nothing, which silently turns the rule off."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : r.network_connection == "ZONE" || length(r.network_zone_names) == 0]]))
    error_message = "network_zone_names only applies when network_connection is ZONE. Names on another connection type would be ignored, which hides a mistake."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : alltrue([for z in r.network_zone_names : length(trimspace(z)) > 0]) && length(distinct(r.network_zone_names)) == length(r.network_zone_names)
      ]
    ]))
    error_message = "network_zone_names entries must be non-empty and listed once each."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in p.rules : alltrue([for g in r.group_names : length(trimspace(g)) > 0]) && length(distinct(r.group_names)) == length(r.group_names)
      ]
    ]))
    error_message = "group_names entries must be non-empty and listed once each."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : !(r.device_is_managed == true && r.device_is_registered == false)]]))
    error_message = "device_is_managed = true cannot be combined with device_is_registered = false. Okta evaluates management only on a registered device; leave device_is_registered unset and the module sends true."
  }

  validation {
    condition     = alltrue(flatten([for p in var.policies : [for r in p.rules : r.priority == null || try(r.priority >= 1 && floor(r.priority) == r.priority, false)]]))
    error_message = "Rule priority must be a positive integer when set."
  }

  validation {
    condition = alltrue([
      for p in var.policies : length(distinct([for r in p.rules : r.priority if r.priority != null])) == length([for r in p.rules : r.priority if r.priority != null])
    ])
    error_message = "Rule priorities must be unique within a policy. Two rules at one priority leave Okta to pick the order, and the order is the policy."
  }
}
