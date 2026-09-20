# ---------------------------------------------------------------------------
# App sign-on policies first. Every app references their ids.
#
# The map passes through unchanged: the module owns the shape, its refusals,
# the zone and group lookups, and the catch-all rule created with DENY. What
# this stack adds is the resolution of an app's policy key to one of these ids
# (main.tf) and the admin-tier check on phishing_resistant_only (outputs.tf).
# ---------------------------------------------------------------------------

module "signon_policies" {
  source = "../../modules/okta/app-signon-policy"

  policies = var.signon_policies
}
