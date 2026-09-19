# modules/azure/key-vault

Manages a map of key vaults with one posture (RBAC authorization, soft delete
and purge protection, a Deny firewall with public access off by default),
optional audit logging to a Log Analytics workspace named by the entry, and
data-plane role assignments by role name to managed identities (by key) or
Entra security groups (by display name).

## Design notes

- **The map key is a stable logical name** (`rotation-secrets`). It is part of
  the Terraform address and should never change once applied; the visible
  name is `name`, which is also the vault's DNS label and therefore
  globally unique.
- **RBAC, never access policies.** `rbac_authorization_enabled` is fixed to
  true. Access policies are a second permission model that lives inside the
  vault, is edited in the portal, and is invisible to the role assignment
  reviews the rest of this repository relies on. With RBAC, who can read a
  secret is an `azurerm_role_assignment` like every other grant, and
  `role_assignments` is the only way this module writes one.
- **Recoverable, and unpurgeable.** Soft delete keeps a deleted vault,
  secret, key, or certificate recoverable for `soft_delete_retention_days`
  (7 to 90, default 90), and purge protection means nothing, not even an
  Owner, can purge it early. Purge protection cannot be turned off once on.
- **Closed by default.** The firewall default action is Deny whatever the
  values. `public_network_access_enabled` defaults to false, which refuses
  every public address and leaves only private endpoints (which this module
  does not create). Turning it on admits `allowed_ip_ranges` and, with
  `trusted_services_bypass`, the trusted Azure services list, and nothing
  else. Validation refuses an IP list while public access is off (it would
  be silently ignored) and refuses private ranges (Key Vault refuses them).
  There is no combination of values that opens a vault to the internet.
- **No TLS setting, because there is none.** Key Vault requires TLS 1.2 on
  every request; the storage account module sets `min_tls_version` because
  storage has the knob.
- **Roles are a fixed menu.** `role_name` must be one of the Key Vault
  data-plane roles (Administrator, Certificates Officer, Certificate User,
  Crypto Officer, Crypto Service Encryption User, Crypto Service Release
  User, Crypto User, Reader, Secrets Officer, Secrets User). Owner,
  Contributor, and Key Vault Contributor are management-plane roles, and Key
  Vault Data Access Administrator assigns the other roles; none of them can
  be granted through this module, which is the point of a catalog shape
  ([ADR 0017](../../../docs/adr/0017-three-kinds-of-stack.md)).
- **Principals are keys or names, never GUIDs.** An identity is named by its
  key in `identity_principal_ids`, which is the `principal_ids` output of
  `modules/azure/managed-identity`, so the stack wires the two and the cell
  says `{ type = "identity", name = "ci-deploy" }`. A group is named by
  display name and resolved with `azuread_group` (`security_enabled`, so a
  Microsoft 365 group with the same name does not make the lookup
  ambiguous). A misspelt identity key fails the plan with a precondition
  that names the assignment; a misspelt group fails the lookup.
- **A group assignment is standing access for the group's members.** Where
  that access should be just in time, name a PIM-governed group
  (`stacks/entra-pim-governance`) and let PIM for Groups gate the membership.
  The assignment stays standing either way, which is the point: what the
  group may do is fixed here and reviewed here, and who is in it is the
  directory's business (README, "Deliberately out of scope").
- **The audit log goes where the entry says.** `log_analytics_workspace` is
  `{ name, resource_group_name }`, resolved by name with a data source; when
  set, a diagnostic setting sends `AuditEvent` (every data-plane call with
  its caller, result, and client address) and all metrics to that workspace.
  When null, nothing is sent and nothing is created.
- **The vault is `prevent_destroy`.** It holds secrets and keys other systems
  depend on. Retiring it is a deliberate change that flips the flag first,
  never a side effect of dropping an entry from a cell.
- **The resource group is looked up by name.** A stack that creates it in the
  same plan (`modules/azure/resource-group`) gives this module
  `depends_on = [module.resource_groups]`.

## What checkov says, and what is skipped

`.github/workflows/azure-pr-validation.yml` runs checkov over the whole
repository with no `soft_fail`. This vault passes CKV_AZURE_42 and
CKV_AZURE_110 (purge protection and soft delete), and CKV_AZURE_109 (the
firewall default action is `Deny`). Two checks are skipped on the vault, each
with the same reason in an inline `checkov:skip` comment:

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AZURE_189` | Ensure that Azure Key Vault disables public network access | `public_network_access_enabled` is a per-entry input that defaults to `false`; checkov cannot resolve a `for_each` value and reports the attribute as set. A cell that turns it on admits only the addresses it lists and the trusted services, behind a `Deny` default, and does so in its diff. |
| `CKV2_AZURE_32` | Ensure private endpoint is used for Key Vault | No private endpoint is created here. It needs a virtual network and a private DNS zone, neither of which this repository manages. The boundary is a `Deny` firewall with public access off by default, RBAC-only authorization, and the audit log. |

## What the apply identity needs

Key Vault Contributor (or Contributor) on the resource group creates the
vault and its diagnostic setting; the diagnostic setting also needs Reader on
the workspace, which resolving it by name needs anyway. Writing a role
assignment is `Microsoft.Authorization/roleAssignments/write` at the vault,
which Contributor does not have (Role Based Access Control Administrator or
User Access Administrator on the resource group does). Resolving a group by
display name needs `Group.Read.All` or Directory Readers in Entra for a
workload identity; a signed-in person has it by default.

Two things a first apply should confirm: that an address in
`allowed_ip_ranges` given without a prefix is not returned by the API as
`/32` and shown as a diff on the next plan (write it the way the API returns
it if so), and that the tenant's Log Analytics workspace accepts the
`AuditEvent` category with `enabled_metric` `AllMetrics` without a diff on
`log_analytics_destination_type`.

## Usage

```hcl
module "vaults" {
  source = "../../modules/azure/key-vault"

  identity_principal_ids = module.identities.principal_ids

  key_vaults = {
    rotation-secrets = {
      name                = "kv-example-rotation"
      resource_group_name = "rg-example-identity"

      log_analytics_workspace = {
        name                = "law-example-security"
        resource_group_name = "rg-example-monitoring"
      }

      role_assignments = {
        rotation-job-writes = {
          role_name   = "Key Vault Secrets Officer"
          principal   = { type = "identity", name = "rotation-job" }
          description = "The rotation job writes the secrets it rotates."
        }
        ci-reads = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "ci-deploy" }
          description = "CI reads deployment secrets at release time."
        }
        operators-read = {
          role_name   = "Key Vault Reader"
          principal   = { type = "group", name = "Platform Operators" }
          description = "Operators list secrets and read metadata; the group is PIM-governed."
        }
      }
    }

    office-ingress = {
      name                          = "kv-example-office"
      resource_group_name           = "rg-example-identity"
      public_network_access_enabled = true
      allowed_ip_ranges             = ["203.0.113.0/24"]
      trusted_services_bypass       = false
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `key_vaults` | `map(object)` | `{}` | Vaults keyed by logical name: `name`, `resource_group_name`, `location`, `sku_name`, `soft_delete_retention_days`, `public_network_access_enabled`, `allowed_ip_ranges`, `trusted_services_bypass`, `enabled_for_*`, `log_analytics_workspace`, `role_assignments`, `tags`. See `variables.tf`. |
| `identity_principal_ids` | `map(string)` | `{}` | Identity key to service principal object ID; the `principal_ids` output of `managed-identity`. |
| `tags` | `map(string)` | `{}` | Tags applied to every vault; an entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `key_vaults` | Key to `{ id, name, vault_uri, resource_group_name, location, public_network_access_enabled, diagnostics }`. |
| `key_vault_ids` | Key to vault resource ID. |
| `vault_uris` | Key to the vault's data-plane URI. |
| `role_assignment_ids` | `"<vault key>/<assignment key>"` to role assignment ID. |
| `role_assignments` | `"<vault key>/<assignment key>"` to `{ vault_key, role_name, principal_type, principal_name, principal_id }`. |
| `diagnostic_setting_ids` | Key to diagnostic setting ID, for the vaults that name a workspace. |
| `group_object_ids` | Group display name to object ID, for every group named. |

## Import

```hcl
import {
  to = module.vaults.azurerm_key_vault.this["rotation-secrets"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.KeyVault/vaults/kv-example-rotation"
}

import {
  to = module.vaults.azurerm_monitor_diagnostic_setting.this["rotation-secrets"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.KeyVault/vaults/kv-example-rotation|log-analytics"
}

import {
  to = module.vaults.azurerm_role_assignment.this["rotation-secrets/ci-reads"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.KeyVault/vaults/kv-example-rotation/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000000"
}
```

A vault adopted this way must already use RBAC authorization and have purge
protection on; a vault with access policies plans a switch to RBAC, after
which the policies are ignored and every consumer needs a role assignment
here before the apply.
