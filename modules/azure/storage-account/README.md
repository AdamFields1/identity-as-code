# modules/azure/storage-account

Manages a map of general-purpose storage accounts with one posture (no
shared keys, TLS 1.2, HTTPS only, no anonymous blobs, versioning and soft
delete, infrastructure encryption, a Deny firewall with public access off by
default), private containers as a nested map, optional blob audit logging to a
Log Analytics workspace named by the entry, and data-plane role assignments by
role name to managed identities (by key) or Entra security groups (by display
name), at the account or at one container.

It is distinct from `modules/azure/backup-storage`, which is one account, one
container, and one lifecycle rule built for the runbook backup job. The
posture is the same; the shape here is the catalog's.

## Design notes

- **The map key is a stable logical name** (`app-artifacts`). It is part of
  the Terraform address and should never change once applied; the visible
  name is `name`, which is also a global DNS label.
- **No keys.** `shared_access_key_enabled = false`: the account refuses Shared
  Key and SAS requests, so every read and write carries an Entra token and is
  attributable to an identity, the same model as the Terraform state account
  ([ADR 0004](../../../docs/adr/0004-azure-storage-state-with-oidc.md)).
  `default_to_oauth_authentication` makes the portal use Entra too. With no
  shared key there is no account SAS, so nothing needs an expiration policy.
- **Transport and exposure.** TLS 1.2 minimum, HTTPS only, anonymous access
  disallowed on every container (`allow_nested_items_to_be_public = false`,
  and every container here is `private`), no cross-tenant replication, copies
  only within the tenant (`allowed_copy_scope = "AAD"`), no SFTP local users,
  no NFS.
- **Closed by default.** The firewall default action is Deny whatever the
  values. `public_network_access_enabled` defaults to false, which refuses
  every public address and leaves only private endpoints (which this module
  does not create). Turning it on admits `allowed_ip_ranges` and, with
  `trusted_services_bypass`, the trusted Azure services list, and nothing
  else. Validation refuses an IP list while public access is off, refuses
  private ranges, and refuses `/31` and `/32` prefixes, all of which the
  storage firewall itself refuses or ignores.
- **Encrypted twice with platform keys, by default.**
  `infrastructure_encryption_enabled` is a bool that defaults to true. It is
  a create-time setting: changing it replaces the account, which
  `prevent_destroy` refuses, so decide it when the entry is written.
- **Recoverable deletes.** Blob soft delete and container soft delete keep a
  deleted item for their own retention (default 14 days each), and blob
  versioning (default on) keeps the content of every overwritten or deleted
  blob as a previous version. Versioning is not supported on an account with
  a hierarchical namespace, so a data lake entry sets
  `blob_versioning_enabled = false` explicitly rather than having the module
  drop it quietly; soft delete still applies. No lifecycle rule expires old
  versions here; an entry that churns data needs one, and that is a later
  input rather than a hidden default.
- **Data Lake is a bool.** `hierarchical_namespace_enabled = true` makes the
  account a Data Lake Storage Gen2 account (directories, POSIX ACLs, the
  `dfs` endpoint, which `primary_dfs_endpoint` outputs). Turning it on for an
  existing account is an in-place migration the provider drives; turning it
  off replaces the account, which `prevent_destroy` refuses.
- **Containers are a nested map, and all private.** Each entry's `containers`
  map is keyed by a stable name and holds the container name and optional
  metadata. They are created through the management plane
  (`storage_account_id`), so the apply identity needs no data-plane role and
  no network path to create one.
- **Roles are a fixed menu.** `role_name` must be Reader or one of the
  Storage data-plane roles (Blob, Queue, Table, and File). Owner,
  Contributor, and Storage Account Contributor are management-plane roles
  and cannot be granted here ([ADR 0017](../../../docs/adr/0017-three-kinds-of-stack.md)).
  With a `container_key` the assignment is scoped to that container, the way
  `backup-storage` scopes its writers, and must be a Storage Blob Data role;
  without one it is scoped to the account.
- **Principals are keys or names, never GUIDs.** An identity is named by its
  key in `identity_principal_ids`, which is the `principal_ids` output of
  `modules/azure/managed-identity`; a group by display name, resolved with
  `azuread_group` (`security_enabled`). A misspelt identity key fails the
  plan with a precondition that names the assignment. A group assignment is
  standing access for the group's members; where that should be just in
  time, name a PIM-governed group (`stacks/entra-pim-governance`).
- **The audit log goes where the entry says.** `log_analytics_workspace` is
  `{ name, resource_group_name }`, resolved by name; when set, a diagnostic
  setting on the blob service sends `StorageRead`, `StorageWrite`, and
  `StorageDelete` (each with the caller's identity) and `Transaction` metrics
  to it. When null, nothing is sent and nothing is created.
- **The account is `prevent_destroy`.** It holds data other systems depend on,
  and two of its inputs replace it when changed. Retiring it is a deliberate
  change that flips the flag first.
- **The resource group is looked up by name.** A stack that creates it in the
  same plan (`modules/azure/resource-group`) gives this module
  `depends_on = [module.resource_groups]`.

## What checkov says, and what is skipped

`.github/workflows/azure-pr-validation.yml` runs checkov over the whole
repository with no `soft_fail`, so every finding has to be either fixed or
skipped with a reason in the file. This account passes CKV_AZURE_44 (TLS
1.2), CKV_AZURE_190 and CKV2_AZURE_47 (no anonymous blob access),
CKV_AZURE_244 (no local users), CKV2_AZURE_38 (soft delete), CKV2_AZURE_40
(no Shared Key authorization), CKV_AZURE_35 (the firewall default action is
`Deny`), CKV_AZURE_34 and CKV2_AZURE_8 (every container is private), and
CKV2_AZURE_41, whose first condition is exactly "shared key access is
disabled".

Six checks are skipped on the account and one on the container, each with the
same reason in an inline `checkov:skip` comment:

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AZURE_3` | Ensure that 'enable_https_traffic_only' is enabled | The check reads the azurerm 3.x attribute name. This provider version spells it `https_traffic_only_enabled`, which is set to `true`. |
| `CKV_AZURE_33` | Ensure Storage logging is enabled for Queue service for read, write and delete requests | `queue_properties` logging is a data-plane write on an account with no shared key, and the classic logging it configures is superseded by diagnostic settings. The diagnostic setting here is on the blob service, which is what the catalog offers; add a queue service setting beside it when an entry starts to use queues. |
| `CKV_AZURE_59` | Ensure that Storage accounts disallow public access | `public_network_access_enabled` is a per-entry input that defaults to `false`; checkov cannot resolve a `for_each` value and reports the attribute as set. A cell that turns it on admits only the addresses it lists and the trusted services, behind a `Deny` default, and does so in its diff. |
| `CKV_AZURE_206` | Ensure that Storage Accounts use replication | `account_replication_type` is a per-entry input that defaults to `GRS`; checkov cannot resolve a `for_each` value. A cell that picks `LRS` or `ZRS` does so in its diff. |
| `CKV2_AZURE_1` | Ensure storage for critical data are encrypted with Customer Managed Key | Customer-managed keys are an opt-in this module does not ship: the entry would have to name a key, an identity with wrap and unwrap, and a rotation. Data is encrypted at rest with platform-managed keys, twice by default. |
| `CKV2_AZURE_33` | Ensure storage account is configured with private endpoint | No private endpoint is created here. It needs a virtual network and a private DNS zone, neither of which this repository manages. The boundary is a `Deny` firewall with public access off by default, Entra-only authentication, and the audit log. |
| `CKV2_AZURE_21` (container) | Ensure Storage logging is enabled for Blob service for read requests | Blob read logging is the diagnostic setting on the blob service, sent to the workspace the entry names. The resource this check looks for, `azurerm_log_analytics_storage_insights`, authenticates with a storage account key, which this account does not have. |

## What the apply identity needs

Contributor on the resource group creates the account, its containers
(management plane), and the diagnostic setting; the diagnostic setting also
needs Reader on the workspace, which resolving it by name needs anyway.
Writing a role assignment is `Microsoft.Authorization/roleAssignments/write`
at the account or container, which Contributor does not have (Role Based
Access Control Administrator or User Access Administrator on the resource
group does). Resolving a group by display name needs `Group.Read.All` or
Directory Readers in Entra for a workload identity.

One provider behaviour the root handles, the same as for `backup-storage`:
in azurerm 4.x the storage account resource still reads queue service
properties and static website settings through the data plane unless the
provider's `features { storage { data_plane_available = false } }` is set.
With public network access off and a `Deny` firewall, that read fails from a
runner outside the network, with an authorization or connectivity error on a
queue or web endpoint. `tenants/azure/root.hcl` sets that flag in the
generated provider for every cell, because the release train applies from
GitHub-hosted runners and no module in this repository manages
`queue_properties` or `static_website`. A caller that uses this module
outside that root sets the flag itself, or plans from a runner that reaches
the account privately.

## Usage

```hcl
module "storage" {
  source = "../../modules/azure/storage-account"

  identity_principal_ids = module.identities.principal_ids

  storage_accounts = {
    app-artifacts = {
      name                = "stexampleartifacts"
      resource_group_name = "rg-example-app"

      containers = {
        releases = { name = "releases" }
        logs     = { name = "build-logs" }
      }

      role_assignments = {
        ci-writes-releases = {
          role_name     = "Storage Blob Data Contributor"
          principal     = { type = "identity", name = "ci-deploy" }
          container_key = "releases"
          description   = "CI publishes release artifacts and nothing else."
        }
        engineers-read = {
          role_name   = "Storage Blob Data Reader"
          principal   = { type = "group", name = "Cloud Engineers" }
          description = "Engineers read artifacts and logs; the group is PIM-governed."
        }
      }

      log_analytics_workspace = {
        name                = "law-example-security"
        resource_group_name = "rg-example-monitoring"
      }
    }

    analytics-lake = {
      name                           = "stexamplelake"
      resource_group_name            = "rg-example-data"
      hierarchical_namespace_enabled = true
      blob_versioning_enabled        = false
      account_replication_type       = "ZRS"
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `storage_accounts` | `map(object)` | `{}` | Accounts keyed by logical name: `name`, `resource_group_name`, `location`, `account_replication_type`, `access_tier`, `infrastructure_encryption_enabled`, `hierarchical_namespace_enabled`, `blob_versioning_enabled`, `blob_soft_delete_retention_days`, `container_soft_delete_retention_days`, `public_network_access_enabled`, `allowed_ip_ranges`, `trusted_services_bypass`, `containers`, `role_assignments`, `log_analytics_workspace`, `tags`. See `variables.tf`. |
| `identity_principal_ids` | `map(string)` | `{}` | Identity key to service principal object ID; the `principal_ids` output of `managed-identity`. |
| `tags` | `map(string)` | `{}` | Tags applied to every account; an entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `storage_accounts` | Key to `{ id, name, resource_group_name, location, primary_blob_endpoint, primary_dfs_endpoint, hierarchical_namespace_enabled, public_network_access_enabled, diagnostics }`. |
| `storage_account_ids` | Key to account resource ID. |
| `primary_blob_endpoints` | Key to blob endpoint. |
| `containers` | `"<account key>/<container key>"` to `{ id, name, account_key, scope }`. |
| `role_assignment_ids` | `"<account key>/<assignment key>"` to role assignment ID. |
| `role_assignments` | `"<account key>/<assignment key>"` to `{ account_key, container_key, role_name, principal_type, principal_name, principal_id, scope }`. |
| `diagnostic_setting_ids` | Key to the blob service diagnostic setting ID, for the accounts that name a workspace. |
| `group_object_ids` | Group display name to object ID, for every group named. |

## Import

```hcl
import {
  to = module.storage.azurerm_storage_account.this["app-artifacts"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-app/providers/Microsoft.Storage/storageAccounts/stexampleartifacts"
}

import {
  to = module.storage.azurerm_storage_container.this["app-artifacts/releases"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-app/providers/Microsoft.Storage/storageAccounts/stexampleartifacts/blobServices/default/containers/releases"
}

import {
  to = module.storage.azurerm_monitor_diagnostic_setting.blob["app-artifacts"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-app/providers/Microsoft.Storage/storageAccounts/stexampleartifacts/blobServices/default|log-analytics"
}
```

An account adopted this way must already have shared key access disabled and
infrastructure encryption in the state the entry declares; the first is a
one-line diff the plan shows, the second is a replacement the plan refuses.
