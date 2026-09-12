# modules/entra/security-group

Manages a map of Entra ID security groups. Owners and members are given as user
principal names or existing group display names and resolved to object IDs by the
module, so no caller ever writes an object ID.

## Design notes

- **Security-enabled, never mail-enabled.** These are access-control and
  privileged-role groups. Distribution lists and Microsoft 365 groups are owned by the
  collaboration platform, not by this repository.
- **`prevent_destroy` on every group.** A group's object ID is the thing Conditional
  Access exclusions, PIM policies, Azure RBAC, and app role assignments point at.
  Recreating a group produces a new ID and silently drops all of them. For a
  break-glass exclusion group that means every Conditional Access policy starts
  applying to the break-glass accounts. Deleting a group is therefore an explicit
  edit to the lifecycle block, visible in review.
- **Membership is managed only when listed.** When `member_users` and
  `member_groups` are both empty the provider attribute is left null and Terraform
  does not touch membership. This is required for PIM-enabled groups: activation
  writes membership, and an empty set in configuration would remove every activated
  member on the next apply.
- **`assignable_to_role` is immutable.** Changing it forces replacement, which
  `prevent_destroy` blocks. That is intended: converting a group to role-assignable
  is a new group with a new ID and a new review.
- **Nested groups must already exist.** `member_groups` is resolved with
  `azuread_group` data sources, so a group cannot reference another group defined in
  the same map. Role-assignable groups cannot contain nested groups at all, and a
  validation says so before the API does.

## Usage

```hcl
module "security_groups" {
  source = "../../modules/entra/security-group"

  groups = {
    pim-global-admin = {
      display_name       = "PIM Global Administrators"
      description        = "Eligible pool for Global Administrator. Membership is written by PIM activation."
      assignable_to_role = true
      owners             = ["iam.lead@corp.example.com"]
    }

    payroll-api-users = {
      display_name  = "APP Payroll API Users"
      member_groups = ["Finance Staff"]
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `groups` | `map(object)` | n/a | Groups keyed by logical name. See `variables.tf` for the full shape. |

## Outputs

| Name | Description |
|------|-------------|
| `group_ids` | Map of key to object ID. |
| `groups` | Map of key to `{ object_id, display_name, assignable_to_role }`. |
| `group_ids_by_display_name` | Map of display name to object ID. |

## Import

```hcl
import {
  to = module.security_groups.azuread_group.this["pim-global-admin"]
  id = "/groups/00000000-0000-0000-0000-000000000000"
}
```
