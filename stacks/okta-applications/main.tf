# okta-applications stack
#
# The Okta application catalog (docs/adr/0017). One deployable unit per Okta
# org that offers three vetted shapes as values, so an application can be
# onboarded over SAML or OIDC without anyone writing Terraform:
#
#   app sign-on policies  -->  SAML apps   (each names a policy by key)
#                         -->  OIDC apps   (each names a policy by key)
#
# The three maps are values a reviewer reads: a policy is a set of named rules,
# a SAML app is a vendor's endpoints and attributes, an OIDC app is a type and
# its redirect URIs. Every guardrail lives in the module that owns the shape
# (what it refuses, what it fixes, prevent_destroy on the policy); this stack
# owns the wiring between the maps and the checks that only make sense across
# them, and nothing else.
#
# Wiring the stack does so a cell never writes an id:
#
#   - An app names a sign-on policy of this cell by its map key
#     (signon_policy). The stack resolves the key against the policy module's
#     ids and hands the app module authentication_policy_id, which is also the
#     dependency edge that creates policies before apps.
#   - Zones and groups are named, never id'd, and the modules look them up.
#     Zones come from the okta-config cell of the same org and groups from the
#     upstream identity provider, so a missing name fails the plan, which is
#     the honest failure.
#
# Checks the stack makes across the maps, so a mistake shows in the plan and
# not in the first sign-in:
#
#   - Every signon_policy key names a policy declared in signon_policies.
#   - An app whose tier is admin names a policy, and that policy's ALLOW rules
#     all require a phishing-resistant possession factor. The module exports
#     that fact from the values, so the check runs at plan time.
#   - No label appears twice, within a map or across the two app maps. Okta
#     allows it; the person clicking a tile cannot tell the apps apart.
#
# Tenant cells (tenants/okta/<env>/okta-applications/) supply values only, as
# a fragment cell: one file per map. The org and base URL are the same values
# the org's okta-config cell carries.
#
# Deliberately NOT managed here: authorization servers, scopes, claims, and
# token lifetimes (a later catalog); SWA, bookmark, and basic-auth apps; user
# profile mappings; the apps' own provisioning of users and groups into the
# vendor; and the groups themselves, which the upstream identity provider
# creates and this stack only names.

# ---------------------------------------------------------------------------
# Policy resolution. An app names a policy by key or names none; the variable
# validations have already refused a key that is not in signon_policies, so
# the index below cannot miss. Null leaves the app on the org's default app
# sign-on policy, which is the permissive one, and is therefore refused on an
# admin-tier app before this local is ever read.
# ---------------------------------------------------------------------------

locals {
  saml_policy_ids = {
    for key, a in var.saml_apps : key => a.signon_policy == null ? null : module.signon_policies.policy_ids[a.signon_policy]
  }

  oauth_policy_ids = {
    for key, a in var.oauth_apps : key => a.signon_policy == null ? null : module.signon_policies.policy_ids[a.signon_policy]
  }

  # Admin-tier apps whose policy does not require phishing-resistant possession
  # on every ALLOW rule. phishing_resistant_only is computed by the policy
  # module from the values, not from the resources, so these lists are known at
  # plan time and the preconditions in outputs.tf can name the offenders. An
  # admin app with no policy is refused by a variable validation first; try()
  # makes the null case a violation here as well, so the two checks agree.
  saml_admin_violations = sort([
    for key, a in var.saml_apps : key
    if a.tier == "admin" && !try(module.signon_policies.phishing_resistant_only[a.signon_policy], false)
  ])

  oauth_admin_violations = sort([
    for key, a in var.oauth_apps : key
    if a.tier == "admin" && !try(module.signon_policies.phishing_resistant_only[a.signon_policy], false)
  ])
}
