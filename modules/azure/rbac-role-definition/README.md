# modules/azure/rbac-role-definition

Manages a set of custom Azure RBAC role definitions from a single map. Custom roles
are the vocabulary every PIM policy and eligibility in this repository speaks, so
this module is applied in its own cell before anything that assigns a role by name.

## Design notes

- The map key is a stable logical name (`platform-operator`, `kv-secrets-rotator`).
  It is part of the Terraform address, so it should never change once applied. The
  display name in Azure is the `name` attribute and can change freely.
- `for_each` over a map, never `count`. Removing one role does not shift the others.
- Scopes are resolved by name. A management group by display name, a subscription by
  display name, a resource group by name. No tenant file ever contains a subscription
  GUID or a management group ID, and a plan against the wrong tenant fails at the
  lookup instead of assigning into the wrong place.
- Every distinct scope is looked up once, however many roles reference it.
- `prevent_destroy` is set on the definition. Eligibilities in another cell reference
  the role by name, and this cell cannot see them. Retiring a role is a deliberate
  two-step change, assignments first, then the flag, then the definition.
- Validation rejects a role with no control-plane actions. A data-plane-only role
  cannot see the resource it acts on in the portal, which is almost never the intent.

## Usage

```hcl
module "custom_roles" {
  source = "../../modules/azure/rbac-role-definition"

  roles = {
    platform-operator = {
      name        = "Platform Operator"
      description = "Day-two operations on shared platform resources without the ability to change RBAC."
      assignable_scope = {
        type = "management_group"
        name = "mg-example-root"
      }
      actions = [
        "*/read",
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/restart/action",
        "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Network/networkSecurityGroups/securityRules/write",
        "Microsoft.Resources/deployments/*",
      ]
      not_actions = [
        "Microsoft.Authorization/*/write",
        "Microsoft.Authorization/*/delete",
      ]
    }

    kv-secrets-rotator = {
      name        = "Key Vault Secrets Rotator"
      description = "Read and set secret versions for automated rotation. No key or certificate access."
      assignable_scope = {
        type = "subscription"
        name = "sub-example-prod"
      }
      additional_assignable_scopes = [
        { type = "subscription", name = "sub-example-nonprod" },
      ]
      actions = [
        "Microsoft.KeyVault/vaults/read",
      ]
      data_actions = [
        "Microsoft.KeyVault/vaults/secrets/getSecret/action",
        "Microsoft.KeyVault/vaults/secrets/setSecret/action",
        "Microsoft.KeyVault/vaults/secrets/readMetadata/action",
      ]
    }
  }
}

output "platform_operator_resource_id" {
  value = module.custom_roles.role_definition_resource_ids["platform-operator"]
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `roles` | `map(object)` | Custom roles keyed by logical name. See `variables.tf` for the object shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `role_definition_ids` | Map of logical key to role definition GUID. |
| `role_definition_resource_ids` | Map of logical key to fully qualified role definition resource ID. |
| `roles` | Map of logical key to `{ name, role_definition_id, resource_id, scope, assignable_scopes }`. |
| `scope_ids` | Map of `<type>/<name>` to resolved scope ID. |

## Importing existing role definitions

The import ID is the role definition resource ID and the scope it was created at,
joined with a pipe.

```hcl
import {
  to = module.custom_roles.azurerm_role_definition.this["platform-operator"]
  id = "/providers/Microsoft.Management/managementGroups/mg-example-root/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000000|/providers/Microsoft.Management/managementGroups/mg-example-root"
}
```

For a subscription-scoped role the scope segment is
`/subscriptions/00000000-0000-0000-0000-000000000000`. The zero-change gate in
`tests/README.md` applies: the plan after import must show nothing to add, change,
or destroy before the apply that records the import.
