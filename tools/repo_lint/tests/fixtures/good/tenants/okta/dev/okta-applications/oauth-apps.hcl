# fixture fragment of ./terragrunt.hcl, included there as "oauth_apps": one
# inputs attribute holding oauth_apps and nothing else.

inputs = {
  oauth_apps = {
    orders-portal = {
      label         = "Orders Portal"
      type          = "web"
      redirect_uris = ["https://orders.dev.example.com/callback"]
      jwks_uri      = "https://orders.dev.example.com/.well-known/jwks.json"
      group_names   = ["app-orders-users"]
      signon_policy = "standard-workforce"
    }
  }
}
