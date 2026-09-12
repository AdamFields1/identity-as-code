# modules/okta/session-policy

Manages one Okta sign-on policy and its rules. Session behaviour (idle timeout,
lifetime, persistent cookie) is set once at the policy level and inherited by every
rule unless a rule overrides it. That keeps tenant values short and makes "prod has a
shorter idle timeout than dev" a one-line difference.

## Design notes

- Rules are a map keyed by a logical name with an explicit `priority`. Maps have no
  order, so the priority is required and must be unique.
- The policy resource has `lifecycle { prevent_destroy = true }`. Removing a sign-on
  policy from a live tenant is never an accident we want Terraform to carry out.
  An engineer must edit the lifecycle block in the same PR, which makes the decision
  visible in review.
- MFA prompt and lifetime attributes are only sent when `mfa_required` is true, and
  zone lists only when `network_connection` is `ZONE`. This keeps plans clean.
- Group IDs are inputs. The module does not look up groups by name; the calling stack
  does that so the lookup happens exactly once per tenant.

## Usage

```hcl
module "session_policy" {
  source = "../../modules/okta/session-policy"

  name            = "Workforce sign-on"
  priority        = 1
  groups_included = [data.okta_group.everyone.id]

  session_defaults = {
    idle_minutes      = 60
    lifetime_minutes  = 480
    persistent_cookie = false
  }

  rules = {
    corp-network = {
      name               = "Corporate network"
      priority           = 1
      mfa_required       = true
      mfa_prompt         = "SESSION"
      mfa_lifetime       = 480
      network_connection = "ZONE"
      zone_ids_included  = [module.network_zones.zone_ids["corp-egress"]]
    }

    anywhere = {
      name         = "Anywhere else"
      priority     = 2
      mfa_required = true
      mfa_prompt   = "ALWAYS"
      session_idle = 30
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name` | `string` | n/a | Policy display name. |
| `description` | `string` | Managed by Terraform | Description. |
| `priority` | `number` | `null` | Policy priority, 1 is first. |
| `status` | `string` | `ACTIVE` | ACTIVE or INACTIVE. |
| `groups_included` | `list(string)` | n/a | Group IDs the policy applies to. |
| `session_defaults` | `object` | 120 / 720 / false | Idle minutes, lifetime minutes, persistent cookie. |
| `rules` | `map(object)` | n/a | Rules keyed by logical name. See `variables.tf`. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_id` | Sign-on policy ID. |
| `policy_name` | Policy display name. |
| `rule_ids` | Map of rule key to rule ID. |

## Import

```hcl
import {
  to = module.session_policy.okta_policy_signon.this
  id = "00p0000000000000000"
}

import {
  to = module.session_policy.okta_policy_rule_signon.this["corp-network"]
  id = "00p0000000000000000/0pr0000000000000000"
}
```

Rule imports use the `policy_id/rule_id` form.
