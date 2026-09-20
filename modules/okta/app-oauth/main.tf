# OIDC applications as catalog shapes.
#
# A cell says what an application is (web, browser, native, or service), where
# it redirects, which sign-on policy protects it, and which groups may use it.
# Everything the OAuth 2.0 security best current practice cares about is derived
# from the type by the table below and is not an input: grant and response
# types, PKCE, the token endpoint authentication method, refresh token rotation,
# redirect matching, and key rotation. A cell that needs a different shape
# needs a different type, not a knob.
#
# omit_secret is fixed true on every app. With it false, the provider writes the
# client secret into state in plain text and re-sends it on every update. With
# it true, Okta mints the secret once and the app owner reads it once from the
# console, and Terraform never holds it. That is why client_secret_basic has to
# be opted into with allow_client_secret, and why the private_key_jwt default
# asks the cell for a jwks_uri instead of a secret.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing an app in the middle of the map never re-addresses its neighbours.

locals {
  # The type table. Every attribute here is fixed by type and the cell cannot
  # override any of them. response_types is code only for the redirect-based
  # types, so the implicit and hybrid flows (token or id_token in the response)
  # cannot be requested. The token response type on a service app is what the
  # Okta app API pairs with client_credentials: the provider itself appends
  # token to response_types whenever that grant is present and sets no other
  # default for it. It is not the implicit flow, which is a grant type and is
  # never in the list, and a service app has no redirect URI for a fragment to
  # land in. The precondition on the resource below holds that exception to
  # exactly that grant, so an edit to this table cannot widen it.
  by_type = {
    web = {
      grant_types    = ["authorization_code", "refresh_token"]
      response_types = ["code"]
      pkce_required  = true
      auth_method    = "private_key_jwt"
      redirects      = true
    }
    browser = {
      grant_types    = ["authorization_code", "refresh_token"]
      response_types = ["code"]
      pkce_required  = true
      auth_method    = "none"
      redirects      = true
    }
    native = {
      grant_types    = ["authorization_code", "refresh_token"]
      response_types = ["code"]
      pkce_required  = true
      auth_method    = "none"
      redirects      = true
    }
    service = {
      grant_types    = ["client_credentials"]
      response_types = ["token"]
      pkce_required  = null
      auth_method    = "private_key_jwt"
      redirects      = false
    }
  }

  # Per-app derived values, resolved once so the resource block reads as a table.
  derived = {
    for k, a in var.apps : k => {
      grant_types    = concat(local.by_type[a.type].grant_types, a.extra_grant_types)
      response_types = local.by_type[a.type].response_types
      pkce_required  = local.by_type[a.type].pkce_required
      auth_method    = a.allow_client_secret ? "client_secret_basic" : local.by_type[a.type].auth_method
      redirects      = local.by_type[a.type].redirects
      rotates        = contains(local.by_type[a.type].grant_types, "refresh_token")
    }
  }

  # Groups are looked up by name, once per distinct name across every app, so a
  # group two apps share is one API read and one data source address.
  group_names = toset(flatten([for a in var.apps : a.group_names]))
}

data "okta_group" "this" {
  for_each = local.group_names

  name = each.value
}

resource "okta_app_oauth" "this" {
  for_each = var.apps

  label  = each.value.label
  type   = each.value.type
  status = each.value.status

  # Derived from the type table. See locals above and the README.
  grant_types                = local.derived[each.key].grant_types
  response_types             = local.derived[each.key].response_types
  pkce_required              = local.derived[each.key].pkce_required
  token_endpoint_auth_method = local.derived[each.key].auth_method
  jwks_uri                   = each.value.jwks_uri

  # Redirect URIs are only valid on the redirect-based types; variables.tf has
  # already refused them on a service app, so null here keeps the payload clean.
  redirect_uris             = local.derived[each.key].redirects ? each.value.redirect_uris : null
  post_logout_redirect_uris = local.derived[each.key].redirects && length(each.value.post_logout_redirect_uris) > 0 ? each.value.post_logout_redirect_uris : null
  wildcard_redirect         = "DISABLED"

  # Rotation attributes are only accepted next to the refresh_token grant, which
  # a service app never has.
  refresh_token_rotation = local.derived[each.key].rotates ? "ROTATE" : null
  refresh_token_leeway   = local.derived[each.key].rotates ? 30 : null

  # Fixed for every type. omit_secret keeps the client secret out of state;
  # auto_key_rotation lets Okta roll the signing keys without a plan.
  omit_secret       = true
  auto_key_rotation = true

  consent_method = each.value.consent_method
  login_mode     = each.value.login_mode
  login_uri      = each.value.login_mode == "DISABLED" ? null : each.value.login_uri
  client_uri     = each.value.client_uri
  logo_uri       = each.value.logo_uri
  policy_uri     = each.value.policy_uri
  tos_uri        = each.value.tos_uri
  hide_ios       = each.value.hide_ios
  hide_web       = each.value.hide_web

  # The calling stack resolves a policy key to an ID. Null falls back to the
  # org default app sign-on policy, which the stack's checks decide about.
  authentication_policy = each.value.authentication_policy_id

  # The groups claim is always a FILTER claim on group names. An EXPRESSION
  # claim would let a cell write Okta Expression Language, which is a policy
  # document by another name, so the type is fixed here.
  dynamic "groups_claim" {
    for_each = each.value.groups_claim == null ? [] : [each.value.groups_claim]

    content {
      name        = groups_claim.value.name
      type        = "FILTER"
      filter_type = groups_claim.value.filter_type
      value       = groups_claim.value.value
    }
  }

  # logo_uri is presentation, not a guardrail. App owners replace the logo from
  # the console and Okta rewrites the stored URI, so tracking it would make
  # every later plan fight a change nobody in this repository made.
  #
  # The precondition is the one invariant the type table promises and a future
  # edit to it could break: a token or id_token response type is sent only
  # when the grant types are exactly client_credentials, where Okta requires
  # it and no browser is involved. Everywhere else the response type is code.
  lifecycle {
    ignore_changes = [logo_uri]

    precondition {
      condition = (
        !contains(local.derived[each.key].response_types, "token") && !contains(local.derived[each.key].response_types, "id_token")
        ) || (
        tolist(local.derived[each.key].grant_types) == tolist(["client_credentials"]) && tolist(local.derived[each.key].response_types) == tolist(["token"])
      )
      error_message = "App ${each.key}: a token or id_token response type is allowed only with grant_types exactly [client_credentials], where the Okta app API requires it. Every redirect-based type is code only, so the implicit and hybrid flows cannot be requested."
    }
  }
}

# One assignments resource per app that names at least one group. The provider
# owns the whole assignment list of the app, so a group removed from the cell is
# unassigned on the next apply, which is the reviewable behaviour we want.
resource "okta_app_group_assignments" "this" {
  for_each = { for k, a in var.apps : k => a if length(a.group_names) > 0 }

  app_id = okta_app_oauth.this[each.key].id

  dynamic "group" {
    for_each = each.value.group_names

    content {
      id       = data.okta_group.this[group.value].id
      priority = lookup(each.value.group_assignment_priorities, group.value, null)
    }
  }
}
