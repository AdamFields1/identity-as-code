# ADR 0004: Azure Storage for Azure state, authenticated with OIDC and no keys

Status: accepted
Date: 2026-09-12

## Context

The Okta tree keeps its state in S3 with an AWS OIDC role (ADR 0003). When the
Azure tree was added, the obvious shortcut was to reuse that bucket: one backend,
one bootstrap, one set of repository variables. The cost is that a pipeline whose
only job is to change Azure RBAC and PIM would then need an AWS identity as well as
an Azure one, a trust relationship between two clouds for the sake of a state file,
and a second place to look when something about the identity model needs auditing.

The other shortcut is Azure Storage with a storage account key. The azurerm backend
supports it, Terragrunt supports it, and it works from day one. It also means a
long-lived secret that grants full data-plane access to every blob in the account,
held by the pipeline and by every engineer who plans locally, rotated by hand if at
all.

## Decision

**Azure state lives in Azure Storage.** `tenants/azure/root.hcl` uses the azurerm
backend with `key = "azure/${path_relative_to_include()}/terraform.tfstate"`, so a
cell at `tenants/azure/corp/azure-pim-governance` writes to
`azure/corp/azure-pim-governance/terraform.tfstate`. The resource group, storage
account, and container are environment variables (`TG_AZ_STATE_RG`,
`TG_AZ_STATE_SA`, `TG_AZ_STATE_CONTAINER`), never HCL literals, for the same reason
the S3 bucket is: the same repository plans from a laptop and from CI against
different backends with no edits.

**The backend authenticates with an Entra token, not a key.** `use_azuread_auth =
true` on the backend and `storage_use_azuread = true` on the provider mean every
call to the state blob carries the same token as every call to Azure Resource
Manager. The identity needs Storage Blob Data Contributor on the container. It does
not need, and is not granted, the ability to list account keys. There is no key to
store, leak, or rotate.

**The token comes from GitHub OIDC.** The workflow requests an ID token from GitHub
(`permissions: id-token: write`) and `azure/login@v2` exchanges it for an Entra
token against a federated credential on an app registration or a user-assigned
managed identity. The federated credential's subject restricts which repository,
branch, and environment may use it. `ARM_USE_OIDC=true` tells the provider and the
backend to do the same exchange directly, so Terraform never sees a client secret
because there is none. The client ID, tenant ID, and subscription ID are repository
variables because none of them is sensitive on its own.

**One identity model for backend and providers.** The same federated identity reads
state, reads role definitions, and writes PIM policies. One credential to bootstrap,
one RBAC assignment to audit, one federated subject to review when the pipeline's
permissions are questioned.

**Separate plan and apply identities, per tenant.** Plan jobs target `corp-plan`
and `subsidiary-plan` environments whose `AZ_CLIENT_ID` override points at a reader
identity: Reader on the management group, Storage Blob Data Reader on the state
container. Apply jobs target `corp` and `subsidiary-apply` with an identity that
can write role definitions, role management policies, and eligibilities. A
compromised PR workflow can read the permission model, which is not secret, but
cannot change it.

## Consequences

- A one-time bootstrap creates the storage account with public access disabled
  and shared key access disabled, the container, the two identities per tenant, the
  federated credentials, and the five GitHub environments. That is out of scope here
  and documented as such.
- Disabling shared key access on the storage account is not just hygiene; it makes
  the "no keys" property enforceable rather than a convention. A misconfigured
  client that tries to use a key fails.
- Local runs use `az login`. The Azure CLI token is the same identity model with a
  person in place of a workflow. `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` are
  exported for the session; nothing else is.
- State locking uses blob leases, which the azurerm backend does natively. There is
  no lock table to provision.
- The Okta tree keeps S3. Two backends is a real cost, and it is smaller than a
  cross-cloud identity dependency for a state file. If the Okta tree ever moves, it
  moves to Azure Storage for the same reasons, not the other way round.
