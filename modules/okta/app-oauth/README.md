# modules/okta/app-oauth

Manages a map of OIDC applications (`okta_app_oauth`) and their group
assignments. It is the OIDC entry of the Okta application catalog
(`stacks/okta-applications`): a cell picks a type, names its redirect URIs and
its groups, and points at a sign-on policy by key. The cell never writes a grant
type, a response type, an authentication method, a client id, or a secret,
because the module derives those from the type and refuses the rest.

## Design notes

- **The type is the catalog entry.** Everything the OAuth 2.0 security best
  current practice cares about is fixed by `type` and cannot be overridden:

  | Type | Grant types | Response types | PKCE | Token endpoint auth | Redirect URIs |
  |------|-------------|----------------|------|---------------------|---------------|
  | `web` | `authorization_code`, `refresh_token` | `code` | required | `private_key_jwt` (`client_secret_basic` only with `allow_client_secret`) | required |
  | `browser` | `authorization_code`, `refresh_token` | `code` | required | `none` | required |
  | `native` | `authorization_code`, `refresh_token`, plus `device_code` only through `extra_grant_types` | `code` | required | `none` | required |
  | `service` | `client_credentials` | `token` | n/a | `private_key_jwt` (`client_secret_basic` only with `allow_client_secret`) | refused |

  The `token` response type on a service app is what the Okta app API pairs
  with `client_credentials` (the provider appends it itself whenever that
  grant is present); it is not the implicit flow, and a service app has no
  redirect URI for a token to land in. That is the one exception to the rule
  that `response_types` is `code` only, and a precondition on the resource
  holds it to grant types of exactly `client_credentials`, so an edit to the
  type table cannot widen it. Implicit and hybrid are grant and response
  combinations the module has no input for, so they cannot be typed, only
  refused.
- **Fixed for every type.** `omit_secret = true`, `wildcard_redirect =
  "DISABLED"`, `auto_key_rotation = true`, and on the types that carry
  `refresh_token`, `refresh_token_rotation = "ROTATE"` with a
  `refresh_token_leeway` of 30 seconds. `issuer_mode` is left at the provider
  default. No `client_id` or `client_secret` is ever set, so Okta mints both.
- **The secret never enters state.** With `omit_secret` fixed true the provider
  does not read the client secret back, so it is not in the state file and not
  in any output. `web` and `service` apps therefore default to `private_key_jwt`
  and ask the cell for a `jwks_uri`. A client that cannot hold a key pair sets
  `allow_client_secret = true`, which switches the token endpoint to
  `client_secret_basic` and puts the word secret in the diff; the app owner
  reads the secret once from the console.
- **Public clients are public.** `browser` and `native` use PKCE with
  `token_endpoint_auth_method = "none"`, and `allow_client_secret` is refused
  on them, because a secret shipped in a bundle is not a secret.
- **URIs are https and exact.** Redirect and post-logout URIs must be `https://`
  with no `*`; `wildcard_redirect` is `DISABLED` on every app so a future edit
  cannot loosen the match. `http://localhost:<port>/...` is accepted only when
  the app sets `allow_localhost_redirects = true`, which a dev cell may do and a
  prod cell never does. Every other URI the cell can name (`jwks_uri`,
  `login_uri`, `client_uri`, `logo_uri`, `policy_uri`, `tos_uri`) is https with
  no wildcard too.
- **The groups claim is a filter, not an expression.** `groups_claim` is always
  a `FILTER` claim on group names with one of `STARTS_WITH`, `EQUALS`,
  `CONTAINS`, or `REGEX`. An `EXPRESSION` claim would let a cell write Okta
  Expression Language, which is a policy document by another name (ADR 0017).
- **Groups are names, looked up once.** `group_names` are resolved with the
  `okta_group` data source, one lookup per distinct name across the whole map,
  and assigned with one `okta_app_group_assignments` resource per app. The
  provider owns the app's whole assignment list, so a group removed from the
  cell is unassigned on the next apply. Groups are provisioned into Okta by the
  upstream identity provider; a name that does not exist fails the plan with
  the name in the error, which is the honest failure.
- **The sign-on policy is an ID from the stack.** `authentication_policy_id`
  is resolved by `stacks/okta-applications` from the policy key the cell wrote;
  `tier` travels with the app so the stack can require a phishing-resistant
  policy on `admin` apps. The module itself acts on neither.
- **`logo_uri` is ignored after creation.** App owners replace the logo from
  the console and Okta rewrites the stored URI. Tracking it would make every
  later plan fight a change nobody in this repository made, so it is the one
  attribute under `ignore_changes`.
- **No `prevent_destroy`.** Unlike a sign-on policy, removing an app from a
  cell is the routine way to offboard it, and the removal is a reviewable
  diff of the cell.

## Usage

```hcl
module "oauth_apps" {
  source = "../../modules/okta/app-oauth"

  apps = {
    orders-portal = {
      label                    = "Orders Portal"
      type                     = "web"
      redirect_uris            = ["https://orders.example.com/callback"]
      post_logout_redirect_uris = ["https://orders.example.com/"]
      jwks_uri                 = "https://orders.example.com/.well-known/jwks.json"
      groups_claim             = { name = "groups", filter_type = "STARTS_WITH", value = "app-orders-" }
      authentication_policy_id = module.signon_policies.policy_ids["standard-workforce"]
      group_names              = ["app-orders-users", "app-orders-admins"]
    }

    orders-console = {
      label                     = "Orders Console"
      type                      = "browser"
      redirect_uris             = ["https://console.orders.example.com/callback", "http://localhost:3000/callback"]
      allow_localhost_redirects = true
      authentication_policy_id  = module.signon_policies.policy_ids["standard-workforce"]
      group_names               = ["app-orders-users"]
    }

    orders-reporting-job = {
      label    = "Orders Reporting Job"
      type     = "service"
      jwks_uri = "https://reporting.orders.example.com/.well-known/jwks.json"
    }
  }
}
```

## What this module refuses

- A `type` other than `web`, `browser`, `native`, or `service`; a duplicate or
  empty `label`; a `status`, `consent_method`, `login_mode`, `tier`, or
  `groups_claim.filter_type` outside its list.
- The implicit or hybrid flow: there is no input for a response type or a
  grant type, and `extra_grant_types` accepts only
  `urn:ietf:params:oauth:grant-type:device_code`, and only on a `native` app.
- A `web` or `service` app without `jwks_uri` unless it sets
  `allow_client_secret = true`; `allow_client_secret` on a `browser` or
  `native` app.
- A redirect or post-logout URI that is not `https://`, with
  `http://localhost:<port>/...` accepted only under
  `allow_localhost_redirects = true`; a `*` in any URI the cell can name; a
  redirect-based app with no redirect URI.
- Redirect or post-logout URIs on a `service` app; a `groups_claim` on a
  `service` app.
- `login_mode` of `SPEC` or `OKTA` without a `login_uri`; a
  `group_assignment_priorities` key that is not in `group_names`; a repeated
  or empty group name.
- At plan time: a group name that does not exist in the org.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `apps` | `map(object)` | n/a | OIDC apps keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `apps` | Map of key to `{ id, label, client_id, type, status }`. Never a secret. |
| `client_ids_by_label` | Map of app label to OAuth client ID. |

## Import

Apps import by app ID, and group assignments by the app ID as well.

```hcl
import {
  to = module.oauth_apps.okta_app_oauth.this["orders-portal"]
  id = "0oa0000000000000000"
}

import {
  to = module.oauth_apps.okta_app_group_assignments.this["orders-portal"]
  id = "0oa0000000000000000"
}
```

An imported app keeps the secret Okta already holds; with `omit_secret` true
the provider does not read it back.
