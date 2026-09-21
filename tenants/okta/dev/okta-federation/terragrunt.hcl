# Okta dev tenant: federation cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module (docs/adr/0017), never in a
# looser entry here.
#
# The cell is written as fragments so it reads like the admin console: this
# file holds the includes, the source, the ordering, and the org, and each
# map lives in the sibling file named for it (identity-providers.hcl,
# routing-rules.hcl), an inputs attribute and nothing else. Terragrunt
# merges every include's inputs into one map, so the stack sees the same
# values it would see from one file. Onboarding an identity provider is a
# new entry in identity-providers.hcl and a certificate file beside it, and
# a rule in routing-rules.hcl that names the entry by key; the reviewer
# reads a diff of values and the modules refuse what the catalog does not
# offer.
#
# Same stack as prod. Dev applies on merge and prod waits at the soak gate,
# so every shape prod carries is exercised here first: the same identity
# provider (the corp Entra tenant, trusting the signing certificate carried
# beside this file as entra-signing-2026.cer) and the same routing rule,
# Workforce to Entra. The one difference from prod is the whole story of
# what dev proves that prod does not rely on:
#   - the rule carries no app_exclude, so dev proves the whole path
#     including the Okta Admin Console; prod excludes the console so its
#     administrators keep a direct path into Okta, and that exclusion is
#     never exercised here
# The org is the dev org on oktapreview.com; every value is a placeholder
# under example.com and the placeholder tenant id.
#
# The other side of this trust is the okta-workforce application in the corp
# entra-enterprise-apps cell (tenants/azure/corp/entra-enterprise-apps/
# saml-apps.hcl). The two sides exchange three values and nothing else: the
# issuer and the signing certificate come this way, from Entra, and the
# audience and the ACS URL go the other way, from this cell's
# identity_provider_onboarding output after the first apply. The stack
# README, "Bootstrapping the trust in two applies", says the order.
#
# Nothing below is an id. Identity providers are named by map key, network
# zones by the name the org's okta-config cell gives them, and groups by
# name. The one value that looks like an id is the issuer,
# https://sts.windows.net/<tenant id>/: it is the URL Entra publishes as the
# <Issuer> of every response and has no name form, so the cell carries the
# placeholder tenant id inside it. It is the other side's identifier, not an
# Okta object id.
#
# State key (derived by root.hcl): okta/dev/okta-federation/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "identity_providers" {
  path = "identity-providers.hcl"
}

include "routing_rules" {
  path = "routing-rules.hcl"
}

terraform {
  source = "../../../../stacks/okta-federation"
}

# Ordering only. A routing rule with a ZONE condition names network zones by
# the names the okta-config cell creates them with, and the stack resolves
# those names at plan time; no outputs are read from that cell. This block
# makes `terragrunt run --all` apply okta-config first, and the release
# workflow orders the jobs the same way, beside okta-applications.
dependencies {
  paths = ["../okta-config"]
}

inputs = {
  okta_org_name = "example-org-dev"
  okta_base_url = "oktapreview.com"
}
