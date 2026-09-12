# modules/entra/app-registration

Manages a map of Entra ID application registrations, each with an always-created
service principal, optional federated identity credentials for GitHub OIDC, API
permissions expressed by name, and optional enforced Microsoft Graph app-role grants.

## Design notes

- **Terraform is the inventory and the guardrail, not the sole editor.** The
  registration's identity (display name, sign-in audience, identifier URIs) and its
  requested API permissions are enforced on every apply. Everything an application
  owner routinely edits (owners, tags, redirect URIs, optional claims, branding) is
  set at creation and then covered by `ignore_changes`, so a portal edit is never
  reverted by the next pipeline run. See
  [ADR 0006](../../../docs/adr/0006-terraform-as-inventory-and-guardrail.md).
- **`ignore_changes` is a module constant, not a variable.** Terraform requires the
  list to be static attribute references. Narrowing or widening it is a change to
  this file and a code review, which is the right amount of friction for a decision
  that changes what the pipeline enforces.
- **`azuread_application_password` is deliberately absent.** Workload identity is
  federated. A GitHub Actions job presents its OIDC token and receives a short-lived
  Entra token; nothing is stored, nothing expires unnoticed, nothing leaks through
  state. A secret added in the portal is outside Terraform's view and is reported by
  `scripts/Export-EntraDrift.ps1`.
- **Permissions are names, never IDs.** `required_resource_access` is keyed by the
  published API name (`MicrosoftGraph`, `AzureServiceManagement`, ...) and lists
  permission names. The module resolves the API's client ID through
  `azuread_application_published_app_ids` and the role and scope IDs through the
  API's service principal. A misspelled name fails the plan with a clear message.
- **Enforced Graph grants are consent as code.** `enforced_graph_app_roles` creates
  `azuread_app_role_assignment` for each listed Graph application permission.
  Removing a name revokes the grant. A validation requires every enforced role to be
  declared in the manifest too, so consent and manifest never disagree.
- **Owners are user principal names.** Resolved with `azuread_user`. A missing user
  fails the plan early instead of creating an ownerless registration.

## Usage

```hcl
module "app_registrations" {
  source = "../../modules/entra/app-registration"

  applications = {
    payroll-api = {
      display_name    = "Payroll API"
      owners          = ["app.owner@corp.example.com"]
      identifier_uris = ["api://payroll-api"]

      required_resource_access = {
        MicrosoftGraph = {
          application = ["User.Read.All"]
          delegated   = ["User.Read"]
        }
      }

      enforced_graph_app_roles = ["User.Read.All"]

      federated_credentials = {
        github-prod = {
          display_name = "GitHub Actions (prod)"
          subject      = "repo:example-org/payroll-api:environment:prod"
        }
      }
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `applications` | `map(object)` | n/a | Registrations keyed by logical name. See `variables.tf` for the full shape. |

## Outputs

| Name | Description |
|------|-------------|
| `applications` | Map of key to `{ object_id, client_id, display_name, service_principal_object_id }`. |
| `client_ids` | Map of key to application (client) ID. |
| `service_principal_object_ids` | Map of key to service principal object ID. |
| `federated_credential_ids` | Map of `app/credential` key to credential ID. |
| `graph_app_role_assignment_ids` | Map of `app/role` key to assignment ID. |

## Import

The azuread 3.x provider addresses an application by its resource ID
(`/applications/<object id>`), a service principal by its object ID, and a federated
credential by `<application object id>/federatedIdentityCredential/<credential id>`.
`scripts/Export-EntraDrift.ps1` emits these blocks for every unmanaged registration.

```hcl
import {
  to = module.app_registrations.azuread_application.this["payroll-api"]
  id = "/applications/00000000-0000-0000-0000-000000000000"
}

import {
  to = module.app_registrations.azuread_service_principal.this["payroll-api"]
  id = "00000000-0000-0000-0000-000000000000"
}

import {
  to = module.app_registrations.azuread_application_federated_identity_credential.this["payroll-api/github-prod"]
  id = "00000000-0000-0000-0000-000000000000/federatedIdentityCredential/00000000-0000-0000-0000-000000000000"
}
```
