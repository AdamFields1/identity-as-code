variable "apps" {
  description = <<-EOT
    OIDC applications to manage, keyed by a stable logical name (for example
    "orders-portal"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the visible name with
    "label".

    label                     : display name in the Okta admin console and end
                                user dashboard. Unique across the map.
    type                      : web, browser, native, or service. Everything
                                OAuth-shaped is derived from it (see the table in
                                main.tf and the README) and cannot be overridden.
    redirect_uris             : sign-in redirect URIs. Required on web, browser,
                                and native; refused on service. https only, no
                                wildcard.
    post_logout_redirect_uris : optional sign-out redirect URIs, same rules.
    jwks_uri                  : https URL of the client's JSON Web Key Set.
                                Required on web and service unless
                                allow_client_secret is true, because those types
                                authenticate to the token endpoint with
                                private_key_jwt by default.
    allow_client_secret       : web and service only. Switches the token endpoint
                                authentication method to client_secret_basic.
                                The secret is never written to state either way;
                                the app owner reads it once from the console.
    allow_localhost_redirects : permits http://localhost:<port>/... redirect and
                                post-logout URIs for local development. A
                                dev-org knob; prod cells never set it.
    extra_grant_types         : native only. The one allowed value is
                                urn:ietf:params:oauth:grant-type:device_code, for
                                devices without a browser. implicit and hybrid
                                have no spelling here.
    groups_claim              : optional groups claim on the ID token, always a
                                FILTER claim on group names: name (the claim
                                name), filter_type (STARTS_WITH, EQUALS,
                                CONTAINS, or REGEX), value. Refused on service,
                                which has no user.
    consent_method            : TRUSTED (no consent screen, the default for
                                first-party apps) or REQUIRED.
    login_mode                : DISABLED (default), SPEC, or OKTA. SPEC and OKTA
                                need login_uri.
    login_uri                 : https URI that initiates login when login_mode
                                is not DISABLED.
    client_uri, logo_uri,
    policy_uri, tos_uri       : optional https URIs shown to end users. logo_uri
                                is ignored after creation (see main.tf).
    hide_ios, hide_web        : hide the app icon on mobile or the web dashboard.
    status                    : ACTIVE or INACTIVE.
    authentication_policy_id  : ID of the app sign-on policy. The calling stack
                                resolves a policy key to this ID; a cell never
                                writes one.
    tier                      : standard (default) or admin. The module does not
                                act on it; the calling stack uses it to require
                                a phishing-resistant policy on admin apps.
    group_names               : Okta group NAMES assigned to the app. Looked up
                                with the okta_group data source, so a group that
                                does not exist fails the plan with its name in
                                the error.
    group_assignment_priorities : optional map of group name to assignment
                                priority. Keys must appear in group_names.
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
    consent_method              = optional(string, "TRUSTED")
    login_mode                  = optional(string, "DISABLED")
    login_uri                   = optional(string)
    client_uri                  = optional(string)
    logo_uri                    = optional(string)
    policy_uri                  = optional(string)
    tos_uri                     = optional(string)
    hide_ios                    = optional(bool, false)
    hide_web                    = optional(bool, false)
    status                      = optional(string, "ACTIVE")
    authentication_policy_id    = optional(string)
    tier                        = optional(string, "standard")
    group_names                 = optional(list(string), [])
    group_assignment_priorities = optional(map(number), {})
  }))

  validation {
    condition     = alltrue([for a in var.apps : contains(["web", "browser", "native", "service"], a.type)])
    error_message = "type must be web, browser, native, or service. The type is the catalog entry: every OAuth setting is derived from it, so a type that is not on the list needs a review of its own, not a free-text value."
  }

  validation {
    condition     = alltrue([for a in var.apps : length(trimspace(a.label)) > 0])
    error_message = "label must not be empty."
  }

  validation {
    condition     = length(distinct([for a in var.apps : a.label])) == length(var.apps)
    error_message = "label must be unique across the map. Okta allows two apps with one label, and an engineer reading the console or an import block cannot tell them apart."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["ACTIVE", "INACTIVE"], a.status)])
    error_message = "status must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["TRUSTED", "REQUIRED"], a.consent_method)])
    error_message = "consent_method must be TRUSTED or REQUIRED."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["DISABLED", "SPEC", "OKTA"], a.login_mode)])
    error_message = "login_mode must be DISABLED, SPEC, or OKTA."
  }

  validation {
    condition     = alltrue([for a in var.apps : a.login_mode == "DISABLED" || a.login_uri != null])
    error_message = "login_uri is required when login_mode is SPEC or OKTA. IdP-initiated login has to know where to send the user."
  }

  validation {
    condition     = alltrue([for a in var.apps : contains(["standard", "admin"], a.tier)])
    error_message = "tier must be standard or admin."
  }

  validation {
    condition = alltrue([
      for a in var.apps : !contains(["web", "service"], a.type) || a.allow_client_secret || a.jwks_uri != null
    ])
    error_message = "A web or service app must supply jwks_uri. Those types authenticate to the token endpoint with private_key_jwt, which needs the client's public keys and never a shared secret. Set allow_client_secret = true only when the client cannot hold a key pair, so the word secret is in the diff."
  }

  validation {
    condition     = alltrue([for a in var.apps : !contains(["browser", "native"], a.type) || !a.allow_client_secret])
    error_message = "allow_client_secret is refused on browser and native apps. A public client cannot keep a secret; anyone with the bundle has it. Those types use PKCE with token_endpoint_auth_method none."
  }

  validation {
    condition = alltrue([
      for a in var.apps : a.type != "service" || (length(a.redirect_uris) == 0 && length(a.post_logout_redirect_uris) == 0)
    ])
    error_message = "redirect_uris and post_logout_redirect_uris are refused on a service app. Client credentials has no browser and no redirect, so a URI here is either a copy-paste mistake or an attempt to turn a service client into a user-facing one."
  }

  validation {
    condition     = alltrue([for a in var.apps : a.type == "service" || length(a.redirect_uris) > 0])
    error_message = "A web, browser, or native app must list at least one redirect_uri. The authorization code flow has nowhere to send the code without one."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for u in concat(a.redirect_uris, a.post_logout_redirect_uris) :
        can(regex("^https://[^*\\s]+$", u)) || (a.allow_localhost_redirects && can(regex("^http://localhost:[0-9]{1,5}(/[^*\\s]*)?$", u)))
      ]
    ]))
    error_message = "Every redirect and post-logout URI must be https:// with no wildcard. The only exception is http://localhost:<port>/... when the app sets allow_localhost_redirects = true, which is a dev-org knob. An http URI anywhere else sends the authorization code in the clear, and a * would be a redirect the module cannot reason about; wildcard_redirect is DISABLED on every app regardless."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for u in [a.jwks_uri, a.login_uri, a.client_uri, a.logo_uri, a.policy_uri, a.tos_uri] :
        u == null || can(regex("^https://[^*\\s]+$", coalesce(u, "x")))
      ]
    ]))
    error_message = "jwks_uri, login_uri, client_uri, logo_uri, policy_uri, and tos_uri must be https:// with no wildcard when set. The JWKS URI in particular is where the token endpoint fetches the keys it trusts, so it is never fetched over http."
  }

  validation {
    condition     = alltrue([for a in var.apps : a.type != "service" || a.groups_claim == null])
    error_message = "groups_claim is refused on a service app. Client credentials mints a token for the client itself, with no user and so no groups to claim."
  }

  validation {
    condition = alltrue([
      for a in var.apps : a.groups_claim == null || contains(["STARTS_WITH", "EQUALS", "CONTAINS", "REGEX"], try(a.groups_claim.filter_type, ""))
    ])
    error_message = "groups_claim.filter_type must be STARTS_WITH, EQUALS, CONTAINS, or REGEX."
  }

  validation {
    condition = alltrue([
      for a in var.apps : a.groups_claim == null || (length(trimspace(try(a.groups_claim.name, ""))) > 0 && length(trimspace(try(a.groups_claim.value, ""))) > 0)
    ])
    error_message = "groups_claim.name and groups_claim.value must not be empty. An empty filter value would put every group the user belongs to in the token."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [
        for g in a.extra_grant_types : a.type == "native" && g == "urn:ietf:params:oauth:grant-type:device_code"
      ]
    ]))
    error_message = "extra_grant_types accepts only urn:ietf:params:oauth:grant-type:device_code, and only on a native app. Every other grant is fixed by the type: authorization_code and refresh_token on web, browser, and native; client_credentials on service. implicit and hybrid have no spelling in this module, because response_types is code only on the redirect-based types and a token or id_token response cannot be requested. password is refused because it hands the client the user's credentials."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [for g in a.group_names : length(trimspace(g)) > 0]
    ]))
    error_message = "group_names entries must not be empty."
  }

  validation {
    condition     = alltrue([for a in var.apps : length(distinct(a.group_names)) == length(a.group_names)])
    error_message = "group_names must not repeat a name within one app."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.apps : [for g in keys(a.group_assignment_priorities) : contains(a.group_names, g)]
    ]))
    error_message = "Every key of group_assignment_priorities must also appear in group_names. A priority for a group that is not assigned is a typo the plan would otherwise hide."
  }
}
