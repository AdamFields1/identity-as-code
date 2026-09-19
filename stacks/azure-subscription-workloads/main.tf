# azure-subscription-workloads stack
#
# The Azure catalog stack (docs/adr/0017). One deployable unit per
# subscription that offers the vetted shapes a workload asks for, as values:
# a resource group, a keyless workload identity, a hardened key vault, a
# hardened storage account. A subscription gets any of them by adding an
# entry to its cell; nobody writes Terraform, and nobody can loosen the
# shape, because the guardrails are in the modules and the cell only picks
# from the menu. Order of dependency:
#
#   resource groups  -->  managed identities  -->  key vaults
#                                              -->  storage accounts
#
# The groups come first because every other shape is created in one of them,
# and the identities before the vaults and accounts because a role
# assignment on a vault or a container names an identity by its key and
# needs its principal ID. The vaults and accounts are independent of each
# other and Terraform applies them side by side.
#
# What this stack wires, so a cell never holds an ID:
#
#   - Every identity, vault, and account names its resource group by that
#     group's key in resource_groups (resource_group_key). The stack turns
#     the key into the group's name for the module, which looks the group up
#     by name; depends_on on the group module defers that lookup to apply on
#     the plan that creates the group, so the first plan does not fail on a
#     group that does not exist yet. The name comes from the same entry the
#     group module creates, so the two cannot disagree.
#   - A role assignment names an identity by its key in identities. The stack
#     passes the identity module's principal_ids map to the vault and storage
#     modules, which resolve the key to the service principal's object ID.
#     A group is named by display name and resolved inside those modules.
#   - Every key is checked in variables.tf before any module runs, so a
#     misspelt resource_group_key or identity key fails with a message that
#     names the cell rather than a module address.
#
# The subscription itself is not an input. tenants/azure/root.hcl reads it
# from the cell's subscription.hcl locator and points the azurerm provider at
# it; the stack discovers it with data.azurerm_client_config where a module
# needs it (the key-vault module, for the vault's tenant). Nothing here can
# be aimed at another subscription by editing a value.
#
# What the catalog refuses to offer, and why (docs/adr/0017): a passthrough
# of provider attributes, an arbitrary role name, a management-plane or
# role-granting role, a principal by GUID, a resource group this cell does
# not own, and any composition where one entry's output is another entry's
# input beyond the identity-to-role wiring above. A workload that needs a
# trust relationship the menu cannot say, or the same composition in more
# than one subscription, is an app stack with its own cells, not a longer
# entry here.
#
# Deliberately NOT managed here: the subscription and its management group
# (platform bootstrap; the stack resolves nothing above the resource group),
# private endpoints and the networks they need, customer-managed keys,
# Entra groups and their membership (named, never created), the Log
# Analytics workspaces the audit logs go to (named, never created), and
# standing role assignments for people: a group assignment here is standing
# access for the group's members, and where that access should be just in
# time the group is a PIM-governed one from stacks/entra-pim-governance.

# ---------------------------------------------------------------------------
# Keys to names. The modules take a resource group by name and an identity
# by principal ID; the cell gives keys. Every attribute is passed through
# explicitly so the module shape stays the contract and a new module input
# is a visible change here, not a silent default.
# ---------------------------------------------------------------------------

locals {
  resource_groups = {
    for key, rg in var.resource_groups : key => {
      name        = rg.name
      location    = rg.location != null ? rg.location : var.location
      tags        = rg.tags
      delete_lock = rg.delete_lock
      lock_notes  = rg.lock_notes
    }
  }

  # The group's name from the entry the group module creates it from. Known
  # at plan time, which the modules' lookups need for their for_each keys.
  resource_group_names = { for key, rg in var.resource_groups : key => rg.name }

  identities = {
    for key, i in var.identities : key => {
      name                  = i.name
      resource_group_name   = local.resource_group_names[i.resource_group_key]
      location              = i.location
      tags                  = i.tags
      federated_credentials = i.federated_credentials
    }
  }

  key_vaults = {
    for key, kv in var.key_vaults : key => {
      name                            = kv.name
      resource_group_name             = local.resource_group_names[kv.resource_group_key]
      location                        = kv.location
      sku_name                        = kv.sku_name
      soft_delete_retention_days      = kv.soft_delete_retention_days
      public_network_access_enabled   = kv.public_network_access_enabled
      allowed_ip_ranges               = kv.allowed_ip_ranges
      trusted_services_bypass         = kv.trusted_services_bypass
      enabled_for_deployment          = kv.enabled_for_deployment
      enabled_for_disk_encryption     = kv.enabled_for_disk_encryption
      enabled_for_template_deployment = kv.enabled_for_template_deployment
      log_analytics_workspace         = kv.log_analytics_workspace
      role_assignments                = kv.role_assignments
      tags                            = kv.tags
    }
  }

  storage_accounts = {
    for key, sa in var.storage_accounts : key => {
      name                                 = sa.name
      resource_group_name                  = local.resource_group_names[sa.resource_group_key]
      location                             = sa.location
      account_replication_type             = sa.account_replication_type
      access_tier                          = sa.access_tier
      infrastructure_encryption_enabled    = sa.infrastructure_encryption_enabled
      hierarchical_namespace_enabled       = sa.hierarchical_namespace_enabled
      blob_versioning_enabled              = sa.blob_versioning_enabled
      blob_soft_delete_retention_days      = sa.blob_soft_delete_retention_days
      container_soft_delete_retention_days = sa.container_soft_delete_retention_days
      public_network_access_enabled        = sa.public_network_access_enabled
      allowed_ip_ranges                    = sa.allowed_ip_ranges
      trusted_services_bypass              = sa.trusted_services_bypass
      containers                           = sa.containers
      role_assignments                     = sa.role_assignments
      log_analytics_workspace              = sa.log_analytics_workspace
      tags                                 = sa.tags
    }
  }
}

# ---------------------------------------------------------------------------
# Resource groups first. Everything else is created in one of them.
# ---------------------------------------------------------------------------

module "resource_groups" {
  source = "../../modules/azure/resource-group"

  resource_groups = local.resource_groups
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Identities. Their principal IDs are what the vaults and accounts grant
# roles to.
# ---------------------------------------------------------------------------

module "identities" {
  source = "../../modules/azure/managed-identity"

  identities = local.identities
  tags       = var.tags

  # The module looks its resource groups up by name. They are created in
  # this plan, so the read is deferred to apply on the plan that creates
  # them, and the identity's location shows as known after apply that once.
  depends_on = [module.resource_groups]
}

# ---------------------------------------------------------------------------
# Key vaults and storage accounts, side by side. Each takes the identity
# map so a role assignment can name an identity by key.
# ---------------------------------------------------------------------------

module "key_vaults" {
  source = "../../modules/azure/key-vault"

  key_vaults             = local.key_vaults
  identity_principal_ids = module.identities.principal_ids
  tags                   = var.tags

  depends_on = [module.resource_groups]
}

module "storage_accounts" {
  source = "../../modules/azure/storage-account"

  storage_accounts       = local.storage_accounts
  identity_principal_ids = module.identities.principal_ids
  tags                   = var.tags

  depends_on = [module.resource_groups]
}
