# modules/azure/pim-eligible-assignment

Manages PIM eligible role assignments from a single map. An eligibility lets the
members of an Entra group activate a role at a scope, subject to the role management
policy for that pair. Nothing here grants standing access.

## Design notes

- The map key is a stable logical name (`platform-operators-at-root`). It is part of
  the Terraform address and should never change once applied.
- Principals are Entra security groups resolved by display name. There is no
  `principal_id` input on purpose: a tenant cell that names a group can be reviewed
  by someone who has never opened the portal, and a GUID cannot.
- Roles and scopes are resolved by name, the same way as `rbac-role-definition` and
  `pim-role-policy`.
- `expiration` is either `{ duration_days = n }` or `{ permanent = true }`. A
  permanent eligibility sends no schedule block at all, because the API treats an
  empty schedule differently from a missing one.
- Validation rejects two entries for the same (scope, role, group), because Azure
  holds exactly one eligibility per triple and two resources would flap.

## The policy must come first

An eligibility with `duration_days = 365` is rejected if the role management policy
for that (scope, role) still says `expire_after = "P180D"`, and a permanent
eligibility is rejected unless the policy says `expiration_required = false`. The
`azure-pim-governance` stack therefore applies `pim-role-policy` before this module
with an explicit `depends_on`. Do not compose this module without that ordering.

## Eligibility IDs rotate: refresh before you import

PIM stores an eligibility as a role eligibility schedule with its own GUID. When an
eligibility that has an end date is renewed or extended in the portal, PIM does not
edit the schedule in place; it creates a new schedule with a new GUID and a new end
date and retires the old one. For a tenant whose eligibilities expire annually, that
means every schedule ID in state goes stale once a year, on a date nobody in the
repository chose.

The provider looks the assignment up by (scope, role, principal), so an ordinary
plan reconciles quietly. The problem is import generation. A drift-export helper that
lists live schedules and emits `import` blocks for anything not in state will, right
after a renewal, see the new schedule as unmanaged and the old one as missing, and
produce an import for an object Terraform already manages under another ID.

The operating pattern is therefore:

1. `terragrunt apply -refresh-only` on the cell. State catches up with the renewed
   schedules and nothing in Azure changes.
2. Generate `imports.tf` for whatever is still unmanaged.
3. Plan. The zero-change gate in `tests/README.md` must be green.
4. Apply, then delete `imports.tf`.

Skipping step 1 does not break Azure. It breaks the import file, and the zero-change
gate catches it, but only after someone has spent time reading a plan that is wrong
for an uninteresting reason.

## Usage

```hcl
module "pim_eligibilities" {
  source = "../../modules/azure/pim-eligible-assignment"

  eligibilities = {
    platform-operators-at-root = {
      group_display_name = "Platform Operators"
      role_name          = "Platform Operator"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Day-two platform operations. Reviewed quarterly by the platform lead."
      expiration         = { duration_days = 365 }
    }

    cloud-engineers-contributor-prod = {
      group_display_name = "Cloud Engineers"
      role_name          = "Contributor"
      scope              = { type = "subscription", name = "sub-example-prod" }
      justification      = "Change delivery into production through PIM only."
      expiration         = { duration_days = 180 }
    }

    security-readers-at-root = {
      group_display_name = "Security Operations"
      role_name          = "Reader"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Read-only investigation access across the estate."
      expiration         = { permanent = true }
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `eligibilities` | `map(object)` | Eligibilities keyed by logical name. See `variables.tf` for the object shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `eligibility_ids` | Map of logical key to eligible assignment resource ID. |
| `eligibilities` | Map of logical key to `{ scope, role_definition_id, principal_id, group_display_name, permanent }`. |
| `group_object_ids` | Map of group display name to object ID. |
| `scope_ids` | Map of `<type>/<name>` to resolved scope ID. |

## Importing existing eligibilities

The import ID is the scope, the fully qualified role definition ID, and the
principal object ID, joined with pipes. Run the refresh-only apply described above
before generating these.

```hcl
import {
  to = module.pim_eligibilities.azurerm_pim_eligible_role_assignment.this["cloud-engineers-contributor-prod"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000|/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000000|00000000-0000-0000-0000-000000000000"
}
```
