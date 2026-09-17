# modules/azure/backup-storage

A storage account and one private blob container for backups, reachable only
with Entra tokens, and Storage Blob Data Contributor on that container for the
identities that write the backups. Built for
`automation/runbooks/Backup-AutomationRunbooks.ps1`; nothing in it is specific
to runbooks.

## Design notes

- **No keys.** `shared_access_key_enabled = false`: the account refuses Shared
  Key and SAS requests, so every read and write carries an Entra token and is
  attributable to an identity, the same model as the Terraform state account
  ([ADR 0004](../../../docs/adr/0004-azure-storage-state-with-oidc.md)).
  `default_to_oauth_authentication` makes the portal use Entra too.
- **Transport and exposure.** TLS 1.2 minimum, HTTPS only, anonymous access
  disallowed on every container (`allow_nested_items_to_be_public = false`),
  the container itself `private`, no cross-tenant replication, copies only
  within the tenant (`allowed_copy_scope = "AAD"`), no SFTP local users.
- **Encrypted twice with platform keys.**
  `infrastructure_encryption_enabled = true` adds a second layer of
  service-managed encryption under the first. It is a create-time setting
  (changing it replaces the account) and needs no key vault, so it is on by
  default here rather than being an option nobody turns on.
- **Least privilege for the writers.** The data role is assigned at the
  container scope (`<account id>/blobServices/default/containers/<name>`), not
  the account, so a writer cannot see or touch anything else the account might
  hold. `writer_principal_ids` is a map, one entry per principal, because the
  caller knows which of its identities writes backups; the automation stack
  passes the tier of the runbook that asks for the storage names, and nobody
  else.
- **Recoverable deletes, and a floor under them.** Blob soft delete and
  container soft delete keep a deleted item for `retention_days` (default 14).
  Blob versioning is on, so the content of a blob that is deleted or
  overwritten survives as a previous version even after the soft-delete window
  closes, and `azurerm_storage_management_policy` deletes those versions
  `version_retention_days` (default 30) after the version was created. The
  lifecycle rule is what keeps the writer's own retention meaningful: without
  it, versioning would quietly keep every backup the runbook ever deleted. Set
  `version_retention_days` to at least the writer's `RetentionDays` when you
  want the two to agree. A time-based immutability policy is not set here; if
  one is added, its period must be shorter than the writer's retention, or
  retention deletes fail.
- **The account is `prevent_destroy`.** It holds the only copies of what it
  backs up. Retiring it is a deliberate change that flips the flag first,
  never a side effect of switching the feature off in a cell.
- **Public network access stays on by default.** Azure Automation cloud jobs
  have no fixed egress address and no virtual network, so there is nothing to
  put in a firewall rule. The boundary is Entra authentication plus the
  container-scoped role. Set `public_network_access_enabled = false` only when
  the writer runs on a Hybrid Runbook Worker that reaches a private endpoint.
- **The resource group is looked up by name**, like the Automation account's.

## What checkov says, and what is skipped

`.github/workflows/azure-pr-validation.yml` runs checkov over the whole
repository with no `soft_fail`, so every finding has to be either fixed or
skipped with a reason in the file. This account passes CKV_AZURE_44 (TLS 1.2),
CKV_AZURE_190 and CKV2_AZURE_47 (no anonymous blob access), CKV_AZURE_206
(geo-redundant by default), CKV_AZURE_244 (no local users), CKV2_AZURE_38
(soft delete), CKV2_AZURE_40 (no Shared Key authorization), CKV_AZURE_34 and
CKV2_AZURE_8 (the container is private), and CKV2_AZURE_41, whose first
condition is exactly "shared key access is disabled": with no Shared Key there
is no account SAS for an expiration policy to bound.

Five checks are skipped on the account and one on the container, each with the
same reason in an inline `checkov:skip` comment:

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AZURE_3` | Ensure that 'enable_https_traffic_only' is enabled | The check reads the azurerm 3.x attribute name. This provider version spells it `https_traffic_only_enabled`, which is set to `true`. |
| `CKV_AZURE_33` | Ensure Storage logging is enabled for Queue service for read, write and delete requests | There is no queue service to log. The writer uses blobs only, and `queue_properties` is a data-plane write on an account with no shared key. |
| `CKV_AZURE_35` | Ensure default network access rule for Storage Accounts is set to deny | The writer is an Azure Automation cloud job: no fixed egress address, no virtual network, and `Microsoft.Automation` appears on neither trusted-services table for the storage firewall (learn.microsoft.com, "Trusted Azure services for Azure Storage network security"). A `Deny` default would lock the backup out. The `network_rules` block states `Allow` explicitly so the posture is in the file. |
| `CKV_AZURE_59` | Ensure that Storage accounts disallow public access | The same reason; `public_network_access_enabled` is an input, set `false` where a Hybrid Runbook Worker and a private endpoint exist. |
| `CKV2_AZURE_1` | Ensure storage for critical data are encrypted with Customer Managed Key | Customer-managed keys are an opt-in this repository does not ship: no key vault, no key, no rotation. Data is encrypted at rest with platform-managed keys, twice. |
| `CKV2_AZURE_33` | Ensure storage account is configured with private endpoint | No private network path exists from the Automation sandbox to this account, as under `CKV_AZURE_35`. |
| `CKV2_AZURE_21` (container) | Ensure Storage logging is enabled for Blob service for read requests | Blob data-plane logging belongs in a diagnostic setting on the blob service, pointed at the workspace that already receives the Automation job streams. The resource this check looks for, `azurerm_log_analytics_storage_insights`, authenticates with a storage account key, which this account does not have. |

Two of those are worth re-reading whenever the deployment model changes: a
tenant that moves the backup onto a Hybrid Runbook Worker should delete the
`CKV_AZURE_35`, `CKV_AZURE_59`, and `CKV2_AZURE_33` skips, set
`public_network_access_enabled = false`, and add the private endpoint, because
the justification is about where the writer runs, not about the data.

## What the apply identity needs

Contributor on the resource group creates the account and, because the
container is created through the management plane (`storage_account_id`), the
container too. Assigning the writer role needs
`Microsoft.Authorization/roleAssignments/write` at the container, which
Contributor does not have (Role Based Access Control Administrator or User
Access Administrator on the resource group does).

One thing to confirm on the first apply: in azurerm 4.x the storage account
resource still reads queue service properties and static website settings
through the data plane unless the provider's `features { storage {
data_plane_available = false } }` is set. With `shared_access_key_enabled =
false` and `storage_use_azuread = true` (the Azure root sets it), that read
uses the apply identity's Entra token, so the apply identity may need a
data-plane read role on the account (for example Storage Queue Data Reader),
or the Terragrunt root may need that feature flag. A plan that fails with an
authorization error on a queue endpoint is this.

## Usage

```hcl
module "backup_storage" {
  source = "../../modules/azure/backup-storage"

  name                = "stexamplebackupscorp"
  resource_group_name = "rg-example-identity-automation"
  container_name      = "runbook-backups"

  writer_principal_ids = {
    observer = module.automation_account.identities["observer"].principal_id
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name` | `string` | n/a | Storage account name. |
| `resource_group_name` | `string` | n/a | Existing resource group, by name. |
| `location` | `string` | `null` | Region; null uses the resource group's. |
| `container_name` | `string` | `"runbook-backups"` | Private container name. |
| `account_replication_type` | `string` | `"GRS"` | Replication. |
| `retention_days` | `number` | `14` | Blob and container soft delete retention. |
| `version_retention_days` | `number` | `30` | Lifecycle deletion of previous blob versions. |
| `public_network_access_enabled` | `bool` | `true` | Public endpoint access. |
| `writer_principal_ids` | `map(string)` | n/a | Key to service principal object ID; each is granted Storage Blob Data Contributor on the container. |
| `tags` | `map(string)` | `{}` | Tags for the account. |

## Outputs

| Name | Description |
|------|-------------|
| `storage_account_id` | Account resource ID. |
| `storage_account_name` | Account name. |
| `container_name` | Container name. |
| `container_scope` | RBAC scope of the container. |
| `primary_blob_endpoint` | Blob endpoint. |
| `writer_role_assignment_ids` | Writer key to role assignment ID. |
| `management_policy_id` | Lifecycle management policy ID. |

## Import

```hcl
import {
  to = module.backup_storage.azurerm_storage_account.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Storage/storageAccounts/stexamplebackupscorp"
}

import {
  to = module.backup_storage.azurerm_storage_container.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Storage/storageAccounts/stexamplebackupscorp/blobServices/default/containers/runbook-backups"
}
```
