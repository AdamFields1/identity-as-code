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
# written once here and a cell says only which pipeline, where, and from
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

# ---------------------------------------------------------------------------
# The resource group. Everything below is created in it and looks it up by
# name, so the modules below carry depends_on on this one: Terraform then
# reads the group during apply on the first run, when it does not exist at
# plan time, and at plan time on every run after.
# ---------------------------------------------------------------------------

module "resource_groups" {
  source = "../../../../modules/azure/resource-group"

  tags = local.tags

  resource_groups = {
    app = {
      name        = local.resource_group_name
      location    = var.location
      delete_lock = var.delete_lock
    }
  }
}

# ---------------------------------------------------------------------------
# The identity and the one GitHub context that may obtain a token for it.
# The resource group is passed by the same name the group was created from:
# the name is known at plan time, so the module can key its lookup on it,
# while depends_on defers the read itself until the group exists.
# ---------------------------------------------------------------------------

module "identities" {
  source = "../../../../modules/azure/managed-identity"

  tags = local.tags

  identities = {
    pipeline = {
      name                = local.identity_name
      resource_group_name = local.resource_group_name

      federated_credentials = {
        github = {
          organization = var.github_organization
          repository   = var.github_repository
          environment  = local.github_environment
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}

# ---------------------------------------------------------------------------
# The vault. Secrets User for the identity, and nothing for anyone else: the
# people who set secrets bring their own PIM-activated access.
# ---------------------------------------------------------------------------

module "key_vaults" {
  source = "../../../../modules/azure/key-vault"

  tags                   = local.tags
  identity_principal_ids = module.identities.principal_ids

  key_vaults = {
    secrets = {
      name                          = local.key_vault_name
      resource_group_name           = local.resource_group_name
      public_network_access_enabled = local.public_network_access_enabled
      allowed_ip_ranges             = var.allowed_ip_ranges
      log_analytics_workspace       = var.log_analytics_workspace

      role_assignments = {
        pipeline-reads-secrets = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "pipeline" }
          description = "The ${var.app_name} pipeline reads its secrets by name at run time. Read only: it cannot list, set, or delete them."
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}

# ---------------------------------------------------------------------------
# The lake. A hierarchical-namespace account (so versioning is off, which the
# module requires stated rather than assumed), two private containers, and
# Blob Data Contributor for the identity on each container, never on the
# account.
# ---------------------------------------------------------------------------

module "storage" {
  source = "../../../../modules/azure/storage-account"

  tags                   = local.tags
  identity_principal_ids = module.identities.principal_ids

  storage_accounts = {
    lake = {
      name                           = local.storage_account_name
      resource_group_name            = local.resource_group_name
      hierarchical_namespace_enabled = true
      blob_versioning_enabled        = false
      public_network_access_enabled  = local.public_network_access_enabled
      allowed_ip_ranges              = var.allowed_ip_ranges
      log_analytics_workspace        = var.log_analytics_workspace

      containers = {
        raw     = { name = "raw" }
        curated = { name = "curated" }
      }

      role_assignments = {
        pipeline-writes-raw = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "pipeline" }
          container_key = "raw"
          description   = "The ${var.app_name} pipeline lands source data in raw. Container scope: the account's other containers are not its to write."
        }
        pipeline-writes-curated = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "pipeline" }
          container_key = "curated"
          description   = "The ${var.app_name} pipeline writes its output to curated. Container scope: the account's other containers are not its to write."
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}

# ---------------------------------------------------------------------------
# Reader on the group, so the identity can resolve the vault and the account
# through the management plane before it talks to either data plane. The
# scope is the group's ID from the module above (the resource_id scope type
# exists for exactly this: a resource created in the same plan), so the cell
# holds no ID and the assignment cannot point anywhere else.
# ---------------------------------------------------------------------------

module "identity_rbac" {
  source = "../../../../modules/azure/workload-role-assignment"

  principal_id = module.identities.principal_ids["pipeline"]

  assignments = {
    reader-on-resource-group = {
      role_name   = "Reader"
      scope       = { type = "resource_id", name = module.resource_groups.resource_group_ids["app"] }
      description = "The ${var.app_name} pipeline resolves its vault and its lake through the management plane. Read only, no data action."
    }
  }
}
