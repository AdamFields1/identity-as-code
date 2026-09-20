# modules/azure/container-registry

Manages a map of container registries with one posture (no admin user, no
anonymous pull, Entra tokens on every request, platform encryption), the
Premium-only knobs behind validation (an IP allow list with a Deny default,
an untagged-manifest retention period, zone redundancy), optional audit
logging to a Log Analytics workspace named by the entry, and data-plane role
assignments by role name to managed identities (by key) or Entra security
groups (by display name).

## Design notes

- **The map key is a stable logical name** (`orders-api`). It is part of the
  Terraform address and should never change once applied; the visible name
  is `name`, which is also the registry's login server label
  (`<name>.azurecr.io`) and therefore globally unique: 5 to 50 letters and
  digits, nothing else.
- **No admin user, ever.** `admin_enabled` is fixed to false. The admin user
  is a username and two passwords that any holder can use from anywhere,
  that no Entra sign-in log records, and that a role assignment review
  cannot see. Every pull and push through this module is an Entra identity
  holding `AcrPull` or `AcrPush`, and `role_assignments` is the only way the
  module grants one.
- **No anonymous pull.** `anonymous_pull_enabled` is fixed to false. A
  registry that serves images to the world is a different product; this one
  serves its own workloads.
- **Reachable by identity only, by default.** `public_network_access_enabled`
  defaults to true, because Azure keeps the public login server on for Basic
  and Standard registries whatever the value, and because every request
  still carries an Entra token: a registry with no network rules is open to
  the internet in the sense that a login page is, and to nobody without a
  role. A Premium entry may set it to false, which refuses every public
  address and leaves only private endpoints, which this module does not
  create (a private endpoint needs a virtual network and a private DNS
  zone, neither of which this repository manages). Validation refuses false
  on the other SKUs so the plan fails with a message instead of the API.
- **The allow list is Premium only, and Deny by default.** `allowed_ip_ranges`
  writes a `network_rule_set` with `default_action = "Deny"` and one
  `ip_rule` per entry, so a registry with a list admits those addresses and
  the trusted Azure services and nothing else. Azure offers registry network
  rules on Premium only, so validation refuses the list on Basic and
  Standard, refuses it while public access is off (it would be silently
  ignored), refuses private ranges (the registry firewall refuses them), and
  refuses anything wider than /8. An entry with no list writes no rule set
  and keeps the platform default.
- **Untagged manifests can expire.** `retention_policy_in_days` (1 to 365,
  Premium only) tells the registry to delete a manifest that has had no tag
  for that long; the usual leftovers of a pipeline that pushes the same tag
  again. Null, the default, keeps every manifest.
- **Zone redundancy is a create-time choice.** `zone_redundancy_enabled`
  (Premium only) spreads the registry across availability zones and cannot
  be changed afterwards; changing it plans a replacement, which
  `prevent_destroy` refuses.
- **The export policy is left at the platform default.** Turning it off is
  accepted by Azure only with public network access off, which is the
  Premium private-endpoint posture above; an entry that reaches it asks for
  the knob then.
- **No customer-managed key.** The registry encrypts at rest with platform
  keys. A CMK needs a key vault key, an identity with wrap and unwrap, and a
  rotation story that the entry would have to name; compose the key-vault
  module and a later input when a tenant requires it.
- **Roles are a fixed menu.** `role_name` must be `AcrPull`, `AcrPush`,
  `AcrDelete`, or `AcrImageSigner`, the registry's data-plane roles. Owner,
  Contributor, Container Registry Contributor and Data Access Configuration
  Administrator, and the roles that assign roles are management-plane and
  cannot be granted through this module, which is the point of a catalog
  shape ([ADR 0017](../../../docs/adr/0017-three-kinds-of-stack.md)).
  `AcrPush` includes pull; a publisher needs one assignment, not two.
- **Principals are keys or names, never GUIDs.** An identity is named by its
  key in `identity_principal_ids`, which is the `principal_ids` output of
  `modules/azure/managed-identity`, so the stack wires the two and the cell
  says `{ type = "identity", name = "orders-api" }`. A group is named by
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
  set, a diagnostic setting sends `ContainerRegistryRepositoryEvents` (every
  push, pull, and delete with the identity that did it and the repository
  and tag it touched), `ContainerRegistryLoginEvents` (every login with its
  identity and result, including the failures), and all metrics to that
  workspace. When null, nothing is sent and nothing is created.
- **The registry is `prevent_destroy`.** It holds every image ever published
  to it, and the workloads that pull from it do not notice it is gone until
  they restart. Retiring it is a deliberate change that flips the flag
  first, never a side effect of dropping an entry from a cell.
- **The resource group is looked up by name.** A stack that creates it in the
  same plan (`modules/azure/resource-group`) gives this module
  `depends_on = [module.resource_groups]`.

## What checkov says, and what is skipped

`.github/workflows/azure-pr-validation.yml` runs checkov over the whole
repository with no `soft_fail`. This registry passes CKV_AZURE_137 (admin
user disabled), CKV_AZURE_138 (anonymous pull disabled), and CKV_AZURE_167
(a retention policy attribute is written; it takes effect on the Premium
entries that set it). Seven checks are skipped on the registry, each with
the same reason in an inline `checkov:skip` comment:

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AZURE_139` | Ensure ACR set to disable public networking | `public_network_access_enabled` is a per-entry input that defaults to `true` because Azure keeps the public login server on for Basic and Standard; every request still carries an Entra token. A Premium cell that turns it off does so in its diff and reaches the registry through a private endpoint this module does not create. |
| `CKV_AZURE_163` | Enable vulnerability scanning for container images | The check wants a literal `sku` of Standard or Premium (the Defender for Containers tiers). `sku` is a per-entry input that defaults to Standard, which checkov cannot resolve through a `for_each`. A cell that picks Basic does so in its diff. |
| `CKV_AZURE_164` | Ensures that ACR uses signed/trusted images | Content trust (`trust_policy_enabled`) is the Notary v1 signing model, which Azure has retired and which is Premium only. Image signing belongs to the publisher pipeline, and a signer's standing here is an `AcrImageSigner` assignment, not a registry flag. |
| `CKV_AZURE_165` | Ensure geo-replicated container registries | Geo-replication is a Premium-only, per-region cost that follows a multi-region deployment decision this catalog does not make for an app; a registry serves the region it is in. |
| `CKV_AZURE_166` | Ensure container image quarantine, scan, and mark images verified | The quarantine policy holds every pushed image until a scanner marks it, which needs the Defender quarantine workflow wired to the registry; the feature is in preview and not offered here. |
| `CKV_AZURE_233` | Ensure Azure Container Registry (ACR) is zone redundant | `zone_redundancy_enabled` is a per-entry input that defaults to `false` because Azure offers it on Premium only; a Premium cell that turns it on does so in its diff. |
| `CKV_AZURE_237` | Ensure dedicated data endpoints are enabled | Dedicated data endpoints are Premium only and change the host names every client firewall must allow; a cell that needs them raises the SKU and asks for the knob. |

## What the apply identity needs

Contributor (or Container Registry Contributor and Data Access Configuration
Administrator) on the resource group creates the registry and its diagnostic
setting; the diagnostic setting also needs Reader on the workspace, which
resolving it by name needs anyway. Writing a role assignment is
`Microsoft.Authorization/roleAssignments/write` at the registry, which
Contributor does not have (Role Based Access Control Administrator or User
Access Administrator on the resource group does). Resolving a group by
display name needs `Group.Read.All` or Directory Readers in Entra for a
workload identity; a signed-in person has it by default.

Three things a first apply should confirm: that an address in
`allowed_ip_ranges` given without a prefix is not returned by the API as
`/32` and shown as a diff on the next plan (write it the way the API returns
it if so); that an entry with no list and no `network_rule_set` written
shows no diff on the computed default after the first apply; and that the
tenant's Log Analytics workspace accepts the two log categories with
`enabled_metric` `AllMetrics` without a diff on
`log_analytics_destination_type`.

## Usage

```hcl
module "registries" {
  source = "../../modules/azure/container-registry"

  identity_principal_ids = module.identities.principal_ids

  container_registries = {
    orders-api = {
      name                = "crexampleordersapiprod"
      resource_group_name = "rg-example-orders-api-prod"

      log_analytics_workspace = {
        name                = "law-example-security"
        resource_group_name = "rg-example-monitoring"
      }

      role_assignments = {
        runtime-pulls = {
          role_name   = "AcrPull"
          principal   = { type = "identity", name = "orders-api" }
          description = "The Container App's identity pulls the image at start-up."
        }
        publisher-pushes = {
          role_name   = "AcrPush"
          principal   = { type = "identity", name = "orders-api-publisher" }
          description = "The GitHub release workflow pushes the image it built."
        }
        operators-delete = {
          role_name   = "AcrDelete"
          principal   = { type = "group", name = "Platform Operators" }
          description = "Operators remove a bad image; the group is PIM-governed."
        }
      }
    }

    office-ingress = {
      name                     = "crexampleofficeprod"
      resource_group_name      = "rg-example-orders-api-prod"
      sku                      = "Premium"
      allowed_ip_ranges        = ["203.0.113.0/24"]
      retention_policy_in_days = 30
      zone_redundancy_enabled  = true
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `container_registries` | `map(object)` | `{}` | Registries keyed by logical name: `name`, `resource_group_name`, `location`, `sku`, `public_network_access_enabled`, `allowed_ip_ranges`, `retention_policy_in_days`, `zone_redundancy_enabled`, `log_analytics_workspace`, `role_assignments`, `tags`. See `variables.tf`. |
| `identity_principal_ids` | `map(string)` | `{}` | Identity key to service principal object ID; the `principal_ids` output of `managed-identity`. |
| `tags` | `map(string)` | `{}` | Tags applied to every registry; an entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `container_registries` | Key to `{ id, name, login_server, sku, resource_group_name, location, public_network_access_enabled, diagnostics }`. |
| `container_registry_ids` | Key to registry resource ID. |
| `login_servers` | Key to the registry's login server (`<name>.azurecr.io`). |
| `login_servers_by_name` | Registry name to login server. |
| `role_assignment_ids` | `"<registry key>/<assignment key>"` to role assignment ID. |
| `role_assignments` | `"<registry key>/<assignment key>"` to `{ registry_key, role_name, principal_type, principal_name, principal_id }`. |
| `diagnostic_setting_ids` | Key to diagnostic setting ID, for the registries that name a workspace. |
| `group_object_ids` | Group display name to object ID, for every group named. |

## Import

```hcl
import {
  to = module.registries.azurerm_container_registry.this["orders-api"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-orders-api-prod/providers/Microsoft.ContainerRegistry/registries/crexampleordersapiprod"
}

import {
  to = module.registries.azurerm_monitor_diagnostic_setting.this["orders-api"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-orders-api-prod/providers/Microsoft.ContainerRegistry/registries/crexampleordersapiprod|log-analytics"
}

import {
  to = module.registries.azurerm_role_assignment.this["orders-api/runtime-pulls"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-orders-api-prod/providers/Microsoft.ContainerRegistry/registries/crexampleordersapiprod/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000000"
}
```

A registry adopted this way must already have the admin user off and
anonymous pull off; one with the admin user on plans it off, after which
anything that logged in with the admin password needs a role assignment
here before the apply. A registry whose `zone_redundancy_enabled` differs
from the entry plans a replacement, which `prevent_destroy` refuses; write
the entry the way the registry is.
