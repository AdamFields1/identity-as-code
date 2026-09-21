variable "policy_id" {
  description = "Id of the org's IDP_DISCOVERY policy. Every org has exactly one; the calling stack looks it up with the okta_policy data source (type IDP_DISCOVERY, name \"Idp Discovery Policy\") and passes the id here, so no cell or module carries it."
  type        = string

  validation {
    condition     = length(trimspace(var.policy_id)) > 0
    error_message = "policy_id must not be blank. The provider refuses a rule without a policy id at apply time; refusing it here puts the reason in the plan."
  }
}

variable "rules" {
  description = <<-EOT
    Routing rules to manage on the identity provider discovery policy, keyed by a
    stable logical name (for example "workforce-to-entra"). The key becomes part
    of the Terraform resource address, so renaming a key moves the resource in
    state; a "moved" block carries it across without touching Okta.

    Renaming the rule is the expensive one, not the key: "name" is ForceNew on
    okta_policy_rule_idp_discovery, so changing it destroys the rule and
    creates a new one. Between the two, sign-ins this rule matched fall
    through to the policy's immutable default rule and land on Okta itself
    rather than the upstream identity provider. Rename in a change of its own,
    at a time when that is acceptable.

    Allowed value sets below are the provider's, from
    https://registry.terraform.io/providers/okta/okta/latest/docs/resources/policy_rule_idp_discovery,
    and the Policies API's, from the Okta management OpenAPI specification
    (IdpDiscoveryPolicyRuleCondition, UserIdentifierType, UserIdentifierMatchType,
    AppAndInstanceType, PolicyPlatformType, and
    IdpDiscoveryPolicyPlatformOperatingSystemType schemas) published at
    https://developer.okta.com/docs/api/openapi/okta-management/management/tag/Policy/.

    name                      : rule name shown in the admin console. 1 to 50
                                characters. Unique across the map.
    priority                  : evaluation order, 1 first. Required because a map
                                has no order. Unique across the map. The policy's
                                immutable default rule, which routes to Okta, is
                                always last.
    status                    : ACTIVE (default) or INACTIVE.
    user_identifier_type      : what the patterns are matched against:
                                IDENTIFIER (default, the username the person
                                typed) or ATTRIBUTE (one attribute of the Okta
                                profile that username resolves to).
    user_identifier_attribute : the profile attribute to match, for example
                                "company". Required for ATTRIBUTE, refused for
                                IDENTIFIER.
    patterns                  : at least one.
      match_type              : SUFFIX, EQUALS, CONTAINS, STARTS_WITH, or
                                EXPRESSION (a regular expression). The provider
                                documents that an EXPRESSION pattern must be the
                                rule's only pattern.
      value                   : the string or regular expression to match, for
                                example "example.com" with SUFFIX.
    idp_ids                   : identity provider ids the matched sign-in is
                                routed to, at least one and at most ten (the
                                API's limit per rule), all of type SAML2. Ids,
                                resolved by the calling stack from the
                                identity providers it manages.
    network_connection        : ANYWHERE (default), ZONE, ON_NETWORK, or
                                OFF_NETWORK. When ZONE, supply exactly one of
                                zone_ids_included and zone_ids_excluded; the
                                provider declares the two as conflicting.
    zone_ids_included         : network zone ids the rule applies from. Ids,
                                resolved by the calling stack from zone names.
                                Refused unless network_connection is ZONE.
    zone_ids_excluded         : network zone ids the rule does not apply from.
                                Same rules as zone_ids_included.
    app_include               : applications the rule applies to. Empty (default)
                                means every application.
      type                    : APP (one application, by id) or APP_TYPE (every
                                application of one type, by name).
      id                      : the application id. Required for APP, refused
                                for APP_TYPE. Resolved by the calling stack
                                from the application's label.
      name                    : the application type name, for example
                                "yahoo_mail". Required for APP_TYPE, refused
                                for APP.
    app_exclude               : applications the rule does not apply to, the
                                same shape as app_include. A rule that routes
                                workforce sign-ins to an upstream identity
                                provider excludes the Okta admin console here so
                                administrators keep a direct path in.
    platform_include          : platforms the rule applies to. Empty (default)
                                means every platform.
      type                    : ANY (default), DESKTOP, or MOBILE.
      os_type                 : ANY (default), IOS, WINDOWS, ANDROID, OSX,
                                CHROMEOS, or OTHER.
      os_expression           : a version expression. Only with os_type OTHER,
                                refused otherwise.

    Fixed and not inputs: the routing target type, SAML2.
  EOT

  type = map(object({
    name                      = string
    priority                  = number
    status                    = optional(string, "ACTIVE")
    user_identifier_type      = optional(string, "IDENTIFIER")
    user_identifier_attribute = optional(string)

    patterns = list(object({
      match_type = string
      value      = string
    }))

    idp_ids = list(string)

    network_connection = optional(string, "ANYWHERE")
    zone_ids_included  = optional(list(string), [])
    zone_ids_excluded  = optional(list(string), [])

    app_include = optional(list(object({
      type = string
      id   = optional(string)
      name = optional(string)
    })), [])

    app_exclude = optional(list(object({
      type = string
      id   = optional(string)
      name = optional(string)
    })), [])

    platform_include = optional(list(object({
      type          = optional(string, "ANY")
      os_type       = optional(string, "ANY")
      os_expression = optional(string)
    })), [])
  }))

  validation {
    condition     = alltrue([for r in var.rules : length(trimspace(r.name)) >= 1 && length(r.name) <= 50])
    error_message = "name must be 1 to 50 characters and not blank. Okta shows it on the routing rules screen and in the system log entry for every routed sign-in."
  }

  validation {
    condition     = length(distinct([for r in var.rules : r.name])) == length(var.rules)
    error_message = "name must be unique across rules. Two rules with one name are indistinguishable in the admin console and in the system log."
  }

  validation {
    condition     = alltrue([for r in var.rules : r.priority >= 1 && floor(r.priority) == r.priority])
    error_message = "priority must be a positive whole number. 1 is evaluated first."
  }

  validation {
    condition     = length(distinct([for r in var.rules : r.priority])) == length(var.rules)
    error_message = "priority must be unique across rules. A map has no order, so the priority is the order, and two rules with one priority would be ordered by whichever the API applied last."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ACTIVE", "INACTIVE"], r.status)])
    error_message = "status must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["IDENTIFIER", "ATTRIBUTE"], r.user_identifier_type)])
    error_message = "user_identifier_type must be IDENTIFIER or ATTRIBUTE."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      (r.user_identifier_type == "ATTRIBUTE") == (r.user_identifier_attribute != null && length(trimspace(coalesce(r.user_identifier_attribute, ""))) > 0)
    ])
    error_message = "user_identifier_attribute is required when user_identifier_type is ATTRIBUTE and refused when it is IDENTIFIER. The API reads it only for ATTRIBUTE; with IDENTIFIER it would be dropped silently, which hides a mistake in the cell."
  }

  validation {
    condition     = alltrue([for r in var.rules : length(r.patterns) > 0])
    error_message = "Every rule needs at least one pattern. A rule with no pattern matches nobody, which looks like a working route that nobody takes."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for p in r.patterns : contains(["SUFFIX", "EQUALS", "CONTAINS", "STARTS_WITH", "EXPRESSION"], p.match_type)]
    ]))
    error_message = "Every pattern's match_type must be SUFFIX, EQUALS, CONTAINS, STARTS_WITH, or EXPRESSION."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for p in r.patterns : length(trimspace(p.value)) > 0]
    ]))
    error_message = "Every pattern needs a non-blank value. An empty SUFFIX or CONTAINS matches every username, which routes the whole org."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      length([for p in r.patterns : p if p.match_type == "EXPRESSION"]) == 0 || length(r.patterns) == 1
    ])
    error_message = "A rule with an EXPRESSION pattern carries that one pattern and no other. The provider documents that a regular expression must be the rule's only pattern."
  }

  validation {
    condition     = alltrue([for r in var.rules : length(r.idp_ids) >= 1 && length(r.idp_ids) <= 10])
    error_message = "Every rule needs 1 to 10 idp_ids. A rule with none would route to Okta itself, which the policy's default rule already does; ten is the API's limit of providers per rule."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      alltrue([for i in r.idp_ids : length(trimspace(i)) > 0]) && length(distinct(r.idp_ids)) == length(r.idp_ids)
    ])
    error_message = "idp_ids entries must be non-blank and not repeated. The calling stack resolves identity provider keys to ids; a blank means a lookup that produced nothing."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ANYWHERE", "ZONE", "ON_NETWORK", "OFF_NETWORK"], r.network_connection)])
    error_message = "network_connection must be ANYWHERE, ZONE, ON_NETWORK, or OFF_NETWORK."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.network_connection == "ZONE" || (length(r.zone_ids_included) == 0 && length(r.zone_ids_excluded) == 0)
    ])
    error_message = "zone_ids_included and zone_ids_excluded are only read when network_connection is ZONE. With any other connection they would be dropped silently, which hides a mistake in the cell."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.network_connection != "ZONE" || (length(r.zone_ids_included) > 0) != (length(r.zone_ids_excluded) > 0)
    ])
    error_message = "A rule with network_connection = ZONE must list exactly one of zone_ids_included and zone_ids_excluded, with at least one zone id in it. The provider declares the two lists as conflicting, and a ZONE rule with neither applies from nowhere."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for z in concat(r.zone_ids_included, r.zone_ids_excluded) : length(trimspace(z)) > 0]
    ]))
    error_message = "Zone id lists must not hold a blank entry. The calling stack resolves zone names to ids; a blank means a lookup that produced nothing."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for a in concat(r.app_include, r.app_exclude) : contains(["APP", "APP_TYPE"], a.type)]
    ]))
    error_message = "Every app_include and app_exclude entry's type must be APP or APP_TYPE."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [
        for a in concat(r.app_include, r.app_exclude) :
        a.type != "APP" || (a.id != null && length(trimspace(coalesce(a.id, ""))) > 0 && a.name == null)
      ]
    ]))
    error_message = "An APP entry carries a non-blank id and no name. The id is resolved by the calling stack from the application's label; a name on an APP entry would be dropped silently."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [
        for a in concat(r.app_include, r.app_exclude) :
        a.type != "APP_TYPE" || (a.name != null && length(trimspace(coalesce(a.name, ""))) > 0 && a.id == null)
      ]
    ]))
    error_message = "An APP_TYPE entry carries a non-blank name and no id. An id on an APP_TYPE entry would be dropped silently."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      length(distinct([for a in r.app_include : "${a.type}/${try(coalesce(a.id, a.name), "")}"])) == length(r.app_include)
      && length(distinct([for a in r.app_exclude : "${a.type}/${try(coalesce(a.id, a.name), "")}"])) == length(r.app_exclude)
    ])
    error_message = "app_include and app_exclude must not repeat an application or type; Okta holds each as a set."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for p in r.platform_include : contains(["ANY", "DESKTOP", "MOBILE"], p.type)]
    ]))
    error_message = "Every platform_include entry's type must be ANY, DESKTOP, or MOBILE."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for p in r.platform_include : contains(["ANY", "IOS", "WINDOWS", "ANDROID", "OSX", "CHROMEOS", "OTHER"], p.os_type)]
    ]))
    error_message = "Every platform_include entry's os_type must be ANY, IOS, WINDOWS, ANDROID, OSX, CHROMEOS, or OTHER."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for p in r.platform_include : (p.os_type == "OTHER") == (p.os_expression != null && length(trimspace(coalesce(p.os_expression, ""))) > 0)]
    ]))
    error_message = "platform_include.os_expression is required when os_type is OTHER and refused otherwise. The provider documents it as available only with OTHER; anywhere else it would be dropped silently."
  }
}
