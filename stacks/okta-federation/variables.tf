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
# Identity providers. Same shape as modules/okta/idp-saml, except that the
# three group lists (provisioning.groups_filter, provisioning.groups_assignment,
# account_link.group_include) are group NAMES that this stack resolves to the
# ids the module takes. Routing rules name an identity provider by this map's
# key (routing_rules.<k>.idps), never by id.
# ---------------------------------------------------------------------------

variable "identity_providers" {
  description = <<-EOT
    Upstream SAML 2.0 identity providers keyed by logical name (for example
    "entra"). See modules/okta/idp-saml for every attribute, its default, and
    what is refused, except the three group lists, which are this stack's
    translation:

    provisioning.groups_filter     : group NAMES the SYNC or APPEND action may
                                     touch. The module takes ids.
    provisioning.groups_assignment : group NAMES every asserted user is added
                                     to under ASSIGN. The module takes ids.
    account_link.group_include     : group NAMES; when set, only existing users
                                     in one of them may be linked. The module
                                     takes ids.

    The stack looks each distinct name up once with data.okta_group and hands
    the module the id; a name that does not exist fails the plan with the name
    in the error. The groups are created by the upstream identity provider,
    not here.

    issuer is the string the identity provider puts in <Issuer>. Entra
    publishes https://sts.windows.net/<tenant id>/, which has no name form, so
    a cell federating to Entra carries the placeholder tenant id there; it is
    the other side's identifier, not an Okta object id.

    signing_certificates values are PEM text. A cell passes
    file("<get_terragrunt_dir()>/entra-signing-<year>.cer") so the certificate
    is read from the file beside the cell, and active_certificate names the
    entry Okta trusts now.
  EOT

  type = map(object({
    name                     = string
    status                   = optional(string, "ACTIVE")
    issuer                   = string
    issuer_mode              = optional(string, "ORG_URL")
    sso_url                  = string
    sso_binding              = optional(string, "HTTP-POST")
    sso_destination          = optional(string)
    acs_type                 = optional(string, "INSTANCE")
    signing_certificates     = map(string)
    active_certificate       = string
    response_signature_scope = optional(string, "ANY")
    max_clock_skew           = optional(number, 120000)
    honor_persistent_name_id = optional(bool, true)

    subject = optional(object({
      match_type        = optional(string, "USERNAME")
      match_attribute   = optional(string)
      format            = optional(list(string), ["urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"])
      filter            = optional(string)
      username_template = optional(string, "idpuser.subjectNameId")
    }), {})

    provisioning = optional(object({
      action               = optional(string, "DISABLED")
      deprovisioned_action = optional(string, "NONE")
      suspended_action     = optional(string, "NONE")
      profile_master       = optional(bool, false)
      groups_action        = optional(string, "NONE")
      groups_attribute     = optional(string)
      groups_filter        = optional(list(string), [])
      groups_assignment    = optional(list(string), [])
    }), {})

    account_link = optional(object({
      action        = optional(string, "AUTO")
      group_include = optional(list(string), [])
    }), {})
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for p in var.identity_providers : [
        for g in concat(p.provisioning.groups_filter, p.provisioning.groups_assignment, p.account_link.group_include) : length(trimspace(g)) > 0
      ]
    ]))
    error_message = "A group list of an identity provider (provisioning.groups_filter, provisioning.groups_assignment, account_link.group_include) holds a blank name. Groups are named here and looked up by the stack; a blank name is a lookup that can only fail."
  }

  validation {
    condition = alltrue([
      for p in var.identity_providers :
      length(distinct(p.provisioning.groups_filter)) == length(p.provisioning.groups_filter)
      && length(distinct(p.provisioning.groups_assignment)) == length(p.provisioning.groups_assignment)
      && length(distinct(p.account_link.group_include)) == length(p.account_link.group_include)
    ])
    error_message = "A group list of an identity provider names the same group twice. Okta holds each list as a set, and the stack looks a name up once; say it once."
  }

  validation {
    condition     = length(distinct([for p in var.identity_providers : p.name])) == length(var.identity_providers)
    error_message = "Two identity providers in this cell share a display name. Okta allows it; the person choosing a trust on the routing rules screen and the reviewer reading a system log event cannot tell them apart."
  }
}

# ---------------------------------------------------------------------------
# Routing rules. Same shape as modules/okta/idp-routing-rules, minus policy_id
# (an id the stack looks up), with idps (KEYS of identity_providers) in place
# of idp_ids, zone NAMES in place of zone ids, and an application LABEL on an
# APP entry in place of its id.
# ---------------------------------------------------------------------------

variable "routing_rules" {
  description = <<-EOT
    Routing rules on the org's identity provider discovery policy, keyed by
    logical name. See modules/okta/idp-routing-rules for every attribute, its
    default, and what is refused, except the four this stack translates:

    idps            : KEYS of entries in identity_providers, at least one. The
                      rule routes matched sign-ins to those trusts and the
                      stack supplies the module with their ids, in the order
                      given.
    zones_included  : network zone NAMES the rule applies from, as the org's
                      okta-config cell names them. Only with
                      network_connection = "ZONE"; the module takes ids.
    zones_excluded  : network zone NAMES the rule does not apply from. Same
                      rules as zones_included; a ZONE rule sets exactly one
                      of the two lists.
    app_include,
    app_exclude     : applications the rule applies to or not. An APP entry
                      carries the application's label (for example
                      "Okta Admin Console") and the stack resolves its id
                      with data.okta_app; an APP_TYPE entry carries the type
                      name. The field that does not belong to the entry's
                      type is refused rather than dropped.

    Priorities are unique across the map: a map has no order, so the priority
    is the order. A rule that routes workforce sign-ins to an upstream identity
    provider excludes the Okta Admin Console in prod so administrators keep a
    direct path into Okta with the factors okta-config enrolls.
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

    idps = list(string)

    network_connection = optional(string, "ANYWHERE")
    zones_included     = optional(list(string), [])
    zones_excluded     = optional(list(string), [])

    app_include = optional(list(object({
      type  = string
      label = optional(string)
      name  = optional(string)
    })), [])

    app_exclude = optional(list(object({
      type  = string
      label = optional(string)
      name  = optional(string)
    })), [])

    platform_include = optional(list(object({
      type          = optional(string, "ANY")
      os_type       = optional(string, "ANY")
      os_expression = optional(string)
    })), [])
  }))
  default = {}

  validation {
    condition     = alltrue(flatten([for r in var.routing_rules : [for idp in r.idps : contains(keys(var.identity_providers), idp)]]))
    error_message = "A routing rule's idps entry is not the key of an entry in this cell's identity_providers. Add the identity provider to identity-providers.hcl, or name one that is there; a rule that routes to a trust this cell does not manage would be an id typed from a console screen."
  }

  validation {
    condition = alltrue([
      for r in var.routing_rules :
      length(r.idps) >= 1 && alltrue([for idp in r.idps : length(trimspace(idp)) > 0]) && length(distinct(r.idps)) == length(r.idps)
    ])
    error_message = "Every routing rule names at least one identity provider key, none blank and none twice. A rule with no target would route to Okta itself, which the policy's default rule already does."
  }

  validation {
    condition     = length(distinct([for r in var.routing_rules : r.priority])) == length(var.routing_rules)
    error_message = "Two routing rules in this cell share a priority. A map has no order, so the priority is the order, and two rules with one priority would be ordered by whichever the API applied last."
  }

  validation {
    condition = alltrue([
      for r in var.routing_rules :
      r.network_connection == "ZONE" || (length(r.zones_included) == 0 && length(r.zones_excluded) == 0)
    ])
    error_message = "zones_included and zones_excluded are only read when network_connection is ZONE. With any other connection they would be dropped silently, and the stack would still look the names up, so a mistake in the cell would fail on the wrong line."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.routing_rules : [for z in concat(r.zones_included, r.zones_excluded) : length(trimspace(z)) > 0]
    ]))
    error_message = "A zone list of a routing rule holds a blank name. Zones are named here, as the org's okta-config cell names them, and looked up by the stack; a blank name is a lookup that can only fail."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.routing_rules : [
        for a in concat(r.app_include, r.app_exclude) :
        contains(["APP", "APP_TYPE"], a.type)
        && (a.type != "APP" || (a.label != null && length(trimspace(coalesce(a.label, ""))) > 0 && a.name == null))
        && (a.type != "APP_TYPE" || (a.name != null && length(trimspace(coalesce(a.name, ""))) > 0 && a.label == null))
      ]
    ]))
    error_message = "Every app_include and app_exclude entry is type APP with a non-blank label and no name, or type APP_TYPE with a non-blank name and no label. The label is what the stack resolves to the application's id; a name on an APP entry or a label on an APP_TYPE entry would be dropped silently."
  }
}
