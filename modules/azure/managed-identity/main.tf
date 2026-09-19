# User-assigned managed identities, one per map entry, each with the GitHub
# Actions federated credentials that let a workflow obtain a token for it.
#
# A managed identity is the catalog's answer to "this workload needs to call
# Azure": a service principal with no credential at all. What may act as it
# is written in federated credentials, each of which names one issuer and one
# subject, and a GitHub Actions job whose OIDC token carries exactly that
# subject can exchange it for an Entra token for this identity. Nothing is
# issued, stored, or rotated, which is the same model the release train uses
# for its own access (docs/adr/0003).
#
# The subject is built here from an organization, a repository, and either a
# branch or an environment, never typed in a cell, for two reasons. Entra
# matches the subject exactly, so a subject written by hand with a wildcard
# or a wrong prefix silently matches nothing and the workflow fails at login
# with no hint why. And the shape says what the credential trusts: a branch
# credential trusts anyone who can push to that branch, an environment
# credential trusts the environment's protection rules (required reviewers,
# deployment branches), which is where the gated tenants already put their
# trust (README, "Promotion is gated"). Tag and pull-request subjects are
# deliberately not offered: a tag can be moved by anyone with write access,
# and a pull request subject trusts every fork's pull request.
#
# The identity's principal ID is what the other catalog modules grant roles
# to: key-vault and storage-account take a map of identity key to principal
# ID (this module's principal_ids output) so a cell names the identity by its
# key and holds no GUID. The client ID is what the workflow passes to
# azure/login as client-id; it is not secret, and it is an output here so the
# stack can print it for whoever fills in the repository variables.
#
# prevent_destroy is deliberately not set. Deleting an identity removes its
# role assignments and federated credentials with it and a workflow that
# used it stops at login, which is a failure that is visible at once and is
# undone by re-applying the cell (with a new principal ID, so grants made
# outside this repository need redoing). That is an outage, not a loss of
# data, and the two shapes that do hold data (key-vault, storage-account)
# carry the flag instead.
#
# The resource group is looked up by name and never created here. A stack
# that creates the group in the same plan (modules/azure/resource-group)
# gives this module depends_on on that module, and Terraform then reads the
# group during apply instead of at plan time.

# ---------------------------------------------------------------------------
# Resource groups. One lookup per distinct name.
# ---------------------------------------------------------------------------

locals {
  resource_group_names = toset([for i in var.identities : i.resource_group_name])
}

data "azurerm_resource_group" "this" {
  for_each = local.resource_group_names

  name = each.value
}

locals {
  locations = {
    for key, i in var.identities : key => coalesce(i.location, data.azurerm_resource_group.this[i.resource_group_name].location)
  }

  # Flattened "identity/credential" map so each credential is one addressable
  # resource, with the subject built from the GitHub context.
  federated_credentials = merge(concat([{}], [
    for identity_key, i in var.identities : {
      for credential_key, c in i.federated_credentials : "${identity_key}/${credential_key}" => {
        identity_key = identity_key
        name         = coalesce(c.name, credential_key)
        issuer       = c.issuer
        audience     = c.audience
        subject = (
          c.branch != null
          ? "repo:${c.organization}/${c.repository}:ref:refs/heads/${c.branch}"
          : "repo:${c.organization}/${c.repository}:environment:${c.environment}"
        )
      }
    }
  ])...)
}

# ---------------------------------------------------------------------------
# Identities.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.identities

  name                = each.value.name
  resource_group_name = data.azurerm_resource_group.this[each.value.resource_group_name].name
  location            = local.locations[each.key]
  tags                = merge(var.tags, each.value.tags)
}

# ---------------------------------------------------------------------------
# Federated credentials. One per (identity, GitHub context).
# ---------------------------------------------------------------------------

resource "azurerm_federated_identity_credential" "this" {
  for_each = local.federated_credentials

  name                      = each.value.name
  user_assigned_identity_id = azurerm_user_assigned_identity.this[each.value.identity_key].id
  issuer                    = each.value.issuer
  subject                   = each.value.subject
  audience                  = [each.value.audience]
}
