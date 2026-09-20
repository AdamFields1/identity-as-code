# modules/okta/app-signon-policy

Manages a set of Okta app sign-on policies (the console calls them authentication
policies; the API calls them `ACCESS_POLICY`) and their rules from a single map.
An app module points at one of these through `authentication_policy`, so the
policies are created first and their ids are exported by key. A rule says what
an ALLOW demands: how many factors, how often the user re-authenticates, and
which authenticator properties (phishing resistant, hardware protected, device
bound) are required; and when it applies: a network zone, a managed or registered
device, a set of groups. Zones and groups are named, never id'd, so a tenant cell
reads like a menu.

## Design notes

- The map key is a stable logical name (`standard-workforce`,
  `admin-phishing-resistant`). It is part of the Terraform address and is what an
  app module names, so it never changes once applied. The display name in Okta is
  `name` and can change freely.
- Rules are a map keyed by a logical name with an optional `priority`. Maps have
  no order, so a rule that cares where it sits carries a priority, unique within
  the policy. Rules without one are appended by Okta after those that have one.
- Zones and groups are looked up by name inside the module, one data source per
  distinct name across every rule. A cell is values only (ADR 0002) and a name is
  the only thing it can say. A missing zone or group fails the plan, which is the
  honest failure: the corp Entra tenant provisions the groups and the okta-config
  cell creates the zones, so a missing one is a sequencing mistake and not
  something a default should paper over.
- Authenticator constraints are a typed shape, not JSON. The provider takes
  `constraints` as a list of JSON strings; the module builds that string with
  `jsonencode` from `constraints.possession` and `constraints.knowledge`, emitting
  only the fields a rule actually sets. A flag left at `OPTIONAL` is the API
  default, and sending it back explicitly is a perpetual diff on some provider
  versions.
- Factor mode, re-authentication frequency, and constraints describe an ALLOW, so
  they are sent as null on a DENY rule. Zone ids are sent only when the connection
  type is `ZONE`. This keeps plans clean.
- `device_is_managed = true` implies `device_is_registered = true`. Okta evaluates
  management only on a registered device, so a managed rule that says nothing
  about registration gets it set; one that says `false` is refused.
- The policy resource has `lifecycle { prevent_destroy = true }`, as the session
  policy does. The provider warns that destroying an app sign-on policy reassigns
  every app on it to the org's default policy, which is the permissive one. An
  engineer must edit the lifecycle block in the same PR, which makes that
  fall-through a visible decision in review.
- `phishing_resistant_only` is computed from the input values rather than from
  the resources, so a stack can check it at plan time before it points an
  admin-tier app at a policy.

### The catch-all rule

Okta creates a system rule (`system = true`, the "Catch-all Rule") on every app
sign-on policy. It matches whatever the named rules do not, its conditions are
immutable, and it cannot be deleted. Left alone, it ALLOWS.

This module sets `catch_all = false`, so the system rule is created with access
DENY. Every path to ALLOW is then a named rule in the map, which is what makes
`phishing_resistant_only` a true statement about the policy and not just about
the rules the module wrote. The module does not manage the system rule as a
resource: importing it only to hold a DENY that creation already set would give
one fact two addresses, and the provider lists most of its fields as immutable.
Its id is exported as `default_rule_ids` so an audit can read it.

The provider applies `catch_all` at creation only. A policy imported into this
module keeps whatever its catch-all already says, so after an import check the
rule once in the console or through the API and set it to DENY by hand if it is
not. The module never creates a permissive catch-all; a policy that needs an
"everyone else" ALLOW writes it as a named rule at the lowest priority, where it
is reviewed like any other.

## Usage

```hcl
module "app_signon_policies" {
  source = "../../modules/okta/app-signon-policy"

  policies = {
    standard-workforce = {
      name = "Standard workforce"
      rules = {
        corp-or-managed = {
          name                        = "Corporate network or managed device"
          priority                    = 1
          access                      = "ALLOW"
          factor_mode                 = "2FA"
          re_authentication_frequency = "PT12H"
          network_connection          = "ZONE"
          network_zone_names          = ["Corporate Egress", "VPN"]
        }
        managed-anywhere = {
          name              = "Managed device, any network"
          priority          = 2
          access            = "ALLOW"
          device_is_managed = true
        }
      }
    }

    admin-phishing-resistant = {
      name = "Admin phishing resistant"
      rules = {
        admins = {
          name                        = "Phishing-resistant, hardware-protected, every time"
          priority                    = 1
          access                      = "ALLOW"
          re_authentication_frequency = "PT0S"
          constraints = {
            possession = {
              phishing_resistant = "REQUIRED"
              hardware_protected = "REQUIRED"
            }
          }
          group_names = ["app-vendor-admins"]
        }
      }
    }
  }
}

module "payroll" {
  source = "../../modules/okta/app-saml"
  # ...
  authentication_policy = module.app_signon_policies.policy_ids["standard-workforce"]
}
```

## What this module refuses

- An ALLOW rule with `factor_mode = "1FA"` unless the policy sets
  `allow_single_factor = true`; that flag without a non-empty
  `single_factor_reason`; and a reason without the flag.
- A policy with no ALLOW rule, including one with no rules. The catch-all is
  DENY, so such a policy denies everyone: that is a deactivation of the app, not
  a sign-on policy, and an app is deactivated by setting its status.
- `network_connection = "ZONE"` with no `network_zone_names`, and zone names on
  any other connection type, where they would be silently ignored.
- A value outside its allowlist: `access` (ALLOW, DENY), `factor_mode` (1FA,
  2FA), `network_connection` (ANYWHERE, ZONE, ON_NETWORK, OFF_NETWORK), the four
  possession flags (REQUIRED, OPTIONAL), `possession.types` (app, email, phone,
  security_key, federated), and `knowledge.types` (password, security_question).
- A `re_authentication_frequency`, on the rule or on the knowledge constraint,
  that is not an ISO 8601 duration of days, hours, minutes, and seconds.
- Duplicate rule priorities within a policy, a priority that is not a positive
  integer, duplicate policy names across the map, an empty policy or rule name,
  and a zone or group name that is empty or listed twice in one rule.
- `device_is_managed = true` together with `device_is_registered = false`.
- At plan time: a zone or group name that does not exist in the org.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `policies` | `map(object)` | n/a | Policies keyed by logical name, each with its rules. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_ids` | Map of policy key to policy ID, for an app module's `authentication_policy`. |
| `policy_names_by_key` | Map of policy key to display name. |
| `phishing_resistant_only` | Map of policy key to true when every ALLOW rule requires a phishing-resistant possession factor. Computed from the values, so it is known at plan time. |
| `rule_ids` | Map of policy key to a map of rule key to rule ID. |
| `default_rule_ids` | Map of policy key to the ID of the system catch-all rule, created with DENY and not managed here. |

## Import

Policies import by id, rules by `policy_id/rule_id`. The rule address is
`"<policy key>/<rule key>"`. After importing a policy, check its catch-all rule
once (see above): `catch_all` applies at creation only.

```hcl
import {
  to = module.app_signon_policies.okta_app_signon_policy.this["standard-workforce"]
  id = "rst0000000000000000"
}

import {
  to = module.app_signon_policies.okta_app_signon_policy_rule.this["standard-workforce/corp-or-managed"]
  id = "rst0000000000000000/rul0000000000000000"
}
```
