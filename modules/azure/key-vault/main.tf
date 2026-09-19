# Key vaults, one per map entry, hardened the same way whatever the values,
# with data-plane access granted by role name to identities and groups.
#
# A vault in this module has one shape and a few knobs. What is fixed:
#
#   - Azure RBAC for data-plane authorization (rbac_authorization_enabled),
#     never access policies. Access policies are a second permission model
#     that lives inside the vault, is edited in the portal, and is invisible
#     to the role assignment reviews the rest of this repository relies on.
#     With RBAC, who can read a secret is an azurerm_role_assignment like
#     every other grant, and the entry below is the only way this module
#     writes one.
#   - Soft delete with a retention period, and purge protection. A deleted
#     vault, secret, or key can be recovered for soft_delete_retention_days,
#     and nothing, not even an Owner, can purge it early. Purge protection
#     cannot be turned off once on; that is what it is for.
#   - The firewall default action is Deny, always. public_network_access_enabled
#     is a bool that defaults to false, which refuses every public address;
#     when a cell turns it on, only allowed_ip_ranges and (with
#     trusted_services_bypass) the trusted Azure services get through. There
#     is no combination of values that opens the vault to the internet.
#   - No minimum TLS setting, because Key Vault has none to set: the service
#     requires TLS 1.2 on every request.
#
# What is offered as values: the SKU, the retention period, the three
# enabled_for_* switches (each is a service, not a person, and each is off
# by default), the firewall inputs above, a Log Analytics workspace for the
# audit log, and the role assignments.
#
# Role assignments name a role and a principal. The role is one of the Key
# Vault data-plane roles and nothing else: a cell cannot make anyone Owner
# or Contributor of a vault through this module, and cannot assign Key Vault
# Data Access Administrator, which assigns the other roles. The principal is
# either an identity by its key in identity_principal_ids (the managed-identity
# module's principal_ids output, so the stack wires the two without a GUID)
# or an Entra security group by display name, resolved with azuread_group. A
# group assignment is standing access for the group's members; where that
# access should be just in time, name a PIM-governed group
# (stacks/entra-pim-governance) and let PIM for Groups gate the membership.
# The assignment stays standing either way, which is the point: what the
# group may do is fixed here and reviewed here, and who is in it is the
# directory's business.
#
# The Log Analytics workspace is resolved by name in its resource group, so
# a cell names it and holds no workspace ID. The diagnostic setting sends
# AuditEvent, which records every data-plane operation with its caller, and
# all metrics. Nothing is sent when no workspace is named.
#
# prevent_destroy on the vault: it holds secrets and keys that other systems
# depend on, and though soft delete keeps a deleted vault recoverable, every
# consumer is broken until someone notices. Removing an entry from a cell
# must never be able to do that as a side effect.
#
# The resource group is looked up by name and never created here. A stack
# that creates the group in the same plan (modules/azure/resource-group)
# gives this module depends_on on that module.

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Lookups. One per distinct resource group, workspace, and group name.
# ---------------------------------------------------------------------------

locals {
  resource_group_names = toset([for kv in var.key_vaults : kv.resource_group_name])

  workspaces = {
    for key, kv in var.key_vaults :
    "${kv.log_analytics_workspace.resource_group_name}/${kv.log_analytics_workspace.name}" => kv.log_analytics_workspace
    if kv.log_analytics_workspace != null
  }

  group_display_names = toset(flatten([
    for kv in var.key_vaults : [for a in kv.role_assignments : a.principal.name if a.principal.type == "group"]
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
    for key, kv in var.key_vaults : key => coalesce(kv.location, data.azurerm_resource_group.this[kv.resource_group_name].location)
  }

  workspace_ids = {
    for key, kv in var.key_vaults :
    key => data.azurerm_log_analytics_workspace.this["${kv.log_analytics_workspace.resource_group_name}/${kv.log_analytics_workspace.name}"].id
    if kv.log_analytics_workspace != null
  }

  # Flattened "vault/assignment" map so each assignment is one addressable
  # resource. The principal ID is resolved here; a missing identity key is
  # caught by the precondition on the assignment so the message names it.
  role_assignments = merge(concat([{}], [
    for vault_key, kv in var.key_vaults : {
      for assignment_key, a in kv.role_assignments : "${vault_key}/${assignment_key}" => {
        vault_key      = vault_key
        assignment_key = assignment_key
        role_name      = a.role_name
        principal_type = a.principal.type
        principal_name = a.principal.name
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
# Vaults.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  # checkov:skip=CKV_AZURE_189:public_network_access_enabled is a per-entry
  # input that defaults to false; checkov cannot resolve a for_each value and
  # reports the attribute as set. A cell that turns it on admits only the
  # addresses it lists and the trusted services, behind a Deny default.
  # checkov:skip=CKV2_AZURE_32:No private endpoint is created here. A private
  # endpoint needs a virtual network and a private DNS zone, neither of which
  # this repository manages; the boundary is a Deny firewall with public
  # access off by default, RBAC-only authorization, and the audit log.
  for_each = var.key_vaults

  name                = each.value.name
  resource_group_name = data.azurerm_resource_group.this[each.value.resource_group_name].name
  location            = local.locations[each.key]
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = each.value.sku_name

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = each.value.soft_delete_retention_days

  public_network_access_enabled   = each.value.public_network_access_enabled
  enabled_for_deployment          = each.value.enabled_for_deployment
  enabled_for_disk_encryption     = each.value.enabled_for_disk_encryption
  enabled_for_template_deployment = each.value.enabled_for_template_deployment

  # Deny is the default action whatever the values. With public access off
  # the block is moot and stated anyway, so the posture is in the file a
  # reviewer reads; with public access on it is what keeps the vault closed
  # to everything but the listed addresses and the trusted services.
  network_acls {
    default_action = "Deny"
    bypass         = each.value.trusted_services_bypass ? "AzureServices" : "None"
    ip_rules       = each.value.allowed_ip_ranges
  }

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    # The vault holds secrets and keys other systems depend on. Removing it
    # is a deliberate change that flips this flag first, never a side effect
    # of dropping an entry from a cell.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Audit log to Log Analytics, for the vaults that name a workspace.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = local.workspace_ids

  name                       = "log-analytics"
  target_resource_id         = azurerm_key_vault.this[each.key].id
  log_analytics_workspace_id = each.value

  # Every data-plane call with its caller, result, and client address.
  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Role assignments. Data-plane roles only, on the vault, by name.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                = azurerm_key_vault.this[each.value.vault_key].id
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
      error_message = "Role assignment \"${each.value.assignment_key}\" on vault \"${each.value.vault_key}\": \"${each.value.principal_name}\" is not a key of identity_principal_ids. Pass the principal_ids output of modules/azure/managed-identity and name one of its keys, or use principal.type = \"group\" for an Entra group."
    }
  }
}
