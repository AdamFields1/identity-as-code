# automation

Runbooks that keep the identity estate tidy and governed between Terraform
applies: things that Terraform should not own because they are decisions made
against live data every day (which credentials have expired, which guests have
gone quiet, which eligibilities are about to lapse, which subscriptions nobody
authorised), cannot own because no resource exists (the authentication methods
policy), or cannot see because nobody declared them (the PIM settings of a
role made eligible from the portal), but that still deserve code, review,
tests, and a deployment pipeline. The runbooks are deployed as code by
`stacks/azure-automation`; the rules below are what every runbook in this
directory follows, and what a reviewer checks a new one against.

```
automation/
  runbooks/
    Invoke-AppCredentialHygiene.ps1        expiring and expired app credentials: digest owners, remove after a grace period
    Invoke-GuestLifecycle.ps1              dormant guests: warn, disable, purge, with the stage held in group membership
    Invoke-AuthenticationMethodsDrift.ps1  authentication methods policy versus policies/entra/authentication-methods: digest, enforce when allowed
    Backup-AutomationRunbooks.ps1          published runbook source to blob storage: package, restore-verify, prune with a floor and a cap
    Invoke-PimEligibilityRenewal.ps1       expiring PIM eligibilities of groups on directory roles, PIM groups, and Azure roles: extend; list individual ones
    Disable-UnauthorizedSubscriptions.ps1  restricted-offer subscriptions with no allowlisted owner: cancel through a just-in-time, self-removed Owner assignment
    Invoke-AzurePimPolicyGovernance.ps1    Azure resource PIM activation rules, declared or not, held to the tenant baseline
    Invoke-EntraPimPolicyDrift.ps1         Entra directory role and PIM group activation rules compared with the baseline: digest, enforce when allowed
    Watch-AutomationJobFailures.ps1        failed jobs and missed scheduled runs in the account: one digest per new finding
  lib/
    AuthenticationMethods.Common.ps1       diff, plan, apply, export; dot-sourced by the script, inlined into the runbook at deploy time
    Runbook.Common.ps1                     logging, identity, transport, lookups, breaker, summary; inlined into the six newer runbooks at deploy time
  tests/
    *.Tests.ps1                            Pester tests, offline, HTTP mocked
    Runbook.Common.Tests.ps1               the shared library, including its inline contract with the runbooks module
    PolicyBaselines.Tests.ps1              the PIM baseline files, the corp cell that publishes them, and the transport rules
    Invoke-Tests.ps1                       parse gate plus Pester runner
```

The related export helper, `scripts/Export-PimEligibilityImports.ps1`, lives with
the other adoption scripts because it is run from a workstation, not from
Automation. `scripts/Set-AuthenticationMethods.ps1` is the workstation and
pipeline face of the drift runbook: same library, same comparison, plus
`-FailOnDrift` for a pull request check and `-Export` for adopting a tenant.

## Schedules in the corp cell

| Runbook | Schedule (UTC) | Caps |
|---------|----------------|------|
| `Backup-AutomationRunbooks` | daily 02:00 | `MaxDeletesPerRun` 20 (skips all retention and fails the job), `MaxShrinkPercent` 25, `KeepAtLeast` 7 |
| `Invoke-PimEligibilityRenewal` | daily 03:30 | `MaxRenewalsPerRun` 20 (aborts) |
| `Disable-UnauthorizedSubscriptions` | daily 04:00 | `MaxDisablesPerRun` 3 (aborts) |
| `Invoke-AzurePimPolicyGovernance` | daily 05:00 | `MaxPolicyUpdatesPerRun` 25 (aborts) |
| `Invoke-EntraPimPolicyDrift` | daily 05:15 | `MaxRuleUpdatesPerRun` 40 (aborts) |
| `Invoke-AppCredentialHygiene` | daily 06:00 | `MaxRemovalsPerRun` 25 (truncates) |
| `Invoke-GuestLifecycle` | Monday 07:00 | `MaxDisablePerRun` 25, `MaxPurgePerRun` 10 (abort) |
| `Invoke-AuthenticationMethodsDrift` | Sunday 08:00 | last enabled method is never disabled |
| `Watch-AutomationJobFailures` | hourly at :45 | at most three writes per run, asserted |

The nightly order is deliberate: the backup runs before anything changes, the
renewal before the PIM sweeps that read the same eligibilities, and the
watcher at a minute when nothing else starts. Every one of them is dry in the
shipped cell.

The subscription guard needs two switches, not one: `dry_run = false` makes it
a report-only live run that mails its digest, and `allowcancel = "true"` in
its cell entry is what lets it create the just-in-time Owner assignment and
call Cancel. Both default to the safe value, and the second is turned only
after the Cancel sign-off described in its header and in
[ADR 0014](../docs/adr/0014-just-in-time-self-elevation-under-an-abac-delegation-condition.md).

## Design rules

**Managed identity only, and one per privilege tier.** A runbook authenticates
as a user-assigned managed identity of the Automation account, and nothing
else. Which one is not the same for every runbook: the account carries one
identity per privilege tier, each holding only what its own runbooks use, and
the cell says which tier a runbook runs as (see "Identity tiers" below and
[ADR 0016](../docs/adr/0016-one-identity-per-privilege-tier-in-one-automation-account.md)).
In the sandbox it reads
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` and asks for a token for the Graph,
Azure Resource Manager, or Storage resource with the identity's `client_id`; if
`Az.Accounts` happens to be loaded it uses `Connect-AzAccount -Identity`; on a
workstation the caller passes `-AccessToken` obtained from their own session
(one token, or a JSON object with `Graph`, `Arm`, and `Storage` keys for a
runbook that calls more than one). There is no credential asset, no
certificate, no client secret, and no code path that could read one. The token
value is held in a script variable and never written to any stream, and the
shared library scrubs anything shaped like a token from every log line and
error. See
[ADR 0010](../docs/adr/0010-automation-runs-on-managed-identity-with-dry-run-defaults.md).

**DryRun is the default.** Every runbook declares `[bool]$DryRun = $true`. It is a boolean rather than a switch because Azure Automation passes schedule parameters as JSON strings, and a string binds to a boolean but not to a switch. A
dry run reads everything, computes everything, logs every action it would take
with the word "Would", and writes nothing. Acting requires `-DryRun:$false` in
the job schedule parameters, which is a reviewed Terraform value in the tenant
cell (`dry_run = false`), never a portal edit. The shipped cell runs every
runbook dry.

**Schedule-bound parameters are `[bool]`, `[int]`, or `[string]`, lists are
semicolon strings, and structured configuration is an Automation variable.** A
job schedule hands every value over as a string, and the Automation service
gives JSON-looking values special handling: it may parse an array or an object
before the value is bound, so JSON text in a `[string]` parameter can arrive
as `@{...}` or as a space-joined array. So a list is one `[string]` holding a
semicolon list, written `join(";", [...])` in the cell (a comma separates
too, and no element may contain either), parsed with the library's
`ConvertTo-StringList`; a JSON array is still accepted from a local run, where
the text arrives unchanged. An object, which means a PIM baseline, is not a
parameter at all: the stack publishes it as an Automation string variable from
a file under `policies/`, the schedule passes the variable's name, and the
runbook reads it with `Get-AutomationStringVariable`. A baseline variable that
is missing or unreadable stops the run rather than falling back to defaults,
and every runbook refuses a value that starts with `@{`, `System.Object`, or
`System.Collections.`. No `[switch]`, and no `[string[]]`, on any top-level
runbook parameter, whether or not a schedule sets it today: `tools/repo_lint`
refuses both (`runbook-params`), so the two lists no schedule sets yet
(`ExcludedAppNames` on the credential hygiene runbook, `MethodIds` on the
authentication methods runbook) are semicolon strings parsed the way
`Recipients` is, and a cell can set them tomorrow without a signature change.

**Every destructive action has a cap, and the kind of cap is chosen per
action.** Credential removal is capped by `-MaxRemovalsPerRun` (default 25) and
truncates: the oldest expiries are removed, the rest are logged and left for
tomorrow, because each removal is independent and already announced to its
owner. Everything else aborts: guest disable and purge (`-MaxDisablePerRun`
25, `-MaxPurgePerRun` 10), subscription cancels (`-MaxDisablesPerRun` 3), PIM
policy patches (`-MaxPolicyUpdatesPerRun` 25, `-MaxRuleUpdatesPerRun` 40), and
PIM renewals (`-MaxRenewalsPerRun` 20). If the planned count exceeds the cap
the run stops with an error before writing anything, in a dry run too,
because a number that large is a symptom (a clock problem, a bulk import, a
broken filter, a new baseline) and a partial run would hide it. The backup's
delete cap stops all retention and fails the job but still uploads the new
backups, because holding back a new, uniquely named blob makes nothing safer.
The job watcher has no cap on findings, on purpose: aborting during a mass
failure would suppress the one alert that matters. All caps are job schedule
parameters.

**Lifecycle stage lives in group membership.** The guest ladder records where a
guest is by putting it in `LC Guests Warned` or `LC Guests Disabled`, and takes it
off the ladder when it is in `LC Guests Exempt`. Every transition is therefore a
group membership write in the Entra audit log, listable by anyone with Global
Reader, reviewable through access reviews, and reversible by a helpdesk agent
without touching code. The three groups are resolved by display name at run
time and are created outside this repository (they are ordinary security
groups). See [ADR 0011](../docs/adr/0011-lifecycle-stage-tracked-in-groups.md).

**Web requests go through one function.** In the first three runbooks
`Invoke-GraphRequest` is the only place a request is built and
`Invoke-RestCall` the only place `Invoke-WebRequest` is called. In the
runbooks on the shared library, `Invoke-CloudRequest` and
`Invoke-StorageRequest` build requests, `Invoke-RunbookHttp` retries them, and
`Invoke-HttpCore` is the only `Invoke-WebRequest` call, with no exception: a
blob download streams to a file through `Invoke-StorageRequest -Operation
GetBlobToFile`. A 429 is retried for every method, honouring `Retry-After` and
otherwise backing off exponentially up to 60 seconds for up to five attempts.
A 5xx or a lost response is retried for GET, PUT, and DELETE, and **not** for
POST or PATCH unless the call passes `-RetryNonIdempotent`, because the
service may already have applied it; the error then says so, and the runbook
that sent it decides (the PIM renewal reads its request back, the guard reads
the subscription state, a digest mail is simply not repeated). A 4xx other
than 429 fails immediately with the service's error body, truncated, scrubbed,
and never including a header.

**Writes are counted, and a run that failed ends Failed.** The library's
`Invoke-RunbookAction` is the path a write takes in the library runbooks: it
logs "Would ..." in a dry run and records the outcome on the summary either
way. A runbook whose failure must page someone ends its job Failed: the
backup and the subscription guard emit their summary first and then throw,
and the watcher throws when it cannot save its state or send its digest, so
`Watch-AutomationJobFailures` (or, for the watcher, the second signal its
header describes) reports it. A runbook that catches its own
errors and exits cleanly is invisible to the watcher.

**National cloud is a switch.** `-Environment Global|USGov` selects the Graph
base URL (`graph.microsoft.com` or `graph.microsoft.us`), the ARM base URL
(`management.azure.com` or `management.usgovcloudapi.net`), and the storage
endpoint suffix, and the same values are the token audiences. Nothing else in
a runbook knows which cloud it is in.

**What is published is one file; what is written is shared.** Azure Automation
runs one file. The first three runbooks (`Invoke-AppCredentialHygiene`,
`Invoke-GuestLifecycle`, and `Invoke-AuthenticationMethodsDrift`) still keep
their own copies of the logging, identity, and transport helpers, which was a
fair trade at three copies; the drift runbook shares only its domain logic,
through `AuthenticationMethods.Common.ps1`. The six newer
runbooks name `automation/lib/Runbook.Common.ps1` as their library instead:
each carries a `# INLINE_LIBRARY_BEGIN` / `# INLINE_LIBRARY_END` block with a
dot-source of the library between the markers, and `stacks/azure-automation`
replaces the block with the library's text at deploy time, so what is
published is still one self-contained file and the text the tests ran is the
text that runs. `AuthenticationMethods.Common.ps1` is the same mechanism for
logic a runbook shares with a workstation script. A runbook names at most one
library. The library has no param block, no `#Requires`, no `$PSScriptRoot` or
`$MyInvocation`, no marker strings, and no byte order mark, and its tests
check all of that and run a sample runbook both from disk and assembled the
way Terraform assembles it. See
`modules/azure/automation-runbooks/README.md`,
[ADR 0012](../docs/adr/0012-authentication-methods-policy-as-desired-state.md),
and [ADR 0013](../docs/adr/0013-one-shared-runbook-library-inlined-at-deploy-time.md).

**The host contract for a library runbook.** Declare `[bool]$DryRun = $true`,
`[ValidateSet('Global','USGov')][string]$Environment`, `[string]$ClientId`,
`[string]$AccessToken`, and `[string]$RunId`; set
`$ErrorActionPreference = 'Stop'` and `$VerbosePreference = 'Continue'`; then
the marker block. Define no function the library defines. In the run function
call `Initialize-RunContext` first and `New-RunSummary` next, call
`Test-CircuitBreaker` before any write, route writes through
`Invoke-RunbookAction`, and end with `Complete-RunSummary`. Wrap every call
that returns a list in `@()`. Gate the entry point with
`if ($MyInvocation.InvocationName -ne '.')` so tests can dot-source the file.

**Values only the stack knows come from the stack.** Every job schedule gets
`clientid`, `environment`, `sendermailbox`, and `dryrun` from the stack, so
every runbook declares those four, even one that ignores a value. `clientid`
is the client ID of the tier identity that runbook's entry names. A runbook
that needs its own account's name, resource group, or subscription, its own
identity's principal ID, or the backup storage names asks for them by name in
the cell's `stack_parameters`; a cell never types them.

**Desired state comes through the account, never from a portal-editable place.**
The drift runbook reads its desired state from Automation variables that the
stack publishes from `policies/entra/authentication-methods` with `file()`
(`AuthMethods_Policy`, `AuthMethods_Fido2`, and so on). A file edit is a plan
diff on a variable; the runbook compares the tenant with what the repository
says, and the two guards it applies (never disable the last enabled method,
never send `policyMigrationState` without `-AllowMigrationStateChange $true`)
are the same guards the script applies in the pipeline. The two PIM baselines
arrive the same way, from `policies/azure/pim-governance/corp-baseline.json`
and `policies/entra/pim-governance/corp-baseline.json` into the variables
`PimPolicy_AzureBaseline` and `PimPolicy_EntraBaseline`, which mirror the PIM
cells ([ADR 0015](../docs/adr/0015-runtime-pim-governance-alongside-declarative-stacks.md)).
The one piece of runtime state a runbook keeps, the watcher's
`JobWatch_AlertedJobIds`, is written by the watcher and is deliberately not a
Terraform resource.

**Windows PowerShell 5.1 and PowerShell 7.** The runbooks are deployed as
`PowerShell72` but must also run under 5.1 on a workstation, so there is no
ternary, no `??`, no `?.`, no parameter or variable named `$input`, no
`Write-Host` (it is invisible in Automation job output), and every
`Invoke-WebRequest` error path handles both `WebException` and
`HttpResponseException`.

## Logging contract

Every runbook has a `Write-RunLog -Level Info|Action|Warn|Error -Message` helper
(its own in the first three, the library's in the rest). Each line is

```
2026-09-16T06:00:12Z [ACTION] run=8f1c... Would remove secret ci on "Payroll API" (keyId ..., expired 2026-08-01).
```

`Info` and `Action` go to the verbose stream, which Azure Automation keeps with
the job because the runbook is deployed with `log_verbose = true`. `Warn` and
`Error` go to their own streams so a job filter finds them. An `Action` line
starting with "Would" is a dry run; the same line without it is a write that
happened. The last thing a runbook emits on the output stream is one summary
object (counts, `RunId`, `DryRun`, warnings, errors, `CompletedUtc`, and, in
the library runbooks, one item per planned or attempted write with its
outcome). The Automation account's diagnostic settings forward job streams to
the SIEM, the `RunId` correlates the summary with the Entra audit log and
Azure activity log entries the identity wrote (the subscription guard also
writes it into the description of its temporary role assignment, and the
renewal runbook into every PIM justification), and that is the record a
ticket points at.

## Identity tiers

The Automation account carries one user-assigned managed identity per
privilege tier, all attached to the account, and every runbook entry in the
cell names the tier it runs as (`identity_key`). The stack passes that tier's
client ID as the runbook's `clientid`
([ADR 0016](../docs/adr/0016-one-identity-per-privilege-tier-in-one-automation-account.md)).

| Tier | Runbooks | Graph | Azure |
|------|----------|-------|-------|
| `observer` | `Watch-AutomationJobFailures`, `Backup-AutomationRunbooks`, `Invoke-AuthenticationMethodsDrift` | `Policy.Read.AuthenticationMethod`, `Group.Read.All`, `Mail.Send` | Reader and Automation Variable Writer on the account, which is write on **every** variable there (see below); Storage Blob Data Contributor on the backup container |
| `lifecycle` | `Invoke-AppCredentialHygiene`, `Invoke-GuestLifecycle` | `Application.ReadWrite.All`, `Directory.Read.All`, `User.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`, `Mail.Send` | none |
| `pim` (tier 0) | `Invoke-AzurePimPolicyGovernance`, `Invoke-EntraPimPolicyDrift`, `Invoke-PimEligibilityRenewal` | the `RoleManagementPolicy.*`, `RoleEligibilitySchedule.*`, and `PrivilegedEligibilitySchedule.*` permissions in the table below, plus `RoleManagement.Read.Directory`, `Group.Read.All`, `Mail.Send` | Reader and PIM Policy Operator (custom) at the root management group |
| `subscription-guard` (tier 0 for its scope) | `Disable-UnauthorizedSubscriptions` | `User.Read.All`, `GroupMember.Read.All`, `Mail.Send` | Reader and the conditioned Role Based Access Control Administrator at the sandbox management group |

Four things follow from the table, and they are the reason it is here rather
than in one list:

- **`observer` is not read-only in Azure, and its one write reaches tier 0
  input.** Azure RBAC has no per-variable scope for Automation, so the custom
  role Automation Variable Writer, granted at the account so the job watcher
  can save the job ids it has reported, is `variables/write` on every variable
  in that account. In the corp cell that is `PimPolicy_AzureBaseline`,
  `PimPolicy_EntraBaseline`, and the nine `AuthMethods_*` variables the stack
  publishes from `desired_state_files` as well as `JobWatch_AlertedJobIds`.
  The lowest tier can therefore replace a tier 0 input: a rewritten Entra
  baseline in mode `exact` with weakened activation values would be applied to
  Global Administrator by the next live `Invoke-EntraPimPolicyDrift` run. What
  holds that down is three code and pipeline controls, none of them an RBAC
  boundary: the watcher writes no variable whose name does not start with
  `JobWatch_` and refuses any other `StateVariableName` before its first call;
  every desired-state variable is owned by Terraform from a file in this
  repository, so a value changed outside a release is drift the next plan
  shows; and the watcher reports any other variable in the account whose
  `lastModifiedTime` falls inside its lookback window, once per change, in its
  hourly digest. Add an activity log alert on
  `Microsoft.Automation/automationAccounts/variables/write` by the `observer`
  principal for any name other than `JobWatch_AlertedJobIds` where the tenant
  has activity log alerting; moving the watcher's state to a blob in the
  backup container removes the grant altogether (ADR 0016).
- **The authentication methods runbook runs in `observer` on its report
  path.** It holds `Policy.Read.AuthenticationMethod`, not the ReadWrite form,
  so it detects drift and mails the digest while the release train enforces
  the policy (ADR 0012). A live run in this tier logs an HTTP 403 for each
  patch it would make and records it as a failed patch; a tenant that wants
  the runbook to enforce moves it to a tier holding
  `Policy.ReadWrite.AuthenticationMethod`.
- **The eligibility renewal ships with `includeazureresources = "false"`**, so
  it touches directory roles and PIM groups only and the `pim` tier needs no
  eligibility action in Azure. Turning the Azure plane on means granting that
  tier `roleEligibilityScheduleRequests/write` (the custom role PIM Policy and
  Eligibility Operator), which creates an eligibility as readily as it extends
  one and so makes the tier Owner-equivalent over the scopes it names.
- **Tiers are not isolation.** Every identity is attached to the same account,
  so anyone who can publish a runbook, start a job, or change a schedule there
  can obtain a token for any tier. Tiers contain a runbook defect or a bad
  parameter; separate Automation accounts are what contain a person, and ADR
  0016 says when they are warranted.

Microsoft's published role definition GUIDs (for example
`8e3af657-a8ff-443c-a75c-2fe8c4bcb635` for Owner, in the subscription guard
and in the ABAC condition it carries) are public constants documented on
learn.microsoft.com, not tenant identifiers. They are the only GUIDs in this
repository that are not placeholders.

## Graph permissions

| Runbook | Application permissions | Why |
|---------|-------------------------|-----|
| `Invoke-AppCredentialHygiene` | `Application.ReadWrite.All`, `Directory.Read.All`, `Mail.Send` | read registrations and credentials, remove them, read owners, send digests |
| `Invoke-GuestLifecycle` | `User.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`, `Mail.Send` | read guests with `signInActivity`, disable and delete, write stage groups, read sponsors, send warnings |
| `Invoke-AuthenticationMethodsDrift` | `Policy.Read.AuthenticationMethod` in the shipped `observer` tier, which is its report path; `Policy.ReadWrite.AuthenticationMethod` only where the runbook is meant to enforce. Plus `Group.Read.All`, `Mail.Send` | read the authentication methods policy (and patch it where allowed), resolve group names, send the drift digest |
| `Backup-AutomationRunbooks` | none | Azure Resource Manager and Storage only |
| `Invoke-PimEligibilityRenewal` | `RoleEligibilitySchedule.ReadWrite.Directory` (`RoleEligibilitySchedule.Read.Directory` for a dry run), `RoleManagementPolicy.Read.Directory`, `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` (`PrivilegedEligibilitySchedule.Read.AzureADGroup` for a dry run), `RoleManagementPolicy.Read.AzureADGroup`, `Group.Read.All`, `Mail.Send` | read and extend directory role and PIM group eligibilities, read the expiration rule that clamps them, find role-assignable groups and resolve names, send the digest |
| `Disable-UnauthorizedSubscriptions` | `User.Read.All`, `GroupMember.Read.All`, `Mail.Send` | resolve allowlisted users, expand allowlisted groups, read owner addresses, send notices and the digest |
| `Invoke-AzurePimPolicyGovernance` | `Group.Read.All` (only when an approver group is named), `Mail.Send` | resolve approver groups, send the digest |
| `Invoke-EntraPimPolicyDrift` | `RoleManagementPolicy.ReadWrite.Directory` (`RoleManagementPolicy.Read.Directory` for a dry run), `RoleManagement.Read.Directory`, `RoleManagementPolicy.ReadWrite.AzureADGroup` (`RoleManagementPolicy.Read.AzureADGroup` for a dry run; only with `IncludeGroupNames`), `Group.Read.All`, `Mail.Send` | read and patch directory role and PIM group policies, read role names, resolve groups and approver members, send the digest |
| `Watch-AutomationJobFailures` | `Mail.Send` (live runs only) | send the digest |

`modules/entra/graph-app-role-grant` grants these to the right tier
identity's service principal as code, one module instance per tier, with each
runbook's permissions named even where another entry's ReadWrite form would
also be accepted (the stack's single-identity form still grants their union).
`Mail.Send` as an application permission lets an identity send as any mailbox;
pair every tier that holds it with an Exchange Online application access
policy that restricts that identity to the sender mailbox
(`New-ApplicationAccessPolicy -AppId <that tier's client id> -PolicyScopeGroupId <mail-enabled security group holding the shared mailbox> -AccessRight RestrictAccess`).
All four corp tiers hold `Mail.Send`, so all four need that command; the
stack's `identities` output lists each tier, its client ID, and whether it
sends mail. The policy is an Exchange object with no Terraform resource and is
applied once, outside this repository. `signInActivity` also needs a Microsoft
Entra ID P1 or P2 licence in the tenant, and the PIM runbooks need Microsoft
Entra ID P2 or Governance licensing for PIM itself.

## Azure permissions

A managed identity cannot activate a PIM role, so the Azure permissions below
are standing assignments, declared inside the tier that needs them in the
cell's `identities` map and created by
`modules/azure/workload-role-assignment`
([ADR 0014](../docs/adr/0014-just-in-time-self-elevation-under-an-abac-delegation-condition.md)).

| Runbook (tier) | Role | Scope | Why |
|----------------|------|-------|-----|
| `Backup-AutomationRunbooks` (`observer`) | Reader | each Automation account it backs up | list runbooks and read their published content (`runbooks/read`, `runbooks/content/read`; the Automation Operator roles cannot read content) |
| | Storage Blob Data Contributor | the backup container | list, read, write, and delete backups (Storage Blob Data Reader is enough for a dry run); created with `backup_storage`, for the tier of the runbook that asks for the storage names |
| `Watch-AutomationJobFailures` (`observer`) | Reader | the Automation account | jobs, streams, schedules, job schedules, its state variable |
| | Automation Variable Writer (custom) | the Automation account | save its state variable. No narrower scope exists, so this is write on every variable in the account, including the PIM baselines and the `AuthMethods_*` desired state |
| `Invoke-AzurePimPolicyGovernance` (`pim`) | Reader | each management group or subscription in `ScopeNames` | eligibility schedule instances, policy assignments, policies, descendants |
| | PIM Policy Operator (custom) | the same | `roleManagementPolicies/write` and `roleManagementPolicies/approvalRule/action`, live only |
| `Invoke-PimEligibilityRenewal` (`pim`) | none while `includeazureresources` is `"false"` | | directory roles and PIM groups are Graph only |
| | Reader, and PIM Policy and Eligibility Operator (custom) | each management group or subscription in `AzureScopeNames`, only with the Azure plane on | Reader covers the eligibility schedules, the policy assignments, the management group descendants, and the read-back `GET` of a renewal request the runbook made; the custom role adds `roleEligibilityScheduleRequests/write` for extend and renew. That action creates an eligibility as readily as it extends one, so it makes the tier Owner-equivalent over those scopes |
| `Disable-UnauthorizedSubscriptions` (`subscription-guard`) | Reader | the narrowest management group holding only the targeted subscriptions | subscriptions, owners, role definitions, role eligibility schedule instances |
| | Role Based Access Control Administrator with a delegation condition (Owner only, itself only) | the same | the just-in-time Owner assignment it creates and removes around each cancel |
| `Invoke-EntraPimPolicyDrift` (`pim`) | none | | Graph only |
| `Invoke-AppCredentialHygiene`, `Invoke-GuestLifecycle` (`lifecycle`), `Invoke-AuthenticationMethodsDrift` (`observer`) | none | | Graph only |

The three custom roles are defined in `tenants/azure/corp/azure-rbac-roles`.
Role Based Access Control Administrator is not a substitute for the PIM
custom roles (it holds no PIM action), User Access Administrator and Owner are
never assigned without a condition (an unconditioned role that can assign
roles lets its holder grant itself anything at the scope, and would void the
guard's condition), and Automation Job Operator is not a substitute for the
watcher's pair (it cannot write a variable and it can start jobs). The
delegation condition on the guard limits which role it may assign and to
which principal, not at which scope, so that identity can make itself an
unconditioned Owner anywhere under its management group; that is why it is a
tier of its own, at a sandbox management group, and never at the root. The
runbooks that take a subscription name get the subscription ID from the stack
instead, which skips the subscription list call and the subscription-level
read it needs.

## Testing locally

```powershell
cd automation\tests
.\Invoke-Tests.ps1
```

The runner parses every `.ps1` under `automation/` and `scripts/` first, then
runs Pester: 3.4.0 on a stock Windows PowerShell 5.1, or the exact version
`-PesterVersion` names. The tests use the `Should Be` syntax that 3.x and 4.x
share, so Pester 5 will not run them; install 4.10.1 with
`Install-Module Pester -RequiredVersion 4.10.1 -Force -SkipPublisherCheck -Scope CurrentUser`
to run them on PowerShell 7. `.github/workflows/automation-tests.yml` does
exactly that on `windows-latest`, under both `powershell` (5.1) and `pwsh`
(7), for every pull request and push that touches `automation/`, `scripts/`,
`policies/`, or `tenants/`. The last two are in the trigger because the suite
asserts against them: `PolicyBaselines.Tests.ps1` reads the two PIM baselines
and the corp cells, and several runbook tests compare a runbook's header with
the corp automation cell.

Nothing in the tests reaches a tenant, and the seams they mock are a short,
deliberate list:

| Mocked | Where | Why |
|--------|-------|-----|
| `Invoke-HttpCore` | every library runbook and the library itself | the one `Invoke-WebRequest` call; a router answers each documented URL with the JSON shape the API reference documents |
| `Start-Sleep` | every library runbook | retries and propagation waits, so a test of five attempts takes no minutes |
| `Test-AzAccountsAvailable` | every library runbook and the library | keeps the token path off `Az.Accounts` when the module happens to be installed |
| `Invoke-WebRequest` | the library's own tests, and as a guard in three runbook tests | proves the identity endpoint call, or fails the test if anything reaches the network below the core |
| `Connect-AzAccount`, `Get-AzContext`, `Get-AzAccessToken` | the library's tests only | the `Az.Accounts` fallback path |
| `ConvertFrom-RunbookJsonText` | the library's tests only | to return the PowerShell 5.1 shape of a parsed JSON array on either edition |
| `Get-AutomationVariable` (a global stand-in) and `$script:RunbookAutomationVariables` | Entra PIM drift, and the library | stands in for the Automation sandbox, which has no cmdlet outside a job |
| `Invoke-RunbookAction`, `Invoke-SubscriptionCancel` | subscription guard | to make one step throw and prove the `finally` block still removes the elevation |
| `Export-PimDriftReport` | Entra PIM drift | to make the report write fail after everything else succeeded |
| `Test-CircuitBreaker`, `ConvertFrom-Json` | job watcher | to trip the breaker on demand, and to return the PowerShell 7 date shapes |
| `Invoke-GraphGetAll`, `Invoke-GraphRequest`, `Invoke-RestCall`, `Get-DesiredStateJson` | the first three runbooks, which predate the library | their own transport and desired-state seams |
| `Invoke-ArmGetAll`, `Write-Host` | `scripts/Export-PimEligibilityImports.ps1` tests | its transport, and its console output |

Everything else runs as it ships, and the clock is a parameter wherever a
decision depends on it.

To run a runbook against a real tenant from a workstation, dry:

```powershell
$graph = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
$arm = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
$storage = az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv
$both = @{ Graph = $graph; Arm = $arm } | ConvertTo-Json -Compress

.\runbooks\Invoke-AppCredentialHygiene.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $graph -ReportPath .\out\credentials.csv
.\runbooks\Invoke-GuestLifecycle.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $graph -ReportPath .\out\guests.csv
.\runbooks\Invoke-AuthenticationMethodsDrift.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients iam@corp.example.com -DesiredStatePath ..\policies\entra\authentication-methods -AccessToken $graph
.\runbooks\Invoke-EntraPimPolicyDrift.ps1 -BaselineJson (Get-Content -Raw ..\policies\entra\pim-governance\corp-baseline.json) -AccessToken $graph -ReportPath .\out\pim-policy-drift.csv
.\runbooks\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'mg:mg-example-root' -BaselineJson (Get-Content -Raw ..\policies\azure\pim-governance\corp-baseline.json) -AccessToken $both -ReportPath .\out\pim-policies.csv
.\runbooks\Invoke-PimEligibilityRenewal.ps1 -IncludeAzureResources $true -AzureScopeNames 'mg:mg-example-root' -AccessToken $both -ReportPath .\out\pim-renewals.csv
.\runbooks\Disable-UnauthorizedSubscriptions.ps1 -SenderMailbox iam-noreply@corp.example.com -ManagementGroupName mg-example-sandbox -AllowedOwnerGroupNames 'SEC Subscription Owners' -AccessToken $both -ReportPath .\out\subscriptions.csv
.\runbooks\Watch-AutomationJobFailures.ps1 -AutomationAccountName aa-example-identity-corp -ResourceGroupName rg-example-identity-automation -SubscriptionName 'sub-example-identity' -AccessToken $arm
.\runbooks\Backup-AutomationRunbooks.ps1 -AutomationAccountNames aa-example-identity-corp -ResourceGroupName rg-example-identity-automation -SubscriptionName 'sub-example-identity' -StorageAccountName stexampleaabackupcorp -AccessToken (@{ Arm = $arm; Storage = $storage } | ConvertTo-Json -Compress)
```

The drift runbook takes `-DesiredStatePath` on a workstation, and the two PIM
runbooks take `-BaselineJson`, because `Get-AutomationVariable` exists only
inside the sandbox; in Automation each reads its variable and those parameters
are left empty. That is also why the local form reads the same file the stack
publishes: what is reviewed, what runs in the tenant, and what is tested are
one text.

Your own account needs the delegated equivalents of the permissions above,
and read access at the Azure scopes, for a dry run to read everything. Do not
pass `-DryRun:$false` from a workstation; the live path is the Automation job,
on the managed identity, with the parameters the tenant cell declares.

## Adding a runbook

1. Start from one of the library runbooks: header, param block with the
   five host parameters, marker block, constants, pure decision functions,
   run function, gated entry point.
2. Put every write behind `Invoke-RunbookAction`, which logs "Would ..." in a
   dry run.
3. Give every destructive action a cap parameter and decide, in the header,
   whether it truncates or aborts, and why. Call `Test-CircuitBreaker` before
   the first write.
4. Keep the decision logic in pure functions that take the clock and the
   inputs as parameters, and test the boundaries. Mock `Invoke-HttpCore` with
   the response shapes the API reference documents, and `Start-Sleep`; mock a
   function of your own only to make a step fail, and add it to the table
   above when you do.
5. Keep schedule-bound parameters to `[bool]`, `[int]`, and `[string]`, take
   lists as semicolon strings and structured configuration as the name of an
   Automation variable, and list the Graph permissions and Azure roles in the
   header.
6. Add the file to the `runbooks` map in the tenant cell with
   `library = "Runbook.Common.ps1"`, a schedule, `DryRun` on, the
   `identity_key` of the tier it runs as, and any stack-known values under
   `stack_parameters`; add its Graph permissions and Azure roles to that tier
   in `identities`, or declare a new tier when what it needs does not belong
   with an existing one; and add it to the tables in this file.
7. If the runbook must share domain logic with a workstation script, put the
   shared functions in `automation/lib/<Name>.ps1` with no transport or
   logging of their own, add the two `INLINE_LIBRARY` marker lines with a
   dot-source between them, and name the file as `library` in the cell. A
   runbook names one library.
