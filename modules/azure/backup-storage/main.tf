# A storage account and one private blob container for backups, reachable
# only with Entra tokens, and a data-plane role on that container for the
# identities that write the backups.
#
# Built for automation/runbooks/Backup-AutomationRunbooks.ps1, which uploads
# each backup as a new, uniquely named blob with If-None-Match: * and prunes
# old ones under a strict prefix. What that runbook asks of its storage, and
# where each requirement lands here:
#
#   - No keys. shared_access_key_enabled = false, so the account refuses
#     Shared Key and SAS requests and every request carries an Entra token,
#     the same model as the Terraform state account (docs/adr/0004).
#     default_to_oauth_authentication makes the portal follow suit.
#   - TLS 1.2 minimum, HTTPS only, no anonymous access on any container,
#     no cross-tenant object replication, copies only within the tenant.
#   - Infrastructure encryption on, so the service encrypts twice with
#     platform-managed keys. It is a create-time setting (changing it
#     replaces the account) and needs no key vault, so it is on by default
#     rather than offered as an option nobody turns on.
#   - A wrong delete is recoverable: blob versioning, blob soft delete, and
#     container soft delete, retention_days each. Versioning keeps the
#     content of a deleted or overwritten blob as a previous version, which
#     the lifecycle rule below removes after the same number of days, so the
#     runbook's retention still means something and versions do not pile up.
#   - The writers can list, read, write, and delete blobs in the backup
#     container and nowhere else: Storage Blob Data Contributor at the
#     container scope, not the account, once per identity that needs it.
#
# What is deliberately not set here, and why each is a checkov skip with the
# same reason on the resource:
#
#   - Customer-managed keys (CKV2_AZURE_1). They need a key vault with purge
#     protection, a key, an identity with wrap and unwrap, and a rotation
#     story, none of which exist in this repository; the account already
#     encrypts at rest with platform-managed keys and now does it twice.
#     Pass a key vault key through a later input when a tenant requires CMK.
#   - A private endpoint (CKV2_AZURE_33) and a default-deny firewall
#     (CKV_AZURE_35, CKV_AZURE_59). Azure Automation cloud jobs run in a
#     shared sandbox with no fixed egress address and no virtual network, and
#     Microsoft.Automation is on neither trusted-services list for the
#     storage firewall (learn.microsoft.com, "Trusted Azure services for
#     Azure Storage network security"), so a default-deny account with no
#     private path would refuse the backup job itself. The boundary is
#     Entra-only authentication plus a container-scoped role. A tenant that
#     runs the backup on a Hybrid Runbook Worker inside a virtual network
#     sets public_network_access_enabled = false and adds a private endpoint
#     next to the worker.
#   - Queue logging (CKV_AZURE_33) and blob read logging (CKV2_AZURE_21).
#     The account has no queues and never will: the runbook uses blobs only.
#     Blob data-plane logging belongs in a diagnostic setting pointed at the
#     workspace that receives it, like the Automation account's, and the
#     resource checkov looks for (azurerm_log_analytics_storage_insights)
#     takes a storage account key, which this account does not have.
#   - A SAS expiration policy (CKV2_AZURE_41 passes here, no skip needed).
#     With shared_access_key_enabled = false the account issues no account
#     SAS at all, which is what the policy is for.
#
# The container is created through the management plane (storage_account_id),
# so creating it needs no data-plane role for the apply identity. The account
# resource in azurerm 4.x still reads queue service properties through the
# data plane unless the provider's storage.data_plane_available feature is
# false; see README.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  location = coalesce(var.location, data.azurerm_resource_group.this.location)
}

resource "azurerm_storage_account" "this" {
  # checkov:skip=CKV_AZURE_3:The check reads the azurerm 3.x attribute name
  # enable_https_traffic_only; this provider version spells it
  # https_traffic_only_enabled, and it is true below.
  # checkov:skip=CKV_AZURE_33:No queue service is used. The backup runbook
  # writes blobs only, no queue exists to log, and queue_properties would be
  # a data-plane write on an account with no shared key.
  # checkov:skip=CKV_AZURE_35:Default-deny needs a network path for the
  # writer. Azure Automation cloud jobs have no fixed egress address, no
  # virtual network, and Microsoft.Automation is not a trusted service for
  # the storage firewall, so a Deny default would lock the backup out. Entra
  # authentication and the container-scoped role are the boundary.
  # checkov:skip=CKV_AZURE_59:Same reason: the writer is an Azure Automation
  # cloud job reaching the public endpoint. public_network_access_enabled is
  # an input, set false where a Hybrid Runbook Worker and a private endpoint
  # exist.
  # checkov:skip=CKV2_AZURE_1:Customer-managed keys are an opt-in this
  # repository does not ship: there is no key vault, key, or rotation here.
  # Data is encrypted at rest with platform-managed keys, twice, because
  # infrastructure_encryption_enabled is true.
  # checkov:skip=CKV2_AZURE_33:No private endpoint, for the reason under
  # CKV_AZURE_35: the Automation sandbox has no private network path to this
  # account.
  name                = var.name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.account_replication_type
  access_tier              = "Hot"

  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  allowed_copy_scope                = "AAD"
  local_user_enabled                = false
  infrastructure_encryption_enabled = true
  public_network_access_enabled     = var.public_network_access_enabled

  # Stated rather than left to the provider default, so the posture is in the
  # file a reviewer reads. bypass has no effect while the default action is
  # Allow, and Azure Automation is not a trusted service, so switching this
  # to Deny without a private endpoint stops the backup.
  network_rules {
    default_action = "Allow"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.retention_days
    }

    container_delete_retention_policy {
      days = var.retention_days
    }
  }

  tags = var.tags

  lifecycle {
    # The account holds the only copies of what it backs up. Removing it is a
    # deliberate change that flips this flag first, never a side effect of
    # turning the feature off in a cell.
    prevent_destroy = true
  }
}

# Versioning keeps the content of every blob the backup runbook deletes, so
# without this rule the runbook's retention would free nothing and the
# account would grow forever. A version is deleted this many days after the
# version was created, which is the age of the backup it belongs to, so the
# rule and the runbook's RetentionDays agree when they carry the same number.
resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "expire-previous-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = var.version_retention_days
      }
    }
  }
}

resource "azurerm_storage_container" "this" {
  # checkov:skip=CKV2_AZURE_21:Blob read logging is a diagnostic setting on
  # the blob service, sent to the workspace that receives the Automation
  # account's job streams, and belongs with that workspace. The resource this
  # check looks for, azurerm_log_analytics_storage_insights, authenticates
  # with a storage account key, which this account does not have.
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# The container scope as Azure RBAC names it.
locals {
  container_scope = "${azurerm_storage_account.this.id}/blobServices/default/containers/${azurerm_storage_container.this.name}"
}

resource "azurerm_role_assignment" "writer" {
  for_each = var.writer_principal_ids

  scope                = local.container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
  description          = "Writes and prunes backups in this container (${each.key}). Managed by Terraform."

  # The writer is usually a managed identity created in the same plan.
  skip_service_principal_aad_check = true
}
