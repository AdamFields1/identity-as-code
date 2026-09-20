# modules/okta/app-saml

Manages a map of custom SAML 2.0 applications and their group assignments. It is
the SAML entry of the Okta applications catalog stack: a cell says where the
service provider lives, how the subject is named, which attributes the assertion
carries, which groups may open the app, and which sign-on policy protects it.
The signing settings, the SAML version, and the absence of an inline hook are
fixed here and are not inputs.

## Design notes

- **Apps are a map keyed by logical name.** Adding or removing an app never
  re-addresses its neighbours. The visible name is `label`, which must be unique
  across the map because Okta shows it on the dashboard tile and in every audit
  event for the app.
- **Signing is fixed, not chosen.** Both the response and the assertion are
  signed with `RSA_SHA256` and a `SHA256` digest, `honor_force_authn` is true so
  a service provider that asks for re-authentication gets it,
  `accessibility_self_service` is false so users cannot assign themselves, the
  authentication context is `PasswordProtectedTransport`, and the SAML version
  is 2.0. None of these has an input. Weakening one is a module change and a
  code review, not a per-app knob.
- **No inline hook.** `inline_hook_id` has no input, so no assertion this module
  issues can be rewritten by code that lives outside this repository.
- **Endpoints are https with a host and no wildcard.** `sso_url`, `audience`,
  `recipient`, `destination`, and the single logout URL are all checked with the
  same rule. The ACS URL is where Okta posts a signed statement about a user; a
  pattern there is an open redirect for identities, and http would carry the
  assertion in clear. `audience` is held to the same rule, so a vendor whose
  entity id is a URN rather than a URL is outside this catalog shape today.
- **`recipient` and `destination` default to `sso_url`.** That is what almost
  every service provider expects; a cell overrides them only when the vendor
  documents a different value, and the override is in the diff.
- **Attribute statements are typed.** An `EXPRESSION` statement carries
  `values`; a `GROUP` statement carries `filter_type` and `filter_value` and
  nothing else. A group statement without a filter is refused because it would
  send every group the user belongs to, which is a directory leak to the vendor.
  The fields that do not belong to a statement's type are refused rather than
  dropped, so a mistake in the cell is visible instead of silent.
- **Groups are names, resolved here.** Every distinct name across every app is
  looked up once with `data.okta_group`. The groups are provisioned into Okta by
  the upstream identity provider, not by this module, so a name that does not
  exist fails the plan with the name in the error. That is the honest failure:
  an empty assignment would look like a working app that nobody can open.
- **One assignments resource per app.** `okta_app_group_assignments` holds an
  app's complete group list, so a group removed from the cell is unassigned on
  the next apply. Apps with no groups get no resource.
- **The sign-on policy is an id the stack passes.** A cell names a policy key;
  the calling stack resolves it against the sign-on policy module and passes
  `authentication_policy_id`. Null leaves the app on the org default policy.
  `tier = "admin"` is carried through so the stack can require a
  phishing-resistant policy on that app; the module itself does not act on it.
- **Branding is the owner's.** `logo` is the only attribute in `ignore_changes`.
  An owner uploads it from the admin console after creation and Terraform never
  reverts it. Everything else, including every endpoint, signing setting,
  attribute statement, and the policy binding, is enforced on every apply,
  because those are the controls.
- **Nothing secret is created or stored.** Okta generates the signing key and
  the module outputs only its certificate and key id, both public.

## Usage

```hcl
module "saml_apps" {
  source = "../../modules/okta/app-saml"

  apps = {
    payroll = {
      label    = "Example Payroll"
      sso_url  = "https://payroll.example.com/saml/acs"
      audience = "https://payroll.example.com"

      subject_name_id_format = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

      attribute_statements = [
        { name = "email", type = "EXPRESSION", values = ["user.email"] },
        { name = "name", type = "EXPRESSION", values = ["user.displayName"] },
        { name = "groups", type = "GROUP", filter_type = "STARTS_WITH", filter_value = "app-payroll-" },
      ]

      group_names              = ["app-payroll-users", "app-payroll-admins"]
      authentication_policy_id = module.signon_policies.policy_ids["standard-workforce"]
    }

    vendor-admin-console = {
      label    = "Example Vendor Admin Console"
      sso_url  = "https://admin.vendor.example.com/sso/saml"
      audience = "https://admin.vendor.example.com"
      tier     = "admin"

      single_logout = {
        url         = "https://admin.vendor.example.com/sso/slo"
        issuer      = "https://admin.vendor.example.com"
        certificate = "MIIC...base64 body only..."
      }

      group_names              = ["app-vendor-admins"]
      authentication_policy_id = module.signon_policies.policy_ids["admin-phishing-resistant"]
    }
  }
}
```

The NameID template defaults to the user's Okta username. When a cell sets it,
the Okta expression is written escaped, `"$${user.userName}"`, so Terraform
passes it through instead of trying to interpolate it.

## What this module refuses

- A `label` that is blank or longer than 100 characters, or two apps with one
  label.
- An `sso_url`, `audience`, `recipient`, `destination`, or `single_logout.url`
  that is not https, has no host, or contains a wildcard.
- A `subject_name_id_format` outside the four-entry allowlist; a blank
  `subject_name_id_template`.
- An attribute statement with a blank or repeated name, an unknown `type` or
  `namespace`, an `EXPRESSION` statement without `values`, a `GROUP` statement
  without `filter_type` (one of `STARTS_WITH`, `EQUALS`, `CONTAINS`, `REGEX`)
  and `filter_value`, or a statement that carries the other type's fields.
- A `single_logout` with a blank issuer, a blank certificate, or a certificate
  that still has its `BEGIN CERTIFICATE` and `END CERTIFICATE` lines.
- A `status` other than `ACTIVE` or `INACTIVE`; a `tier` other than `standard`
  or `admin`.
- A blank or repeated entry in `group_names`; a `group_assignment_priorities`
  key that is not in `group_names`.
- At plan time: a group name that does not exist in the org.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `apps` | `map(object)` | n/a | SAML apps keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `apps` | Map of key to `{ id, label, entity_url, http_post_binding, metadata_url, certificate, key_id, status }`. |
| `app_ids_by_label` | Map of app label to app ID. |
| `vendor_onboarding` | Map of key to `{ entity_id, sso_url, metadata_url, certificate }`, the four values a service provider asks for. |

## Import

Apps and their group assignments both import by the app ID.

```hcl
import {
  to = module.saml_apps.okta_app_saml.this["payroll"]
  id = "0oa0000000000000000"
}

import {
  to = module.saml_apps.okta_app_group_assignments.this["payroll"]
  id = "0oa0000000000000000"
}
```
