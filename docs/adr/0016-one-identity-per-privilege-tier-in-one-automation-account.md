# ADR 0016: One managed identity per privilege tier, inside one Automation account

Status: accepted
Date: 2026-09-17

## Context

ADR 0010 gave the runbooks one user-assigned managed identity per Automation
account and said so plainly in its consequences: "That is more permission than
any one runbook needs and is accepted for now." With three runbooks and six
Graph permissions that was a fair trade.

Nine runbooks later it is not. The union that one identity held was:

- `Application.ReadWrite.All`, `User.ReadWrite.All`, `Group.ReadWrite.All`,
  `Directory.Read.All`, `AuditLog.Read.All` (credential hygiene, guests),
- `Policy.ReadWrite.AuthenticationMethod` (authentication methods),
- `RoleManagementPolicy.ReadWrite.Directory`,
  `RoleManagementPolicy.ReadWrite.AzureADGroup`,
  `RoleEligibilitySchedule.ReadWrite.Directory`,
  `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup`,
  `RoleManagement.Read.Directory` (the PIM runbooks),
- `User.Read.All`, `GroupMember.Read.All`, `Group.Read.All`, `Mail.Send`,
- Reader and a PIM custom role at the root management group, Reader and a
  variable-writing custom role on the Automation account, and Role Based
  Access Control Administrator under a delegation condition at a sandbox
  management group (ADR 0014).

Every runbook ran with all of it. A bug in the backup runbook's blob name
handling ran as an identity that could also rewrite Global Administrator's
PIM policy; a bad parameter in the guest ladder ran as an identity that could
also make itself Owner of a sandbox subscription. Worse, the union voided
constraints that were carefully placed: the guard's delegation condition means
nothing if the same identity separately holds a role that can create
eligibilities, and a reviewer reading one cell entry could not tell what the
identity it names may do.

Three options:

1. **Keep one identity.** Simple, one Exchange application access policy, one
   client ID. Rejected: the union above is not defensible, and it grows with
   every runbook.
2. **One Automation account per tier.** True isolation: an identity is
   attached to its own account, and only someone who can write in that account
   can use it. Costs four accounts, four sets of schedules, variables,
   diagnostic settings, and state, four cells or a cell with four of
   everything, and a job watcher per account (or one that reads them all).
3. **One account, several user-assigned identities, one per tier, each
   runbook naming the tier it runs as.** Azure Automation allows several
   user-assigned identities on an account, and a runbook selects one by
   passing its client id to the identity endpoint, which is exactly what
   `ClientId` already does in every runbook here.

## Decision

**The Automation account carries one user-assigned managed identity per
privilege tier, and every runbook names its tier.**
`modules/azure/automation-account` takes an `identities` map and attaches all
of them; `stacks/azure-automation` takes the same map with each tier's
`graph_app_roles` and `arm_role_assignments`, and every entry in `runbooks`
carries an `identity_key`. The stack passes that tier's client id as the
runbook's `clientid`, and its principal id wherever the runbook asks for
`identity_principal_id`. A cell that declares no identities keeps the single
identity, under the key `default`, so the earlier shape still works and a
`moved` block keeps it in state.

The corp cell declares four tiers:

| Tier | Runbooks | Graph | Azure |
|------|----------|-------|-------|
| `observer` | job watcher, runbook backup, authentication methods drift | `Policy.Read.AuthenticationMethod`, `Group.Read.All`, `Mail.Send` | Reader and Automation Variable Writer on the account (account-wide: see below); Storage Blob Data Contributor on the backup container |
| `lifecycle` | credential hygiene, guest lifecycle | `Application.ReadWrite.All`, `Directory.Read.All`, `User.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`, `Mail.Send` | none |
| `pim` (tier 0) | Azure PIM policy governance, Entra PIM policy drift, PIM eligibility renewal | the `RoleManagementPolicy.*`, `RoleEligibilitySchedule.*`, and `PrivilegedEligibilitySchedule.*` permissions those three use, plus `RoleManagement.Read.Directory`, `Group.Read.All`, `Mail.Send` | Reader and the custom PIM Policy Operator at the root management group |
| `subscription-guard` (tier 0 for its scope) | subscription guard | `User.Read.All`, `GroupMember.Read.All`, `Mail.Send` | Reader and the conditioned Role Based Access Control Administrator at the sandbox management group |

Two rules follow from the table and are enforced by the stack:

- **A tier gets nothing its runbooks do not use.** The authentication methods
  runbook runs in `observer` on its report path with
  `Policy.Read.AuthenticationMethod`; the release train enforces that policy
  (ADR 0012). The eligibility renewal runs with `includeazureresources = false`
  and therefore needs no Azure role at all; turning the Azure plane on means
  giving the `pim` tier `roleEligibilityScheduleRequests/write` (the custom
  role PIM Policy and Eligibility Operator), which can create an eligibility
  as readily as extend one and is therefore Owner-equivalent over the scopes
  it covers. That is why the corp cell ships with the Azure plane off and the
  narrower PIM Policy Operator role.
- **An identity nobody names is refused**, and so is a runbook naming a tier
  that does not exist, or the two forms mixed in one cell.

**The one place the first rule does not hold, stated plainly.** Azure RBAC has
no per-variable scope for Azure Automation: the narrowest scope for
`Microsoft.Automation/automationAccounts/variables/write` is the Automation
account. The `observer` tier holds the custom role Automation Variable Writer
there so the job watcher can save the job ids it has already reported, and
that one assignment is write on **every** variable in the account. In the corp
cell that includes the tier 0 inputs `PimPolicy_AzureBaseline` and
`PimPolicy_EntraBaseline` and the nine `AuthMethods_*` variables the stack
publishes from `desired_state_files`. The lowest tier can therefore replace a
tier 0 input: a rewritten Entra baseline in mode `exact` with weakened
activation values would be applied to Global Administrator by the next live
`Invoke-EntraPimPolicyDrift` run. Three things hold that down, and none of
them is an RBAC boundary:

- The watcher writes no variable whose name does not begin with `JobWatch_`.
  `Write-JobWatchState` refuses any other name, and the runbook refuses such a
  `StateVariableName` before its first call, so a bad job-schedule parameter
  or a defect in that code path cannot aim the write at a baseline.
- Every desired-state variable is owned by Terraform, from a file in this
  repository. A value changed outside a release is drift the next plan shows.
- The watcher lists the account's variables on each hourly run and reports any
  variable other than its own state whose `lastModifiedTime` falls inside the
  lookback window, once per change, in the same digest as failed jobs. A
  release that changes a baseline produces one of those rows; anything else
  did not come from the repository. It is detection, not prevention, and it
  runs as the `observer` identity itself, so an activity log alert on
  `Microsoft.Automation/automationAccounts/variables/write` by that principal
  for any name other than `JobWatch_AlertedJobIds`, raised outside the
  account, is the control to add where the tenant has one.

Moving the watcher's state to a blob in the backup container would remove the
grant altogether, and is the change to make if the account ever holds a
variable whose contents matter more than this.

## What this does not buy, and when to use separate accounts

**Every identity is attached to the same account, so anyone who can publish a
runbook, start a job, change a schedule or its parameters, or register a
hybrid worker in that account can obtain a token for any of the four.** A job
is just a script that asks the identity endpoint for a token with a client id,
and nothing stops it asking with the `pim` tier's. The tiers therefore contain
a runbook defect, a bad parameter, or a wrong scope name, and they make what
each runbook may do reviewable in one place. They are not a boundary against
someone who controls the account, and they do not make write access to
`automation/`, to the Automation account, or to this repository any less
privileged: that path is still tier 0, as ADR 0014 and ADR 0015 say.

Separate Automation accounts are what actually separates the identities,
because RBAC on the account is then the boundary. It is warranted when:

- the people who may change a tier 0 runbook are not the people who may change
  the rest (the `pim` and `subscription-guard` tiers are the candidates here:
  one can rewrite the activation rules of Global Administrator, the other can
  make itself Owner anywhere under its management group and cancel
  subscriptions);
- a tenant's separation-of-duties requirement names the Automation account as
  the control boundary, or an auditor asks who can use an identity rather than
  what it holds;
- a tier needs a different network posture (a Hybrid Runbook Worker behind a
  private endpoint) or a different change cadence from the rest.

When that day comes, the move is small: a second cell pointing at the same
stack with its own account name, the tier's identities and runbooks, and its
own schedules. The stack does not need to change, and the runbooks do not need
to change at all.

## Consequences

- **Four identities mean four Exchange application access policies.** Every
  tier that holds `Mail.Send` (all four here, because each sends a digest or a
  notice) needs `New-ApplicationAccessPolicy -AppId <that tier's client id>`
  against the mail-enabled group holding the shared mailbox. The stack's
  `identities` output lists each tier, its client id, and whether it holds
  `Mail.Send`, for exactly that command. Missing one is a live run that fails
  to send, not a silent success.
- **Moving an existing account to tiers destroys the shared identity.** The
  `moved` blocks map the old single identity and its Graph grants to the
  `default` key; a cell that declares tiers has no such key, so the plan shows
  that identity, its app role assignments, and its role assignments being
  destroyed and the tier identities being created. Every job schedule is
  replaced too, because `clientid` changes. Add the new client ids to the
  Exchange policy before turning `dry_run` off.
- **The union is gone, so a missing permission is now a failed job rather
  than a silent success.** A runbook moved to a tier that lacks a permission
  it needs fails with HTTP 403 in its own log, which is the failure mode this
  ADR prefers to a quiet over-grant. The first dry runs after a tier change
  are where that shows up; the job watcher reports the failed job.
- **Two custom PIM roles now exist** (`stacks/azure-rbac-roles`, corp cell):
  PIM Policy Operator, which the `pim` tier holds, and PIM Policy and
  Eligibility Operator, which nothing holds today and which is what the Azure
  plane of the renewal would need. Defining a role nobody is assigned is
  cheap and makes the trade visible in a diff.
- **The reviewer's question changes shape.** Instead of "what may the runbook
  identity do", which had one long answer, a cell now answers "what may this
  tier do" four times, next to the runbooks that use it.
- **Nothing here changes what a compromised repository or pipeline can do.**
  ADR 0003's rules about CI credentials and ADR 0010's about dry runs and caps
  are still the controls that matter most.
