# modules/entra/pim-eligibility

Manages the two hops of the PIM model, both expressed by name:

1. A role-assignable group is made eligible for an Entra directory role
   (`azuread_directory_role_eligibility_schedule_request`).
2. Users or groups are made eligible for membership of a PIM-enabled group
   (`azuread_privileged_access_group_eligibility_schedule`).

Nobody holds a standing directory role. A person activates group membership under
the group's role management policy, then activates the role the group is eligible
for.

## Design notes

- **Roles are resolved from templates.** `azuread_directory_role_templates` lists
  every built-in role whether or not it has been activated in the tenant, and the
  template ID is the role definition ID the schedule request expects. A misspelled
  role name fails the plan with a message naming the fix.
- **Principals are names.** Users by user principal name, groups by display name.
  A missing principal fails the plan early.
- **Permanent by default, time-bound when asked.** Setting `duration` implies a
  non-permanent eligibility. Setting `permanent = false` without a duration is
  rejected by validation.
- **Schedule requests are replace-only.** The Entra API has no update operation for
  an eligibility schedule request; changing a role or principal is a new request and
  Terraform replaces the resource. Removing an entry ends the eligibility.
- **No `prevent_destroy`.** Removing an eligibility is the intended way to offboard
  someone from privileged access and should be a one-line change.

## Usage

```hcl
module "eligibility" {
  source = "../../modules/entra/pim-eligibility"

  directory_role_eligibilities = {
    global-admin = {
      role_display_name  = "Global Administrator"
      group_display_name = "PIM Global Administrators"
    }
  }

  group_eligibilities = {
    iam-lead-global-admin = {
      group_display_name = "PIM Global Administrators"
      principal_user     = "iam.lead@corp.example.com"
    }

    iam-engineers-security-admin = {
      group_display_name = "PIM Security Administrators"
      principal_group    = "IAM Engineers"
      duration           = "P180D"
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `directory_role_eligibilities` | `map(object)` | `{}` | Group to directory role eligibilities. |
| `group_eligibilities` | `map(object)` | `{}` | User or group to PIM group eligibilities. |

## Outputs

| Name | Description |
|------|-------------|
| `directory_role_eligibility_ids` | Map of key to schedule request ID. |
| `group_eligibility_ids` | Map of key to eligibility schedule ID. |
| `role_template_ids` | Map of role display name to template ID for every referenced role. |

## Import

```hcl
import {
  to = module.eligibility.azuread_directory_role_eligibility_schedule_request.this["global-admin"]
  id = "00000000-0000-0000-0000-000000000000"
}

import {
  to = module.eligibility.azuread_privileged_access_group_eligibility_schedule.this["iam-lead-global-admin"]
  id = "00000000-0000-0000-0000-000000000000_member_00000000-0000-0000-0000-000000000000"
}
```
