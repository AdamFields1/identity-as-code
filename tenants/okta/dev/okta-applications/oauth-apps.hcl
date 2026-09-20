# Okta dev tenant: the application catalog cell's OIDC apps.
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
# to keep. The one dev-only knob is allow_localhost_redirects on the
# console, below. After apply, the stack's oauth_client_ids output holds
# each client id; there is never a secret to hand over.

inputs = {
  oauth_apps = {
    # Server-side web app. Authenticates to the token endpoint with a key it
    # publishes at jwks_uri; the groups claim is filtered to the app's own
    # groups so the token carries no more of the directory than it needs.
    orders-portal = {
      label                     = "Orders Portal"
      type                      = "web"
      redirect_uris             = ["https://orders.dev.example.com/callback"]
      post_logout_redirect_uris = ["https://orders.dev.example.com/"]
      jwks_uri                  = "https://orders.dev.example.com/.well-known/jwks.json"

      groups_claim = {
        name        = "groups"
        filter_type = "STARTS_WITH"
        value       = "app-orders-"
      }

      group_names   = ["app-orders-users", "app-orders-admins"]
      signon_policy = "standard-workforce"
    }

    # Single-page app. A public client: PKCE, no secret, no JWKS. The
    # localhost redirect is how an engineer runs the SPA on a laptop against
    # the dev org; the knob puts the word localhost in the diff, the module
    # still requires a port and refuses any other http URI, and the prod
    # cell never sets it.
    orders-console = {
      label                     = "Orders Console"
      type                      = "browser"
      allow_localhost_redirects = true
      redirect_uris = [
        "https://console.orders.dev.example.com/callback",
        "http://localhost:3000/callback",
      ]
      post_logout_redirect_uris = [
        "https://console.orders.dev.example.com/",
        "http://localhost:3000/",
      ]

      groups_claim = {
        name        = "groups"
        filter_type = "STARTS_WITH"
        value       = "app-orders-"
      }

      group_names   = ["app-orders-users"]
      signon_policy = "standard-workforce"
    }
  }
}
