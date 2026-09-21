# modules/entra/saml-enterprise-app

Manages a map of SAML enterprise applications in Entra ID: for each service
provider the application (instantiated from a gallery template or from Entra's
non-gallery template), its service principal in SAML mode, a signing certificate,
a claims mapping policy rendered from typed values, the app role assignments that
put groups in scope, and optional provisioning. It is the Entra entry of the
application catalog ([ADR 0021](../../../docs/adr/0021-entra-enterprise-applications-as-a-catalog-shape.md),
on the shape [ADR 0020](../../../docs/adr/0020-applications-are-catalog-shapes-with-guardrails.md) set):
the same vendor is onboarded from either identity provider with the same values,
and `modules/okta/app-saml` is the Okta counterpart. The `entra-enterprise-apps`
stack calls it once with the cell's map.

The pattern is `modules/entra/aws-identity-center-app` generalised: that module
instantiates one gallery template, adopts the service principal the
instantiation creates, resolves the template's app role by display name, and
configures SCIM from variables. Each of those choices is kept here.

## Design notes

- **Apps are a map keyed by logical name.** Adding or removing an app never
  re-addresses its neighbours. The visible name is `display_name`, unique across
  the map and, through `prevent_duplicate_names`, in the tenant.
- **Gallery or custom, by one field.** `gallery_template_display_name` names a
  gallery entry, resolved by display name with `azuread_application_template`
  as the Identity Center module resolves its template. Null means a custom SAML
  application, instantiated from the non-gallery template Microsoft publishes
  for SAML, password and linked sign-on. That template's display name is not
  stated on any public documentation page, so the module resolves it by its
  published ID (`custom_template_id`, a constant that is the same in every
  tenant of the global cloud; the applicationTemplate: instantiate page lists
  the US Government and China IDs for a tenant that needs one) rather than by a
  guessed name. The data source still confirms the template exists at plan.
- **Assignment is the scope and SAML is the mode.** `app_role_assignment_required`
  is forced on and `preferred_single_sign_on_mode` is fixed to `saml`; neither
  has an input. `app_roles_to_groups` is the only way into an application, and
  an application with no assigned group is refused because it would sign in
  nobody.
- **App roles are resolved, never typed, and the two kinds differ.** For a
  gallery app the module reads `app_roles` from the instantiated service
  principal and picks the one enabled user-assignable role whose display name
  matches (usually `User`, the role gallery applications publish and the portal
  assigns by default); a precondition fails naming the missing role and listing
  what the template publishes. For a custom app the keys of `app_roles_to_groups`
  become the application's own app roles, each with an ID derived from the app
  key and the role name with `uuidv5`, so the check is a variable validation and
  the role set is enforced on every apply. The limit: a service principal's
  `app_roles` are computed, so on the first plan of a new gallery app they are
  unknown and Terraform defers the check to apply. The application, service
  principal and certificate apply first; the assignment fails with the message,
  and the corrected role name completes on the next run. On every later plan the
  roles are known and the check runs at plan. This is why the module holds two
  `azuread_application` resources, `gallery` and `custom`: `ignore_changes`
  must be static, a gallery app must ignore `app_role` (the provider reads the
  template's roles back on every refresh and would otherwise plan to remove
  them), and a custom app must enforce it.
- **The claims policy is rendered, never written.** `name_id` and `claims` are
  typed values. The module builds one `azuread_claims_mapping_policy` per app
  with `jsonencode` (a `ClaimsSchema` of `Source`/`ID`/`SamlClaimType` entries,
  the NameID being the entry whose claim type is the nameidentifier URI, and
  `IncludeBasicClaimSet` true) and binds it with
  `azuread_service_principal_claims_mapping_policy_assignment`, so a cell never
  contains a policy document (ADR 0002). The NameID source allowlist is the
  list Microsoft permits as a SAML NameID source. The signing certificate below
  is the service principal's own key, which is the custom signing key the claims
  mapping reference requires for mapped claims; `acceptMappedClaims` is not set,
  as the same page advises.
- **`name_id.format` is carried, not enforced.** A claims mapping policy has no
  element for the NameID format; Entra honours the `NameIDPolicy` the service
  provider sends and otherwise uses the source's default. The module validates
  the format against the allowlist and surfaces its URN in `vendor_onboarding`
  so the vendor's metadata requests it.
- **A groups claim is the application's group claim.** `groups` is not a claims
  mapping source. A claim with source `groups` sets `group_membership_claims` to
  `ApplicationGroup` (only the groups assigned to this application, which is
  the same set `app_roles_to_groups` names) and adds the `groups` optional
  claim on the SAML token with `cloud_displayname`, so the vendor receives
  group names as the Okta side sends them. Both are set at creation and then
  covered by `ignore_changes`, and the attribute name is Entra's fixed groups
  claim URI, which is why the claim must be named `groups`.
- **SAML endpoints are enforced; branding is not.** `identifier_uris` (the entity
  ID) and the web block (`reply_urls`, `logout_url`) are enforced on every
  apply, because they are where the assertion goes. Owners, tags, optional
  claims, the group membership claim setting and branding are set at creation
  and then left to the application owner, the same inventory-and-guardrail
  contract as `modules/entra/app-registration` (ADR 0006). `ignore_changes` is a
  module constant, not a variable; widening it is a code review.
- **Endpoints are https with a host and no wildcard.** `reply_urls`,
  `sign_on_url` and `logout_url` share one rule. The ACS URL is where Entra
  posts a signed statement about a user; a pattern there is an open redirect
  for identities, and http would carry the assertion in clear. `identifier_uris`
  is looser by design: a gallery app such as Google Workspace requires the bare
  identifier `google.com`, so an entity ID may be a URI or a bare host, with no
  wildcard either way.
- **The signing certificate is Entra's.** `azuread_service_principal_token_signing_certificate`
  makes Entra generate the key pair. The private key never leaves the tenant;
  the public certificate reaches the vendor inside the federation metadata.
  Rotation is a new certificate here and a metadata re-import on the vendor
  side. The provider requires the display name to start with `CN=`; a bare name
  in the cell is prefixed by the module.
- **Groups are names, resolved here.** Every distinct name across every app is
  looked up once with `azuread_group`. The groups are created in
  `stacks/entra-app-registrations` or provisioned elsewhere, so a name that does
  not exist fails the plan with the name in the error. That is the honest
  failure: an empty assignment would look like a working app that nobody can
  open.
- **The provisioning token is its own sensitive input.** `provisioning` in the
  map is `{ template_id, base_address }` only; the bearer token arrives in
  `provisioning_secret_tokens`, a sensitive map keyed by app, and the stack
  takes it from the environment, so a cell never mentions it and the map never
  holds a secret. The token is kept out of the map because Terraform refuses a
  `for_each` over a value derived from a sensitive one, and a map that holds
  the token is such a value; the only `nonsensitive()` in the module is on
  that variable's keys, which are app names, and the token itself is read only
  where the synchronization secret writes it. The provider stores it in state
  and in any saved plan, which is why the state container and plan artifacts
  are access controlled and why the token is rotated on the vendor side rather
  than treated as permanent.
- **The tenant's endpoints are built, never typed.** `saml_endpoints` and
  `vendor_onboarding` derive the login and logout URL
  (`https://login.microsoftonline.com/<tenant id>/saml2`, the
  SingleSignOnService and SingleLogoutService locations the federation metadata
  publishes), the issuer (`https://sts.windows.net/<tenant id>/`) and each
  app's metadata URL from the provider's tenant ID.

## What stays manual, and where

- **Provisioning connectors authorised by OAuth consent.** Google Workspace's
  connector is authorised by an administrator consenting in a Google dialog
  that the portal opens, and Terraform cannot perform that consent. The cell
  leaves `provisioning` unset and the one console step is: enterprise
  application, Provisioning, Get started, New configuration, Authorize, accept
  in the Google window, Test connection, Save, then start provisioning. Nothing
  about that step is in state, and the module never reports drift on it.
- **Token-based SCIM connectors** are the Identity Center pattern: apply with
  `provisioning` unset, obtain the endpoint and token from the vendor, set
  `provisioning = { template_id, base_address }` on the app, export the token
  as `TF_VAR_provisioning_secret_tokens` keyed by the app, and re-apply. The
  synchronization template ID is what
  `GET /servicePrincipals/<object id>/synchronization/templates` returns for
  the instantiated application.
- **The vendor side.** After apply, `vendor_onboarding` holds what the service
  provider asks for: issuer, login and logout URLs, the metadata URL, the
  signing certificate thumbprint and the NameID format to request. The vendor
  imports the metadata (or the certificate the metadata carries) and the
  thumbprint it shows is the one to compare against the output.

## Usage

```hcl
module "saml_apps" {
  source = "../../modules/entra/saml-enterprise-app"

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

The second entry is the same fictional vendor `modules/okta/app-saml` onboards:
the same entity ID, ACS URL, subject and group names from either identity
provider; the attributes are each provider's rendering of the vendor's guide
(Okta sends `name` from `displayName`, Entra sends `firstName` and `lastName`).

## What this module refuses

- A blank `display_name`, or two apps with one display name.
- A blank `gallery_template_display_name` (null means custom).
- An empty `identifier_uris`, or an entity ID with a wildcard or whitespace.
- An empty `reply_urls`; a reply, sign-on or logout URL that is not https, has
  no host, or contains a wildcard.
- No `notification_email_addresses`, or an entry that is not an address. (An
  address outside `example.com` in this repository is the placeholders lint's
  business, not the module's.)
- A blank `signing_certificate.display_name`; an `end_date` that is not RFC3339.
- A `name_id.source` outside `mail`, `userPrincipalName`, `employeeId`,
  `onPremisesSamAccountName`; a `name_id.format` outside `emailAddress`,
  `persistent`, `unspecified`.
- A claim with a blank name or a name with whitespace, a repeated name, a
  source outside the allowlist, a `groups` source not named `groups`, or the
  nameidentifier URI as a claim name.
- An app role display name that appears twice (case insensitively), a role
  with no groups, a group repeated within a role, or no app roles at all.
- `provisioning` without `template_id` (a `base_address` alone), a
  `template_id` that is not an identifier, or a `base_address` that is not
  https; a `provisioning_secret_tokens` key that names no app with
  `provisioning` set.
- At plan time: a group name that does not exist in the tenant. For a gallery
  app, an app role display name the template does not publish (at plan once
  the application exists, at apply on the first run, see Design notes).

## Out of scope

OIDC enterprise applications beyond app registrations (those are
`modules/entra/app-registration`), password-based single sign-on, linked
applications, and the provisioning connectors' OAuth authorisations.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `saml_apps` | `map(object)` | n/a | SAML enterprise applications keyed by logical name. See `variables.tf` for the full shape and validation rules. |
| `provisioning_secret_tokens` | `map(string)` | `{}` | App key to the bearer token of its token-based SCIM connector. Sensitive; from the environment or a sensitive stack variable, never a literal. Every key must name an app that sets `provisioning`. |
| `custom_template_id` | `string` | Microsoft's global-cloud non-gallery template ID | Template a custom (non-gallery) app is instantiated from. Override only for a US Government or China tenant. |

## Outputs

| Name | Description |
|------|-------------|
| `apps` | Map of key to `{ application_object_id, client_id, display_name, service_principal_object_id, metadata_url, signing_certificate_thumbprint, claims_mapping_policy_id }`. |
| `client_ids` | Map of key to application (client) ID. |
| `service_principal_object_ids` | Map of key to service principal object ID. |
| `saml_endpoints` | `{ login_url, logout_url, issuer }` of the tenant, built from the provider's tenant ID. |
| `vendor_onboarding` | Map of key to `{ issuer, login_url, logout_url, metadata_url, signing_certificate_thumbprint, name_id_format }`, what a service provider asks for. |
| `signing_certificates` | Map of key to `{ key_id, thumbprint, start_date, end_date }`. |
| `app_role_ids` | Map of key to `{ role display name => role ID }` the groups were assigned with. |
| `assigned_group_ids` | Group display name to object ID, across every app. |
| `app_role_assignment_ids` | `app/role/group` key to assignment ID. |
| `synchronization_job_ids` | Map of key to provisioning job ID, for apps that set `provisioning`. |

## Import

```hcl
import {
  to = module.saml_apps.azuread_application.custom["example-payroll"]
  id = "/applications/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.saml_apps.azuread_application.gallery["google-workspace"]
  id = "/applications/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.saml_apps.azuread_service_principal.this["example-payroll"]
  id = "/servicePrincipals/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.saml_apps.azuread_claims_mapping_policy.this["example-payroll"]
  id = "/policies/claimsMappingPolicies/00000000-0000-0000-0000-000000000000"
}
```

The service principal is also adopted automatically by `use_existing`, so its
block is only needed to adopt a hand-built application whose SAML settings you
intend to enforce from now on. An imported custom application's app roles are
replaced by the module's on the first apply, which re-creates every assignment
on them; the signing certificate, the policy assignment, the synchronization
secret and the job are recreated rather than imported, and a re-created
certificate is a metadata re-import on the vendor side.
