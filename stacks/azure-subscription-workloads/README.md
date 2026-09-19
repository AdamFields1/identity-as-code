# stacks/azure-subscription-workloads

The Azure catalog stack: the deployable unit for the one-off resources a
subscription asks for, offered as values from a menu of vetted shapes. It
composes four modules, in order, into one plan and one state file per
subscription:

1. `resource-group` creates the resource groups the cell owns, each with an
   optional CanNotDelete lock.
2. `managed-identity` creates user-assigned identities in those groups, with
   the GitHub Actions federated credentials that may obtain a token for each.
3. `key-vault` creates hardened vaults in those groups and grants data-plane
   roles on them to the identities (by key) or to Entra groups (by name).
4. `storage-account` creates hardened accounts and private containers in
   those groups and grants data-plane roles on them the same way.

Cells under `tenants/azure/<tenant>/subscriptions/<sub-name>/azure-subscription-workloads/`
point at this stack and provide values only. There is one cell per
subscription that has workloads, each with its own state file, addressed by
the `subscription.hcl` locator beside it and by nothing in the cell. See
[ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md).

## The catalog boundary

The nine platform stacks are shared: every tenant has a cell for each, and
`diff` between two tenants' cells answers "what is stricter there". This stack
is a catalog stack, the second kind ADR 0017 names. It is planned once per
subscription that has a cell for it, and what makes it a catalog is not that
it is per subscription but that it offers **shapes, not resource types**:

- **A shape has one posture and a few knobs.** Every vault uses RBAC
  authorization, soft delete with purge protection, and a Deny firewall with
  public access off by default. Every storage account refuses shared keys and
  SAS, requires TLS 1.2 and HTTPS, forbids anonymous access, encrypts twice,
  keeps versions and soft-deleted blobs, and sits behind the same Deny
  firewall. Every identity is federated and has no secret. A cell picks the
  SKU, the retention, the replication, the containers, the roles; it cannot
  pick the posture. There is no combination of values that opens a vault or
  an account to the internet or grants a management-plane role.
- **Roles are a fixed menu.** A vault assignment is one of the Key Vault
  data-plane roles; a storage assignment is Reader or one of the Storage
  data-plane roles, at the account or at one container. Owner, Contributor,
  the Contributor roles of each service, and Key Vault Data Access
  Administrator are refused by the modules, so nothing in this stack can
  grant the ability to grant.
- **Principals are keys or names, never GUIDs.** An identity is named by its
  key in `identities`; the stack resolves the key to the service principal's
  object ID. A group is named by display name and resolved in the module. A
  cell that names an identity key that does not exist fails validation with
  a message that names the cell.
- **Nothing passes through.** No entry accepts a policy document, an ARN-like
  resource ID, or a map of provider attributes. The test, from ADR 0017: if
  the person writing the cell has to know a resource type's attribute names,
  the entry is wrong and the shape belongs in a module.

Where the line is drawn, and what to do on the other side of it:

- A workload whose vault must trust a principal created beside it, whose
  storage container's writer is a function app in the same plan, or whose
  identity needs a role on something this menu does not offer, needs
  cross-resource wiring the catalog cannot say. That is an **app stack**: a
  stack of its own under `stacks/`, composing the same modules (and others),
  with its own values-only cells. The one wiring this stack does offer is the
  one every workload needs, an identity granted a data-plane role on a vault
  or a container it lives beside.
- The same composition needed in more than one subscription is also an app
  stack, with one cell per subscription; repeating the values in each cell is
  what cells are for ([ADR 0002](../../docs/adr/0002-values-only-tenant-cells.md)).
- A shape that is missing from the menu (a queue, a container registry, a
  Log Analytics workspace) is a new module and a new map here, reviewed as a
  permission-model change: an entry is a promise that the shape is safe with
  any values that pass its validations. The catalog is finished when it
  covers what subscriptions ask for, not when it covers the provider.

## What the stack wires

A cell holds four maps, keyed by stable logical names, and the stack turns
the keys into the IDs the modules need:

| In the cell | The stack does | So the cell never holds |
|-------------|----------------|-------------------------|
| `resource_group_key = "app"` on an identity, vault, or account | passes the `resource_groups["app"].name` to the module, which looks the group up by name; `depends_on` on the group module defers that lookup to apply on the plan that creates the group | a resource group ID, or a group it does not own |
| `principal = { type = "identity", name = "ci-deploy" }` on a role assignment | passes the identity module's `principal_ids` to the vault and storage modules, which resolve `ci-deploy` to its object ID | a principal object ID |
| `principal = { type = "group", name = "Platform Operators" }` | the module resolves the display name with `azuread_group` (`security_enabled`) | a group object ID |
| `location = "eastus"` once at the top | every resource group without its own location is created there; identities, vaults, and accounts follow their group unless their entry says otherwise | a region repeated per entry |
| `tags = { owner = "iam" }` once at the top | applied to every resource; an entry's own tags are merged over them, the entry winning per key | tags repeated per entry |

The subscription is not an input. `tenants/azure/root.hcl` reads it from the
cell's `subscription.hcl` locator and points the `azurerm` provider at it,
and the key-vault module discovers the tenant with `data.azurerm_client_config`.
A cell cannot be aimed at another subscription by editing a value, and two
cells cannot share a state key, because both come from the path.

## What this stack refuses

Checked here, before any module runs, so the error names the cell:

- An empty `resource_groups`. Every shape lives in a group this cell owns,
  so a cell with none has nothing to hold.
- A resource group entry with no `location` when the stack-level `location`
  is not set.
- A `resource_group_key` that is not a key of `resource_groups`, on any
  identity, vault, or account.
- A role assignment whose `principal.type` is `identity` and whose
  `principal.name` is not a key of `identities`.
- A `tenant_id` that is not a GUID, or a `subscription_id` that is set and is
  not one.

Checked in the modules, with the reason in each module's README:

- A vault or account name that is not a valid global DNS label, a resource
  group name that ends in a period, an identity name Entra would refuse, and
  two entries with the same name.
- A role name outside the data-plane menu, a principal type other than
  `identity` or `group`, a container-scoped assignment with a non-blob role
  or a `container_key` that is not a container of the same entry, and two
  assignments that give one principal one role at one scope.
- `allowed_ip_ranges` while public network access is off (it would be
  silently ignored), a private or link-local range, and a `/31` or `/32`
  storage prefix.
- Blob versioning together with a hierarchical namespace.
- A federated credential with both `branch` and `environment`, with neither,
  with a wildcard in the branch, or duplicating another credential's GitHub
  context on the same identity. Tag and pull-request subjects are not offered.

## Retiring a shape

Resource groups, vaults, and storage accounts carry `prevent_destroy`, so
dropping an entry from a cell is a refused plan, not a deleted resource.
Retiring one is a deliberate change that lifts the flag in the module first,
in its own pull request, so the plan that deletes it is obviously about
deleting it. A resource group with `delete_lock = true` additionally needs
the lock turned off and applied in a change before the one that deletes,
because Terraform does not order a lock's removal before another module's
deletions (`modules/azure/resource-group/README.md`).

Identities carry no flag: deleting one removes its role assignments and
federated credentials with it and stops a workflow at login, which is an
outage that is visible at once and undone by re-applying the cell. Grants
made to the identity outside this repository need redoing then, because the
new identity has a new principal ID.

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "azurerm"`
and `provider "azuread"` blocks are generated by Terragrunt from `tenant_id`
and `subscription_id`; `tenants/azure/root.hcl` takes the tenant from
`ARM_TENANT_ID` and the subscription from the cell's locator, and the
generated file says which. The identity is a GitHub OIDC federated credential
in CI and the Azure CLI login on a laptop.

The apply identity needs Contributor at the subscription (resource groups
are subscription resources; the rest is inside them), plus two actions
Contributor does not carry, at the resource groups it creates:
`Microsoft.Authorization/roleAssignments/write` for every role assignment a
vault or account entry declares (Role Based Access Control Administrator or
User Access Administrator), and `Microsoft.Authorization/locks/write` for
every group with `delete_lock` (User Access Administrator, Owner, or a custom
role carrying that one action; Role Based Access Control Administrator does
not include it). Resolving a group by display name needs `Group.Read.All` or
Directory Readers in Entra for a workload identity. Reader on any Log
Analytics workspace an entry names is needed to resolve it and to write the
diagnostic setting.

One provider behaviour is handled by the root rather than confirmed per
cell, from `modules/azure/storage-account/README.md`: in azurerm 4.x the
account resource still reads queue and static website properties through
the data plane unless the provider's `features { storage {
data_plane_available = false } }` is set, and with public network access off
that read fails from a runner outside the network. `tenants/azure/root.hcl`
sets that flag in the generated provider for every cell, because the
release train applies from GitHub-hosted runners and no module here manages
either data-plane block.

## The cell

A cell for this stack looks like this. The committed one,
`tenants/azure/corp/subscriptions/sub-example-prod/azure-subscription-workloads/terragrunt.hcl`,
differs in the details: its own tags, and a Log Analytics workspace named on
the vault and the account for their audit logs.

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/azure-subscription-workloads"
}

inputs = {
  location = "eastus"

  tags = {
    owner = "app-team"
  }

  resource_groups = {
    app = {
      name        = "rg-example-app"
      delete_lock = true
    }
  }

  identities = {
    ci-deploy = {
      name               = "id-example-app-ci"
      resource_group_key = "app"

      federated_credentials = {
        prod = {
          organization = "example-org"
          repository   = "example-app"
          environment  = "prod"
        }
      }
    }
  }

  key_vaults = {
    app-secrets = {
      name               = "kv-example-app"
      resource_group_key = "app"

      role_assignments = {
        ci-reads = {
          role_name   = "Key Vault Secrets User"
          principal   = { type = "identity", name = "ci-deploy" }
          description = "CI reads deployment secrets at release time."
        }
      }
    }
  }

  storage_accounts = {
    app-artifacts = {
      name               = "stexampleapp"
      resource_group_key = "app"

      containers = {
        releases = { name = "releases" }
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
          description = "Engineers read artifacts; the group is PIM-governed."
        }
      }
    }
  }
}
```

Three blocks, six `..` in the source (out of the cell, the subscription
directory, `subscriptions`, the tenant, `azure`, and `tenants`, landing at the
repository root), no GUID, no region repeated, no ID of any kind. `tenant_id` and `subscription_id` are not set;
`root.hcl` supplies them from `ARM_TENANT_ID` and the locator.

## Standalone use without Terragrunt

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "azure_subscription_workloads" {
  source = "./stacks/azure-subscription-workloads"

  tenant_id       = "00000000-0000-0000-0000-000000000000"
  subscription_id = "00000000-0000-0000-0000-000000000000"

  location = "eastus"

  resource_groups = {
    app = { name = "rg-example-app" }
  }

  identities = {
    rotation-job = {
      name               = "id-example-rotation"
      resource_group_key = "app"
    }
  }

  key_vaults = {
    rotation-secrets = {
      name               = "kv-example-rotation"
      resource_group_key = "app"

      role_assignments = {
        rotation-job-writes = {
          role_name   = "Key Vault Secrets Officer"
          principal   = { type = "identity", name = "rotation-job" }
          description = "The rotation job writes the secrets it rotates."
        }
      }
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `tenant_id` | `string` | Entra tenant ID, from the environment via root.hcl. |
| `subscription_id` | `string` | Subscription of the cell, from its locator via root.hcl. |
| `location` | `string` | Region for every resource group without its own. Null (default) means each group says. |
| `tags` | `map(string)` | Tags for every resource; an entry's own tags are merged over them. Default `{}`. |
| `resource_groups` | `map(object)` | Groups the cell owns, keyed by logical name: `name`, `location`, `tags`, `delete_lock`, `lock_notes`. At least one. |
| `identities` | `map(object)` | Identities keyed by logical name: `name`, `resource_group_key`, `location`, `tags`, `federated_credentials`. Default `{}`. |
| `key_vaults` | `map(object)` | Vaults keyed by logical name: `name`, `resource_group_key`, and the key-vault module's knobs and `role_assignments`. Default `{}`. |
| `storage_accounts` | `map(object)` | Accounts keyed by logical name: `name`, `resource_group_key`, and the storage-account module's knobs, `containers`, and `role_assignments`. Default `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `resource_groups` | Key to `{ id, name, location, locked }`. |
| `identities` | Key to `{ id, name, principal_id, client_id, tenant_id, resource_group_name, location }`. |
| `identity_client_ids` | Key to client ID, for the workflow's `client-id`. |
| `federated_credentials` | `"<identity key>/<credential key>"` to `{ id, name, identity_key, issuer, subject, audience }`. |
| `key_vaults` | Key to `{ id, name, vault_uri, resource_group_name, location, public_network_access_enabled, diagnostics }`. |
| `key_vault_uris` | Key to the vault's data-plane URI. |
| `key_vault_role_assignments` | `"<vault key>/<assignment key>"` to the resolved grant. |
| `storage_accounts` | Key to `{ id, name, resource_group_name, location, primary_blob_endpoint, primary_dfs_endpoint, hierarchical_namespace_enabled, public_network_access_enabled, diagnostics }`. |
| `storage_containers` | `"<account key>/<container key>"` to `{ id, name, account_key, scope }`. |
| `storage_role_assignments` | `"<account key>/<assignment key>"` to the resolved grant, with its scope. |
| `group_object_ids` | Group display name to object ID, for every group named. |
