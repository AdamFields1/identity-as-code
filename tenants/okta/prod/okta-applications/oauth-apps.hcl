# Okta prod tenant: the application catalog cell's OIDC apps.
#
# A fragment of ./terragrunt.hcl, included there as "oauth_apps": one inputs
# attribute holding oauth_apps and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.
#
# OIDC apps. An entry says what kind of client it is and where it redirects;
# the type decides the rest and the cell cannot override it: authorization
# code with refresh tokens (code only, never implicit) on web, browser, and
# native, client credentials on service, PKCE on the public types,
# private_key_jwt on web and service from the jwks_uri given here, refresh
# token rotation, wildcard_redirect disabled, automatic key rotation. No
# entry sets allow_client_secret, so no app of this org has a shared secret
# to keep, and no entry sets allow_localhost_redirects: that knob is for the
# dev org only, and a prod cell never turns it on. After apply, the stack's
# oauth_client_ids output holds each client id; there is never a secret to
# hand over.

inputs = {
  oauth_apps = {
    # Server-side web app. Authenticates to the token endpoint with a key it
    # publishes at jwks_uri; the groups claim is filtered to the app's own
    # groups so the token carries no more of the directory than it needs.
    orders-portal = {
      label                     = "Orders Portal"
      type                      = "web"
      redirect_uris             = ["https://orders.example.com/callback"]
      post_logout_redirect_uris = ["https://orders.example.com/"]
      jwks_uri                  = "https://orders.example.com/.well-known/jwks.json"

      groups_claim = {
        name        = "groups"
        filter_type = "STARTS_WITH"
        value       = "app-orders-"
      }

      group_names   = ["app-orders-users", "app-orders-admins"]
      signon_policy = "standard-workforce"
    }

    # Single-page app. A public client: PKCE, no secret, no JWKS.
    orders-console = {
      label                     = "Orders Console"
      type                      = "browser"
      redirect_uris             = ["https://console.orders.example.com/callback"]
      post_logout_redirect_uris = ["https://console.orders.example.com/"]

      groups_claim = {
        name        = "groups"
        filter_type = "STARTS_WITH"
        value       = "app-orders-"
      }

      group_names   = ["app-orders-users"]
      signon_policy = "standard-workforce"
    }

    # Machine-to-machine client. Client credentials: no redirect, no groups
    # claim, no group assignment, and no sign-on policy, because there is no
    # user sign-in for one to evaluate; the token endpoint authenticates the
    # job by the keys it publishes at jwks_uri (signon-policies.hcl says the
    # same from the policy side).
    orders-reporting-job = {
      label    = "Orders Reporting Job"
      type     = "service"
      jwks_uri = "https://reporting.orders.example.com/.well-known/jwks.json"
    }
  }
}
