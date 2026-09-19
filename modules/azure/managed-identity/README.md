# modules/azure/managed-identity

Manages a map of user-assigned managed identities, each with the GitHub
Actions federated credentials that let a workflow obtain a token for it. No
secret is created anywhere: what may act as an identity is a list of
(issuer, subject) pairs, and the subject is built here from a GitHub
organization, repository, and branch or environment.

## Design notes

- **The map key is a stable logical name** (`ci-deploy`). It is part of the
  Terraform address, and it is also how the `key-vault` and `storage-account`
  modules name the identity in a role assignment
  (`principal = { type = "identity", name = "ci-deploy" }`), so it should
  never change once applied. The visible name is `name`.
- **Federated, never a secret.** A federated credential trusts one issuer and
  one subject. A GitHub Actions job whose OIDC token carries exactly that
  subject exchanges it for an Entra token for the identity; nothing is
  issued, stored, or rotated. It is the same model the release train uses for
  its own access ([ADR 0003](../../../docs/adr/0003-no-long-lived-secrets-in-ci.md)).
- **The subject is built, not typed.** Entra matches the subject exactly, so
  a subject written by hand with a wildcard or a wrong prefix silently matches
  nothing and the workflow fails at login with no hint why. A credential says
  `organization`, `repository`, and either `branch` or `environment`, and the
  module writes `repo:<org>/<repo>:ref:refs/heads/<branch>` or
  `repo:<org>/<repo>:environment:<environment>`. Validation refuses a wildcard
  in a branch name for the same reason.
- **Branch or environment says what is trusted.** A branch credential trusts
  anyone who can push to that branch. An environment credential trusts the
  environment's protection rules (required reviewers, deployment branches),
  which is where this repository already puts its trust for the gated
  tenants (README, "Promotion is gated"). Prefer environments for anything
  that writes. Tag and pull-request subjects are deliberately not offered: a
  tag can be moved by anyone with write access, and a pull request subject
  trusts every fork's pull request.
- **Two outputs are the contract.** `principal_ids` (key to service
  principal object ID) is what the other catalog modules take as
  `identity_principal_ids`, so the stack wires an identity to a vault or an
  account by key and no cell holds a GUID. `client_ids` (key to client ID) is
  what the workflow passes to `azure/login` as `client-id`; it is not secret,
  and the stack can output it for whoever fills in the repository variables.
- **No `prevent_destroy`.** Deleting an identity removes its role assignments
  and federated credentials with it, and a workflow that used it stops at
  login: an outage that is visible at once and undone by re-applying the cell
  (with a new principal ID, so grants made outside this repository need
  redoing). That is not a loss of data, and the two shapes that do hold data
  (`key-vault`, `storage-account`) carry the flag instead.
- **The resource group is looked up by name**, like the Automation account's.
  A stack that creates the group in the same plan
  (`modules/azure/resource-group`) gives this module
  `depends_on = [module.resource_groups]`; Terraform then reads the group
  during apply instead of at plan time, and the plan shows the location as
  known after apply.

## What the workflow needs

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}          # client_ids output
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

All three are repository or environment variables, not secrets. The job must
run in the branch or environment the credential names, or the token's subject
will not match and login fails with `AADSTS70021` (no matching federated
identity record).

## What the apply identity needs

Managed Identity Contributor on the resource group creates identities and
their federated credentials; Contributor covers it too. Nothing here assigns
a role, so no `Microsoft.Authorization/roleAssignments/write` is needed.

## Usage

```hcl
module "identities" {
  source = "../../modules/azure/managed-identity"

  identities = {
    ci-deploy = {
      name                = "id-example-ci-deploy"
      resource_group_name = "rg-example-identity"

      federated_credentials = {
        main = {
          organization = "example-org"
          repository   = "example-app"
          branch       = "main"
        }
        prod = {
          organization = "example-org"
          repository   = "example-app"
          environment  = "prod"
        }
      }
    }

    rotation-job = {
      name                = "id-example-rotation"
      resource_group_name = "rg-example-identity"
    }
  }
}

module "vaults" {
  source = "../../modules/azure/key-vault"

  identity_principal_ids = module.identities.principal_ids
  # ...
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `identities` | `map(object)` | `{}` | Identities keyed by logical name: `name`, `resource_group_name`, `location`, `tags`, `federated_credentials`. See `variables.tf`. |
| `tags` | `map(string)` | `{}` | Tags applied to every identity; an entry's own tags are merged over them. |

## Outputs

| Name | Description |
|------|-------------|
| `identities` | Key to `{ id, name, principal_id, client_id, tenant_id, resource_group_name, location }`. |
| `principal_ids` | Key to service principal object ID; the `identity_principal_ids` input of `key-vault` and `storage-account`. |
| `client_ids` | Key to client ID, for the workflow's `client-id`. |
| `identity_ids` | Key to identity resource ID, for a resource that attaches the identity. |
| `federated_credentials` | `"<identity key>/<credential key>"` to `{ id, name, identity_key, issuer, subject, audience }`. |

## Import

```hcl
import {
  to = module.identities.azurerm_user_assigned_identity.this["ci-deploy"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-example-ci-deploy"
}

import {
  to = module.identities.azurerm_federated_identity_credential.this["ci-deploy/main"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-example-ci-deploy/federatedIdentityCredentials/main"
}
```
