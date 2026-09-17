# modules/azure/workload-role-assignment

Manages the standing Azure role assignments of one workload identity (a
managed identity or another service principal) from a single map. Scopes and
roles are given by name. An entry may carry an Azure ABAC condition, written
with name tokens instead of GUIDs.

## Design notes

- **Workloads only.** People get Azure access as PIM eligibilities
  (`modules/azure/pim-eligible-assignment`), never as a standing assignment
  from this repository. A managed identity cannot activate a PIM role, so the
  permissions an automation identity holds in Azure Resource Manager are
  standing assignments, and they are declared here, in a map a reviewer can
  read. `principal_type` is fixed to `ServicePrincipal`.
- **Names, not IDs.** A scope is `{ type, name }` with `type` one of
  `management_group` (display name), `subscription` (display name), or
  `resource_group` (name in the provider's subscription), resolved the same
  way as `rbac-role-definition` and `pim-eligible-assignment`. The role is
  resolved by display name at the entry's own scope, so a misspelt role fails
  the plan. The fourth type, `resource_id`, takes a full ARM ID and exists for
  a stack that created the resource in the same plan; `stacks/azure-automation`
  uses it for its own Automation account.
- **The three roles that can grant roles need a condition.** Owner, User
  Access Administrator, and Role Based Access Control Administrator are
  rejected by validation unless the entry has a `condition`. Unconditioned,
  any of them lets the identity make itself anything at the scope, which is a
  design conversation, not a map entry.
- **One entry per (scope, role).** Validation rejects duplicates so a
  condition cannot be split across two assignments of the same role.
- **New identities.** `skip_service_principal_aad_check` is set, because an
  identity created in the same plan may not have reached every Entra replica
  when ARM checks it. The principal ID comes from the identity resource, so
  skipping the lookup weakens nothing.

## Conditions with name tokens

A delegation condition names role definition GUIDs and principal object IDs,
and a tenant cell never holds a GUID (ADR 0002). The condition text may
therefore use two tokens, which this module replaces before the assignment is
written:

| Token | Replaced with |
|-------|---------------|
| `<principal_id>` | `var.principal_id`, the identity this module assigns to |
| `<role_id:NAME>` | the GUID of the role definition named `NAME`, resolved at the entry's scope |

The braces of the ABAC set syntax stay in the text, so a token sits where the
GUID would. This is the condition the corp automation cell gives its Role
Based Access Control Administrator assignment, in the form documented under
"Examples to delegate Azure role assignment management with conditions"
(Constrain roles and specific principals) on learn.microsoft.com:

```
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
  AND
  @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
  AND
  @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
 )
)
```

The write half reads `@Request` (the assignment being created) and the delete
half reads `@Resource` (the assignment being removed), as the documentation
requires. Delegation conditions can target only
`Microsoft.Authorization/roleAssignments/write` and `/delete`; any other
action the role grants is unconstrained by them. That is why Role Based Access
Control Administrator (role assignments plus `*/read`) is the role to condition,
and User Access Administrator (all of `Microsoft.Authorization/*`, including
PIM schedule requests and policy writes) is not. The rendered text of every
condition is in the `conditions` output.

Read what such a condition does and does not buy before reusing it. The
delegation attributes are RoleDefinitionId, PrincipalId, and PrincipalType:
they say **what** may be assigned and **to whom**, never **where**. A
principal holding the condition above can assign Owner to itself at any scope
under the assignment, so it is Owner-equivalent across that scope, and the
only sound place for such an assignment is a management group narrow enough
that this is acceptable. What the condition does buy is that it cannot grant
anything to anyone else, cannot grant itself any other role, and cannot remove
another principal's access, which bounds a bug in the code that uses it
(docs/adr/0014).

Terraform has no fold, so the substitution is done without a loop: every role
token is replaced with the separator `<role_id>` (a role token without a
name, which the token pattern never matches and ABAC text never contains),
the text is split on it, and the parts are joined back with the GUIDs
`regexall()` found, in order. Validation keeps the separator out of the
condition.

## Usage

```hcl
module "automation_rbac" {
  source = "../../modules/azure/workload-role-assignment"

  principal_id = module.automation_account.identities["pim"].principal_id

  assignments = {
    reader-at-root = {
      role_name   = "Reader"
      scope       = { type = "management_group", name = "mg-example-root" }
      description = "Dry-run reads for the PIM runbooks."
    }

    watcher-on-account = {
      role_name = "Reader"
      scope     = { type = "resource_id", name = module.automation_account.automation_account_id }
    }

    subscription-guard = {
      role_name   = "Role Based Access Control Administrator"
      scope       = { type = "management_group", name = "mg-example-sandbox" }
      description = "Just-in-time Owner on a subscription it is about to cancel, for itself only."
      condition   = file("${path.module}/conditions/self-owner-only.txt")
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `principal_id` | `string` | n/a | Object ID of the service principal to assign to. |
| `assignments` | `map(object)` | `{}` | Assignments keyed by logical name; see `variables.tf`. |

## Outputs

| Name | Description |
|------|-------------|
| `assignment_ids` | Key to role assignment resource ID. |
| `assignments` | Key to `{ scope, role_name, role_definition_id, conditioned }`. |
| `scope_ids` | Key to resolved scope ID. |
| `conditions` | Key to the condition text as sent, tokens replaced. |

## Import

The import ID is the role assignment's resource ID.

```hcl
import {
  to = module.automation_rbac.azurerm_role_assignment.this["reader-at-root"]
  id = "/providers/Microsoft.Management/managementGroups/mg-example-root/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000000"
}
```
