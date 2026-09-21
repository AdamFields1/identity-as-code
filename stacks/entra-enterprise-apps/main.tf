# entra-enterprise-apps stack
#
# The Entra application catalog (docs/adr/0021, on the shape docs/adr/0020
# set). One deployable unit per tenant
# that offers one vetted shape as values, so a service provider can be
# onboarded over SAML without anyone writing Terraform:
#
#   saml_apps  -->  application (gallery template or custom)
#                   + service principal in SAML mode
#                   + signing certificate
#                   + claims mapping policy, rendered by the module
#                   + app role assignments to groups, by name
#                   + optional provisioning job
#
# The map is values a reviewer reads: an app is a vendor's endpoints, how its
# subject is named, the attributes its assertion carries, and which groups may
# open it through which app role. Every guardrail about a single entry lives in
# the module that owns the shape (modules/entra/saml-enterprise-app: what it
# refuses, what it fixes, what it renders); this stack owns the checks that
# only make sense across the whole map, the one credential that must not sit
# in a cell, and nothing else.
#
# Checks the stack makes across the map, so a mistake shows in the plan and
# not in the first sign-in:
#
#   - No display name appears twice, compared without case. Entra's own
#     duplicate check is case insensitive and would refuse the second app at
#     apply; the person clicking a tile cannot tell the two apart either way.
#   - No reply URL is shared by two apps. An assertion consumer service URL is
#     one service provider's; two apps posting to it is a copy-paste error
#     that would send one vendor's assertion to another's endpoint.
#   - No entity ID is shared by two apps. Entra requires identifier URIs to be
#     unique in the tenant and would refuse the second at apply.
#   - Every provisioning token names an app of this cell that sets
#     provisioning, so a token with no job to use it is refused rather than
#     written to state for nothing.
#
# Wiring the stack does so a cell never holds a secret: a token-based SCIM
# connector's token arrives through TF_VAR_provisioning_secret_tokens, keyed
# by app, and the stack passes that map to the module's own sensitive input
# beside the saml_apps map, whose provisioning block (template_id and
# base_address, the cell's unchanged) never holds it. The cell's provisioning
# block is therefore safe to print, as the entra-aws-federation stack keeps
# its SCIM credentials. The token has its own input rather than a field of
# the map because Terraform refuses a for_each over a value derived from a
# sensitive one, and a map that carries the token is such a value.
#
# Groups are named, never id'd, and the module looks them up. They are created
# in stacks/entra-app-registrations or provisioned elsewhere, so a name that
# does not exist fails the plan with the name in the error, which is the
# honest failure: an empty assignment would look like a working app nobody
# can open. Assigning the group is the whole scope of the app, because
# assignment is required on every application the module manages.
#
# Tenant cells (tenants/azure/<tenant>/entra-enterprise-apps/) supply values
# only, as a fragment cell: one file for the map. tenant_id and subscription_id
# arrive from root.hcl, never from the cell.
#
# Deliberately NOT managed here: OIDC enterprise applications beyond app
# registrations (stacks/entra-app-registrations), password-based and linked
# sign-on, the groups themselves, and the provisioning connectors' OAuth
# authorisations (Google Workspace is one; the README shows the console step).
#
# This file is the stack's record; the module call is in saml-apps.tf and the
# variables and their checks in variables.tf. There is no wiring left to do
# here: the cell's map goes to the module as is, and the token map beside it.
