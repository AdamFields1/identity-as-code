# stacks/azure-automation

The deployable unit for a tenant's identity hygiene and governance runbooks.
It composes five modules into one plan and one state file:

1. `automation-account` creates the Automation account, one user-assigned
   managed identity per privilege tier, and the account variables, including
   one variable per desired-state file the cell lists.
2. `backup-storage` (optional) creates the storage account and private
   container the runbook backup writes to, with Storage Blob Data Contributor
   on the container for the identity of the runbook that writes backups.
3. `automation-runbooks` publishes the runbooks in `automation/runbooks` from
   their files (with a shared library from `automation/lib` inlined where a
   runbook names one), creates the schedules, and links each runbook to a
   schedule with its parameters.
4. `graph-app-role-grant`, once per tier, grants that tier's identity the
   Microsoft Graph application permissions its runbooks need, by name.
5. `workload-role-assignment`, once per tier, gives that tier's identity the
   Azure role assignments its runbooks need, by scope name and role name, with
   optional ABAC conditions written with name tokens.

Tenant cells under `tenants/azure/<tenant>/azure-automation/` point at this stack
and provide values only. In this repository only `corp` has such a cell.

## The runbooks

| Runbook | Library | Corp tier | Corp schedule | What it does |
|---------|---------|-----------|---------------|--------------|
| `Invoke-AppCredentialHygiene` | none | `lifecycle` | daily 06:00 UTC | expiring and expired app credentials: digest owners, remove after a grace period |
| `Invoke-GuestLifecycle` | none | `lifecycle` | Monday 07:00 UTC | dormant guests: warn, disable, purge, stage held in group membership |
| `Invoke-AuthenticationMethodsDrift` | `AuthenticationMethods.Common.ps1` | `observer` | Sunday 08:00 UTC | authentication methods policy versus the repository's desired state, as a report |
| `Backup-AutomationRunbooks` | `Runbook.Common.ps1` | `observer` | daily 02:00 UTC | published source of every runbook in the account to blob storage, restore-verified, pruned with a floor and a cap |
| `Invoke-PimEligibilityRenewal` | `Runbook.Common.ps1` | `pim` | daily 03:30 UTC | extends expiring PIM eligibilities of groups on directory roles and PIM groups; the Azure plane is opt-in |
| `Disable-UnauthorizedSubscriptions` | `Runbook.Common.ps1` | `subscription-guard` | daily 04:00 UTC | reports, and once allowed cancels, restricted-offer subscriptions with no allowlisted owner, through a just-in-time Owner assignment |
| `Invoke-AzurePimPolicyGovernance` | `Runbook.Common.ps1` | `pim` | daily 05:00 UTC | holds Azure resource PIM activation rules to the baseline, undeclared pairs included |
| `Invoke-EntraPimPolicyDrift` | `Runbook.Common.ps1` | `pim` | daily 05:15 UTC | compares Entra directory role and PIM group activation rules with the baseline |
| `Watch-AutomationJobFailures` | `Runbook.Common.ps1` | `observer` | hourly at :45 | one digest when a job failed or a scheduled run did not happen |

## Identity tiers

A cell declares `identities`, a map keyed by privilege tier, and each runbook
entry names its tier in `identity_key`. Each tier has its own user-assigned
managed identity, its own `graph_app_roles`, and its own
`arm_role_assignments`, and holds only what its runbooks use. The corp tiers
are `observer`, `lifecycle`, `pim`, and `subscription-guard`; what each holds
is in `automation/README.md` and in
[ADR 0016](../../docs/adr/0016-one-identity-per-privilege-tier-in-one-automation-account.md).

The stack refuses a runbook naming a tier that does not exist, a tier no
runbook names, and the two forms mixed. A cell that declares no `identities`
keeps the earlier single-identity form: `identity_name`, `graph_app_roles`,
and `arm_role_assignments` at the top level, one identity keyed `default`, and
`moved` blocks that keep an existing deployment's identity and Graph grants in
state.

All tier identities are attached to the one Automation account, so a tier
bounds a runbook defect or a bad parameter, not anyone who can publish a
runbook or start a job in the account. Every tier that holds `Mail.Send` needs
its own Exchange application access policy; the `identities` output lists each
tier's client ID and whether it sends mail.

## What the stack injects into every job schedule

A cell states the sender mailbox, the cloud, and whether runs are dry once. The
stack turns those, plus the client ID of the tier identity each runbook runs as
(which only exists after the account module has run), into job schedule
parameters for every runbook:

| Parameter | From | Why here |
|-----------|------|----------|
| `clientid` | the `identity_key` tier's `client_id` | the runbook passes it to the Automation identity endpoint; a cell cannot know it, and it decides which identity the job runs as |
| `environment` | `graph_environment` | one cloud per tenant, not per runbook |
| `sendermailbox` | `sender_mailbox` | one mailbox per tenant, restricted by the Exchange policy |
| `dryrun` | `dry_run` | one switch to flip after the dry-run output has been reviewed |

Per-runbook parameters (thresholds, caps, group names) stay in the cell under
each runbook. A cell that tries to pass one of the four injected keys fails
validation, so two runbooks in one tenant cannot disagree about them. Every
runbook in `automation/runbooks` declares all four, even one that ignores a
value (the backup sends no mail), because a job schedule that passes a
parameter the runbook does not declare is expected to fail to bind.

## Values a runbook asks for by name

Some parameters are values only the stack knows, and they are not the same for
every runbook, so they are not injected everywhere. A runbook entry asks for
them in `stack_parameters`, which maps a parameter key to the name of a value:

| Value name | Value | Used by (corp) |
|------------|-------|----------------|
| `automation_account_name` | this stack's Automation account | `Watch-AutomationJobFailures` |
| `automation_account_names` | the same, as a one-element semicolon list | `Backup-AutomationRunbooks` |
| `resource_group_name` | the account's resource group | the watcher and the backup |
| `subscription_id` | the account's subscription, as an ID | the watcher and the backup; both skip the subscription lookup when given an ID |
| `identity_principal_id` | object ID of this runbook's own tier identity | `Disable-UnauthorizedSubscriptions`, which refuses a live run if its token disagrees |
| `backup_storage_account_name` | the `backup_storage` account | the backup |
| `backup_container_name` | the `backup_storage` container | the backup |

The cell names the value; it never types it, so no cell holds a GUID or
repeats the account name. Validation rejects an unknown value name, a key that
is also in `parameters` or is one of the four injected keys, a backup value
when `backup_storage` is not set, and `backup_storage` when no runbook asks
for a backup value (which would leave the container with no writer). Asking
for a backup value is also what grants that runbook's tier Storage Blob Data
Contributor on the container, so the data role follows the runbook that
writes.

## Dry run is the shipped default

`dry_run` defaults to `true` and the corp cell sets it to `true` explicitly. All
nine runbooks read everything, compute everything, and log every action they
would take. Flipping to `false` is a one-line change to the cell, reviewed in a pull
request whose plan shows the job schedules being replaced (every job schedule
argument forces replacement). Nothing in the portal can turn a dry schedule live
without that plan. Before flipping it, read the runbook headers: the first live
PIM runs are expected to trip their caps once on a tenant still on Microsoft's
defaults.

The subscription guard has a second switch of its own, `allowcancel`, in its
cell entry. `dry_run = false` alone makes it a report-only live run that mails
its digest and creates no Owner assignment at all; `allowcancel = "true"` is
what lets it elevate and cancel, and it is turned only after a written
sign-off on Cancel and a sandbox round trip
([ADR 0014](../../docs/adr/0014-just-in-time-self-elevation-under-an-abac-delegation-condition.md)).

## Azure role assignments for the identities

A managed identity cannot activate a PIM role, so what a runbook may do in
Azure Resource Manager is a set of standing assignments on its tier's
identity, declared inside that tier's `arm_role_assignments` and created by
`modules/azure/workload-role-assignment`. A scope is a management group or
subscription display name, a resource group name, or `automation_account`
(this stack's own account). A role is a display name, built-in or custom;
custom roles are defined in `stacks/azure-rbac-roles`
([ADR 0005](../../docs/adr/0005-definitions-and-assignments-in-separate-cells.md)),
which is why the corp automation cell has a `dependencies` block on the corp
roles cell.

**A custom role and its first use do not belong in the same pull request.** A
role is resolved by name at plan time, so a pull request that adds a role
definition and an assignment that names it plans red in this cell ("Role
definition ... was not found") until the roles cell has been applied, which
happens on merge. The release train already applies the roles cell first, so
the change is correct and the plan is not; land the definition in its own pull
request, let it apply, then open the one that uses it. Where that is not
practical, say in the pull request description which plan is expected to fail
and why, and do not merge on a red plan without reading it.

One careless entry can undo another's constraint, in any tier: Owner, User
Access Administrator, and Role Based Access Control Administrator are
therefore refused without a `condition`, at the stack and again in the module.

A condition is Azure ABAC text (conditionVersion 2.0). It names GUIDs, which a
cell never holds, so it may use two tokens the module replaces:
`<principal_id>` (the identity of the tier the entry belongs to) and
`<role_id:NAME>` (the GUID of the role named `NAME`). The corp cell uses them
for the subscription guard's delegation condition; the rendered text is in the
`arm_role_assignment_conditions` output.

What the corp cell grants, and why:

| Tier | Entry | Role | Scope | For |
|------|-------|------|-------|-----|
| `observer` | `watcher-reader-on-account` | Reader | this Automation account | the watcher's reads and the backup's runbook and content reads |
| `observer` | `watcher-state-on-account` | Automation Variable Writer (custom) | this Automation account | the watcher's state variable, and, because there is no narrower scope, every other variable in the account |
| `observer` | (from `backup_storage`) | Storage Blob Data Contributor | the backup container | the backup's uploads, reads, and prunes |
| `pim` | `pim-reader-at-root` | Reader | root management group | the Azure PIM sweep's reads, dry and live |
| `pim` | `pim-policy-operator-at-root` | PIM Policy Operator (custom) | root management group | policy patches, live only |
| `subscription-guard` | `subscription-guard-reader-at-sandbox` | Reader | sandbox management group | subscriptions, owners, and Owner eligibilities |
| `subscription-guard` | `subscription-guard-at-sandbox` | Role Based Access Control Administrator, conditioned | sandbox management group | the guard's just-in-time Owner on itself |

`watcher-state-on-account` is the one grant in that table whose reach is wider
than the sentence in its `For` column. Azure RBAC has no per-variable scope for
Automation, so `Microsoft.Automation/automationAccounts/variables/write` at the
account is write on every variable in it: in the corp cell that is the two PIM
baselines and the nine `AuthMethods_*` variables `desired_state_files`
publishes, which are tier 0 input, as well as `JobWatch_AlertedJobIds`. The
watcher refuses to write any name that does not start with `JobWatch_`, the
desired-state variables are Terraform-owned so a change outside a release is
plan drift, and the watcher reports other variables changed inside its lookback
window in its digest; none of those is an RBAC boundary, so see ADR 0016 for
the activity log alert to add and for the blob alternative that removes the
grant.

The `lifecycle` tier holds no Azure role at all, and the PIM eligibility
renewal needs none while its Azure plane is off. Turning that plane on
(`includeazureresources = "true"`) means giving the `pim` tier the wider
custom role PIM Policy and Eligibility Operator, whose
`roleEligibilityScheduleRequests/write` can create an eligibility for any
principal at the scope and therefore makes the tier Owner-equivalent there.

Two built-in roles that look like they fit do not. Role Based Access Control
Administrator holds no `roleManagementPolicies` or
`roleEligibilityScheduleRequests` action, so it cannot do the PIM runbooks'
writes, and an unconditioned copy of it would void the guard's condition.
Automation Job Operator cannot write a variable (a live watcher that cannot
save its state sends nothing and fails) and can start jobs, which the watcher
never does.

## Backup storage

`backup_storage` is null by default. Set to an object, it creates a storage
account with shared key access disabled, TLS 1.2 minimum, HTTPS only, no
anonymous access, infrastructure encryption, blob versioning with a lifecycle
rule behind it, and blob and container soft delete; one private container; and
Storage Blob Data Contributor on that container for the identity of every
runbook that asks for a backup value in `stack_parameters`, which in corp is
the `observer` tier alone. The account is `prevent_destroy`, so setting
`backup_storage` back to null fails the plan until the flag is lifted in a
deliberate change. See `modules/azure/backup-storage/README.md` for the
checkov skips it carries and the one provider behaviour to confirm on the
first apply.

## What is outside this stack

- **The stage groups.** `Invoke-GuestLifecycle` resolves `LC Guests Warned`,
  `LC Guests Disabled`, and `LC Guests Exempt` by display name. They are ordinary
  security groups created with the tenant's other groups; the runbook refuses to
  run if one is missing or ambiguous. The same goes for every other group a
  runbook names (approver groups, the subscription owner allowlist group, the
  PIM groups).
- **The sender mailbox and the Exchange application access policies.**
  `Mail.Send` is granted here; the policy that restricts an identity to the
  mailbox is an Exchange object with no Terraform resource, applied once per
  identity with `New-ApplicationAccessPolicy -AppId <that tier's client id>`.
  The `identities` output lists every tier, its client ID, and whether it
  holds `Mail.Send`, for exactly those commands.
- **Diagnostic settings.** Job streams reach the SIEM through the Automation
  account's diagnostic settings, which belong with the Log Analytics workspace
  that receives them. The job watcher excludes itself, so its own failures
  need that path (or an Azure Monitor alert on the account's TotalJob metric)
  as a second signal.
- **The watcher's state variable.** `Watch-AutomationJobFailures` creates and
  rewrites `JobWatch_AlertedJobIds` itself. Declaring it here would make every
  plan show drift.
- **Custom role definitions.** `stacks/azure-rbac-roles`.
- **The resource group.** Looked up by name, created by the platform bootstrap.

## Runbook files and Terragrunt

The stack reads runbook bodies from `automation/runbooks`, resolved relative to
the stack as `${path.module}/../../automation/runbooks/<file>`, the same way the
stack reaches `../../modules`. A cell names the file only, never a path. A
runbook entry may also name a `library` under `automation/lib`; the runbooks
module inlines it between the runbook's marker lines at deploy time (see
`modules/azure/automation-runbooks/README.md` and
[ADR 0013](../../docs/adr/0013-one-shared-runbook-library-inlined-at-deploy-time.md)).

A runbook parameter that is a list is one string in the job schedule, joined
with semicolons: the cell writes `join(";", [...])`, which serialises values
and is not logic, and the runbooks split it with the library's
`ConvertTo-StringList`. Never `jsonencode()` a list into a job schedule
parameter, and never put an object in one at all: the Automation service may
parse a JSON-looking value before it binds it, and a `[string]` parameter then
receives `@{...}` or a space-joined array. Objects go through
`desired_state_files` instead (below). No list element may contain a semicolon
or a comma.

## Desired-state files as Automation variables

The authentication methods policy has no Terraform resource
([ADR 0012](../../docs/adr/0012-authentication-methods-policy-as-desired-state.md)).
Its desired state is the JSON under `policies/entra/authentication-methods`,
and `desired_state_files` publishes each file as an Automation string
variable (`AuthMethods_Policy`, `AuthMethods_Fido2`, and so on) holding the
file's text. `Invoke-AuthenticationMethodsDrift` reads those variables with
`Get-AutomationVariable`, so the weekly comparison is against exactly what the
repository says, a file edit is a plan diff on the variable, and nothing is
read from a portal-editable place that could silently diverge. A cell lists
repository-relative paths; the stack calls `file()` on each.

The two PIM baselines travel the same road, for the second reason above:
`policies/azure/pim-governance/corp-baseline.json` becomes
`PimPolicy_AzureBaseline` and `policies/entra/pim-governance/corp-baseline.json`
becomes `PimPolicy_EntraBaseline`, and each runbook entry passes only
`baselinevariablename`. Both runbooks stop rather than fall back to their
built-in defaults when the variable is missing or unreadable, so a baseline
that did not deploy is a failed job, not a silent sweep with no overrides
([ADR 0015](../../docs/adr/0015-runtime-pim-governance-alongside-declarative-stacks.md)).

## Provider configuration

`versions.tf` declares `required_providers` only. The provider blocks are
generated by Terragrunt from `tenant_id` and `subscription_id`, which
`tenants/azure/root.hcl` reads from the environment. The apply identity needs
Contributor on the resource group (account, identities, runbooks, backup
storage), the ability to grant Graph application permissions
(`AppRoleAssignment.ReadWrite.All` with `Application.Read.All`, or Privileged
Role Administrator), and the ability to create role assignments, including a
Role Based Access Control Administrator assignment, at every scope any tier's
`arm_role_assignments` names and on the backup container (Owner or User
Access Administrator there).

## Standalone use without Terragrunt

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "azure_automation" {
  source = "./stacks/azure-automation"

  tenant_id       = "00000000-0000-0000-0000-000000000000"
  subscription_id = "00000000-0000-0000-0000-000000000000"

  resource_group_name     = "rg-example-identity-automation"
  automation_account_name = "aa-example-identity"
  tenant_label            = "corp"
  sender_mailbox          = "iam-noreply@corp.example.com"
  dry_run                 = true

  identities = {
    observer = {
      name            = "id-example-automation-observer"
      graph_app_roles = ["Mail.Send"]

      arm_role_assignments = {
        watcher-reader-on-account = {
          role_name = "Reader"
          scope     = { type = "automation_account" }
        }
        watcher-state-on-account = {
          role_name = "Automation Variable Writer"
          scope     = { type = "automation_account" }
        }
      }
    }
  }

  schedules = {
    hourly-45-utc = {
      name       = "hourly-45-utc"
      frequency  = "Hour"
      start_time = "2027-01-04T00:45:00Z"
    }
  }

  runbooks = {
    job-failure-watch = {
      name         = "Watch-AutomationJobFailures"
      file         = "Watch-AutomationJobFailures.ps1"
      library      = "Runbook.Common.ps1"
      schedule_key = "hourly-45-utc"
      identity_key = "observer"
      parameters = {
        recipients = join(";", ["iam@corp.example.com"])
      }
      stack_parameters = {
        automationaccountname = "automation_account_name"
        resourcegroupname     = "resource_group_name"
        subscriptionname      = "subscription_id"
      }
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `tenant_id` | `string` | Entra tenant ID, from the environment via root.hcl. |
| `subscription_id` | `string` | Subscription of the account, from the environment via root.hcl. |
| `resource_group_name` | `string` | Existing resource group, by name. |
| `location` | `string` | Region; null uses the resource group's. |
| `automation_account_name` | `string` | Account name. |
| `identities` | `map(object)` | One entry per privilege tier: identity name, its Graph permissions, its Azure role assignments. Default `{}` (single-identity form). |
| `identity_name` | `string` | Single-identity form: the one identity's name. Null with tiers. |
| `tags` | `map(string)` | Tags for account, identities, runbooks, backup storage. |
| `tenant_label` | `string` | Short tenant label for log context. |
| `sender_mailbox` | `string` | Shared mailbox the runbooks send from. |
| `dry_run` | `bool` | Passed to every runbook. Default `true`. |
| `graph_environment` | `string` | `Global` or `USGov`. |
| `graph_app_roles` | `list(string)` | Single-identity form: Graph permissions for the one identity. Null (default) means the union the shipped runbooks need. |
| `runbooks` | `map(object)` | Runbooks with file, optional library, schedule key, identity key, parameters, and stack_parameters. |
| `schedules` | `map(object)` | Schedules; see `modules/azure/automation-runbooks`. |
| `desired_state_files` | `map(string)` | Variable name to repository-relative JSON path, published as Automation string variables (desired state and the PIM baselines). Default `{}`. |
| `arm_role_assignments` | `map(object)` | Single-identity form: Azure role assignments for the one identity, by scope and role name, with optional token-based ABAC conditions. Default `{}`. |
| `backup_storage` | `object` | Backup storage account and container. Default `null` (none). |

## Outputs

| Name | Description |
|------|-------------|
| `automation_account_id` | Account resource ID. |
| `identities` | Tier to its identity name, principal ID, client ID, Graph permissions, whether it sends mail, and the runbooks that run as it. |
| `identity_principal_id` | The `default` identity's service principal object ID, or null with tiers. |
| `identity_client_id` | The `default` identity's client ID, or null with tiers. |
| `runbook_names` | Key to runbook name. |
| `runbook_content_hashes` | Key to SHA-256 of the deployed file. |
| `job_schedule_ids` | Key to job schedule ID. |
| `graph_app_role_assignment_ids` | Tier to permission name to assignment ID. |
| `arm_role_assignment_ids` | Tier to assignment key to role assignment ID. |
| `arm_role_assignment_conditions` | Tier to assignment key to the condition as sent, tokens replaced. |
| `backup_storage` | Backup account and container names, container scope, and the tiers allowed to write, or null. |
