# modules/azure/resource-group

Manages a map of resource groups, each with an optional CanNotDelete
management lock behind a bool. It is the container the other catalog shapes
(`managed-identity`, `key-vault`, `storage-account`) are created in, and the
one module under `modules/azure` that reads no data source: a resource group
depends on nothing.

## Design notes

- **The map key is a stable logical name** (`identity-automation`). It is part
  of the Terraform address and should never change once applied; the visible
  name is `name`.
- **Every group is `prevent_destroy`.** Deleting a resource group deletes
  every resource in it, managed by this cell, by another cell, or by nobody.
  Removing an entry from a cell, or changing an immutable attribute (`name`,
  `location`), must never be able to do that as a side effect. Retiring a
  group is a deliberate change that lifts the flag in this module first, in
  its own pull request, so the plan that deletes it is obviously about
  deleting it (the same rule as `backup-storage` and the custom role
  definitions, [ADR 0005](../../../docs/adr/0005-definitions-and-assignments-in-separate-cells.md)).
- **The lock is a bool, and it is CanNotDelete, never ReadOnly.** The
  `prevent_destroy` flag protects against Terraform; a management lock
  protects against everyone else. While `delete_lock` is true, the portal,
  the CLI, and any Terraform plan (this cell's or another's) are refused
  when they try to delete the group or anything in it, and reads and writes
  are unaffected. A ReadOnly lock is not offered: it breaks ordinary
  operations such as listing role assignments and reading storage
  properties, and would stop the other catalog stacks from planning against
  the group.
- **Turning the lock off and deleting are two changes.** Setting
  `delete_lock = false` removes the lock, and only the lock, in the plan that
  does it. Terraform orders the lock's removal after the group's creation,
  not before another module's deletions, so a lock removed and a resource
  deleted in the same plan can still fail on the delete. Remove the lock,
  apply, then delete.
- **Tags merge.** The module-level `tags` apply to every group and an entry's
  own `tags` are merged over them, the entry winning per key.

## What the apply identity needs

Contributor at the subscription creates and tags resource groups. A
management lock is `Microsoft.Authorization/locks/write`, which Contributor
does not have: Owner or User Access Administrator on the group does, and so
does a custom role that carries that one action. An apply identity that can
create the group but not the lock fails on the lock, after the group exists,
which is the honest failure.

## Usage

```hcl
module "resource_groups" {
  source = "../../modules/azure/resource-group"

  tags = {
    owner = "iam"
  }

  resource_groups = {
    identity = {
      name        = "rg-example-identity"
      location    = "eastus"
      delete_lock = true
      tags        = { workload = "identity-automation" }
    }

    scratch = {
      name     = "rg-example-scratch"
      location = "eastus"
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `resource_groups` | `map(object)` | `{}` | Groups keyed by logical name: `name`, `location`, `tags`, `delete_lock`, `lock_notes`. See `variables.tf`. |
| `tags` | `map(string)` | `{}` | Tags applied to every group; an entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `resource_groups` | Key to `{ id, name, location, locked }`. |
| `resource_group_ids` | Key to resource group ID. |
| `resource_group_names` | Key to resource group name, for the modules that look a group up by name. |
| `lock_ids` | Key to the lock's resource ID, for the locked entries. |

## Import

```hcl
import {
  to = module.resource_groups.azurerm_resource_group.this["identity"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity"
}

import {
  to = module.resource_groups.azurerm_management_lock.delete["identity"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.Authorization/locks/do-not-delete"
}
```

A group adopted this way keeps whatever lock it has under whatever name; if
that name is not `do-not-delete`, import it and expect the plan to replace it
with one of that name, or delete the old lock first.
