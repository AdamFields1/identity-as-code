variable "apps" {
  description = <<-EOT
    Custom SAML 2.0 applications to manage, keyed by a stable logical name (for
    example "payroll"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the visible name with
    "label".

    label                    : name shown in the admin console and the end-user
                               dashboard. 1 to 100 characters. Unique per org.
    sso_url                  : the service provider's assertion consumer service
                               URL. https only, a host, no wildcard.
    audience                 : the service provider's entity id, the audience
                               restriction in the assertion. https only.
    recipient                : where the assertion may be presented. Defaults to
                               sso_url.
    destination              : the Destination attribute of the response.
                               Defaults to sso_url.
    subject_name_id_template : Okta expression for the NameID. Default is the
                               user's Okta username, written escaped as
                               "$${user.userName}" so Terraform passes it through.
    subject_name_id_format   : one of the four allowed NameID formats:
                               urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified
                               (default), ...:emailAddress, ...:persistent, or
                               ...:transient.
    attribute_statements     : attributes carried in the assertion, in order.
      name                   : attribute name as the service provider expects it.
                               Unique within the app.
      type                   : EXPRESSION (values are Okta expressions) or GROUP
                               (the user's group names, filtered).
      namespace              : attribute name format. basic (default), uri, or
                               unspecified.
      values                 : list of Okta expressions. Required for EXPRESSION,
                               refused for GROUP.
      filter_type            : STARTS_WITH, EQUALS, CONTAINS, or REGEX. Required
                               for GROUP, refused for EXPRESSION.
      filter_value           : the filter operand. Required for GROUP, refused
                               for EXPRESSION.
    single_logout            : optional. url (https, the SP's logout endpoint),
                               issuer (the SP's issuer), and certificate (the
                               SP's signing certificate, base64 body only, no
                               BEGIN and END lines).
    hide_ios / hide_web      : hide the app tile on the mobile app or the web
                               dashboard. Default false.
    status                   : ACTIVE (default) or INACTIVE.
    authentication_policy_id : id of the app sign-on policy, resolved by the
                               calling stack from a policy key. Null leaves the
                               app on the org default policy.
    tier                     : standard (default) or admin. Carried through to the
                               calling stack, which requires an admin app to bind
                               a policy whose ALLOW rules are all phishing
                               resistant. The module itself does not act on it.
    group_names              : Okta group NAMES assigned to the app. Resolved by
                               lookup; a missing group fails the plan.
    group_assignment_priorities : optional map of group name to assignment
                               priority. Every key must also appear in
                               group_names.

    Fixed and not inputs: SAML 2.0, response and assertion signed, RSA_SHA256
    signature, SHA256 digest, PasswordProtectedTransport authentication context,
    honor_force_authn true, accessibility_self_service false, the provider's
    default username template, and no inline hook.
  EOT

  type = map(object({
    label                    = string
    sso_url                  = string
    audience                 = string
    recipient                = optional(string)
    destination              = optional(string)
    subject_name_id_template = optional(string, "$${user.userName}")
    subject_name_id_format   = optional(string, "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified")

    attribute_statements = optional(list(object({
      name         = string
      type         = string
      namespace    = optional(string, "urn:oasis:names:tc:SAML:2.0:attrname-format:basic")
      values       = optional(list(string), [])
      filter_type  = optional(string)
      filter_value = optional(string)
    })), [])

    single_logout = optional(object({
      url         = string
      issuer      = string
      certificate = string
    }))

    hide_ios                 = optional(bool, false)
    hide_web                 = optional(bool, false)
    status                   = optional(string, "ACTIVE")
    authentication_policy_id = optional(string)
    tier                     = optional(string, "standard")

    group_names                 = optional(list(string), [])
    group_assignment_priorities = optional(map(number), {})
  }))

  validation {
    condition     = alltrue([for a in var.apps : length(trimspace(a.label)) >= 1 && length(a.label) <= 100])
    error_message = "label must be 1 to 100 characters and not blank. Okta shows it on the dashboard tile and in every audit event for the app."
  }

  validation {
    condition     = length(distinct([for a in var.apps : a.label])) == length(var.apps)
    error_message = "label must be unique across apps. Two apps with one label are indistinguishable in the admin console, in audit events, and to the person clicking a tile."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for u in compact([a.sso_url, a.audience, a.recipient, a.destination]) :
        can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", u))
      ]
    ]))
    error_message = "sso_url, audience, recipient, and destination must be https URLs with a host and no wildcard, for example https://payroll.example.com/saml/acs. http is refused because the assertion would travel in clear; a wildcard is refused because the ACS URL is where Okta posts a signed assertion about a user, and a pattern there is an open redirect for identities."
  }

  validation {
    condition     = alltrue([for a in var.apps : length(trimspace(a.subject_name_id_template)) > 0])
    error_message = "subject_name_id_template must not be blank. The default, written escaped as \"$${user.userName}\", is the user's Okta username."
  }

  validation {
    condition = alltrue([
      for a in var.apps : contains([
        "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
        "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
        "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
        "urn:oasis:names:tc:SAML:2.0:nameid-format:transient",
      ], a.subject_name_id_format)
    ])
    error_message = "subject_name_id_format must be one of urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified, urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress, urn:oasis:names:tc:SAML:2.0:nameid-format:persistent, or urn:oasis:names:tc:SAML:2.0:nameid-format:transient. The allowlist is the catalog: a format that is not on it needs a review of its own."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [for s in a.attribute_statements : length(trimspace(s.name)) > 0]
    ]))
    error_message = "Every attribute statement needs a non-blank name; the service provider matches attributes by it."
  }

  validation {
    condition = alltrue([
      for a in var.apps : length(distinct([for s in a.attribute_statements : s.name])) == length(a.attribute_statements)
    ])
    error_message = "Attribute statement names must be unique within an app. Two statements with one name produce an assertion whose meaning depends on which one the service provider reads last."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [for s in a.attribute_statements : contains(["EXPRESSION", "GROUP"], s.type)]
    ]))
    error_message = "Attribute statement type must be EXPRESSION or GROUP."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for s in a.attribute_statements : contains([
          "urn:oasis:names:tc:SAML:2.0:attrname-format:basic",
          "urn:oasis:names:tc:SAML:2.0:attrname-format:uri",
          "urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified",
        ], s.namespace)
      ]
    ]))
    error_message = "Attribute statement namespace must be urn:oasis:names:tc:SAML:2.0:attrname-format:basic, ...:uri, or ...:unspecified."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for s in a.attribute_statements : s.type != "EXPRESSION" || length(s.values) > 0
      ]
    ]))
    error_message = "An EXPRESSION attribute statement must carry at least one value. A statement with no values is an attribute the service provider receives empty, which is a silent misconfiguration."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for s in a.attribute_statements : s.type != "GROUP" || (
          contains(["STARTS_WITH", "EQUALS", "CONTAINS", "REGEX"], coalesce(s.filter_type, "unset")) && length(trimspace(coalesce(s.filter_value, ""))) > 0
        )
      ]
    ]))
    error_message = "A GROUP attribute statement must set filter_type (STARTS_WITH, EQUALS, CONTAINS, or REGEX) and a non-blank filter_value. An unfiltered group statement sends every group the user is in to the service provider, which is a data leak from the directory to the vendor."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for s in a.attribute_statements :
        (s.type == "GROUP" && length(s.values) == 0) || (s.type == "EXPRESSION" && s.filter_type == null && s.filter_value == null) || !contains(["EXPRESSION", "GROUP"], s.type)
      ]
    ]))
    error_message = "An attribute statement carries only the fields of its type: values for EXPRESSION, filter_type and filter_value for GROUP. The other fields would be dropped silently, which hides a mistake in the cell."
  }

  validation {
    condition = alltrue([
      for a in var.apps : a.single_logout == null || can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", a.single_logout.url))
    ])
    error_message = "single_logout.url must be an https URL with a host and no wildcard. The logout response carries a signed statement about the session and travels to this address."
  }

  validation {
    condition = alltrue([
      for a in var.apps : a.single_logout == null || (
        length(trimspace(a.single_logout.issuer)) > 0 && length(trimspace(a.single_logout.certificate)) > 0 && !strcontains(a.single_logout.certificate, "-----")
      )
    ])
    error_message = "single_logout needs a non-blank issuer and the service provider's signing certificate as its base64 body only, without the BEGIN CERTIFICATE and END CERTIFICATE lines. Okta rejects the armored form at apply time; refusing it here puts the reason in the plan."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["ACTIVE", "INACTIVE"], a.status)])
    error_message = "status must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["standard", "admin"], a.tier)])
    error_message = "tier must be standard or admin. The calling stack uses admin to require a phishing-resistant sign-on policy."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [for g in a.group_names : length(trimspace(g)) > 0]
    ]))
    error_message = "group_names entries must be non-blank group names."
  }

  validation {
    condition     = alltrue([for a in var.apps : length(distinct(a.group_names)) == length(a.group_names)])
    error_message = "group_names must not repeat a name within an app; the assignment set holds each group once."
  }

  validation {
    condition = alltrue([
      for a in var.apps : length(setsubtract(keys(a.group_assignment_priorities), a.group_names)) == 0
    ])
    error_message = "Every key of group_assignment_priorities must also appear in group_names. A priority for a group that is not assigned does nothing, and silently doing nothing hides a typo."
  }
}
