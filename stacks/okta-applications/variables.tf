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
# App sign-on policies. Same shape as modules/okta/app-signon-policy. Apps
# name a policy by this map's key (saml_apps.<k>.signon_policy,
# oauth_apps.<k>.signon_policy), never by id. Zones and groups inside a rule
# are NAMES; the module looks them up.
# ---------------------------------------------------------------------------

variable "signon_policies" {
  description = "App sign-on policies keyed by logical name, each with its rules. See modules/okta/app-signon-policy for attribute semantics, defaults, and what is refused. An app names one of these by key; the stack resolves the id."
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
  default = {}
}

# ---------------------------------------------------------------------------
# SAML apps. Same shape as modules/okta/app-saml, minus authentication_policy_id
# (an id, which a cell never writes) and plus signon_policy, the KEY of an entry
# in signon_policies that this stack resolves to that id.
# ---------------------------------------------------------------------------

variable "saml_apps" {
  description = <<-EOT
    Custom SAML 2.0 apps keyed by logical name. See modules/okta/app-saml for
    every attribute except signon_policy, which is this stack's addition:

    signon_policy : the KEY of an entry in signon_policies. The app is bound to
                    that policy and the stack supplies the module with its id.
                    Unset leaves the app on the org's default app sign-on policy,
                    which is refused when tier is admin.

    tier = "admin" requires signon_policy to name a policy whose ALLOW rules all
    require a phishing-resistant possession factor. Labels are unique across
    saml_apps and oauth_apps together. group_names are group NAMES the module
    looks up; a missing group fails the plan.
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

    hide_ios      = optional(bool, false)
    hide_web      = optional(bool, false)
    status        = optional(string, "ACTIVE")
    signon_policy = optional(string)
    tier          = optional(string, "standard")

    group_names                 = optional(list(string), [])
    group_assignment_priorities = optional(map(number), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for a in var.saml_apps : a.signon_policy == null || contains(keys(var.signon_policies), coalesce(a.signon_policy, "-"))])
    error_message = "A SAML app's signon_policy is not the key of an entry in this cell's signon_policies. Add the policy to signon-policies.hcl, or leave signon_policy unset for the org default policy on a standard-tier app."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : a.tier != "admin" || a.signon_policy != null])
    error_message = "A SAML app with tier = \"admin\" must name a signon_policy. Unset means the org's default app sign-on policy, which is the permissive one, and an admin console is exactly the app that must not fall through to it."
  }

  validation {
    condition     = length(distinct([for a in var.saml_apps : a.label])) == length(var.saml_apps)
    error_message = "Two SAML apps in this cell share a label. Okta allows it; the person clicking a tile and the reviewer reading an audit event cannot tell them apart."
  }
}

# ---------------------------------------------------------------------------
# OIDC apps. Same shape as modules/okta/app-oauth, minus authentication_policy_id
# and plus signon_policy, as for the SAML apps. Everything OAuth-shaped is
# derived from type inside the module and has no input here.
# ---------------------------------------------------------------------------

variable "oauth_apps" {
  description = <<-EOT
    OIDC apps keyed by logical name. See modules/okta/app-oauth for every
    attribute except signon_policy, which is this stack's addition:

    signon_policy : the KEY of an entry in signon_policies. The app is bound to
                    that policy and the stack supplies the module with its id.
                    Unset leaves the app on the org's default app sign-on policy,
                    which is refused when tier is admin. A service app normally
                    leaves it unset: client credentials has no user sign-in for
                    the policy to evaluate.

    tier = "admin" requires signon_policy to name a policy whose ALLOW rules all
    require a phishing-resistant possession factor. Labels are unique across
    saml_apps and oauth_apps together. group_names are group NAMES the module
    looks up; a missing group fails the plan.
  EOT

  type = map(object({
    label                     = string
    type                      = string
    redirect_uris             = optional(list(string), [])
    post_logout_redirect_uris = optional(list(string), [])
    jwks_uri                  = optional(string)
    allow_client_secret       = optional(bool, false)
    allow_localhost_redirects = optional(bool, false)
    extra_grant_types         = optional(list(string), [])
    groups_claim = optional(object({
      name        = string
      filter_type = string
      value       = string
    }))
    consent_method = optional(string, "TRUSTED")
    login_mode     = optional(string, "DISABLED")
    login_uri      = optional(string)
    client_uri     = optional(string)
    logo_uri       = optional(string)
    policy_uri     = optional(string)
    tos_uri        = optional(string)
    hide_ios       = optional(bool, false)
    hide_web       = optional(bool, false)
    status         = optional(string, "ACTIVE")
    signon_policy  = optional(string)
    tier           = optional(string, "standard")

    group_names                 = optional(list(string), [])
    group_assignment_priorities = optional(map(number), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for a in var.oauth_apps : a.signon_policy == null || contains(keys(var.signon_policies), coalesce(a.signon_policy, "-"))])
    error_message = "An OIDC app's signon_policy is not the key of an entry in this cell's signon_policies. Add the policy to signon-policies.hcl, or leave signon_policy unset for the org default policy on a standard-tier app."
  }

  validation {
    condition     = alltrue([for a in var.oauth_apps : a.tier != "admin" || a.signon_policy != null])
    error_message = "An OIDC app with tier = \"admin\" must name a signon_policy. Unset means the org's default app sign-on policy, which is the permissive one, and an admin app is exactly the app that must not fall through to it."
  }

  validation {
    condition     = length(distinct([for a in var.oauth_apps : a.label])) == length(var.oauth_apps)
    error_message = "Two OIDC apps in this cell share a label. Okta allows it; the person clicking a tile and the reviewer reading an audit event cannot tell them apart."
  }

  validation {
    condition     = length(setintersection(toset([for a in var.oauth_apps : a.label]), toset([for a in var.saml_apps : a.label]))) == 0
    error_message = "A label appears in both saml_apps and oauth_apps. One application is onboarded over one protocol; two tiles with one name is a trap for the person clicking and for the reviewer reading the audit log."
  }
}
