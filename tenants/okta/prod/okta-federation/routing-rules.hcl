# Okta prod tenant: the federation cell's routing rules.
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

inputs = {
  routing_rules = {
    # Every workforce username ends in the corp domain, so the suffix is the
    # whole condition; from anywhere, because the factors are Entra's to
    # evaluate. The Okta Admin Console is excluded on purpose: this is the
    # break-glass line. Administrators keep signing in to Okta directly with
    # the phishing-resistant factors okta-config enrolls, so an Entra outage
    # does not lock the org's administrators out. The dev cell carries the
    # same rule without the exclusion and proves the whole path first.
    workforce-to-entra = {
      name                 = "Workforce to Entra"
      priority             = 1
      user_identifier_type = "IDENTIFIER"
      patterns             = [{ match_type = "SUFFIX", value = "example.com" }]
      idps                 = ["entra"]
      network_connection   = "ANYWHERE"

      app_exclude = [{ type = "APP", label = "Okta Admin Console" }]
    }
  }
}
