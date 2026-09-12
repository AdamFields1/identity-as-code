# modules/entra/conditional-access

Manages named locations, custom authentication strengths, and Conditional Access
policies. Policies reference locations and strengths by logical key and reference
groups, roles, and applications by display name.

## Design notes

- **The break-glass exclusion is mandatory.** `break_glass_exclusion_group` has no
  default and rejects an empty string. Its object ID is appended to the excluded
  groups of every policy the module creates. There is no per-policy opt-out because
  the one policy that forgets it is the one that locks the tenant out. See
  [ADR 0007](../../../docs/adr/0007-break-glass-exclusion-is-mandatory.md).
- **Report-only first.** `state` defaults to `enabledForReportingButNotEnforced`. A
  new policy lands in the sign-in log as "would have been blocked" before it blocks
  anyone. Promoting it to `enabled` is a one-word change in the tenant cell, visible
  in review, after the report-only data has been read.
- **`prevent_destroy` on every policy.** Destroying an enforced policy removes a
  control silently. Destroying and recreating one (for example after a key rename)
  leaves a gap and then a new policy with no report-only soak. Both belong in an
  explicit lifecycle edit.
- **No IDs in tenant values.** Groups resolve through `azuread_group`, roles through
  `azuread_directory_role_templates`, enterprise applications through
  `azuread_service_principal` by display name, and locations and strengths through
  this module's own resources. Graph wants bare object IDs for named locations and
  the prefixed resource ID for authentication strengths; the module handles both so
  callers never need to know.
- **Individual users are not a condition.** `included_users` accepts only `All`,
  `None`, and `GuestsOrExternalUsers`. Anything narrower is a group, so scope changes
  are membership changes in the directory, not policy edits.
- **Validation before the API.** State, client app types, risk levels, platforms,
  built-in controls, session control values, and every cross-reference (location
  keys, strength keys) are checked in `variables.tf`.

## Usage

```hcl
module "conditional_access" {
  source = "../../modules/entra/conditional-access"

  break_glass_exclusion_group = "SEC Break Glass Accounts"

  named_locations = {
    corp-egress = {
      display_name = "Corporate egress"
      ip_ranges    = ["203.0.113.0/24"]
      trusted      = true
    }
  }

  authentication_strengths = {
    phishing-resistant = {
      display_name         = "Phishing-resistant MFA"
      allowed_combinations = ["windowsHelloForBusiness", "fido2", "x509CertificateMultiFactor"]
    }
  }

  policies = {
    block-legacy-auth = {
      display_name     = "CA001 Block legacy authentication"
      client_app_types = ["exchangeActiveSync", "other"]
      users            = { included_users = ["All"] }
      grant_controls   = { built_in_controls = ["block"] }
    }

    require-phishing-resistant-privileged = {
      display_name   = "CA002 Require phishing-resistant MFA for privileged groups"
      users          = { included_groups = ["PIM Global Administrators"] }
      grant_controls = { authentication_strength = "phishing-resistant" }
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `named_locations` | `map(object)` | `{}` | IP or country locations keyed by logical name. |
| `authentication_strengths` | `map(object)` | `{}` | Custom strengths keyed by logical name. |
| `break_glass_exclusion_group` | `string` | n/a | Display name of the emergency access group. Required, non-empty. |
| `policies` | `map(object)` | n/a | Policies keyed by logical name. See `variables.tf` for the full shape. |

## Outputs

| Name | Description |
|------|-------------|
| `named_location_ids` | Map of key to named location object ID. |
| `authentication_strength_ids` | Map of key to strength policy ID. |
| `policy_ids` | Map of key to policy object ID. |
| `policies` | Map of key to `{ object_id, display_name, state }`. |
| `break_glass_group_id` | Object ID of the exclusion group. |

## Import

```hcl
import {
  to = module.conditional_access.azuread_named_location.this["corp-egress"]
  id = "/identity/conditionalAccess/namedLocations/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.conditional_access.azuread_authentication_strength_policy.this["phishing-resistant"]
  id = "/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.conditional_access.azuread_conditional_access_policy.this["block-legacy-auth"]
  id = "/identity/conditionalAccess/policies/00000000-0000-0000-0000-000000000000"
}
```
