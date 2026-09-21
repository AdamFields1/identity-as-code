# modules/okta/idp-routing-rules

Manages a map of routing rules on the org's identity provider discovery policy.
It is the routing half of the Okta federation stack: a cell says who (a pattern
on the username or a profile attribute), from where (a network condition), on
what (an application and platform condition), and which SAML 2.0 identity
providers those sign-ins are sent to. The policy itself is not created here;
every org has exactly one, and the calling stack looks it up by name and passes
its id.

## Design notes

- **Rules are a map keyed by logical name with an explicit `priority`.** A map
  has no order, so the priority is required and must be unique across the map.
  1 is evaluated first. The policy's default rule, which routes to Okta itself,
  is immutable and always last, so a sign-in no rule matches still reaches the
  Okta sign-in page.
- **The policy is an id the stack passes.** Okta names the one `IDP_DISCOVERY`
  policy "Idp Discovery Policy"; the provider's documentation for this resource
  looks it up with `data.okta_policy` by that name and type. The calling stack
  does that lookup and passes `policy_id`, so no cell or module carries an Okta
  object id.
- **The routing target is fixed to `SAML2`.** Every `idp_ids` entry becomes an
  `idp_providers` block of type `SAML2`. An OIDC or social identity provider,
  or a rule that routes back to Okta, is a different shape and is out of scope.
  The API allows up to ten providers per rule and the module holds that line.
- **Identifier conditions are typed.** `IDENTIFIER` matches the patterns
  against the username the person typed; `ATTRIBUTE` matches them against one
  profile attribute and needs `user_identifier_attribute`, which is refused for
  `IDENTIFIER` rather than dropped. An `EXPRESSION` pattern must be the rule's
  only pattern, as the provider documents.
- **Zone lists only with `ZONE`.** Includes and excludes are sent only when
  `network_connection` is `ZONE`, and the provider declares the two lists as
  conflicting, so a `ZONE` rule carries exactly one of them. The other
  connection types (`ANYWHERE`, `ON_NETWORK`, `OFF_NETWORK`) refuse zone lists.
- **Application conditions are typed.** An `APP` entry carries an id, resolved
  by the calling stack from the application's label with `data.okta_app`; an
  `APP_TYPE` entry carries a type name. The field that does not belong to the
  entry's type is refused rather than dropped. The reason `app_exclude` exists
  in this catalog is the admin console: a rule that routes workforce sign-ins
  to an upstream identity provider excludes it so administrators keep a direct
  path into Okta with the factors `okta-config` enrolls, and an outage upstream
  does not lock them out.
- **Platform conditions are optional.** `platform_include` defaults to empty,
  which means every platform. `os_expression` belongs to `os_type = "OTHER"`
  only.
- **Ids come from the stack.** Identity providers, zones, and applications are
  ids here. The calling stack resolves names and labels, the way `okta-config`
  resolves `zones_included`, so the lookup happens once per stack and a name
  that does not exist fails the plan with the name in the error.
- **The feature has a flag.** The provider notes that an org without the
  `ADVANCED_SSO` feature refuses this resource with "You do not have permission
  to access the feature you are requesting". That is an org entitlement, not a
  configuration error.

## Usage

```hcl
data "okta_policy" "idp_discovery" {
  name = "Idp Discovery Policy"
  type = "IDP_DISCOVERY"
}

module "routing_rules" {
  source = "../../modules/okta/idp-routing-rules"

  policy_id = data.okta_policy.idp_discovery.id

  rules = {
    workforce-to-entra = {
      name     = "Workforce to Entra"
      priority = 1

      patterns = [
        { match_type = "SUFFIX", value = "example.com" },
      ]

      idp_ids = [module.identity_providers.identity_providers["entra"].id]

      app_exclude = [
        { type = "APP", id = data.okta_app.admin_console.id },
      ]
    }

    contractors-on-corp-network = {
      name     = "Contractors on the corp network"
      priority = 2

      user_identifier_type      = "ATTRIBUTE"
      user_identifier_attribute = "company"
      patterns = [
        { match_type = "EQUALS", value = "Example Contracting" },
      ]

      idp_ids = [module.identity_providers.identity_providers["entra"].id]

      network_connection = "ZONE"
      zone_ids_included  = [data.okta_network_zone.this["corp-egress"].id]

      platform_include = [
        { type = "DESKTOP", os_type = "WINDOWS" },
      ]
    }
  }
}
```

## What this module refuses

- A blank `policy_id`.
- A `name` that is blank or longer than 50 characters, or two rules with one
  name.
- A `priority` that is not a positive whole number, or two rules with one
  priority.
- A `status`, `user_identifier_type`, `match_type`, `network_connection`,
  application `type`, platform `type`, or `os_type` outside its allowlist.
- `ATTRIBUTE` without `user_identifier_attribute`, or `IDENTIFIER` with one.
- No pattern; a pattern with a blank value; an `EXPRESSION` pattern beside
  another pattern.
- No `idp_ids`, more than ten, a blank entry, or a repeated entry.
- Zone lists with a connection other than `ZONE`; a `ZONE` rule with no zones
  or with both includes and excludes; a blank zone id.
- An `APP` entry without an id or with a name; an `APP_TYPE` entry without a
  name or with an id; a repeated application entry.
- `os_expression` without `os_type = "OTHER"`, or `OTHER` without one.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `policy_id` | `string` | n/a | Id of the org's `IDP_DISCOVERY` policy, looked up by the calling stack. |
| `rules` | `map(object)` | n/a | Routing rules keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `rules` | Map of key to `{ id, name, priority, status }`. |
| `rule_ids` | Map of key to routing rule ID. |

## Import

A rule imports by `<policy_id>/<rule_id>`.

```hcl
import {
  to = module.routing_rules.okta_policy_rule_idp_discovery.this["workforce-to-entra"]
  id = "00p0000000000000000/0pr0000000000000000"
}
```
