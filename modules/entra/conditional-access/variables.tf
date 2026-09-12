variable "named_locations" {
  description = <<-EOT
    Named locations keyed by a stable logical name (for example "corp-egress").
    Policies reference locations by these keys, never by ID. Each location is either
    an IP location or a country location, not both.

    display_name              : shown in the portal.
    ip_ranges                 : IPv4 or IPv6 CIDRs. Makes this an IP location.
    trusted                   : IP locations only. Trusted locations are excluded by
                                "AllTrusted" and skip sign-in risk evaluation.
    countries                 : ISO 3166-2 two-letter codes. Makes this a country location.
    include_unknown_countries : country locations only.
    country_lookup_method     : clientIpAddress (default) or authenticatorAppGps.
  EOT

  type = map(object({
    display_name              = string
    ip_ranges                 = optional(list(string), [])
    trusted                   = optional(bool, false)
    countries                 = optional(list(string), [])
    include_unknown_countries = optional(bool, false)
    country_lookup_method     = optional(string, "clientIpAddress")
  }))
  default = {}

  validation {
    condition = alltrue([
      for l in var.named_locations : (length(l.ip_ranges) > 0) != (length(l.countries) > 0)
    ])
    error_message = "Each named location must define exactly one of ip_ranges or countries."
  }

  validation {
    condition = alltrue(flatten([
      for l in var.named_locations : [
        for r in l.ip_ranges : can(regex("^(([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}|[0-9a-fA-F:]+/[0-9]{1,3})$", r))
      ]
    ]))
    error_message = "ip_ranges entries must be IPv4 CIDRs (203.0.113.0/24) or IPv6 CIDRs (2001:db8::/32)."
  }

  validation {
    condition = alltrue(flatten([
      for l in var.named_locations : [for c in l.countries : can(regex("^[A-Z]{2}$", c))]
    ]))
    error_message = "countries entries must be two-letter upper-case ISO 3166-2 codes."
  }

  validation {
    condition     = alltrue([for l in var.named_locations : contains(["clientIpAddress", "authenticatorAppGps"], l.country_lookup_method)])
    error_message = "country_lookup_method must be clientIpAddress or authenticatorAppGps."
  }
}

variable "authentication_strengths" {
  description = <<-EOT
    Custom authentication strength policies keyed by a stable logical name (for
    example "phishing-resistant"). Policies reference strengths by these keys.

    allowed_combinations : authentication method combinations accepted by this
    strength, using the Graph names, for example "windowsHelloForBusiness", "fido2",
    "x509CertificateMultiFactor", "password,microsoftAuthenticatorPush".
  EOT

  type = map(object({
    display_name         = string
    description          = optional(string, "Managed by Terraform.")
    allowed_combinations = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for s in var.authentication_strengths : length(s.allowed_combinations) > 0])
    error_message = "Each authentication strength must allow at least one combination."
  }
}

variable "break_glass_exclusion_group" {
  description = <<-EOT
    Display name of the security group holding the emergency access (break-glass)
    accounts. It is appended to the excluded groups of EVERY policy in this module,
    whether or not the policy lists it. There is no way to opt a policy out. See
    docs/adr/0007-break-glass-exclusion-is-mandatory.md.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.break_glass_exclusion_group)) > 0
    error_message = "break_glass_exclusion_group must name the emergency access group. It cannot be empty."
  }
}

variable "policies" {
  description = <<-EOT
    Conditional Access policies keyed by a stable logical name (for example
    "block-legacy-auth").

    display_name : shown in the portal.
    state        : enabledForReportingButNotEnforced (default), enabled, or disabled.
                   New policies land in report-only so the sign-in log shows who
                   would have been blocked before anyone is.

    users : who the policy applies to. Groups and roles are names, resolved by the module.
      included_users  : "All", "None", or "GuestsOrExternalUsers".
      excluded_users  : "GuestsOrExternalUsers".
      included_groups : group display names.
      excluded_groups : group display names. The break-glass group is always appended.
      included_roles  : directory role display names (role templates).
      excluded_roles  : directory role display names.

    applications : what the policy applies to.
      included     : "All", "None", "Office365", "MicrosoftAdminPortals", or enterprise
                     application display names resolved to client IDs.
      excluded     : same values.
      user_actions : "urn:user:registersecurityinfo" or "urn:user:registerdevice".

    client_app_types    : all (default), browser, mobileAppsAndDesktopClients,
                          exchangeActiveSync, easSupported, other.
    sign_in_risk_levels : low, medium, high, hidden, none.
    user_risk_levels    : low, medium, high, hidden, none.
    platforms           : { included = [...], excluded = [...] } using all, android,
                          iOS, linux, macOS, windows, windowsPhone.
    locations           : { included = [...], excluded = [...] } using "All",
                          "AllTrusted", or named_locations keys.

    grant_controls : required unless session_controls is set.
      operator                : AND or OR (default OR).
      built_in_controls       : block, mfa, compliantDevice, domainJoinedDevice,
                                approvedApplication, compliantApplication, passwordChange.
      authentication_strength : an authentication_strengths key.

    session_controls : optional.
  EOT

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
    condition     = alltrue([for p in var.policies : contains(["enabled", "disabled", "enabledForReportingButNotEnforced"], p.state)])
    error_message = "state must be enabled, disabled, or enabledForReportingButNotEnforced."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      (length(p.users.included_users) + length(p.users.included_groups) + length(p.users.included_roles)) > 0
    ])
    error_message = "Every policy must include at least one of included_users, included_groups, or included_roles."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [for u in p.users.included_users : contains(["All", "None", "GuestsOrExternalUsers"], u)]
    ]))
    error_message = "included_users accepts only All, None, or GuestsOrExternalUsers. Put individual users in a group."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [for u in p.users.excluded_users : u == "GuestsOrExternalUsers"]
    ]))
    error_message = "excluded_users accepts only GuestsOrExternalUsers. Put individual users in a group."
  }

  validation {
    condition = alltrue([
      for p in var.policies : (length(p.applications.included) + length(p.applications.user_actions)) > 0
    ])
    error_message = "Every policy must include at least one application or user action."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for a in p.applications.user_actions : contains(["urn:user:registersecurityinfo", "urn:user:registerdevice"], a)
      ]
    ]))
    error_message = "user_actions must be urn:user:registersecurityinfo or urn:user:registerdevice."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for t in p.client_app_types : contains(["all", "browser", "mobileAppsAndDesktopClients", "exchangeActiveSync", "easSupported", "other"], t)
      ]
    ]))
    error_message = "client_app_types must be all, browser, mobileAppsAndDesktopClients, exchangeActiveSync, easSupported, or other."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for r in concat(p.sign_in_risk_levels, p.user_risk_levels) : contains(["low", "medium", "high", "hidden", "none"], r)
      ]
    ]))
    error_message = "Risk levels must be low, medium, high, hidden, or none."
  }

  validation {
    condition = alltrue([
      for p in var.policies : p.platforms == null || alltrue([
        for x in concat(p.platforms.included, p.platforms.excluded) :
        contains(["all", "android", "iOS", "linux", "macOS", "windows", "windowsPhone"], x)
      ])
    ])
    error_message = "Platforms must be all, android, iOS, linux, macOS, windows, or windowsPhone."
  }

  validation {
    condition = alltrue([
      for p in var.policies : p.locations == null || alltrue([
        for l in concat(p.locations.included, p.locations.excluded) :
        contains(["All", "AllTrusted"], l) || contains(keys(var.named_locations), l)
      ])
    ])
    error_message = "Locations must be All, AllTrusted, or a key in named_locations."
  }

  validation {
    condition     = alltrue([for p in var.policies : p.grant_controls != null || p.session_controls != null])
    error_message = "Every policy must define grant_controls or session_controls."
  }

  validation {
    condition = alltrue([
      for p in var.policies : p.grant_controls == null || (
        contains(["AND", "OR"], p.grant_controls.operator) &&
        (length(p.grant_controls.built_in_controls) > 0 || p.grant_controls.authentication_strength != null)
      )
    ])
    error_message = "grant_controls needs operator AND or OR and at least one built_in_controls entry or an authentication_strength key."
  }

  validation {
    condition = alltrue([
      for p in var.policies : p.grant_controls == null || alltrue([
        for c in p.grant_controls.built_in_controls :
        contains(["block", "mfa", "approvedApplication", "compliantApplication", "compliantDevice", "domainJoinedDevice", "passwordChange"], c)
      ])
    ])
    error_message = "built_in_controls must be block, mfa, approvedApplication, compliantApplication, compliantDevice, domainJoinedDevice, or passwordChange."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.grant_controls == null || p.grant_controls.authentication_strength == null || contains(keys(var.authentication_strengths), p.grant_controls.authentication_strength)
    ])
    error_message = "grant_controls.authentication_strength must be a key in authentication_strengths."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.grant_controls == null || !(contains(p.grant_controls.built_in_controls, "block") && length(p.grant_controls.built_in_controls) > 1)
    ])
    error_message = "block cannot be combined with other grant controls."
  }

  validation {
    condition = alltrue([
      for p in var.policies : p.session_controls == null || (
        (p.session_controls.persistent_browser_mode == null || contains(["always", "never"], p.session_controls.persistent_browser_mode)) &&
        (p.session_controls.cloud_app_security_policy == null || contains(["blockDownloads", "mcasConfigured", "monitorOnly"], p.session_controls.cloud_app_security_policy)) &&
        (p.session_controls.sign_in_frequency_period == null || contains(["hours", "days"], p.session_controls.sign_in_frequency_period)) &&
        (p.session_controls.sign_in_frequency_authentication_type == null || contains(["primaryAndSecondaryAuthentication", "secondaryAuthentication"], p.session_controls.sign_in_frequency_authentication_type)) &&
        (p.session_controls.sign_in_frequency_interval == null || contains(["timeBased", "everyTime"], p.session_controls.sign_in_frequency_interval)) &&
        ((p.session_controls.sign_in_frequency == null) == (p.session_controls.sign_in_frequency_period == null))
      )
    ])
    error_message = "session_controls has an invalid value. sign_in_frequency and sign_in_frequency_period must be set together."
  }
}
