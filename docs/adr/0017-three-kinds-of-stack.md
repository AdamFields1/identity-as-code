# ADR 0017: Three kinds of stack, and addressing lives in locator files

Status: accepted
Date: 2026-09-19

## Context

Every stack in this repository so far is shared. `okta-config` has a cell in
both Okta tenants, `entra-conditional-access` in both Entra tenants,
`aws-identity-center` in both partitions, and the only thing that differs
between the cells is values. ADR 0001 defined a stack by its deployment
boundary and ADR 0002 defined a cell as values only, and neither said a stack
had to be used by more than one tenant; it just happened that all nine were.

The next requests do not fit that shape. One account needs an IAM role that
a CI runner in that account can assume. One subscription needs a Key Vault
for a rotation job and nothing else. One application needs a queue, a role
whose trust policy names the queue's consumer, and a bucket the role may
write to, in two accounts. None of these is tenant-wide, none of them
belongs in the Identity Center stack or the PIM stack, and each of them is
exactly the kind of thing that gets written as a one-off `main.tf` in the
account, outside the layout, with the ID typed in.

Three ways to take them were considered.

**Terraform in the account.** A `main.tf` under the account directory with
its own provider block and its own resources. It is the fastest way to ship
one role and it breaks every rule at once: `modules/` stops being the only
place with a resource block, the cell stops being reviewable by someone who
has never opened the console, and the account ID and the provider
configuration sit in a file a reviewer diffs.

**Grow the platform stacks.** Add a `roles_by_account` map to a shared stack
and let each tenant cell list what every account gets. The stack's state file
becomes the estate, a change for one account plans every account, and the
blast radius of a typo is every account in the map. ADR 0005 rejected this
shape for Azure roles for the same reasons.

**Allow stacks that are not shared.** Keep the three layers and the cell rule
exactly as they are, and drop the unstated assumption that a stack has more
than one tenant behind it.

There is a second question underneath the first. An account-scoped cell has
to say which account it is in, and a subscription-scoped cell which
subscription. The obvious place, `inputs = { account_id = "111111111111" }`,
makes an ID a value: it shows up in the diff a reviewer reads, the provider
configuration comes to depend on a cell input, and any cell can re-address
itself to another account by editing one line, with nothing structural in the
way. ADR 0002 says a cell contains no IDs, and the reason was never that IDs
are secret; it was that a reviewer should be reading values, not addresses.

## Decision

### A stack does not have to be shared

There are three kinds of stack. They share one rule, which is the rule that
must survive: a cell never holds a resource block, a data source, a
conditional, or a module call. A cell has an include, a source pointing at a
stack, and inputs of values.

**Platform stacks** are the nine that exist. Every tenant of a family has a
cell for each, the tenant's values are the only difference between the cells,
and `diff` between two tenants' cells answers "what is stricter there".
Nothing about them changes.

**Catalog stacks** offer a menu of vetted resource shapes as values, so that
an account or a subscription can get a one-off IAM role, bucket, key,
identity, or vault without anyone writing Terraform. The stack holds the
shapes: a typed map per kind of thing, keyed by stable names, with the
guardrails inside the module it composes (validations, permissions
boundaries, `prevent_destroy` where destruction is dangerous) and with names
resolved to IDs the way every stack does it. The cell picks entries from the
menu and fills in the values. A catalog stack is planned once per account or
subscription that has a cell for it, into that cell's own state file.

**App stacks** hold the composition one application needs when the catalog
cannot express it: the queue, the role that names the queue, and the bucket
the role writes to, wired together in one plan. An app stack is still a
stack: its cell is values only, it composes modules, and it has one state
file per cell. What makes it an app stack is that its shape is the
application's, not the estate's.

The line between a catalog stack and an app stack is drawn in two places.
A shape moves from the catalog to an app stack when it needs cross-resource
wiring the catalog cannot express: a trust policy that must name a resource
created beside it, an access policy whose principal is created in the same
plan, an output of one entry that is an input of another. And a composition
becomes an app stack, rather than a longer catalog entry, when the same
composition is needed in more than one account; it is then a stack with
several cells, and repeating the values in each cell is what cells are for
(ADR 0002). The reverse also holds: an app stack that turns out to be one
resource with knobs goes back into the catalog as an entry.

The catalog offers shapes, not resource types. An entry that accepts an
arbitrary policy document, an arbitrary ARN, or a passthrough map of provider
attributes is Terraform with extra steps, and the test for it is simple: if
the person writing the cell has to know the resource type's attribute names,
the entry is wrong and the shape belongs in a module.

### Account IDs and subscription IDs are addressing, not configuration

An account ID or a subscription ID says where a cell is, not what it wants.
They live in locator files in the tenant tree, never in a cell's inputs, and
the roots turn them into provider configuration:

```
tenants/aws/<partition>/partition.hcl
  locals { partition = "aws" | "aws-us-gov", region = "us-east-1" }

tenants/aws/<partition>/accounts/<account-name>/account.hcl
  locals { account_id = "111111111111", account_name = "example-prod" }

tenants/azure/<tenant>/subscriptions/<sub-name>/subscription.hcl
  locals { subscription_id = "11111111-1111-1111-1111-111111111111", subscription_name = "sub-example-prod" }
```

A locator is not a cell. It has no include, no source, and no inputs, and
Terragrunt never runs it; it only reads it. An account-scoped cell lives at
`tenants/aws/<partition>/accounts/<account-name>/<stack>/` and a
subscription-scoped cell at
`tenants/azure/<tenant>/subscriptions/<sub-name>/<stack>/`, and each is the
same three blocks as every other cell.

Amended 2026-09-20: an app stack's cell sits one level deeper, under an
`apps/` directory inside the account or subscription directory
(`tenants/aws/<partition>/accounts/<account-name>/apps/<app>/`,
`tenants/azure/<tenant>/subscriptions/<sub-name>/apps/<app>/`), so the
directory reads as the baseline, the catalog, and the applications, and an
application is not mistaken for a third kind of account plumbing. Nothing
else distinguishes it: the same three blocks, the same locators found by
walking up, the same discovery by the presence of `terragrunt.hcl`, and a
state key that follows the path. The two app cells were moved in the same
change.

`tenants/aws/root.hcl` finds the two AWS locators by walking up from the
cell with `find_in_parent_folders`, reads them with `read_terragrunt_config`,
and generates the provider with `allowed_account_ids = ["<account_id>"]`
and `profile = "identity-as-code-<account_name>"`, so a plan whose
credentials land in any other account stops before its first resource API
call. The account's deployment role is deliberately not in the generated
file. A saved plan carries the configuration it was made from, and
`terraform apply <planfile>` applies that configuration rather than the
working directory's, so an `assume_role` rendered at plan time would be the
role the apply job assumes too; the release train plans account cells as a
read-only deployment role and applies them as a writer (ADR 0003), and that
split can only live where the plan file cannot capture it. The profile is
that place: its name is derived from the locator and is the same in every
environment, and what fills it is the runner's shared config, which the
workflow writes from the locators and the environment's
`TG_AWS_DEPLOY_ROLE_NAME` with `credential_source = Environment`, so the
role is assumed from the OIDC session while the state backend keeps that
session and the deployment role never touches state. Locally it is a
profile an engineer defines once per account. The partition locator also
supplies `region` as an input, so an account cell does not say it; a cell
that sets `region` itself still wins, which is how the Identity Center
cells keep naming their instance's region. A cell with no `account.hcl`
above it, which is every platform cell, is addressed exactly as before: the
ambient credentials, and `TG_AWS_ROLE_ARN` if it is set.

`tenants/azure/root.hcl` does the same with `subscription.hcl`: when one is
found, its `subscription_id` goes into the generated `azurerm` provider in
place of `ARM_SUBSCRIPTION_ID`; when none is found, `ARM_SUBSCRIPTION_ID` is
used as before. The tenant still comes from `ARM_TENANT_ID` in both cases,
because the tenant is the tree (`corp/`, `subsidiary/`), not a locator.

Both roots refuse a locator whose ID is malformed and a locator whose name
does not equal the name of the directory it sits in. The directory name is
the account or subscription name, the locator repeats it, and the check is
what catches a locator copied from a neighbouring account and left unedited.

A stack that needs its own account or subscription ID discovers it
(`data.aws_caller_identity`, `data.azurerm_client_config`), the way the
Identity Center stack discovers its instance and partition. Nothing passes
the ID from the locator to the stack as an input, so a stack cannot be
pointed at an account by its values and a cell still contains no ID.

The state key does not change. It is still derived from the cell's path, so
`tenants/aws/commercial/accounts/example-prod/aws-account-baseline` writes
`aws/commercial/accounts/example-prod/aws-account-baseline/terraform.tfstate`
and two cells cannot share a key.

## Consequences

- **More state files.** One per (account, stack) and one per (subscription,
  stack), instead of one per (tenant, stack). That is the cost of a blast
  radius that is one account, and it is the same cost ADR 0005 accepted for
  the same reason. A `terragrunt run --all` under an account directory runs
  that account's cells and nothing else.
- **The catalog must be curated.** Every entry is a promise that the shape is
  safe with any values that pass its validations, which makes adding an
  entry a permission-model review, not a feature request. Someone owns the
  menu. The stacks say what they refuse; an entry that cannot say that is
  not ready.
- **The temptation to grow the catalog into a second Terraform is real and
  is named here so it can be refused.** The catalog is finished when it
  covers what accounts ask for, not when it covers the provider. When an
  entry starts to need a passthrough, the answer is an app stack or a new
  module, never a looser entry.
- **Locators are read at Terragrunt evaluation time, before Terraform runs.**
  A missing or malformed locator fails `terragrunt init`, not `apply`, with
  the check's name in the message. The search walks up past the repository
  root, so a stray `account.hcl` above the checkout would be found; the
  directory-name check is what makes that visible.
- **The deployment roles are platform bootstrap.** Each account carries two
  roles under the names the `<partition>-plan` and apply environments give
  `TG_AWS_DEPLOY_ROLE_NAME`: a read-only one whose trust policy lists only
  the partition's plan OIDC role (`AWS_PLAN_ROLE_ARN`), and a writer whose
  trust policy lists only the apply OIDC role (`AWS_APPLY_ROLE_ARN`), so a
  pull request's plan can never reach a writer anywhere in the estate.
  Both are provisioned in the same separate repository that provisions the
  state buckets and OIDC roles (README, deliberately out of scope), and
  neither needs the state bucket. An account without them fails in the
  workflow's profile step, before Terragrunt runs, with the profile's name
  and the account it did not land in; locally it fails when the provider
  finds no profile. Both are the honest failure.
- **The workflows find cells by the presence of `terragrunt.hcl`, not by
  depth.** Both pull request workflows select cells with
  `find tenants/<cloud> -name terragrunt.hcl` and re-plan every cell an
  edited `partition.hcl`, `account.hcl`, or `subscription.hcl` addresses;
  `accounts/` and `accounts/<account-name>/` hold locators, not cells. The
  release trains carry one hardcoded plan and apply job per cell, so a new
  cell also needs its two jobs added there. Account cells run under the
  partition's existing environments, `commercial-plan` and `commercial`,
  with `TG_AWS_DEPLOY_ROLE_NAME` naming the reader or the writer; there
  are no per-account environments.
- **Nothing changes for the existing cells.** Every current cell has no
  locator above it except `partition.hcl`, which only offers a `region` they
  already set themselves. Their state keys, their providers, and their plans
  are the same before and after.
