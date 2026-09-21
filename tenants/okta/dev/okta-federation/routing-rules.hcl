# Okta dev tenant: the federation cell's routing rules.
#
# A fragment of ./terragrunt.hcl, included there as "routing_rules": one
# inputs attribute holding routing_rules and nothing else. Values only, as
# the cell is; the header comment in terragrunt.hcl describes the whole cell.
#
# Rules on the org's identity provider discovery policy. An entry is a
# pattern on the username, a network condition, an application condition,
# and the identity providers of identity-providers.hcl it routes to, by
# key. Priorities are the order, unique across the map. Zones are the names
# the okta-config cell creates, applications are labels. The policy's
# default rule, which routes to Okta itself, is immutable and always last,
# so a sign-in no rule matches still reaches the Okta sign-in page.
#
# Dev proves the whole path, the Okta Admin Console included: the rule
# below carries no app_exclude, so a dev administrator's sign-in to the
# console goes through Entra too, and the routing is seen end to end before
# prod relies on it. Prod excludes the console so its administrators keep a
# direct path into Okta; that exclusion is prod's break-glass line and is
# not exercised here.

inputs = {
  routing_rules = {
    # Every workforce username ends in the corp domain, so the suffix is the
    # whole condition; from anywhere, because the factors are Entra's to
    # evaluate. Same rule as prod, without the admin console exclusion.
    workforce-to-entra = {
      name                 = "Workforce to Entra"
      priority             = 1
      user_identifier_type = "IDENTIFIER"
      patterns             = [{ match_type = "SUFFIX", value = "example.com" }]
      idps                 = ["entra"]
      network_connection   = "ANYWHERE"
    }
  }
}
