# stacks/entra-enterprise-apps

The deployable unit for an Entra tenant's application catalog over SAML. It
composes one module into one plan and one state file:

1. `saml-enterprise-app` creates, for each service provider in the map, the
   application (from a gallery template or from Entra's non-gallery template),
   its service principal in SAML mode, its signing certificate, a claims mapping
   policy rendered from typed values, the app role assignments that put groups
   in scope, and an optional provisioning job.

Tenant cells under `tenants/azure/<tenant>/entra-enterprise-apps/` point at this
stack and provide values only, as a fragment cell with one file for the map.
Onboarding an application is an entry in that fragment: the stack owns the
wiring and the cross-map checks, the module owns the guardrails, so a cell
reads like the portal's single sign-on page and a reviewer reads a diff of
values. See [ADR 0021](../../docs/adr/0021-entra-enterprise-applications-as-a-catalog-shape.md)
for this stack's record and [ADR 0020](../../docs/adr/0020-applications-are-catalog-shapes-with-guardrails.md)
for why this is a catalog in shape and a platform stack in placement; the
Okta counterpart is `stacks/okta-applications`, and the same vendor is
onboarded from either identity provider with the same values. In this
repository only `corp` has such a cell: application onboarding is confined to
the corporate tenant.

## What this stack does not manage

- **OIDC enterprise applications beyond app registrations.** Those are
  `stacks/entra-app-registrations` and `modules/entra/app-registration`.
- **Password-based and linked sign-on.** The module fixes
  `preferred_single_sign_on_mode` to `saml`; the other modes have no shape here.
- **The groups.** `app_roles_to_groups` names groups; the module looks them up.
  They are created in `stacks/entra-app-registrations` or provisioned elsewhere,
  and a name that does not exist fails the plan with the name in the error
  rather than creating an app nobody can open.
- **The provisioning connectors' OAuth authorisations.** A connector such as
  Google Workspace's is authorised by an administrator consenting in a dialog
  the portal opens. Terraform cannot perform that consent, so the cell leaves
  `provisioning` unset and the one console step is below.
- **Post-provisioning edits by owners.** Owners, tags, branding, optional
  claims and the group membership claim setting are set at creation and then
  ignored; the entity ID, reply and logout URLs, the signing certificate, the
  claims policy and the assignments are enforced on every apply. Terraform is
  the inventory and guardrail; owners keep day-to-day control. See
  [ADR 0006](../../docs/adr/0006-terraform-as-inventory-and-guardrail.md).

## Onboarding an application

Two paths, one per kind of application. Both are an entry in the cell's
`saml-apps.hcl`; the groups an entry names must already exist.

### A gallery application

Pick the gallery entry by its display name. The vendor's guide gives the entity
ID (for some gallery apps a bare identifier rather than a URI) and the
assertion consumer service URL; the cell says those, the sign-on URL the My
Apps tile starts from, who is mailed before the certificate expires, how the
subject is named, and which group opens the app through which of the
template's roles (usually `User`):

```hcl
inputs = {
  saml_apps = {
    google-workspace = {
      display_name                  = "Google Workspace"
      gallery_template_display_name = "Google Cloud / G Suite Connector by Microsoft"
      identifier_uris               = ["google.com"]
      reply_urls                    = ["https://www.google.com/a/example.com/acs"]
      sign_on_url                   = "https://www.google.com/a/example.com/ServiceLogin?continue=https://mail.google.com"
      notification_email_addresses  = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Google Workspace SAML signing" }
      name_id             = { source = "mail", format = "emailAddress" }

      app_roles_to_groups = {
        User = ["app-google-workspace-users"]
      }

      # provisioning stays unset: the Google connector is authorised by an
      # OAuth consent in the portal, which Terraform cannot perform.
    }
  }
}
```

The role must be one the template publishes. The module reads the instantiated
service principal's roles and refuses a name it does not find, listing what the
template publishes; on the first run of a new gallery app those roles are not
known until apply, so that check is deferred to apply once and runs at plan on
every later run (see the module README, Design notes).

### A custom application

Leave `gallery_template_display_name` unset. The vendor's guide gives the entity
ID and the ACS URL; the cell adds the attributes the assertion carries, each a
name the vendor expects and a source from the allowlist, and the app roles,
which the module creates on the application with the groups assigned through
them:

```hcl
inputs = {
  saml_apps = {
    example-payroll = {
      display_name                 = "Example Payroll"
      identifier_uris              = ["https://payroll.example.com"]
      reply_urls                   = ["https://payroll.example.com/saml/acs"]
      sign_on_url                  = "https://payroll.example.com/login"
      notification_email_addresses = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Example Payroll SAML signing" }
      name_id             = { source = "mail", format = "emailAddress" }

      claims = [
        { name = "email", source = "mail" },
        { name = "firstName", source = "givenName" },
        { name = "lastName", source = "surname" },
        { name = "groups", source = "groups" },
      ]

      app_roles_to_groups = {
        User  = ["app-payroll-users"]
        Admin = ["app-payroll-admins"]
      }
    }
  }
}
```

This is the same fictional vendor `tenants/okta/prod/okta-applications/saml-apps.hcl`
onboards: the same entity ID, ACS URL, subject and group names from either
identity provider; the attributes are each provider's rendering of the vendor's
guide (Okta sends `name` from `displayName`, Entra sends `firstName` and
`lastName`).

Everything the vendor would otherwise be asked to accept is fixed by the module
and not in the cell: assignment required, SAML as the sign-on mode, a signing
key Entra generates, a claims mapping policy the module renders (a cell never
writes JSON), https endpoints with a host and no wildcard, and the group claim
limited to the groups assigned to the application.

### What the outputs hand the vendor

After apply, `vendor_onboarding` holds, per app, what the service provider asks
for: `issuer`, `login_url` and `logout_url` (the tenant's SAML endpoints,
built from the provider's tenant ID and never typed), `metadata_url` (the
federation metadata for this app, which carries the public certificate),
`signing_certificate_thumbprint` (what to compare against the certificate the
vendor shows after the import), and `name_id_format` (the NameID format the
vendor should request; Entra honours the service provider's `NameIDPolicy`).
None of it is secret. Hand it over, and the vendor's test login is the
acceptance.

### Provisioning

For a connector that takes a SCIM endpoint and a bearer token, apply with
`provisioning` unset, obtain the endpoint and token from the vendor, and re-apply
with `provisioning = { template_id, base_address }` in the cell and the token
in the environment:

```sh
export TF_VAR_provisioning_secret_tokens='{
  example-payroll = "CHANGEME"
}'
```

The key is the app's key in `saml_apps`; the endpoint stays in the cell beside
the template, because it is not a secret. In CI the value is a GitHub
environment secret. The stack passes the map to the module's own sensitive
input, so neither the cell nor the `saml_apps` map ever holds the token; it is
written to the application's synchronization secret and to state, never to a
file in this repository. The template ID is what
`GET /servicePrincipals/<object id>/synchronization/templates` returns for the
instantiated application.

For Google Workspace the connector is authorised by an OAuth consent, so the
cell leaves `provisioning` unset and an administrator performs the one console
step once: open the enterprise application, Provisioning, Get started, New
configuration, Authorize, accept in the Google window, Test connection, Save,
then start provisioning. Nothing about that step is in state, and this stack
never reports drift on it.

## What this stack refuses

The module refuses everything about a single entry (see its README: the URL
rules, the allowlists, the claim and app role rules, provisioning without a
template). This stack refuses what only the whole cell can show:

- Two apps with one `display_name`, compared without case. Entra's duplicate
  check is case insensitive and would refuse the second app at apply; the
  person clicking a tile cannot tell the two apart either way.
- A reply URL that appears on two apps. An ACS URL belongs to one service
  provider; the same URL on a second app sends that vendor a signed assertion
  meant for another audience.
- An entity ID that appears on two apps. Entra requires identifier URIs to be
  unique in the tenant and would refuse the second app at apply.
- A `provisioning_secret_tokens` key that is not an app of this cell with
  `provisioning` set: a token with no job to use it.
- At plan time, from the module: a group name that does not exist in the
  tenant, and on a gallery app an app role display name the template does not
  publish (deferred to apply on the first run of a new app, see above).

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "azuread"` and
`provider "azurerm"` blocks are generated by Terragrunt (`tenants/azure/root.hcl`),
which supplies `tenant_id` and `subscription_id` from `ARM_TENANT_ID` and
`ARM_SUBSCRIPTION_ID` so no tenant cell contains a GUID. Both providers
authenticate with OIDC. `subscription_id` is accepted but unused by this
Entra-only stack. The two variables are declared exactly as
`stacks/entra-app-registrations` declares them, because the same generated
provider block reads both stacks.

## Standalone use without Terragrunt

```hcl
provider "azuread" {
  tenant_id = "00000000-0000-0000-0000-000000000000"
  use_oidc  = true
}

module "entra_enterprise_apps" {
  source = "./stacks/entra-enterprise-apps"

  tenant_id = "00000000-0000-0000-0000-000000000000"

  saml_apps = {
    example-payroll = {
      display_name                 = "Example Payroll"
      identifier_uris              = ["https://payroll.example.com"]
      reply_urls                   = ["https://payroll.example.com/saml/acs"]
      sign_on_url                  = "https://payroll.example.com/login"
      notification_email_addresses = ["iam-alerts@example.com"]

      signing_certificate = { display_name = "Example Payroll SAML signing" }

      claims = [
        { name = "email", source = "mail" },
        { name = "groups", source = "groups" },
      ]

      app_roles_to_groups = {
        User = ["app-payroll-users"]
      }
    }
  }
}
```

## Adopting existing applications

`scripts/Export-EntraDrift.ps1` writes its imports and skeleton for
`stacks/entra-app-registrations` and counts gallery and custom enterprise
applications only as non-candidates, so adoption here is by `import` blocks. Add the entry to the cell
exactly as the application is configured today, drop an `imports.tf` beside the
tenant `terragrunt.hcl` with the module README's import blocks (the
application by object ID, the service principal by object ID, and the claims
mapping policy when one exists), and plan. `root.hcl` picks the file up. The
service principal is also adopted automatically by `use_existing`, so its block
is only needed for a hand-built application whose SAML settings you intend to
enforce from now on. Expect the first apply to replace a custom application's
app roles with the module's (and every assignment on them), and to create the
signing certificate, the policy assignment and any provisioning job rather
than import them; a new certificate is a metadata re-import on the vendor side.
Plan until the second run shows 0 to add, 0 to change, 0 to destroy
(`tests/README.md`), apply, then delete `imports.tf`.

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `tenant_id` | `string` | Entra tenant ID. |
| `subscription_id` | `string` | Accepted for the generated azurerm provider; unused here. |
| `saml_apps` | `map(object)` | SAML enterprise applications keyed by logical name: the `saml-enterprise-app` shape, `provisioning = { template_id, base_address }` included; the token has its own input. Default `{}`. |
| `provisioning_secret_tokens` | `map(string)` | App key to the bearer token of its token-based SCIM connector. Sensitive; from `TF_VAR_provisioning_secret_tokens`, never from a cell, passed to the module's own sensitive input. Default `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `vendor_onboarding` | App key to `{ issuer, login_url, logout_url, metadata_url, signing_certificate_thumbprint, name_id_format }`, what the vendor configures. |
| `saml_endpoints` | `{ login_url, logout_url, issuer }` of the tenant, built from the provider's tenant ID. |
| `apps` | App key to `{ application_object_id, client_id, display_name, service_principal_object_id, metadata_url, signing_certificate_thumbprint, claims_mapping_policy_id }`. |
| `client_ids` | App key to application (client) ID. |
| `service_principal_object_ids` | App key to service principal object ID. |
| `signing_certificates` | App key to `{ key_id, thumbprint, start_date, end_date }`. |
| `app_role_ids` | App key to `{ role display name => role ID }` the groups were assigned with. |
| `assigned_group_ids` | Group display name to object ID, across every app. |
| `app_role_assignment_ids` | `app/role/group` key to assignment ID. |
| `synchronization_job_ids` | App key to provisioning job ID, for apps that set `provisioning`. |
