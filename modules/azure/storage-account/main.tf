# General-purpose storage accounts, one per map entry, hardened the same way
# whatever the values, with private containers and data-plane access granted
# by role name to identities and groups.
#
# This is the catalog's general-purpose account, distinct from backup-storage,
# which is one account with one container, one lifecycle rule, and one job
# in mind. What the two share is the posture, stated here once:
#
#   - No keys. shared_access_key_enabled = false, so the account refuses
#     Shared Key and SAS requests and every request carries an Entra token,
#     the same model as the Terraform state account (docs/adr/0004).
#     default_to_oauth_authentication makes the portal follow suit. With no
#     shared key there is no account SAS either, so nothing needs an
#     expiration policy.
#   - TLS 1.2 minimum, HTTPS only, no anonymous access on any container
#     (allow_nested_items_to_be_public = false, and every container here is
#     private), no cross-tenant object replication, copies only within the
#     tenant, no SFTP local users, no NFS.
#   - Infrastructure encryption on by default, so the service encrypts twice
#     with platform-managed keys. It is a create-time setting (changing it
#     replaces the account, which prevent_destroy refuses) and needs no key
#     vault; an entry that must not have it says so.
#   - A wrong delete is recoverable: blob soft delete and container soft
#     delete, each with its own retention, and blob versioning by default.
#     Versioning is refused together with a hierarchical namespace because
#     the platform does not support the pair; soft delete still applies.
#   - The firewall default action is Deny, always. public_network_access_enabled
#     is a bool that defaults to false, which refuses every public address;
#     when a cell turns it on, only allowed_ip_ranges and (with
#     trusted_services_bypass) the trusted Azure services get through. There
#     is no combination of values that opens the account to the internet.
#
# What is offered as values: replication, access tier, the two create-time
# switches (infrastructure encryption, hierarchical namespace), versioning
# and the retention periods, the firewall inputs above, a map of private
# containers, a Log Analytics workspace for the blob audit log, and the role
# assignments.
#
# Role assignments name a role, a principal, and optionally a container. The
# role is one of the Storage data-plane roles, or Reader, and nothing else: a
# cell cannot make anyone Owner, Contributor, or Storage Account Contributor
# of an account through this module. The principal is either an identity by
# its key in identity_principal_ids (the managed-identity module's
# principal_ids output, so the stack wires the two without a GUID) or an
# Entra security group by display name, resolved with azuread_group. With a
# container_key the assignment is scoped to that container, the way
# backup-storage scopes its writers, and must be a blob data role. A group
# assignment is standing access for the group's members; where that access
# should be just in time, name a PIM-governed group
# (stacks/entra-pim-governance) and let PIM for Groups gate the membership.
#
# The Log Analytics workspace is resolved by name in its resource group, so a
# cell names it and holds no workspace ID. The diagnostic setting sits on the
# blob service and sends StorageRead, StorageWrite, and StorageDelete, each
# with the caller's identity, plus transaction metrics. Nothing is sent when
# no workspace is named.
#
# What is deliberately not set here, and why each is a checkov skip with the
# same reason on the resource:
#
#   - Customer-managed keys (CKV2_AZURE_1). They need a key vault key, an
#     identity with wrap and unwrap, and a rotation story that the account
#     entry would have to name; the account encrypts at rest with
#     platform-managed keys and, by default, twice. Compose the key-vault
#     module and a later input when a tenant requires CMK.
#   - A private endpoint (CKV2_AZURE_33). It needs a virtual network and a
#     private DNS zone, neither of which this repository manages. The
#     boundary is a Deny firewall with public access off by default, Entra-
#     only authentication, and the audit log.
#   - Queue logging through queue_properties (CKV_AZURE_33). The classic
#     logging block is a data-plane write on an account with no shared key,
#     and the diagnostic setting is the current mechanism; it is on the blob
#     service here because blobs are what the catalog offers. Add a queue
#     service setting beside it when an entry starts to use queues.
#   - Blob read logging as checkov looks for it (CKV2_AZURE_21). The resource
#     it wants, azurerm_log_analytics_storage_insights, authenticates with a
#     storage account key, which this account does not have. The diagnostic
#     setting below sends the same reads to the same workspace.
#   - CKV_AZURE_59 and CKV_AZURE_206 are per-entry values (public access
#     false by default, replication GRS by default) that checkov cannot
#     resolve through a for_each and reports as set.
#
# The containers are created through the management plane (storage_account_id),
# so creating one needs no data-plane role and no network path for the apply
# identity. The account resource in azurerm 4.x still reads queue service
# properties and static website settings through the data plane unless the
# provider's storage.data_plane_available feature is false; with public
# access off, that read fails from outside the network. See README.
#
# The resource group is looked up by name and never created here. A stack
# that creates the group in the same plan (modules/azure/resource-group)
# gives this module depends_on on that module.

# ---------------------------------------------------------------------------
# Lookups. One per distinct resource group, workspace, and group name.
# ---------------------------------------------------------------------------

locals {
  resource_group_names = toset([for sa in var.storage_accounts : sa.resource_group_name])

  workspaces = {
    for key, sa in var.storage_accounts :
    "${sa.log_analytics_workspace.resource_group_name}/${sa.log_analytics_workspace.name}" => sa.log_analytics_workspace
    if sa.log_analytics_workspace != null
  }

  group_display_names = toset(flatten([
    for sa in var.storage_accounts : [for a in sa.role_assignments : a.principal.name if a.principal.type == "group"]
  ]))
}

data "azurerm_resource_group" "this" {
  for_each = local.resource_group_names

  name = each.value
}

data "azurerm_log_analytics_workspace" "this" {
  for_each = local.workspaces

  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}

# security_enabled narrows the match so a Microsoft 365 group with the same
# display name as a security group does not make the lookup ambiguous.
data "azuread_group" "by_display_name" {
  for_each = local.group_display_names

  display_name     = each.value
  security_enabled = true
}

locals {
  locations = {
    for key, sa in var.storage_accounts : key => coalesce(sa.location, data.azurerm_resource_group.this[sa.resource_group_name].location)
  }

  workspace_ids = {
    for key, sa in var.storage_accounts :
    key => data.azurerm_log_analytics_workspace.this["${sa.log_analytics_workspace.resource_group_name}/${sa.log_analytics_workspace.name}"].id
    if sa.log_analytics_workspace != null
  }

  # Flattened "account/container" map so each container is one addressable
  # resource.
  containers = merge(concat([{}], [
    for account_key, sa in var.storage_accounts : {
      for container_key, c in sa.containers : "${account_key}/${container_key}" => {
        account_key = account_key
        name        = c.name
        metadata    = c.metadata
      }
    }
  ])...)

  # Flattened "account/assignment" map. The principal ID is resolved here; a
  # missing identity key is caught by the precondition on the assignment so
  # the message names it.
  role_assignments = merge(concat([{}], [
    for account_key, sa in var.storage_accounts : {
      for assignment_key, a in sa.role_assignments : "${account_key}/${assignment_key}" => {
        account_key    = account_key
        assignment_key = assignment_key
        role_name      = a.role_name
        principal_type = a.principal.type
        principal_name = a.principal.name
        container_key  = a.container_key
        description    = a.description
        principal_id = (
          a.principal.type == "group"
          ? data.azuread_group.by_display_name[a.principal.name].object_id
          : lookup(var.identity_principal_ids, a.principal.name, null)
        )
      }
    }
  ])...)
}

# ---------------------------------------------------------------------------
# Accounts.
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "this" {
  # checkov:skip=CKV_AZURE_3:The check reads the azurerm 3.x attribute name
  # enable_https_traffic_only; this provider version spells it
  # https_traffic_only_enabled, and it is true below.
  # checkov:skip=CKV_AZURE_33:queue_properties logging is a data-plane write
  # on an account with no shared key, and the classic logging it configures
  # is superseded by diagnostic settings. The diagnostic setting here is on
  # the blob service, which is what the catalog offers; add a queue service
  # setting when an entry starts to use queues.
  # checkov:skip=CKV_AZURE_59:public_network_access_enabled is a per-entry
  # input that defaults to false; checkov cannot resolve a for_each value and
  # reports the attribute as set. A cell that turns it on admits only the
  # addresses it lists and the trusted services, behind a Deny default.
  # checkov:skip=CKV_AZURE_206:account_replication_type is a per-entry input
  # that defaults to GRS; checkov cannot resolve a for_each value. A cell
  # that picks LRS or ZRS does so in its diff.
  # checkov:skip=CKV2_AZURE_1:Customer-managed keys are an opt-in this module
  # does not ship: the entry would have to name a key, an identity with wrap
  # and unwrap, and a rotation. Data is encrypted at rest with platform-
  # managed keys, twice by default (infrastructure_encryption_enabled).
  # checkov:skip=CKV2_AZURE_33:No private endpoint is created here. It needs
  # a virtual network and a private DNS zone, neither of which this
  # repository manages; the boundary is a Deny firewall with public access
  # off by default, Entra-only authentication, and the audit log.
  for_each = var.storage_accounts

  name                = each.value.name
  resource_group_name = data.azurerm_resource_group.this[each.value.resource_group_name].name
  location            = local.locations[each.key]

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = each.value.account_replication_type
  access_tier              = each.value.access_tier

  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  allowed_copy_scope                = "AAD"
  local_user_enabled                = false
  sftp_enabled                      = false
  nfsv3_enabled                     = false
  infrastructure_encryption_enabled = each.value.infrastructure_encryption_enabled
  is_hns_enabled                    = each.value.hierarchical_namespace_enabled
  public_network_access_enabled     = each.value.public_network_access_enabled

  # Deny is the default action whatever the values. With public access off
  # the block is moot and stated anyway, so the posture is in the file a
  # reviewer reads; with public access on it is what keeps the account
  # closed to everything but the listed addresses and the trusted services.
  network_rules {
    default_action = "Deny"
    bypass         = each.value.trusted_services_bypass ? ["AzureServices"] : ["None"]
    ip_rules       = each.value.allowed_ip_ranges
  }

  blob_properties {
    versioning_enabled = each.value.blob_versioning_enabled

    delete_retention_policy {
      days = each.value.blob_soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = each.value.container_soft_delete_retention_days
    }
  }

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    # The account holds data other systems depend on, and two of its inputs
    # (infrastructure encryption, hierarchical namespace) replace it when
    # changed. Removing it is a deliberate change that flips this flag first,
    # never a side effect of dropping an entry or editing a create-time
    # setting in a cell.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Containers. Private, created through the management plane.
# ---------------------------------------------------------------------------

resource "azurerm_storage_container" "this" {
  # checkov:skip=CKV2_AZURE_21:Blob read logging is the diagnostic setting on
  # the blob service below, sent to the workspace the entry names. The
  # resource this check looks for, azurerm_log_analytics_storage_insights,
  # authenticates with a storage account key, which this account does not
  # have.
  for_each = local.containers

  name                  = each.value.name
  storage_account_id    = azurerm_storage_account.this[each.value.account_key].id
  container_access_type = "private"
  metadata              = length(each.value.metadata) > 0 ? each.value.metadata : null
}

# The container scope as Azure RBAC names it.
locals {
  container_scopes = {
    for key, c in azurerm_storage_container.this :
    key => "${azurerm_storage_account.this[local.containers[key].account_key].id}/blobServices/default/containers/${c.name}"
  }
}

# ---------------------------------------------------------------------------
# Blob audit log to Log Analytics, for the accounts that name a workspace.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "blob" {
  for_each = local.workspace_ids

  name                       = "log-analytics"
  target_resource_id         = "${azurerm_storage_account.this[each.key].id}/blobServices/default"
  log_analytics_workspace_id = each.value

  # Every data-plane call on the blob service with its caller, result, and
  # client address.
  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }
}

# ---------------------------------------------------------------------------
# Role assignments. Data-plane roles only, on the account or one container,
# by name.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope = (
    each.value.container_key == null
    ? azurerm_storage_account.this[each.value.account_key].id
    : local.container_scopes["${each.value.account_key}/${each.value.container_key}"]
  )
  role_definition_name = each.value.role_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type == "group" ? "Group" : "ServicePrincipal"
  description          = each.value.description

  # An identity created in the same plan may not have reached every Entra
  # replica when ARM checks it. The principal ID comes from the identity
  # resource, so skipping the lookup weakens nothing. Groups are looked up
  # by display name above, so they exist by definition.
  skip_service_principal_aad_check = each.value.principal_type == "identity"

  lifecycle {
    precondition {
      condition     = each.value.principal_id != null
      error_message = "Role assignment \"${each.value.assignment_key}\" on account \"${each.value.account_key}\": \"${each.value.principal_name}\" is not a key of identity_principal_ids. Pass the principal_ids output of modules/azure/managed-identity and name one of its keys, or use principal.type = \"group\" for an Entra group."
    }
  }
}
