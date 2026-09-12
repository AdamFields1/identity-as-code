# modules/okta/password-policy

Manages one Okta password policy and its rules. Settings are grouped into four small
objects so a tenant can override one value and inherit the rest.

## Secure defaults

| Group | Setting | Default | Why |
|-------|---------|---------|-----|
| complexity | `min_length` | 14 | Length beats composition rules (NIST SP 800-63B). |
| complexity | `dictionary_lookup` | true | Blocks the passwords attackers try first. |
| complexity | `exclude_username`, `exclude_first_name`, `exclude_last_name` | true | Stops the obvious guesses. |
| age | `max_age_days` | 0 (never) | Forced rotation produces predictable passwords. Rotate on evidence of compromise instead. |
| age | `history_count` | 24 | Prevents ping-pong reuse when a reset does happen. |
| age | `min_age_minutes` | 60 | Stops a user cycling through history in one sitting. |
| lockout | `max_attempts` | 10 | Slows online guessing. |
| lockout | `auto_unlock_minutes` | 30 | A lockout that never clears is a denial-of-service tool against your own users. |
| recovery | `email` | ACTIVE | The only channel on by default. |
| recovery | `sms`, `call` | INACTIVE | SIM swap and voice phishing make these the weakest recovery paths. |
| recovery | `question` | INACTIVE | Security questions are guessable and reusable. |

All defaults are overridable per tenant. Validation blocks stop values that Okta would
reject (for example a per-class minimum of 2, which the API does not support).

## Usage

```hcl
module "password_policy" {
  source = "../../modules/okta/password-policy"

  name            = "Workforce password policy"
  priority        = 1
  groups_included = [data.okta_group.everyone.id]

  complexity = {
    min_length = 16
  }

  lockout = {
    max_attempts        = 5
    auto_unlock_minutes = 60
  }

  rules = {
    default = {
      name            = "Self-service allowed"
      priority        = 1
      password_change = "ALLOW"
      password_reset  = "ALLOW"
      password_unlock = "ALLOW"
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
| `auth_provider` | `string` | `OKTA` | OKTA, ACTIVE_DIRECTORY, or LDAP. |
| `complexity` | `object` | see above | Length and character rules. |
| `age` | `object` | see above | Expiry and history. |
| `lockout` | `object` | see above | Lockout thresholds. |
| `recovery` | `object` | see above | Self-service recovery channels. |
| `rules` | `map(object)` | n/a | Rules keyed by logical name. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_id` | Password policy ID. |
| `policy_name` | Policy display name. |
| `rule_ids` | Map of rule key to rule ID. |

## Import

```hcl
import {
  to = module.password_policy.okta_policy_password.this
  id = "00p0000000000000000"
}

import {
  to = module.password_policy.okta_policy_rule_password.this["default"]
  id = "00p0000000000000000/0pr0000000000000000"
}
```
