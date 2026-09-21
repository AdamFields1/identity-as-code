# Entra corp tenant cell: enterprise applications over SAML.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in the module (docs/adr/0020), never in
# a looser entry here.
#
# Application onboarding is confined to corp, as it is for app registrations.
# The subsidiary has no entra-enterprise-apps cell; its people reach these
# service providers through corp groups.
#
# The cell is written as fragments so it reads like the portal's single
# sign-on page: this file holds the includes, the source, and the wiring, and
# the one map lives in the sibling file named for it (saml-apps.hcl), an
# inputs attribute and nothing else. Terragrunt merges every include's inputs
# with the ones here into one map, so the stack sees exactly what a single
# inputs block would have given it. Onboarding an application is a new entry
# in saml-apps.hcl; the reviewer reads a diff of values and the module refuses
# what the catalog does not offer. A fragment is not a cell: it has no include
# of its own, no source, and Terragrunt never runs it.
#
# What this cell holds: four SAML service providers. Google Workspace is a
# gallery application, created from its template by display name. Okta
# (workforce federation) and Okta (workforce federation, dev) are the other
# side of the trusts the two okta-federation cells create, one application
# per Okta org because an application carries one entity ID and one reply URL
# while Okta mints both per trust: Entra asserts and Okta is the service
# provider, so those values are the Okta side's and the stack README of
# stacks/okta-federation describes the two applies that exchange them.
# Example Payroll is a custom application, the same fictional
# vendor
# tenants/okta/prod/okta-applications/saml-apps.hcl onboards: the same entity
# ID, ACS URL, subject and group names, so the vendor is configured once and
# trusts either identity provider; the attributes are each provider's
# rendering of the vendor's guide (Okta sends name from displayName, Entra
# sends firstName and lastName). That is the parity the two catalogs promise
# (docs/adr/0021, on the shape docs/adr/0020 set): one shape per protocol,
# the same values from either side, and the guardrails in the modules.
#
# Nothing below is an id. A gallery template is named by its display name,
# and every group in app_roles_to_groups is a display name the module looks
# up. The groups are not created here: they come from
# ../entra-app-registrations or are provisioned elsewhere, and a name that
# does not exist yet fails the plan with the name in the error, which is the
# honest failure. Assignment is required on every application the module
# manages, so the groups named here are the whole scope of each app.
#
# Provisioning: the Google Workspace connector is authorised by an
# administrator consenting in a Google dialog the portal opens, which
# Terraform cannot perform, so that entry leaves provisioning unset and the
# one console step (enterprise application, Provisioning, Get started, New
# configuration, Authorize, accept in the Google window, Test connection,
# Save, then start provisioning) is done once by hand. A token-based SCIM
# connector states template_id and base_address in the fragment; the token
# arrives through TF_VAR_provisioning_secret_tokens (see the stack README),
# keyed by the app, and never through this cell.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/entra-enterprise-apps/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Fragments. One per map the cell sets; this stack composes one.
include "saml_apps" {
  path = "saml-apps.hcl"
}

terraform {
  source = "../../../../stacks/entra-enterprise-apps"
}

# Cell-wide values. This stack has none: the tenant arrives from root.hcl and
# the map lives in its fragment, so this attribute is the empty map the
# fragment's inputs merge into.
inputs = {}
