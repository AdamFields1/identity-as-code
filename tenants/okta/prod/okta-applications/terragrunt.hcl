# Okta prod tenant: application catalog cell.
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
# What this cell holds, and how the entries refer to each other:
#   - two sign-on policies: standard-workforce (two factors, re-authentication
#     every twelve hours, from a corporate zone or a managed device) and
#     admin-phishing-resistant (phishing-resistant and hardware-protected
#     possession, re-authentication on every sign-in)
#   - two SAML apps: the payroll vendor on standard-workforce, and the vendor
#     admin console, tier admin, on admin-phishing-resistant
#   - three OIDC apps: the orders portal (web), the orders console (browser),
#     and the orders reporting job (service, client credentials, no policy)
# The stack checks the wiring at plan: every policy key an app names exists,
# an admin-tier app names a policy whose ALLOW rules all require
# phishing-resistant possession, and no two apps share a label.
#
# Nothing below is an id. Policies are named by map key, network zones by
# the name the org's okta-config cell gives them, and groups by name. The
# groups are not created here or anywhere in this repository: the upstream
# identity provider (the corp Entra tenant) provisions them into Okta, and a
# group named here that does not exist yet fails the plan with the name in
# the error, which is the honest failure.
#
# State key (derived by root.hcl): okta/prod/okta-applications/terraform.tfstate

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
  okta_org_name = "example-org"
  okta_base_url = "okta.com"
}
