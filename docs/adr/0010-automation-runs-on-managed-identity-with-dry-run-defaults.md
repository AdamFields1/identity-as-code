# ADR 0010: Scheduled identity hygiene runs on a managed identity, dry by default, with a cap on every destructive action

Status: accepted
Date: 2026-09-16

> Note, 2026-09-17: two decisions below have since been refined, and this
> record keeps its original wording.
>
> - **`DryRun` is `[bool]$DryRun = $true`, not `[switch]`.** A job schedule
>   passes every value as a string, and a string binds to a boolean but not to
>   a switch, so every runbook declares a `[bool]`, and schedule-bound
>   parameters are `[bool]`, `[int]`, or `[string]` only. See
>   [ADR 0013](0013-one-shared-runbook-library-inlined-at-deploy-time.md), "the
>   host runbook has a contract too", and `automation/README.md`.
> - **One identity per Automation account became one identity per privilege
>   tier.** The consequence below ("more permission than any one runbook
>   needs") is what
>   [ADR 0016](0016-one-identity-per-privilege-tier-in-one-automation-account.md)
>   acts on. Everything else here (managed identity only, no secret, dry by
>   default, a cap per destructive action) stands unchanged.

## Context

Some identity work cannot be a Terraform resource because the decision depends
on live data that changes every day: which application credentials have
expired and for how long, which guests have not signed in since a date, who
owns the application that is about to break. Terraform can declare that a
credential should not exist; it cannot notice that one expired last Tuesday and
tell the owner. That work has traditionally been a script on somebody's
workstation, run when they remember, under their own account, with a
`-WhatIf` they stop typing after the first week.

Three questions had to be settled: what identity the work runs as, what the
default behaviour of a run is, and what happens when a run would do a great
deal at once.

**Identity.** The options were a service principal with a client secret held
as an Automation credential asset, a service principal with a certificate, a
system-assigned managed identity on the Automation account, or a user-assigned
managed identity. The first two create exactly the long-lived secret ADR 0003
refuses everywhere else, now with write access to users and applications. A
system-assigned identity has no secret but is created with the account and
destroyed with it, so it cannot be granted permissions in the same plan that
creates the account and a rebuilt account comes back with none.

**Default behaviour.** A runbook that acts by default is one bad parameter away
from disabling every guest in the tenant. A runbook that must be told to act
turns that into a reviewed value.

**Volume.** A run that finds 400 guests to disable is not a run that should
disable 400 guests. Either something changed (a sign-in log outage, a bulk
import, a clock) or the thresholds were wrong, and in both cases the right
response is a person looking before anything happens.

## Decision

**Runbooks run on a user-assigned managed identity created by Terraform, and
nothing else.** `modules/azure/automation-account` creates the identity with the
account; `modules/entra/graph-app-role-grant` grants it Microsoft Graph
application permissions by name in the same plan; the runbook asks the Automation
identity endpoint for a token with that identity's client ID, which the stack
injects into every job schedule. There is no credential asset, no certificate,
no client secret, and no code path in a runbook that could read one. On a
workstation the caller passes their own token for a dry run; the live path exists
only inside Automation. The token value is never written to any stream.

**Every runbook is dry by default.** `[switch]$DryRun = $true` on every runbook.
A dry run reads and computes everything and logs every action prefixed with
"Would". Acting requires `-DryRun:$false`, which reaches the runbook only as a
job schedule parameter, which is `dry_run = false` in the tenant cell, which is a
pull request whose plan shows the job schedules being replaced. The shipped corp
cell is dry. A stack variable that a runbook could not be deployed without makes
the default visible in the one file a reviewer reads.

**Every destructive action has a cap, and the cap's failure mode is chosen per
action.** Credential removal truncates at `MaxRemovalsPerRun`: each removal is
independent, was announced to an owner in an earlier digest, and the rest can
wait for tomorrow. Guest disable and purge abort at `MaxDisablePerRun` and
`MaxPurgePerRun`: the run stops with an error before writing anything, because
a count that large is a symptom and a partial run would hide it. The caps are
parameters in the cell, not constants, so raising one for a single run is a
reviewed change too.

**Owners are told before anything is removed.** The credential runbook sends
one digest per owner naming every expiring and expired credential and the date
removal becomes possible, and removes only what has been expired for the full
grace period. The guest runbook warns the guest and the sponsor and climbs one
rung per run. Nobody is surprised by a removal they were not told about.

**Runs are correlated to the audit trail.** Every log line and the summary
object carry a `RunId`. The Automation account's diagnostic settings forward
the job streams to the SIEM; the Entra audit log records the identity's writes;
the `RunId` joins them, and a ticket points at the run.

## Consequences

- One user-assigned identity per tenant Automation account, granted six Graph
  application permissions. That is more permission than any one runbook needs
  and is accepted for now; splitting into one identity per runbook is a second
  account module call and a narrower `graph_app_roles` list when it is wanted.
- `Mail.Send` as an application permission can send as any mailbox. The
  Exchange application access policy that restricts it to the sender mailbox
  has no Terraform resource and is applied once outside this repository; the
  stack outputs the identity client ID for exactly that command, and the READMEs
  say so in three places because it is the one step that is easy to skip.
- Runbooks are self-contained files with the logging, identity, and transport
  helpers repeated in each. Azure Automation runs one file; a shared module
  asset would be a second thing to version and deploy.
- The tests never reach a tenant. The two functions that build and send
  requests are mocked, the clock is a parameter, and the boundaries (exactly
  `WarnDays` out, exactly `RemoveAfterDays` past, exactly the cap) are asserted.
- A `[switch]` parameter is set from a job schedule by the string `"false"`. If
  a future Automation runtime binds that differently, the failure is a job that
  errors out on parameter binding, not a dry schedule that quietly goes live.
- Certificates are removed by rewriting the application's `keyCredentials`
  without the expired entry, not through `removeKey`, which requires a
  proof-of-possession token signed by a key the runbook does not have. The
  header says so; a reader who expects `removeKey` will find the reason.
