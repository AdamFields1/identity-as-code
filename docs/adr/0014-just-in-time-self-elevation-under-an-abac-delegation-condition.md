# ADR 0014: The subscription guard elevates itself just in time, under an ABAC delegation condition

Status: accepted
Date: 2026-09-17

## Context

`Disable-UnauthorizedSubscriptions` finds Enabled subscriptions of restricted
offer types (Visual Studio and MSDN, free trial, pay-as-you-go) whose direct
human owners are not on an allowlist, and cancels them. The runbook is named
for the result, a canceled subscription shows the Disabled state, but the
operation it calls is Cancel: Azure Resource Manager documents no "disable"
operation, and the Subscription API (2021-10-01) offers Accept Ownership,
Cancel, Enable, and Rename. The cancel documentation says the caller must be
an owner of the subscription without a condition, and Contributor explicitly
excludes `Microsoft.Subscription/cancel/action`. So at the moment of the call
the runbook identity has to be an unconditioned Owner of the subscription it
is canceling, and at no other moment does it need to be.

Cancel is not a switch that can be flipped back. Microsoft's documentation
says billing stops and services are disabled at once (virtual machines
deallocated, temporary addresses released, storage read-only), an owner may
delete the subscription 3 days after cancellation (7 for field and partner
channel subscriptions), Azure deletes it automatically 90 days after
cancellation, and the data is kept for 30 to 90 days. Reversal is a portal
reactivation for pay-as-you-go and a support request inside 90 days for other
offers; the Enable operation exists but its reference says nothing about
canceled subscriptions. A cancel is therefore the first step of a deletion
timeline, which is why it needs a decision before a switch.

The runbooks run as a user-assigned managed identity (ADR 0010). The ways to
give it Owner at the right moment were:

1. **Standing Owner** at the management group that holds the targeted
   subscriptions. Always on, over everything below, including the power to
   grant anything to anyone. A bug in the decision logic, or anyone who can
   edit a runbook, has that power every hour of every day.
2. **Standing User Access Administrator**, letting the runbook grant itself
   Owner when needed. It holds all of `Microsoft.Authorization/*`: role
   assignments for anyone, role definitions, policy assignments, PIM
   schedule requests, and PIM policies.
3. **A PIM eligibility for the identity.** Not available: PIM does not
   create eligible assignments for applications, service principals, or
   managed identities, because they cannot perform the activation steps
   (Microsoft Learn, "Assign Azure resource roles in Privileged Identity
   Management").
4. **Role Based Access Control Administrator with a delegation condition**,
   letting the runbook grant itself Owner on one subscription, cancel it,
   and remove the grant, while the condition stops it granting anything else
   to anyone.

Delegation conditions are Azure ABAC conditions (conditionVersion 2.0) on a
role assignment. Microsoft Learn ("Delegate Azure access management to
others", "Authorization actions and attributes") documents exactly two
actions a delegation condition can target,
`Microsoft.Authorization/roleAssignments/write` and `.../delete`, with the
attributes RoleDefinitionId, PrincipalId, and PrincipalType, read from
`@Request` on write and from `@Resource` on delete. Any role with
`roleAssignments/write` can carry one, and Role Based Access Control
Administrator is the role designed for it: role assignment write and delete,
`*/read`, and support tickets, nothing else.

## Decision

**This runbook runs on an identity of its own (the `subscription-guard` tier,
[ADR 0016](0016-one-identity-per-privilege-tier-in-one-automation-account.md)),
and that identity holds two standing assignments, both at the narrowest
management group that holds only the targeted subscriptions: Reader, and Role
Based Access Control Administrator with a condition that allows creating and
deleting assignments of the Owner role only, and only for the identity
itself.** The condition is the documented "constrain roles and specific
principals" form:

```
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
  AND
  @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {<role_id:Owner>}
  AND
  @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {<principal_id>}
 )
)
```

It is declared in the corp automation cell, inside the `subscription-guard`
tier's `arm_role_assignments`.
`modules/azure/workload-role-assignment` replaces `<role_id:Owner>` with the
Owner role's GUID, resolved by name at the scope, and `<principal_id>` with
that tier identity's object ID, so the cell holds no GUID (ADR 0002) and the
rendered text is a stack output a reviewer can read.

**Role Based Access Control Administrator, not User Access Administrator.**
A delegation condition constrains only role assignment writes and deletes.
On User Access Administrator every other `Microsoft.Authorization` action,
including PIM schedule requests, PIM policy writes, and role definition
writes, would stay unconstrained. On Role Based Access Control Administrator
there is nothing else to constrain.

**The elevation is per subscription and self-removed.** For each
subscription it is about to cancel, the runbook creates an unconditioned
Owner assignment for itself at that subscription (named with a new GUID and
described with the runbook name and RunId), waits for it to propagate,
cancels, and in a `finally` block deletes the assignment and reads it back
until ARM answers 404. A removal it cannot confirm fails the job, stops any
further elevation in the run, and is named in the summary and the digest.
Each run first removes leftovers of its own description that an interrupted
job left behind. A circuit breaker (three by default) aborts before the first
grant when there are more candidates than that.

**Unconditioned assignment-granting roles are refused, for this identity and
every other.** An unconditioned Owner, User Access Administrator, or Role
Based Access Control Administrator lets its holder grant itself anything at
the scope, and one that overlaps the guard's scope would void this condition.
The stack and the module both refuse those three roles without a condition, in
every tier. The PIM runbooks, which need Authorization writes of their own,
get a custom role that holds exactly the PIM actions they use (ADR 0015)
instead of a built-in role that can assign roles.

**Two switches, and Cancel needs a person before the second.** The corp cell
runs the guard with `dry_run = true` and `allowcancel = "false"`. Nothing is
canceled, and no Owner assignment is created at all, unless `DryRun` is false
**and** `AllowCancel` is true. They are turned in that order: `dry_run =
false` first, which is a report-only live run that removes leftovers and mails
a digest listing every subscription it would cancel (decision `WouldCancel`),
and `allowcancel = "true"` only after the owners of the control sign off in
writing that Cancel is the intended action, given the deletion timeline above,
and one sandbox subscription of each targeted offer has been canceled and
reactivated. Each switch is a reviewed line in the cell, and the run summary
and the digest subject say which mode a run was in.

## Consequences

- **The condition limits what and to whom, not where.** The delegation
  attributes are RoleDefinitionId, PrincipalId, and PrincipalType; none of
  them is a scope. The identity can therefore, at any time, make itself an
  unconditioned Owner of the management group it is assigned at and of every
  subscription below it. It is Owner-equivalent over that scope (control-plane
  tier 0), and any sentence that says it "cannot grant anything to anyone
  else" is only true with that qualifier attached. So: the assignment goes at
  the narrowest management group that holds only the targeted dev, test, and
  sandbox subscriptions (the corp cell names `mg-example-sandbox`), never at
  the tenant root and never above production; and write access to the account
  (runbooks, jobs, schedules, variables, hybrid worker groups) is limited to
  the pipeline and to people who already hold Owner there, with one standing
  exception that is written down rather than assumed away: the `observer`
  tier holds the custom role Automation Variable Writer at the Automation
  account, and Azure RBAC has no per-variable scope, so that is write on
  **every** variable in the account, not only the watcher's state (ADR 0016
  and the `observer` row of `automation/README.md`). The runbook header lists
  the activity log alert to set on role assignment writes by this principal.
- What the condition buys is containment of the code path and a narrower
  blast radius for a mistake: a decision bug can at worst cancel a
  subscription under the guard's management group, and cannot grant a person
  or another workload anything or remove anybody else's access. It is not a
  defence against someone who controls the identity, and not against a runbook
  that deliberately assigns Owner to itself at the management group.
- The identity is the guard's own (ADR 0016), so this condition is no longer
  diluted by the PIM runbooks' permissions: their custom role, which includes
  `roleEligibilityScheduleRequests/write` where the Azure plane is enabled,
  belongs to a different identity. What tiers do not change is that both
  identities are attached to the same Automation account, so anyone who can
  publish a runbook or start a job there can use either. Separate accounts are
  the boundary that fixes that, and ADR 0016 says when they are warranted.
- Cancel is reversible only inside Microsoft's window (pay-as-you-go in the
  portal, other offers through a support request within 90 days), and Azure
  deletes a canceled subscription 90 days after cancellation, with the data
  kept for 30 to 90 days. Whether REST Cancel is accepted on every targeted
  offer is unproven until the sandbox round trip, which is the second half of
  the `allowcancel` sign-off.
- Every grant and removal is an activity log entry under the identity's name
  with the RunId in its description, and every cancel is a subscription
  event, so the SIEM can reconstruct each run.
- The condition text is compared by the provider as written. The module
  trims surrounding whitespace; if a plan after the first apply shows a diff
  on the condition, ARM has normalised the text and the cell should carry it
  on one line.
