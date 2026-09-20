# data-pipeline app stack
#
# One deployable unit for one data pipeline in one subscription: the resource
# group it lives in, the managed identity its GitHub workflow runs as, the
# vault that holds its secrets, and the data lake it reads from and writes to.
# Order of dependency:
#
#   resource group  -->  managed identity + GitHub federated credential
#                   -->  key vault   (identity: Key Vault Secrets User)
#                   -->  data lake   (identity: Storage Blob Data Contributor on raw and curated)
#                   -->  Reader on the resource group for the identity
#
# The group comes first because everything else is created in it and looks it
# up by name. The identity comes next because the three leaves grant it a
# role, and a role assignment needs a principal that exists. The leaves are
# independent of each other and Terraform applies them side by side.
#
# Why this is an app stack and not a catalog cell (docs/adr/0017). Each of
# the four shapes is in the catalog, and none of them is the point: the
# pipeline is the wiring between them. The Secrets User on the vault and the
# Blob Data Contributor on the containers are the identity created two lines
# up, the Reader is on the group created first, and the account, the vault,
# and the identity are named from one pair of words so they cannot drift
# apart. That is cross-resource wiring a catalog entry cannot express, and
# it is the same composition wherever the pipeline is deployed, so it is
# written once in this directory and a cell says only which pipeline, where, and from
# which repository. A second subscription is a second cell, not a second
# stack.
#
# Names are derived here, never typed. rg-<app>-<env>, id-<app>-<env>,
# kv-<app>-<env>, and st<app><env> (hyphens removed; storage allows none)
# all come from app_name and environment, and the validations on those two
# variables are what keep every derived name inside its service's limit: the
# vault's 24 characters is the tightest, and "kv-" + 12 + "-" + 8 fits it.
#
# What the identity may do, and no more. Key Vault Secrets User reads secret
# values by name; it cannot list, set, or delete them, and it holds nothing
# on keys or certificates. Storage Blob Data Contributor is granted on the
# raw and curated containers, not on the account, so a container added later
# is not the pipeline's until a change here says so. Reader on the group lets
# the identity resolve the vault and the account through the management
# plane, which every SDK and the Azure CLI do before a data-plane call, and
# grants no data action. Nothing here can grant a management-plane write
# role: the modules refuse Owner, Contributor, and the roles that assign
# roles, and this stack asks for none of them.
#
# Both data planes are closed by default. public_network_access_enabled is
# false on the vault and the lake unless allowed_ip_ranges lists addresses,
# in which case the same list opens both to exactly those addresses behind a
# Deny default. A GitHub-hosted runner has no fixed address; a pipeline that
# runs on one reaches nothing here, which is the intended outcome rather
# than a reason to open the firewall (see README).
#
# What a cell never sees: the identity's principal ID (wired to the vault
# and the lake as identity_principal_ids, by key), the group's resource ID
# (the scope of the Reader assignment), the tenant ID the vault is bound to
# (the key-vault module reads it from the provider), and the subscription
# (the locator, docs/adr/0017). No GUID exists in a cell.
#
# Deliberately NOT managed here: the Log Analytics workspace (named and
# resolved, never created); the secrets themselves (the vault starts empty,
# and the people who set the pipeline's secrets do so with their own
# PIM-activated access, not through this stack); private endpoints, virtual
# networks, and private DNS (this repository manages no network); the
# compute the pipeline runs on (Data Factory, Databricks, Functions, or a
# self-hosted runner) and the data in the lake; and a lifecycle rule on the
# containers, which is a later input once the pipeline's retention is known,
# never a hidden default.

locals {
  name_suffix = "${var.app_name}-${var.environment}"

  resource_group_name  = "rg-${local.name_suffix}"
  identity_name        = "id-${local.name_suffix}"
  key_vault_name       = "kv-${local.name_suffix}"
  storage_account_name = "st${replace(var.app_name, "-", "")}${var.environment}"

  # The GitHub environment the credential trusts: the cell's, or the
  # pipeline's own environment name when the cell does not say.
  github_environment = coalesce(var.github_environment, var.environment)

  # Public access is a consequence of listing addresses, never a separate
  # switch a cell could leave on with an empty list.
  public_network_access_enabled = length(var.allowed_ip_ranges) > 0

  # Every resource carries the pipeline's name and environment; the cell's
  # own tags are merged over them.
  tags = merge(
    {
      application = var.app_name
      environment = var.environment
    },
    var.tags,
  )
}
