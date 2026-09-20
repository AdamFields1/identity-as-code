# ---------------------------------------------------------------------------
# OIDC apps, after the policies they name.
#
# As with the SAML apps, the cell's values pass through untouched and the one
# substitution is the policy key for the policy id. Everything OAuth-shaped
# (grant and response types, PKCE, the token endpoint method, rotation, the
# wildcard setting, omit_secret) is derived from type inside the module and
# has no input here to widen. A service app names no policy in the worked
# cells: client credentials has no user sign-in for a sign-on policy to
# evaluate, and the token endpoint authenticates the client by its keys.
# ---------------------------------------------------------------------------

module "oauth_apps" {
  source = "../../modules/okta/app-oauth"

  apps = {
    for key, a in var.oauth_apps : key => {
      label                     = a.label
      type                      = a.type
      redirect_uris             = a.redirect_uris
      post_logout_redirect_uris = a.post_logout_redirect_uris
      jwks_uri                  = a.jwks_uri
      allow_client_secret       = a.allow_client_secret
      allow_localhost_redirects = a.allow_localhost_redirects
      extra_grant_types         = a.extra_grant_types
      groups_claim              = a.groups_claim
      consent_method            = a.consent_method
      login_mode                = a.login_mode
      login_uri                 = a.login_uri
      client_uri                = a.client_uri
      logo_uri                  = a.logo_uri
      policy_uri                = a.policy_uri
      tos_uri                   = a.tos_uri
      hide_ios                  = a.hide_ios
      hide_web                  = a.hide_web
      status                    = a.status
      authentication_policy_id  = local.oauth_policy_ids[key]
      tier                      = a.tier

      group_names                 = a.group_names
      group_assignment_priorities = a.group_assignment_priorities
    }
  }
}
