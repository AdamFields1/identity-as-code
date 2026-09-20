# Okta dev tenant: application catalog cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module (docs/adr/0017), never in a
# looser entry here.
#
# The cell is written as fragments so it reads like the admin console: this
# file holds the includes, the source, the ordering, and the org, and each
# map lives in the sibling file named for it (signon-policies.hcl,
# saml-apps.hcl, oauth-apps.hcl), an inputs attribute and nothing else.
# Terragrunt merges every include's inputs into one map, so the stack sees
# the same values it would see from one file. Onboarding an application is a
# new entry in saml-apps.hcl or oauth-apps.hcl that names a policy of
# signon-policies.hcl by key; the reviewer reads a diff of values and the
# modules refuse what the catalog does not offer.
#
# Same stack as prod. Dev applies on merge and prod waits at the soak gate,
# so every shape prod carries is exercised here first: both sign-on
# policies are present even though no dev app is admin tier yet. The
# differences from prod are the whole story of "what dev may do that prod
# may not":
#   - the orders console allows http://localhost:3000/callback through the
#     allow_localhost_redirects knob, so an engineer can run the SPA locally
#     against the dev org; prod never sets the knob
#   - the vendor admin console and the reporting job are not onboarded, so
#     the admin tier and the service type are exercised in prod only
# The hosts are the dev instances of the same applications; every value is
# a placeholder under example.com.
#
# Nothing below is an id. Policies are named by map key, network zones by
# the name the org's okta-config cell gives them, and groups by name. The
# groups are not created here or anywhere in this repository: the upstream
# identity provider (the corp Entra tenant) provisions them into Okta, and a
# group named here that does not exist yet fails the plan with the name in
# the error, which is the honest failure.
#
# State key (derived by root.hcl): okta/dev/okta-applications/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "signon_policies" {
  path = "signon-policies.hcl"
}

include "saml_apps" {
  path = "saml-apps.hcl"
}

include "oauth_apps" {
  path = "oauth-apps.hcl"
}

terraform {
  source = "../../../../stacks/okta-applications"
}

# Ordering only. The sign-on policy rules name network zones by the names the
# okta-config cell creates them with (Corporate egress, VPN concentrators),
# and the stack resolves those names at plan time; no outputs are read from
# that cell. This block makes `terragrunt run --all` apply okta-config first,
# and the release workflow orders the jobs the same way.
dependencies {
  paths = ["../okta-config"]
}

inputs = {
  okta_org_name = "example-org-dev"
  okta_base_url = "oktapreview.com"
}
