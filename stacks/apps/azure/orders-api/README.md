# stacks/apps/azure/orders-api

The deployable unit for the orders-api application in one subscription:
everything a container needs before it can start, and nothing it runs. It
composes four modules, in order, into one plan and one state file:

1. `resource-group` creates the group everything below lives in, with a
   CanNotDelete lock by default.
2. `managed-identity` creates two identities: the runtime identity the
   container runs as, with no credential of any kind (the Container App is
   assigned it by its own pipeline), and the publisher identity the release
   workflow pushes as, with one federated credential for one GitHub
   environment of one repository. No secret exists.
3. `container-registry` creates the registry the image is pulled from, with
   no admin user and no anonymous pull, audited to a Log Analytics
   workspace, with the runtime identity as AcrPull and the publisher as
   AcrPush.
4. `key-vault` creates the vault that holds the application's secrets, closed
   to the public network unless the cell lists addresses, audited to the
   same workspace, with the runtime identity as Key Vault Secrets User.

Every role is a data-plane role on the registry or the vault. Nothing is
granted on the group or through the management plane, to either identity.

Cells under `tenants/azure/<tenant>/subscriptions/<sub-name>/apps/` point at
this stack and provide values only: the environment, the region, the GitHub
organization and repository, the workspace, the registry SKU, and optionally
the addresses that may reach the data planes. The application's name is the
stack's default. The subscription comes from the locator beside the cell,
never from the cell
([ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md)). One cell is
one deployment of the application; a subscription that runs two has two
cells, each directory named for its deployment (`orders-api-canary`), and the
state key follows the path as it does everywhere else.

The AWS side of the same application, `stacks/apps/aws/orders-api`, is the
same shape in that cloud's words: an ECR repository for the registry, a task
role for the runtime identity, a task execution role for the start-up
identity (here the runtime identity holds AcrPull itself), an image publisher
role trusted through OIDC, a parameter namespace for the secrets. Neither
manages a bucket or a storage account, and neither manages the compute; that
is what distinguishes the pair from payments-api and data-pipeline.

## Why this is an app stack

[ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md) draws the line
between a catalog stack and an app stack in two places, and this stack is on
the app side of both.

**The shape needs wiring the catalog cannot express.** Each of the four
resources here is a catalog shape on its own, and none of them is the point.
The application is the relationships: the principal on the registry's
AcrPull assignment and on the vault's Secrets User assignment is the runtime
identity created in the same plan, the principal on the AcrPush assignment
is the publisher identity created beside it, and the registry, the vault,
and the two identities are named from one pair of words so they cannot
drift apart.
A catalog cell picks entries from a menu and fills in values; it has no way
to say "the identity two entries up", because a value is not a reference.
The composition therefore lives in a stack, where references are ordinary
module outputs and Terraform orders the graph
([ADR 0001](../../../../docs/adr/0001-stacks-as-deployment-unit.md)), and
the cell says which environment, where, and from which repository.

**The same composition is needed in more than one place.** Every deployment
of the application gets the same four resources with the same posture, and
a deployment that graduates from dev to prod is the same composition in a
second subscription. That is a stack with several cells, and repeating a
handful of values in each cell is what cells are for
([ADR 0002](../../../../docs/adr/0002-values-only-tenant-cells.md)). Writing
it as a longer catalog entry would put the wiring in a cell, which is the
thing the cell rule forbids.

The reverse test also holds: if the application ever needs only one of these
resources with knobs, that resource goes back to being a catalog entry and
this stack is retired.

What does not change: the cell is values only, the stack composes modules
and holds no resource block, every guardrail (the fixed role menus,
`prevent_destroy` on the group, the registry, and the vault, the Deny
firewalls, the registry's admin user and anonymous pull fixed off) is in the
module it belongs to, and there is one state file per cell.

## The model

```
GitHub Actions job in environment <publisher_github_environment> of <org>/<repo>
        |
        | OIDC token, subject repo:<org>/<repo>:environment:<publisher_github_environment>
        v
id-<app_name>-<environment>-publisher      user-assigned managed identity, no credential
        |
        `-- AcrPush ........................... cr<app_name><environment>   (push includes pull)

Container App (not managed here), assigned the runtime identity by its own pipeline
        |
        | tokens minted by the platform; no credential, no federated credential
        v
id-<app_name>-<environment>                user-assigned managed identity
        |
        |-- AcrPull ........................... cr<app_name><environment>
        `-- Key Vault Secrets User ............ kv-<app_name>-<environment>
```

Two identities, because two different things act. The runtime identity is
what the container is: it pulls the image at start-up, reads its secrets by
name, and holds nothing that would let it change either. The publisher
identity is what the release workflow is: it pushes an image and can do
nothing else here, not read a secret, not touch the group. One identity
holding both would let a compromised workflow read production secrets and a
compromised container overwrite its own image; two identities with one role
each make that a change to this stack instead of a consequence of it.

The release workflow logs in with `azure/login` using the publisher's client
ID (the `publisher_identity_client_id` output; not a secret), runs
`az acr login`, and pushes. The Container App is given the runtime identity
by the pipeline that deploys the app, names it on its registry entry and on
each Key Vault secret reference, and the platform does the rest. Nothing
else in the estate trusts either identity, nothing outside Azure can obtain
a token for the runtime identity at all, and nothing can act as the
publisher without a token whose subject matches the credential exactly.

## Names are derived

A cell states one word (the environment; the application's name is the
default) and the stack names everything from the two:

| Resource | Name | Limit that binds |
|----------|------|------------------|
| resource group | `rg-<app_name>-<environment>` | none reached |
| runtime identity | `id-<app_name>-<environment>` | none reached |
| publisher identity | `id-<app_name>-<environment>-publisher` | none reached |
| container registry | `cr<app_name without hyphens><environment>` | 5 to 50 letters and digits |
| key vault | `kv-<app_name>-<environment>` | 24 characters; letters, digits, single hyphens |

`app_name` is 2 to 12 lowercase letters, digits, and single hyphens
(`orders-api` is 10); `environment` is 2 to 8 lowercase letters and digits.
Those two validations are what keep `kv-` plus both plus a hyphen inside 24
characters, and the registry name, with the hyphens removed, is shorter
still and never below 5. The registry and vault names are global DNS labels
(`<name>.azurecr.io`, `<name>.vault.azure.net`), so a name taken elsewhere
in Azure fails the apply; there is no random suffix, because a name a
reviewer can predict from the cell is worth more than one that never
collides.

`app_name` and `environment` are name components and tags (`application` and
`environment`, underneath the cell's own tags), never conditionals: nothing
in this stack behaves differently in prod than in dev (README, "Path is
environment"). The one thing that varies with a value is the registry
firewall, and it varies with the SKU, not the environment (below).

## What the identities hold, and why not more

| Identity | Role | Scope | For |
|----------|------|-------|-----|
| runtime | AcrPull | the registry | pulls the image at start-up; cannot push, delete, or sign |
| runtime | Key Vault Secrets User | the vault | reads secret values by name at start-up and at run time; cannot list, set, or delete them, and holds nothing on keys or certificates |
| publisher | AcrPush | the registry | pushes the image the release workflow built; push includes pull, so one assignment, not two |

Not granted, on purpose: any management-plane role for either identity,
Reader on the group included. The container pulls at the registry's login
server and reads secrets at the vault's data-plane URI, both of which its
pipeline takes from this stack's outputs, so nothing it does reads a
resource through ARM; a Reader on the group would let a compromised
container enumerate every resource and role assignment in it, the publisher
identity included, for no call it makes. Also not granted: anything on the
vault for the publisher (a docker push resolves the login server through
DNS, not ARM, and a release workflow has no business reading a secret), AcrDelete or
AcrImageSigner to anyone (an operator who must delete an image does so with
PIM-activated access, or a later change adds an AcrDelete assignment to a
PIM-governed group here, reviewed as one), Key Vault Secrets Officer (the
container reads secrets; the people who set them do so with their own
PIM-activated access), and any management-plane write role (the modules
refuse Owner, Contributor, and the roles that assign roles, and this stack
asks for none of them).

## Two data planes, two postures

The vault is closed by default. `public_network_access_enabled` is false on
it unless `allowed_ip_ranges` lists addresses, in which case the list opens
it to exactly those addresses and the Azure trusted services, behind a Deny
default. There is no separate switch a cell could leave on with an empty
list.

The registry's public login server is on whatever the SKU. Azure keeps it on
for Basic and Standard registries, and every request carries an Entra token,
so a registry with no rule set is reachable by identity from anywhere and by
nobody without a role: the same posture as a login page. Azure sells the
registry firewall on Premium only, so the same `allowed_ip_ranges` is
written to the registry as a Deny-default rule set on Premium and withheld
on the other two SKUs, where the module would refuse it. A cell that needs
the registry's firewall raises `registry_sku` to `Premium`; a cell on
Standard still has the registry's admin user off, anonymous pull off, and
every pull and push logged with the identity that did it.

What the Container App needs from this. It pulls from the registry with
AcrPull, which works from anywhere on any SKU. It reads the vault with
Secrets User, which works only from an address the vault admits: the
Container Apps environment's egress address listed in `allowed_ip_ranges`,
or a private endpoint from the environment's virtual network. Neither is
created here: this repository manages no network, so a closed vault is
reached through the cell's allowed addresses or a private endpoint created
elsewhere, and a Container App on a plain consumption environment with an
empty `allowed_ip_ranges` will fail to resolve its secrets at start-up, which
is the intended outcome, not a reason to open the vault to the internet.

A GitHub-hosted runner has no fixed egress address and cannot be listed. The
publisher never needs to be: it pushes to the registry, which admits it by
identity on Basic and Standard, and on Premium the release workflow runs on
self-hosted runners behind a NAT address that is listed. Private, loopback,
and link-local ranges are refused by the modules.

## What this stack refuses

- An `app_name` or `environment` outside the character and length rules
  above, which is what keeps every derived name valid.
- A branch credential. The publisher trusts one GitHub environment and
  nothing else is offered here, because an environment carries protection
  rules and a branch trusts anyone who can push to it.
- Any credential on the runtime identity. Nothing outside Azure obtains a
  token for it; the Container App is assigned it and the platform mints its
  tokens.
- `registry_retention_days` on a Basic or Standard registry. Azure offers
  the untagged-manifest retention policy on Premium only; the stack refuses
  the pair by validation, naming the two variables, before the module
  refuses it in its own words.
- A `/31` or `/32` prefix in `allowed_ip_ranges` (write a single address
  bare, the form the Key Vault API returns it in, and the shape the
  data-pipeline stack accepts, so one list serves both app stacks), and, in
  the modules, a private range.
- A second registry, vault, or identity, or a group holding a role. The
  shape is the application's; a deployment that needs more is a change to
  this stack, reviewed as one, not a longer cell.
- The registry's admin user, anonymous pull, and a customer-managed key on
  the registry or the vault. The first two are fixed off in the module; the
  third is a later change with its own key, wrap identity, and rotation
  story.
- Removing the group, the registry, or the vault by removing the cell. All
  three are `prevent_destroy` in their modules, and the group also carries
  a CanNotDelete lock by default. Retiring the application is a deliberate
  change that lifts the flags first, in its own pull request. The identities
  are not `prevent_destroy`: losing one is an outage the next apply undoes,
  not a loss of data (see `modules/azure/managed-identity`), though the
  Container App and the workflow then hold a client ID that no longer exists
  until they are updated.

## Provider configuration

`versions.tf` declares `required_providers` only, for both `azurerm` and
`azuread`: the key-vault and container-registry modules resolve Entra groups
by display name and declare the provider (this stack names no group), so a
stack that composes either pins both, as `stacks/apps/azure/data-pipeline`
does. The provider blocks are generated by Terragrunt from `tenant_id` and
`subscription_id`; under `subscriptions/<sub-name>/` the subscription comes
from that directory's `subscription.hcl` and the tenant from
`ARM_TENANT_ID` (`tenants/azure/root.hcl`). The stack passes neither to any
module.

The apply identity needs Contributor and User Access Administrator (or
Owner) at the subscription, because the group does not exist until the
first apply and everything else is created inside it. Contributor creates
the group, the two identities and the credential, the registry, the vault,
and the two diagnostic settings; User Access Administrator writes the three
role assignments and the lock
(`Microsoft.Authorization/roleAssignments/write` and
`Microsoft.Authorization/locks/write`, neither of which Contributor has). It
also needs Reader on the Log Analytics workspace, which resolving it by name
needs anyway. Nothing here resolves a group in Entra, so no Graph permission
is needed.

## First plan, first apply

The group is created in the same plan that the identities, the registry, and
the vault look it up in, so those three modules carry
`depends_on = [module.resource_groups]` and Terraform reads the group during
apply instead of at plan time. Two consequences, both on the first run
only:

- The plan shows the location of the identities, the registry, and the
  vault as known after apply. They will be the group's, which is `location`.
- The workspace lookups are deferred with the group's, so a misspelt
  `log_analytics_workspace` fails during the first apply, after the group
  exists, rather than at plan. Every later plan reads it at plan time and
  fails there.

Once the group exists, plans are ordinary: every lookup happens at plan time
and a clean plan is empty.

Two things are left to confirm on the first apply, both inherited from the
modules. A bare address in `allowed_ip_ranges` should come back from the Key
Vault API, and on Premium from the registry API, without a `/32` suffix; if
the next plan shows one as a diff, `modules/azure/key-vault/README.md` and
`modules/azure/container-registry/README.md` say what to write. And the
workspace should accept the registry's two log categories and `AllMetrics`
without a diff on `log_analytics_destination_type`. A Standard registry with
no rule set written should show no diff on the computed `network_rule_set`
after the first apply; the module README lists that among its own checks.

## Standalone use without Terragrunt

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "orders_api" {
  source = "./stacks/apps/azure/orders-api"

  tenant_id       = "11111111-1111-1111-1111-111111111111"
  subscription_id = "11111111-1111-1111-1111-111111111111"

  environment = "prod"
  location    = "eastus"

  github_organization = "example-org"
  github_repository   = "orders-api"

  log_analytics_workspace = {
    name                = "law-example-security"
    resource_group_name = "rg-example-monitoring"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  tags = {
    owner = "commerce-platform"
  }
}
```

## The cell

A subscription cell for this stack is the same three blocks as every other
cell (ADR 0002, ADR 0017), plus the ordering dependency on the baseline cell
that creates the workspace it names. The committed prod cell,
`tenants/azure/corp/subscriptions/sub-example-prod/apps/orders-api/terragrunt.hcl`,
without its header comment:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/azure/orders-api"
}

# Ordering only. The registry and the vault audit to the Log Analytics
# workspace the baseline cell creates, named below and resolved by name; no
# outputs are read from that cell. See docs/adr/0005.
dependencies {
  paths = ["../../azure-subscription-baseline"]
}

inputs = {
  environment = "prod"
  location    = "eastus"

  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "production"

  registry_sku            = "Premium"
  registry_retention_days = 7

  log_analytics_workspace = {
    name                = "law-example-prod-activity"
    resource_group_name = "rg-example-baseline"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  delete_lock = true

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
```

What it sets, and why. `publisher_github_environment` names the
repository's `production` environment because that environment is not
called `prod`, the deployment's name; a cell whose GitHub environment shares
its deployment's name omits the input. `registry_sku = "Premium"` buys the
registry firewall and the untagged-manifest retention policy, and
`registry_retention_days = 7` is the retention: the release workflow pushes
the same tag again on every hotfix, and seven days is long enough to roll
back to the manifest it replaced. `allowed_ip_ranges` opens the vault and,
on Premium, the registry to exactly that block, the NAT address of the
self-hosted runners the release jobs run on, behind a Deny default.
`delete_lock = true` is the stack's default written out so the dev cell's
`false` reads as a difference. The dependency path climbs two levels,
because the cell sits under `apps/` inside the subscription directory and
the baseline cell sits beside `apps/`. The workspace it names is the one the
subscription baseline cell creates (`law-example-prod-activity` in
`rg-example-baseline`).

No `app_name`: the stack's default is the application's name, and a cell
states it only to deploy the composition under another one. No subscription
ID: the locator in `sub-example-prod/subscription.hcl` addresses the cell and
the root turns it into the provider's `subscription_id`. No tenant ID:
`ARM_TENANT_ID`. No principal ID, no resource ID, no client ID: the stack
wires the first two and outputs the third for whoever fills in the
workflow's variables and the Container App's identity block. The state key
is `azure/corp/subscriptions/sub-example-prod/apps/orders-api/terraform.tfstate`.

The dev cell in `sub-example-dev` is the same file with `environment =
"dev"`, the `development` environment, `registry_sku = "Standard"` and no
`registry_retention_days` (the stack refuses the second without Premium),
an empty `allowed_ip_ranges` that leaves the vault closed, and
`delete_lock = false`; `diff` between the two is the complete answer to
"what is different in prod".

## What the workflow needs

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  publish:
    environment: production                            # publisher_github_environment
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}        # publisher_identity_client_id output
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - run: az acr login --name ${{ vars.ACR_NAME }}   # container_registry_name output
      - run: docker push ${{ vars.ACR_LOGIN_SERVER }}/orders-api:${{ github.sha }}
```

All four are repository or environment variables, not secrets. The job must
run in the GitHub environment the credential names, or the token's subject
will not match and login fails with `AADSTS70021`; the
`publisher_federated_credential_subject` output is the exact string to
compare against. The workflow that deploys the Container App is a different
workflow with a different identity, outside this stack's scope; it needs
whatever the compute needs, and nothing here.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tenant_id` | `string` | n/a | Entra tenant ID, from the environment via root.hcl. |
| `subscription_id` | `string` | `null` | Subscription of the application, from the locator via root.hcl. |
| `app_name` | `string` | `"orders-api"` | Application name; the first half of every resource name. 2 to 12 lowercase letters, digits, single hyphens. |
| `environment` | `string` | n/a | Environment; the second half of every resource name and the default GitHub environment. 2 to 8 lowercase letters and digits. |
| `location` | `string` | n/a | Azure region, short form. |
| `github_organization` | `string` | n/a | Organization that owns the application's repository. |
| `github_repository` | `string` | n/a | The repository, without the organization. |
| `publisher_github_environment` | `string` | `null` | GitHub environment the publisher identity trusts; null means `environment`. |
| `registry_sku` | `string` | `"Standard"` | `Basic`, `Standard`, or `Premium`. The firewall, the retention policy, and zone redundancy are Premium only. |
| `registry_retention_days` | `number` | `null` | Days an untagged manifest is kept, 1 to 365. Premium only; refused with any other SKU. |
| `log_analytics_workspace` | `object` | n/a | `{ name, resource_group_name }` of the workspace that receives the registry and vault audit logs. |
| `allowed_ip_ranges` | `list(string)` | `[]` | Public addresses admitted to the vault and, on Premium, to the registry. Empty keeps the vault closed. |
| `delete_lock` | `bool` | `true` | CanNotDelete lock on the resource group. |
| `tags` | `map(string)` | `{}` | Tags on every resource, over `application` and `environment`. |

## Outputs

| Name | Description |
|------|-------------|
| `resource_group_name` | `rg-<app_name>-<environment>`. |
| `runtime_identity_name` | The runtime identity's name, also its display name in Entra. |
| `runtime_identity_id` | Resource ID of the runtime identity, what the Container App's identity block names. |
| `runtime_identity_client_id` | Client ID the application passes to `DefaultAzureCredential` when it holds more than one identity. Not a secret. |
| `runtime_identity_principal_id` | Service principal object ID the AcrPull and Secrets User assignments are made to. |
| `publisher_identity_client_id` | Client ID for the release workflow's `azure/login`. Not a secret. |
| `publisher_federated_credential_subject` | The exact subject the release workflow's token must carry. |
| `container_registry_name` | `cr<app_name without hyphens><environment>`, what `az acr login` names. |
| `container_registry_login_server` | `<name>.azurecr.io`, the host of every image reference. |
| `key_vault_name` | `kv-<app_name>-<environment>`. |
| `key_vault_uri` | The vault's data-plane URI, the prefix of every `keyVaultUrl`. |
| `role_assignment_ids` | `container-registry/orders-api/...` and `key-vault/secrets/...` to role assignment IDs; all three are data-plane roles. |

## Consuming the outputs

The Container Apps environment and the Container App are not managed here,
on purpose. The compute is the application's pipeline's to deploy, roll, and
scale, at the cadence of the application's releases rather than of this
repository's, and its shape (CPU, replicas, ingress, revisions, probes) is
the application's business, not the estate's. This stack ends where the
container starts: the identity it runs as, the registry it pulls from, the
vault it reads, and the roles that connect them. The network is out of scope
the same way: no virtual network, private endpoint, or private DNS zone is
created here, so a closed vault is reached through the cell's allowed
addresses or a private endpoint created elsewhere.

What the app's own pipeline writes, then, is a Container App that names this
stack's outputs, and nothing else about identity. The fragment below is the
YAML shape `az containerapp create --yaml` and the ARM `Microsoft.App/containerApps`
resource take, as documentation only; every value in angle brackets is an
output of this stack, and the subscription ID is a placeholder:

```yaml
# Documentation only. Not managed by this stack or this repository.
identity:
  type: UserAssigned
  userAssignedIdentities:
    # runtime_identity_id output:
    # /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders-api-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-orders-api-prod
    <runtime_identity_id>: {}
properties:
  configuration:
    registries:
      - server: <container_registry_login_server>   # crordersapiprod, at its login server
        identity: <runtime_identity_id>             # AcrPull, granted by this stack
    secrets:
      - name: db-password
        keyVaultUrl: <key_vault_uri>secrets/db-password   # https://kv-orders-api-prod.vault.azure.net/secrets/db-password
        identity: <runtime_identity_id>                   # Key Vault Secrets User, granted by this stack
  template:
    containers:
      - name: orders-api
        image: <container_registry_login_server>/orders-api:1.4.2
        env:
          - name: DB_PASSWORD
            secretRef: db-password
          - name: AZURE_CLIENT_ID
            value: <runtime_identity_client_id>     # only when the app holds more than one identity
```

Three things the fragment shows. The identity block names the runtime
identity by resource ID, and the app holds no system-assigned identity,
because a system-assigned identity would be a second principal with no role
here and no name a reviewer could predict. The `registries` entry names the
login server and the same identity, which is how the platform pulls with
AcrPull instead of with an admin password (there is none). Each `secrets`
entry names a `keyVaultUrl` under the vault's URI and the same identity,
which is how the platform reads the secret with Secrets User at start-up and
on each revision, and the container sees it as an environment variable or a
mounted file, never as a Key Vault call of its own. The secret `db-password`
itself is set in the vault by someone with PIM-activated access, not by this
stack and not by the app's pipeline.
