# okta-federation stack
#
# Okta federating to an upstream SAML 2.0 identity provider (docs/adr/0017,
# docs/adr/0020). One deployable unit per Okta org that closes the loop between
# the two identity providers this repository manages: the corp Entra tenant
# becomes an upstream identity provider for the Okta org (Entra asserts, Okta
# is the service provider), and routing rules on the org's identity provider
# discovery policy send workforce sign-ins to it:
#
#   identity providers  -->  routing rules   (each names identity providers by key)
#
# The two maps are values a reviewer reads: an identity provider is the other
# side's issuer, its sign-on endpoint, and its public signing certificate; a
# routing rule is a pattern on the username, a network condition, an
# application condition, and the identity providers it routes to. Every
# guardrail lives in the module that owns the shape (what it refuses, what it
# fixes: SHA-256 on both signatures, signed AuthnRequests, SAML2 as the only
# routing target); this stack owns the wiring between the maps and the checks
# that only make sense across them, and nothing else.
#
# Wiring the stack does so a cell never writes an id:
#
#   - A routing rule names the identity providers of this cell by their map
#     keys (idps). The stack resolves each key against the identity provider
#     module's output and hands the routing module idp_ids, which is also the
#     dependency edge that creates identity providers before rules.
#   - Groups, zones, and applications are named, never id'd. Groups (the
#     account-link and provisioning group lists) are looked up by name, the
#     way okta-config resolves groups_included. Zones (a rule's ZONE
#     condition) are looked up by the names the org's okta-config cell creates
#     them with, so a zone that cell has not created yet fails the plan with
#     its name in the error, which is the honest failure. Applications (a
#     rule's APP include or exclude, in practice the Okta Admin Console) are
#     looked up by label.
#   - The IDP_DISCOVERY policy is looked up by its fixed name. Every org has
#     exactly one, Okta names it "Idp Discovery Policy", and the provider's
#     own documentation for the rule resource looks it up that way
#     (https://registry.terraform.io/providers/okta/okta/latest/docs/resources/policy_rule_idp_discovery,
#     "All Okta orgs contain only one IdP Discovery Policy").
#
# Checks the stack makes across the maps, so a mistake shows in the plan and
# not in the first sign-in:
#
#   - Every idps entry of a routing rule is a key of identity_providers.
#   - Every group, zone, and application name is looked up exactly once, by
#     distinct name, so the plan carries one read per name and one error per
#     missing name.
#   - No two routing rules share a priority, because a map has no order and
#     the priority is the order.
#
# Tenant cells (tenants/okta/<env>/okta-federation/) supply values only, as a
# fragment cell: one file per map, plus the identity provider's signing
# certificate as a .cer file beside the cell that the fragment reads with
# file(). The org and base URL are the same values the org's okta-config cell
# carries, and they are also what builds the ACS URL the other side needs.
#
# Deliberately NOT managed here: OIDC upstream identity providers
# (okta_idp_oidc) and social identity providers, which are different shapes;
# the inverse direction, Okta as an upstream identity provider for Entra
# (external identities or direct federation on the Entra side); the Entra-side
# enterprise application, which the corp entra-enterprise-apps cell holds as
# one entry per Okta org (okta-workforce, okta-workforce-dev), because an
# application carries one audience and one reply URL while Okta mints both per
# trust; those applications' OAuth-consented provisioning connectors;
# the IDP_DISCOVERY policy itself, which Okta creates with the org; and the
# groups and zones the cells name, which the upstream identity provider and
# the okta-config cell create.

# ---------------------------------------------------------------------------
# Group lookups. One data source per distinct group name across every identity
# provider's provisioning and account-link lists, the way okta-config does it.
# The module takes ids; a name that does not exist fails the plan here with
# the name in the error, before any trust is created.
# ---------------------------------------------------------------------------

locals {
  all_group_names = toset(flatten([
    for p in var.identity_providers : concat(
      p.provisioning.groups_filter,
      p.provisioning.groups_assignment,
      p.account_link.group_include,
    )
  ]))
}

data "okta_group" "by_name" {
  for_each = local.all_group_names

  name = each.value
}

# ---------------------------------------------------------------------------
# Zone lookups. One data source per distinct zone name across every routing
# rule's ZONE condition. The zones are created by the org's okta-config cell,
# which the cells declare as a dependency so the train applies it first; a
# name it has not created yet fails the plan with the name in the error.
# ---------------------------------------------------------------------------

locals {
  all_zone_names = toset(flatten([
    for r in var.routing_rules : concat(r.zones_included, r.zones_excluded)
  ]))
}

data "okta_network_zone" "by_name" {
  for_each = local.all_zone_names

  name = each.value
}

# ---------------------------------------------------------------------------
# Application lookups. One data source per distinct label across every routing
# rule's APP include and exclude entries. The data source needs only the label
# (id, label, and label_prefix conflict with one another); the label a rule
# names in practice is "Okta Admin Console", which Okta creates once per org.
#
# The postcondition is the guard, and it is not theoretical. The data source
# queries Okta with ?q=<label>, which the API matches as a starts-with over
# both name and label, and then looks for an exact label among the results; if
# none of them has it, the provider silently keeps the first result rather than
# failing. A renamed or mistyped label would therefore plan green against some
# other application, and in prod the rule that excludes the admin console would
# exclude that other application instead, which is the break-glass line ADR
# 0022 says this exclusion exists to hold.
# ---------------------------------------------------------------------------

locals {
  all_app_labels = toset(flatten([
    for r in var.routing_rules : [
      for a in concat(r.app_include, r.app_exclude) : a.label
      if a.type == "APP" && a.label != null
    ]
  ]))
}

data "okta_app" "by_label" {
  for_each = local.all_app_labels

  label = each.value

  lifecycle {
    postcondition {
      condition     = self.label == each.value
      error_message = "data.okta_app resolved a different application than the label asked for. The okta_app data source keeps the first near-match when no result carries the exact label, so a routing rule's include or exclude would bind to the wrong application and plan green. Check the label in the cell against the application's label in the org."
    }
  }
}

# ---------------------------------------------------------------------------
# The identity provider discovery policy. Every org has exactly one, created
# by Okta with the org and named "Idp Discovery Policy"; the routing module
# takes its id and the cells never see it.
# ---------------------------------------------------------------------------

data "okta_policy" "idp_discovery" {
  name = "Idp Discovery Policy"
  type = "IDP_DISCOVERY"
}

locals {
  group_ids = { for name, g in data.okta_group.by_name : name => g.id }
  zone_ids  = { for name, z in data.okta_network_zone.by_name : name => z.id }
  app_ids   = { for label, a in data.okta_app.by_label : label => a.id }

  # The org's URL, from the same two values the generated provider block reads.
  # It is the host of the ACS URL the other side posts the response to.
  org_url = "https://${var.okta_org_name}.${var.okta_base_url}"
}
