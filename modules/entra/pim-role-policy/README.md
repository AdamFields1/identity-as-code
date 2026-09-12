# modules/entra/pim-role-policy

Manages the PIM for Groups role management policy (activation, eligibility, active
assignment, and notification rules) for member or owner roles of PIM-enabled groups.
Groups and approver groups are resolved by display name.

## Design notes

- **Nothing is created.** Entra creates one policy per group per role when a group
  is onboarded to PIM, which for role-assignable groups happens at creation. The
  provider adopts the existing policy on first apply. Removing the resource stops
  managing the policy; it does not delete it, so there is no `prevent_destroy`.
- **Secure defaults.** Activation is capped at PT4H, requires MFA and a
  justification, and does not require approval. Eligibility expires after P365D and
  direct active assignment after P180D. A tenant that omits every optional block gets
  the strict behaviour. A stricter tenant lowers `maximum_duration` and turns on
  `require_approval`; a looser one has to say so explicitly.
- **Approval needs approvers.** `require_approval = true` without at least one
  `approver_groups` entry is rejected by validation, not by the API halfway through
  an apply.
- **Durations are validated.** `maximum_duration` and `expire_after` must match an
  ISO 8601 duration (`PT4H`, `P180D`). The regex is deliberately simple; Entra applies
  its own limits (activation between PT30M and PT24H, for example) and reports them.
- **Notifications are minimal.** Administrators are notified about new eligible
  assignments and activations. Assignee and approver notifications keep Entra
  defaults. The variable shape can grow if a tenant needs more.

## Usage

```hcl
module "role_policies" {
  source = "../../modules/entra/pim-role-policy"

  policies = {
    global-admin-member = {
      group_display_name = "PIM Global Administrators"
      role               = "member"

      activation = {
        maximum_duration = "PT2H"
        require_approval = true
        approver_groups  = ["SEC IAM Approvers"]
      }
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `policies` | `map(object)` | n/a | Policies keyed by logical name. See `variables.tf` for the full shape and defaults. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_ids` | Map of key to policy ID. |
| `policies` | Map of key to `{ id, group_id, role, display_name }`. |

## Import

Not needed. The provider adopts the tenant's existing policy for the group and role
on the first apply.
