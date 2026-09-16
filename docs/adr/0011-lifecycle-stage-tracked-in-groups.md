# ADR 0011: Guest lifecycle stage is tracked as group membership

Status: accepted
Date: 2026-09-16

## Context

A dormant-guest ladder (warn, disable, purge) has to remember where each guest
is. The warning must be sent once, not every week; a guest must not be disabled
without having been warned; a purge must only follow a disable that the ladder
itself did, not one an administrator did for another reason. Something has to
hold that state between runs.

Four places were considered.

**A table in storage or a database.** Accurate and private, and invisible to
everyone who is not the runbook. An access reviewer, a helpdesk agent, or an
auditor asking "which guests are about to be disabled" needs a query against a
store they have no access to, and taking a guest off the ladder means editing
a row nobody else can see.

**An extension attribute or custom security attribute on the user.** This is
the design I have run in production: one attribute holds the stage and another
holds the date the guest entered it, stamped by the runbook on each transition.
It works well. The stage travels with the object, it survives group cleanup,
and the entry date is right there for the purge arithmetic. Its costs are the
reasons this repository chose differently: writing it is a user object update
that looks like every other user update in the audit log, reading it needs a
`$select` nobody remembers, the attribute numbers are a convention that has to
be documented somewhere outside the directory, and there is no natural way to
review "everyone at stage two" as a set or to hand a helpdesk agent a safe way
to exempt someone. In a tenant where those attributes are already governed and
the helpdesk already knows them, it is the better choice, and the runbook
logic here would port to it by swapping the three membership reads and writes
for an attribute read and two attribute writes.

**Inference from the account itself.** Disabled means disabled, dormant for N
days means warned. This cannot tell an account the ladder disabled from one a
person disabled, cannot record that a warning was actually sent, and makes the
purge decision depend on data the runbook did not write.

**Membership of a group per stage.** `LC Guests Warned`, `LC Guests Disabled`,
and an exclusion group `LC Guests Exempt`. Adding a member is a directory write
by the runbook's identity with the target and the time in the Entra audit log.
The set at each stage is listable by anyone with Global Reader, reviewable by an
access review pointed at the group, and editable by a helpdesk agent who adds a
guest to Exempt without touching code or a database.

## Decision

The stage is the group. `Invoke-GuestLifecycle` resolves the three groups by
display name at run time (the names are runbook parameters in the tenant cell),
reads their membership once, and decides each guest's stage from dormancy plus
which groups the guest is in:

- A guest not in any group who crosses `WarnDays` is added to Warned and mailed,
  once.
- A guest in Warned who crosses `DisableDays` is disabled, moved from Warned to
  Disabled.
- A guest in Disabled whose account is disabled and who crosses
  `DisableDays + PurgeDays` is deleted.
- A guest in Warned or Disabled who signs in again is removed from both, and the
  ladder starts over.
- A guest in Exempt is never touched, whatever the dormancy.
- A guest in Disabled whose account is enabled again is held and logged as a
  warning: someone re-enabled it outside the ladder, and the runbook does not
  guess why.

Restoration is a human action. The runbook never re-enables an account and
never restores one from the deleted items container. A guest who was disabled
or soft-deleted by the ladder gets back through a ticket, and a person on the
identity team re-enables or restores the account after confirming the sponsor
still wants the access. The runbook only observes the result: an account it
finds enabled again while still in Disabled is held and logged, never pushed
back down the ladder. Automating the way in is safe because every step is
reversible for thirty days; automating the way back would let a single sign-in
or a misfiled request undo a decision a person should make.

A guest climbs at most one rung per run, and never reaches Disable without
having been in Warned. The first run against an old tenant therefore warns
everyone and disables nobody, and the circuit breakers in ADR 0010 catch the
cases where even a warning wave is too large to be right.

The groups are ordinary security groups, created with the tenant's other
groups and never by this repository, because they are referenced by name and
a recreated group with a new object ID would be an empty ladder.

## Consequences

- Every transition is in the Entra audit log as a group membership change by
  the runbook identity, alongside the account disable and the delete. The
  `RunId` in the job output joins them.
- "Who is about to be disabled" is the membership of `LC Guests Warned`, read
  from the portal, Graph, or an access review, with no runbook access needed.
- Taking a guest off the ladder is adding them to `LC Guests Exempt`, which a
  helpdesk agent can do today; the next run leaves them alone and says so.
- Re-enable and restore are never automated. A disabled or soft-deleted guest
  returns through a ticket and a person, which keeps the highest-consequence
  reversal on the same review path as the original access request.
- A guest cannot be purged by the ladder unless the ladder disabled them,
  because purge requires Disabled membership and a disabled account. A person
  who disables a guest by hand does not start a purge clock.
- The date a guest entered a stage is not stored; dormancy is recomputed from
  sign-in activity each run and the stage groups gate the transitions. That is
  enough for the ladder and keeps the groups free of metadata. If a stage
  timestamp is ever needed, the audit log entry for the membership change has it.
- Three group names per tenant are values in the cell. A tenant that wants
  different names, or a different ladder, changes the cell.
