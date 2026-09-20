# stacks/okta-applications

The deployable unit for an Okta org's application catalog. It composes three
modules into one plan and one state file:

1. `app-signon-policy` creates the app sign-on policies and their rules, with
   zones and groups named rather than id'd.
2. `app-saml` creates the custom SAML 2.0 apps, bound to a policy by key, with
   their group assignments.
3. `app-oauth` creates the OIDC apps (web, browser, native, service), bound to a
   policy by key, with their group assignments.

Tenant cells under `tenants/okta/<env>/okta-applications/` point at this stack
and provide values only, one fragment file per map. Onboarding an application is
an entry in a fragment: the stack owns the wiring and the modules own the
guardrails, so a cell reads like a menu and a reviewer reads a diff of values.
See [ADR 0020](../../docs/adr/0020-applications-are-catalog-shapes-with-guardrails.md)
for why this is a catalog in shape and a platform stack in placement.

## What this stack does not manage

Authorization servers, scopes, claims, and token lifetimes are a later catalog.
SWA, bookmark, and basic-auth apps, user profile mappings, and the apps' own
provisioning of users and groups into the vendor are outside it. The groups the
cells name are created in Okta by the upstream identity provider (the corp Entra
tenant, as the repository README presents it), and the network zones a policy
rule names are created by the org's `okta-config` cell; this stack reads both
with data sources and never hardcodes an id. If a group or zone named in a cell
does not exist, the plan fails early with the name in the error rather than
creating an app nobody can open or a rule that matches nothing.

## How policies, zones, and groups are referenced

An app names its sign-on policy by the logical key used in `signon_policies`,
for example `signon_policy = "standard-workforce"`. The stack resolves the key
against the policy module's `policy_ids` output and passes the id to the app
module as `authentication_policy_id`, which also gives Terraform the dependency
edge it needs to create policies before apps. A validation block rejects a key
that is not in the map before the plan reaches the API. An app that names no
policy stays on the org's default app sign-on policy, which is the permissive
one; that is allowed on a standard-tier app and refused on an admin-tier one.

Inside a policy rule, `network_zone_names` and `group_names` are names, looked up
by the policy module once per distinct name. Inside an app, `group_names` are
names too, looked up by the app module the same way. Nothing in a cell is an id,
and the `okta-config` cell of the same org applies first because the zones it
creates are what the rules name (the cells declare that dependency).

## Onboarding an application

Two paths, one per protocol. Both start by picking a policy from
`signon-policies.hcl`; the worked cells carry `standard-workforce` (two factors,
re-authentication every twelve hours, from a corporate zone or a managed device)
and `admin-phishing-resistant` (phishing-resistant and hardware-protected
possession, re-authentication every time).

### A vendor's SAML app

The vendor's onboarding guide gives the two values the cell needs: the assertion
consumer service URL (`sso_url`) and the entity id the vendor expects as the
audience (`audience`). The cell says those, the NameID format the vendor asks
for, the attributes the assertion carries, the groups whose members may open the
app, and the policy:

```hcl
inputs = {
  saml_apps = {
    payroll = {
      label                  = "Example Payroll"
      sso_url                = "https://payroll.example.com/saml/acs"
      audience               = "https://payroll.example.com"
      subject_name_id_format = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
      attribute_statements = [
        { name = "email", type = "EXPRESSION", values = ["user.email"] },
        { name = "name", type = "EXPRESSION", values = ["user.displayName"] },
        { name = "groups", type = "GROUP", filter_type = "STARTS_WITH", filter_value = "app-payroll-" },
      ]
      group_names   = ["app-payroll-users", "app-payroll-admins"]
      signon_policy = "standard-workforce"
    }
  }
}
```

Everything the vendor would otherwise be asked to accept is fixed by the module
and not in the cell: SAML 2.0, response and assertion both signed with
RSA-SHA256 and a SHA256 digest, `honor_force_authn`, no self-service assignment,
https endpoints with no wildcard, and no inline hook. After apply, the
`saml_vendor_onboarding` output holds the four values the vendor configures on
their side: `entity_id` (the Okta issuer), `sso_url` (Okta's HTTP-POST binding),
`metadata_url`, and the signing `certificate`. None of them is secret; the
certificate is the public half of the signing key. Hand them over, and the
vendor's test login is the acceptance.

An admin console at a vendor is the same entry with `tier = "admin"` and
`signon_policy = "admin-phishing-resistant"`. The stack refuses the plan if the
policy it names accepts a phishable factor on any ALLOW rule ("What this stack
refuses").

### An internal OIDC app

The developer says what kind of client it is and where it redirects. A server-side
web app supplies a JWKS URI, because web and service apps authenticate to the
token endpoint with `private_key_jwt` and never a shared secret unless the cell
says `allow_client_secret = true`:

```hcl
inputs = {
  oauth_apps = {
    orders-portal = {
      label         = "Orders Portal"
      type          = "web"
      redirect_uris = ["https://orders.example.com/callback"]
      jwks_uri      = "https://orders.example.com/.well-known/jwks.json"
      groups_claim  = { name = "groups", filter_type = "STARTS_WITH", value = "app-orders-" }
      group_names   = ["app-orders-users", "app-orders-admins"]
      signon_policy = "standard-workforce"
    }
    orders-console = {
      label         = "Orders Console"
      type          = "browser"
      redirect_uris = ["https://console.orders.example.com/callback"]
      signon_policy = "standard-workforce"
    }
    orders-reporting-job = {
      label    = "Orders Reporting Job"
      type     = "service"
      jwks_uri = "https://reporting.orders.example.com/.well-known/jwks.json"
    }
  }
}
```

The type decides the rest, and the cell cannot override it: `authorization_code`
and `refresh_token` with `code` only on web, browser, and native (so the implicit
flow cannot be requested), `client_credentials` on service, PKCE on the public
types, refresh token rotation, `wildcard_redirect` disabled, and automatic key
rotation. A dev cell may set `allow_localhost_redirects = true` on a browser app
to add `http://localhost:<port>/...` to its redirect URIs; a prod cell never
does. A service app names no policy: client credentials has no user sign-in for a
sign-on policy to evaluate, and the token endpoint authenticates the client by
its keys.

After apply, the developer receives the `client_id` from `oauth_client_ids` and
the org's issuer and discovery document, which are the org's and not the app's.
There is no secret to hand over: `omit_secret` is fixed true in the module, so
the secret is never in state or in an output. A client that opted into
`allow_client_secret` reads its secret once from the admin console.

## What this stack refuses

The modules refuse everything about a single entry (see each module's README:
the URL rules, the allowlists, the type table, single-factor access without a
reason). This stack refuses what only the whole cell can show:

- A `signon_policy` that is not a key of `signon_policies`, on either app map.
- An app with `tier = "admin"` that names no policy, because unset means the
  org's default policy, which is the permissive one.
- An app with `tier = "admin"` whose policy has an ALLOW rule that does not set
  `constraints.possession.phishing_resistant = "REQUIRED"`. This is a
  precondition on the `saml_app_ids` and `oauth_app_ids` outputs rather than a
  variable validation, because it reads the policy module's
  `phishing_resistant_only` output: the module owns what phishing resistant
  means, and the stack asks it. The output is computed from the values, so the
  check runs at plan time and the message names the offending apps. It is a
  true statement about the policy because the module creates the catch-all rule
  with DENY, so every path to ALLOW is a named rule.
- A label that appears twice in one map or once in each. Okta allows it; the
  person clicking a tile cannot tell the apps apart.
- At plan time, from the modules: a zone or group name that does not exist in
  the org.

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "okta"` block is
generated by Terragrunt from tenant inputs (`okta_org_name`, `okta_base_url`) and the
API token is read by the provider from the `OKTA_API_TOKEN` environment variable. The
stack can therefore be planned against any tenant with no code changes. The two
variables are declared exactly as `stacks/okta-config` declares them, because
the same generated provider block reads both stacks.

## Standalone use without Terragrunt

```hcl
provider "okta" {
  org_name = "example-org"
  base_url = "oktapreview.com"
  # api_token read from OKTA_API_TOKEN
}

module "okta_applications" {
  source = "./stacks/okta-applications"

  okta_org_name = "example-org"
  okta_base_url = "oktapreview.com"

  signon_policies = {
    standard-workforce = {
      name = "Standard workforce"
      rules = {
        corp-zones = {
          name               = "Corporate zones"
          priority           = 1
          access             = "ALLOW"
          network_connection = "ZONE"
          network_zone_names = ["Corporate Egress", "VPN"]
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
        }
      }
    }
  }

  saml_apps = {
    vendor-admin-console = {
      label         = "Example Vendor Admin Console"
      sso_url       = "https://admin.vendor.example.com/sso/saml"
      audience      = "https://admin.vendor.example.com"
      tier          = "admin"
      group_names   = ["app-vendor-admins"]
      signon_policy = "admin-phishing-resistant"
    }
  }

  oauth_apps = {
    orders-console = {
      label         = "Orders Console"
      type          = "browser"
      redirect_uris = ["https://console.orders.example.com/callback"]
      signon_policy = "standard-workforce"
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `okta_org_name` | `string` | Org subdomain. |
| `okta_base_url` | `string` | okta.com, oktapreview.com, okta-emea.com, okta.mil. |
| `signon_policies` | `map(object)` | App sign-on policies keyed by logical name, each with rules that name zones and groups. Default `{}`. |
| `saml_apps` | `map(object)` | SAML apps keyed by logical name, the `app-saml` shape with `signon_policy` (a key of `signon_policies`) in place of the policy id. Default `{}`. |
| `oauth_apps` | `map(object)` | OIDC apps keyed by logical name, the `app-oauth` shape with `signon_policy` in place of the policy id. Default `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `signon_policy_ids` | Policy key to policy ID. |
| `saml_vendor_onboarding` | SAML app key to `{ entity_id, sso_url, metadata_url, certificate }`, what the vendor configures. |
| `saml_app_ids` | SAML app key to app ID. Carries the admin-tier precondition. |
| `oauth_client_ids` | OIDC app key to client ID, what the developer configures. Never a secret. |
| `oauth_app_ids` | OIDC app key to app ID. Carries the admin-tier precondition. |
