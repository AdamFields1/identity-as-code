# modules/okta/mfa-policy

Manages one Okta MFA enrollment policy and its rules. Authenticator settings are passed
as a single map keyed by authenticator name, which the module fans out to the
provider's per-authenticator attributes.

## Design notes

- One `authenticators` map instead of twenty separate variables. Tenant values stay
  readable and adding a new authenticator is a one-line change in the tenant cell.
- Validation requires at least one `REQUIRED` authenticator. A policy that only has
  optional authenticators lets a user finish enrollment with nothing but a password.
- `is_oie` defaults to `true`. Classic Engine tenants set it to `false` and use the
  Classic keys (`okta_push`, `okta_otp`, and so on).
- `enroll` on rules uses the provider values `LOGIN`, `CHALLENGE`, `NEVER`.
- The policy resource has `prevent_destroy = true` for the same reason as the
  session policy: losing it drops users onto a weaker default policy.

## Usage

```hcl
module "mfa_policy" {
  source = "../../modules/okta/mfa-policy"

  name            = "Workforce MFA enrollment"
  priority        = 1
  groups_included = [data.okta_group.everyone.id]

  authenticators = {
    okta_verify   = { enroll = "REQUIRED" }
    fido_webauthn = { enroll = "OPTIONAL" }
    okta_password = { enroll = "REQUIRED" }
    phone_number  = { enroll = "NOT_ALLOWED" }
  }

  rules = {
    default = {
      name     = "Enroll at next sign-in"
      priority = 1
      enroll   = "LOGIN"
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name` | `string` | n/a | Policy display name. |
| `description` | `string` | Managed by Terraform | Description. |
| `priority` | `number` | `null` | Policy priority. |
| `status` | `string` | `ACTIVE` | ACTIVE or INACTIVE. |
| `groups_included` | `list(string)` | n/a | Group IDs. |
| `is_oie` | `bool` | `true` | Identity Engine tenant. |
| `authenticators` | `map(object)` | n/a | Enrollment settings keyed by authenticator. |
| `rules` | `map(object)` | n/a | Rules keyed by logical name. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_id` | MFA policy ID. |
| `policy_name` | Policy display name. |
| `rule_ids` | Map of rule key to rule ID. |

## Import

```hcl
import {
  to = module.mfa_policy.okta_policy_mfa.this
  id = "00p0000000000000000"
}

import {
  to = module.mfa_policy.okta_policy_rule_mfa.this["default"]
  id = "00p0000000000000000/0pr0000000000000000"
}
```
