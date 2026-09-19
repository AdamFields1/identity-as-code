# stacks/apps/azure/data-pipeline

The deployable unit for one data pipeline in one subscription. It composes
five modules, in order, into one plan and one state file:

1. `resource-group` creates the group everything below lives in, with a
   CanNotDelete lock by default.
2. `managed-identity` creates the identity the pipeline's GitHub workflow
   runs as, with one federated credential for one GitHub environment of one
   repository. No secret exists.
3. `key-vault` creates the vault that holds the pipeline's secrets, closed to
   the public network unless the cell lists addresses, audited to a Log
   Analytics workspace, with the identity as Key Vault Secrets User.
4. `storage-account` creates the data lake (a hierarchical-namespace account)
   with two private containers, `raw` and `curated`, the same firewall and
   audit posture, and the identity as Storage Blob Data Contributor on each
   container.
5. `workload-role-assignment` gives the identity Reader on the group.

Cells under `tenants/azure/<tenant>/subscriptions/<sub-name>/` point at this
stack and provide values only: the pipeline's name and environment, the
region, the GitHub organization and repository, the workspace, and optionally
the addresses that may reach the data planes. The subscription comes from
the locator beside the cell, never from the cell
([ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md)). One cell is
one pipeline; a subscription that runs two has two cells, each directory
named for its pipeline (`data-pipeline-sales`), and the state key follows
the path as it does everywhere else.

## Why this is an app stack

[ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md) draws the line
between a catalog stack and an app stack in two places, and this stack is on
the app side of both.

**The shape needs wiring the catalog cannot express.** Each of the four
resources here is a catalog shape on its own, and none of them is the point.
The pipeline is the relationships: the principal on the vault's Secrets User
assignment and on the containers' Blob Data Contributor assignments is the
identity created in the same plan, the scope of the Reader assignment is the
group created in the same plan, and the vault, the account, and the identity
are named from one pair of words so they cannot drift apart. A catalog cell
picks entries from a menu and fills in values; it has no way to say "the
identity two entries up", because a value is not a reference. The
composition therefore lives in a stack, where references are ordinary module
outputs and Terraform orders the graph
([ADR 0001](../../../../docs/adr/0001-stacks-as-deployment-unit.md)), and
the cell says which pipeline, where, and from which repository.

**The same composition is needed in more than one place.** Every pipeline
gets the same four resources with the same posture, and a pipeline that
graduates from dev to prod is the same composition in a second subscription.
That is a stack with several cells, and repeating a handful of values in
each cell is what cells are for
([ADR 0002](../../../../docs/adr/0002-values-only-tenant-cells.md)). Writing
it as a longer catalog entry would put the wiring in a cell, which is the
thing the cell rule forbids.

The reverse test also holds: if the pipeline ever needs only one of these
resources with knobs, that resource goes back to being a catalog entry and
this stack is retired.

What does not change: the cell is values only, the stack composes modules
and holds no resource block, every guardrail (the fixed role menus,
`prevent_destroy` on the group, the vault, and the account, the Deny
firewall) is in the module it belongs to, and there is one state file per
cell.

## The model

```
GitHub Actions job in environment <github_environment> of <org>/<repo>
        |
        | OIDC token, subject repo:<org>/<repo>:environment:<github_environment>
        v
id-<app_name>-<environment>            user-assigned managed identity, no credential
        |
        |-- Key Vault Secrets User ............ kv-<app_name>-<environment>
        |-- Storage Blob Data Contributor ..... st<app_name><environment> / raw
        |-- Storage Blob Data Contributor ..... st<app_name><environment> / curated
        `-- Reader ............................ rg-<app_name>-<environment>
```

The job logs in with `azure/login` using the identity's client ID (the
`identity_client_id` output; not a secret), reads what it needs from the
vault, and reads and writes the two containers. Nothing else in the estate
trusts the identity, and nothing can act as it without a token whose subject
matches the credential exactly.

## Names are derived

A cell states two words and the stack names everything from them:

| Resource | Name | Limit that binds |
|----------|------|------------------|
| resource group | `rg-<app_name>-<environment>` | none reached |
| identity | `id-<app_name>-<environment>` | none reached |
| key vault | `kv-<app_name>-<environment>` | 24 characters; letters, digits, single hyphens |
| storage account | `st<app_name without hyphens><environment>` | 24 lowercase letters and digits |
| containers | `raw`, `curated` | fixed |

`app_name` is 2 to 12 lowercase letters, digits, and single hyphens;
`environment` is 2 to 8 lowercase letters and digits. Those two validations
are what keep `kv-` plus both plus a hyphen inside 24 characters, and the
storage name is shorter still. The vault and account names are global DNS
labels, so a name taken elsewhere in Azure fails the apply; there is no
random suffix, because a name a reviewer can predict from the cell is worth
more than one that never collides.

`app_name` and `environment` are name components and tags (`application` and
`environment`, underneath the cell's own tags), never conditionals: nothing
in this stack behaves differently in prod than in dev (README, "Path is
environment").

## What the identity holds, and why not more

| Role | Scope | For |
|------|-------|-----|
| Key Vault Secrets User | the vault | reads secret values by name at run time; cannot list, set, or delete them, and holds nothing on keys or certificates |
| Storage Blob Data Contributor | container `raw` | lands source data |
| Storage Blob Data Contributor | container `curated` | writes the pipeline's output |
| Reader | the resource group | resolves the vault and the account through the management plane, which every SDK and the CLI do before a data-plane call; no data action |

Not granted, on purpose: any role at the account scope (a third container
added later is not the pipeline's until a change here says so), Key Vault
Secrets Officer (the pipeline reads secrets; the people who set them do so
with their own PIM-activated access), and any management-plane write role
(the modules refuse Owner, Contributor, and the roles that assign roles, and
this stack asks for none of them).

## Closed by default

`public_network_access_enabled` is false on the vault and the account unless
`allowed_ip_ranges` lists addresses, in which case the same list opens both
to exactly those addresses and the Azure trusted services, behind a Deny
default. There is no separate switch a cell could leave on with an empty
list.

A GitHub-hosted runner has no fixed egress address and cannot be listed. A
pipeline whose jobs run on one reaches neither the vault nor the lake, and
that is the intended outcome, not a reason to open either: run the jobs on
self-hosted runners behind a NAT address and list that address, or reach the
data planes over private endpoints, which this repository does not create.
Private, loopback, and link-local ranges are refused by the modules.

## What this stack refuses

- An `app_name` or `environment` outside the character and length rules
  above, which is what keeps every derived name valid.
- A branch credential. The identity trusts one GitHub environment and
  nothing else is offered here, because an environment carries protection
  rules and a branch trusts anyone who can push to it.
- A second identity, vault, or account, or a third container. The shape is
  the pipeline's; a pipeline that needs more is a change to this stack,
  reviewed as one, not a longer cell.
- A `/31` or `/32` prefix in `allowed_ip_ranges` (the storage firewall does
  not accept them; write a single address bare), and, in the modules, a
  private range.
- Blob versioning on the lake. A hierarchical-namespace account does not
  support it, so the stack sets `blob_versioning_enabled = false` explicitly
  and the module would refuse anything else; blob and container soft delete
  (14 days each) still apply.
- Removing the group, the vault, or the account by removing the cell. All
  three are `prevent_destroy` in their modules, and the group also carries
  a CanNotDelete lock by default. Retiring a pipeline is a deliberate change
  that lifts the flags first, in its own pull request. The identity is not
  `prevent_destroy`: losing it is an outage the next apply undoes, not a loss
  of data (see `modules/azure/managed-identity`).

## Provider configuration

`versions.tf` declares `required_providers` only, for both `azurerm` and
`azuread`: the key-vault and storage-account modules resolve Entra groups by
display name and declare the provider (this stack names no group), so a
stack that composes either pins both, as `stacks/azure-automation` does. The
provider blocks are generated by Terragrunt from `tenant_id` and
`subscription_id`; under `subscriptions/<sub-name>/` the subscription comes
from that directory's `subscription.hcl` and the tenant from
`ARM_TENANT_ID` (`tenants/azure/root.hcl`). The stack passes neither to any
module.

The apply identity needs Contributor and User Access Administrator (or
Owner) at the subscription, because the group does not exist until the
first apply and everything else is created inside it. Contributor creates
the group, the identity and its credential, the vault, the account and its
containers, and the two diagnostic settings; User Access Administrator
writes the four role assignments and the lock
(`Microsoft.Authorization/roleAssignments/write` and
`Microsoft.Authorization/locks/write`, neither of which Contributor has). It
also needs Reader on the Log Analytics workspace, which resolving it by name
needs anyway. Nothing here resolves a group in Entra, so no Graph permission
is needed.

## First plan, first apply

The group is created in the same plan that the identity, the vault, and the
account look it up in, so those three modules carry
`depends_on = [module.resource_groups]` and Terraform reads the group during
apply instead of at plan time. Three consequences, all on the first run
only:

- The plan shows the location of the identity, the vault, and the account as
  known after apply. They will be the group's, which is `location`.
- The workspace lookup is deferred with the group's, so a misspelt
  `log_analytics_workspace` fails during the first apply, after the group
  exists, rather than at plan. Every later plan reads it at plan time and
  fails there.
- The Reader assignment resolves the role at the group's ID, which does not
  exist yet, so that lookup is deferred too.

Once the group exists, plans are ordinary: every lookup happens at plan time
and a clean plan is empty.

One provider behaviour is handled by the root and one is left to confirm on
the first apply, both inherited from the modules. With public network
access off, the azurerm 4.x storage account resource still reads queue
service properties and static website settings through the data plane
unless the provider's `features { storage { data_plane_available = false } }`
is set; from a runner outside the network that read fails with an
authorization or connectivity error on a queue or web endpoint.
`tenants/azure/root.hcl` sets that flag in the generated provider for every
cell, because the release train applies from GitHub-hosted runners and no
module here manages either data-plane block. What remains to confirm: a
bare address in `allowed_ip_ranges` should come back from the Key Vault API
without a `/32` suffix; if the next plan shows one as a diff,
`modules/azure/key-vault/README.md` says what to write.

## Standalone use without Terragrunt

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "data_pipeline" {
  source = "./stacks/apps/azure/data-pipeline"

  tenant_id       = "11111111-1111-1111-1111-111111111111"
  subscription_id = "11111111-1111-1111-1111-111111111111"

  app_name    = "sales-etl"
  environment = "prod"
  location    = "eastus"

  github_organization = "example-org"
  github_repository   = "sales-etl"

  log_analytics_workspace = {
    name                = "law-example-security"
    resource_group_name = "rg-example-monitoring"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  tags = {
    owner = "data-platform"
  }
}
```

## The cell

A subscription cell for this stack is the same three blocks as every other
cell (ADR 0002, ADR 0017), and looks like this. The committed one,
`tenants/azure/corp/subscriptions/sub-example-prod/data-pipeline/terragrunt.hcl`,
names the workspace the subscription baseline cell creates
(`law-example-prod-activity` in `rg-example-baseline`) rather than the
security workspace shown here:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/apps/azure/data-pipeline"
}

inputs = {
  app_name    = "sales-etl"
  environment = "prod"
  location    = "eastus"

  github_organization = "example-org"
  github_repository   = "sales-etl"

  log_analytics_workspace = {
    name                = "law-example-security"
    resource_group_name = "rg-example-monitoring"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  tags = {
    owner = "data-platform"
  }
}
```

No subscription ID: the locator in `sub-example-prod/subscription.hcl`
addresses the cell and the root turns it into the provider's
`subscription_id`. No tenant ID: `ARM_TENANT_ID`. No principal ID, no
resource ID, no client ID: the stack wires the first two and outputs the
third for whoever fills in the workflow's variables. The state key is
`azure/corp/subscriptions/sub-example-prod/data-pipeline/terraform.tfstate`.

## What the workflow needs

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  run:
    environment: prod                                  # github_environment
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}        # identity_client_id output
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

All three are repository or environment variables, not secrets. The job must
run in the GitHub environment the credential names, or the token's subject
will not match and login fails with `AADSTS70021`; the
`federated_credential_subject` output is the exact string to compare against.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tenant_id` | `string` | n/a | Entra tenant ID, from the environment via root.hcl. |
| `subscription_id` | `string` | `null` | Subscription of the pipeline, from the locator via root.hcl. |
| `app_name` | `string` | n/a | Pipeline name; the first half of every resource name. 2 to 12 lowercase letters, digits, single hyphens. |
| `environment` | `string` | n/a | Environment; the second half of every resource name and the default GitHub environment. 2 to 8 lowercase letters and digits. |
| `location` | `string` | n/a | Azure region, short form. |
| `github_organization` | `string` | n/a | Organization that owns the pipeline's repository. |
| `github_repository` | `string` | n/a | The repository, without the organization. |
| `github_environment` | `string` | `null` | GitHub environment the identity trusts; null means `environment`. |
| `log_analytics_workspace` | `object` | n/a | `{ name, resource_group_name }` of the workspace that receives the vault and blob audit logs. |
| `allowed_ip_ranges` | `list(string)` | `[]` | Public addresses admitted to the vault and the lake. Empty keeps both closed. |
| `delete_lock` | `bool` | `true` | CanNotDelete lock on the resource group. |
| `tags` | `map(string)` | `{}` | Tags on every resource, over `application` and `environment`. |

## Outputs

| Name | Description |
|------|-------------|
| `resource_group_name` | `rg-<app_name>-<environment>`. |
| `resource_group_id` | Resource ID of the group, the Reader assignment's scope. |
| `identity_name` | The identity's name, also its display name in Entra. |
| `identity_client_id` | Client ID for `azure/login`. Not a secret. |
| `identity_principal_id` | Service principal object ID every assignment here is made to. |
| `federated_credential_subject` | The exact subject the workflow's token must carry. |
| `key_vault_name` | `kv-<app_name>-<environment>`. |
| `key_vault_uri` | The vault's data-plane URI. |
| `storage_account_name` | `st<app_name without hyphens><environment>`. |
| `storage_dfs_endpoint` | The lake's Data Lake Storage Gen2 endpoint. |
| `container_names` | `raw` and `curated` to their container names. |
| `role_assignment_ids` | `key-vault/...`, `storage/lake/...`, and `resource-group/...` to role assignment IDs. |
