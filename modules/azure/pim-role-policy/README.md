# modules/azure/pim-role-policy

Manages Azure PIM role management policies for a set of (scope, role) pairs. A role
management policy is the rule set PIM enforces when someone activates a role: how
long the activation lasts, whether MFA and a justification are required, whether an
approver has to say yes, and how long an eligibility may exist before it expires.

## Design notes

- Azure already has a policy for every role at every scope. This module never
  creates one; the resource adopts the existing policy on first apply and rewrites
  its rules. A first plan shows "create" for each entry, which is the provider's
  way of saying "not yet in state", not "new object in Azure".
- The map key is a stable logical name (`owner-at-root`, `contributor-prod`). It is
  part of the Terraform address and should never change once applied.
- One policy per (scope, role) pair. Validation rejects two entries for the same
  pair because Azure only has one, and two resources fighting over it would flap.
- Scope and role are resolved by name. The role lookup is scoped, so the resource
  receives the fully qualified role definition ID at that scope, and built-in and
  custom roles resolve identically.
- Module-level variables are the tenant baseline. Each entry can override any field,
  and an unset override inherits. A stricter tenant therefore changes one line
  (`activation_maximum_duration = "PT2H"`) rather than every entry.
- Approver groups arrive as object IDs. The calling stack resolves display names with
  the `azuread_group` data source so this module needs only the azurerm provider,
  and tenant cells still never contain a GUID.
- ISO 8601 durations are validated before the plan reaches the API: activation
  windows must be `PT<n>H` or `PT<n>M`, expirations must be one of the five values
  PIM accepts.

## Usage

```hcl
module "pim_policies" {
  source = "../../modules/azure/pim-role-policy"

  # Tenant baseline.
  activation_maximum_duration        = "PT4H"
  require_multifactor_authentication = true
  require_justification              = true
  require_approval                   = false

  eligible_assignment_rules = {
    expiration_required = true
    expire_after        = "P365D"
  }

  policies = {
    owner-at-root = {
      role_name = "Owner"
      scope     = { type = "management_group", name = "mg-example-root" }
      activation = {
        maximum_duration          = "PT1H"
        require_approval          = true
        approver_group_object_ids = [data.azuread_group.pim_approvers.object_id]
      }
    }

    contributor-prod = {
      role_name = "Contributor"
      scope     = { type = "subscription", name = "sub-example-prod" }
    }

    platform-operator-at-root = {
      role_name = "Platform Operator"
      scope     = { type = "management_group", name = "mg-example-root" }
      eligible_assignment_rules = {
        expiration_required = false
      }
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `activation_maximum_duration` | `string` | `"PT4H"` | Longest single activation. |
| `require_multifactor_authentication` | `bool` | `true` | MFA on activation. |
| `require_justification` | `bool` | `true` | Written justification on activation. |
| `require_ticket_info` | `bool` | `false` | Ticket number and system on activation. |
| `require_approval` | `bool` | `false` | Approver must accept each activation. |
| `approver_group_object_ids` | `list(string)` | `[]` | Groups whose members may approve. |
| `eligible_assignment_rules` | `object` | 365 days, required | Eligibility expiration baseline. |
| `active_assignment_rules` | `object` | 180 days, required, MFA, justification | Standing assignment baseline. |
| `notification_rules` | `object` | `null` | Minimal admin notification settings. |
| `policies` | `map(object)` | | Policies keyed by logical name. See `variables.tf`. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_ids` | Map of logical key to policy resource ID. |
| `policies` | Map of logical key to `{ name, scope, role_definition_id, activation_maximum_duration, require_approval }`. |
| `role_definition_ids` | Map of logical key to the resolved role definition ID. |
| `scope_ids` | Map of `<type>/<name>` to resolved scope ID. |

## Importing existing policies

Because the policy already exists, "import" and "first apply" do almost the same
thing. The difference is the zero-change gate: an import followed by a plan shows
exactly which rules differ from the tenant baseline before anything is written. The
import ID is the scope and the role definition ID joined with a pipe.

```hcl
import {
  to = module.pim_policies.azurerm_role_management_policy.this["contributor-prod"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000|/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000000"
}
```
