# ADR 0015: PIM settings are declared by the stacks and swept by runbooks, against one baseline

Status: accepted
Date: 2026-09-17

## Context

`stacks/azure-pim-governance` declares the role management policy for every
(scope, role) pair a tenant cell lists, and `stacks/entra-pim-governance`
declares the member policies of the privileged PIM groups. Terraform is the
right owner for those: each change is a pull request, a plan, and state, and
the eligibilities in the same stacks depend on the policies being written
first (ADR 0005 and the stack comments).

Terraform only governs what a cell names, and only when a plan runs. Four
kinds of PIM setting fall outside that:

- **Pairs nobody declared.** A role made eligible from the portal, a
  subscription created last week under a management group the cell covers,
  a custom role another team added. Each has a role management policy with
  Microsoft's defaults (or whatever someone set), and Azure PIM settings are
  per role and per resource: a subscription's settings are not inherited by
  its resource groups (Microsoft Learn, "Configure Azure resource role
  settings in PIM"). The providers have no data source that lists every
  eligible pair under a management group, and a plan that created policies
  from such a list would stop the cell being the reviewable statement of
  intent.
- **Entra directory role settings.** The Entra stack governs the PIM groups'
  policies and deliberately leaves the directory role settings alone, so the
  activation rules of Global Administrator itself had no owner in code.
- **Portal edits to declared settings.** They persist until the next plan
  and apply of that cell, which happens on a merge, not on a schedule.
- **Eligibility end dates.** An eligibility of a group lapses on a date
  nobody chose on purpose, and the access decision it carries (group
  membership) has not changed.

Letting runbooks own PIM settings outright would lose the review, the plan,
and the ordering Terraform gives the declared pairs. Letting Terraform own
them alone leaves the four gaps above. Running both risks two writers
disagreeing about the same policy every night.

## Decision

**Both, with one baseline and rules that make the two writers converge.**
Three runbooks, all on the shared library (ADR 0013), all dry by default:

- `Invoke-AzurePimPolicyGovernance` sweeps every Azure pair that has an
  eligibility under the named management groups and subscriptions (ARM
  api-version 2020-10-01) and holds three activation rules: the maximum
  activation duration, the enablement requirements (MFA, justification,
  ticket), and approval with its approvers.
- `Invoke-EntraPimPolicyDrift` does the same for every Entra directory role
  and for the named PIM groups (Graph v1.0).
- `Invoke-PimEligibilityRenewal` extends the eligibilities of groups that
  are about to expire, on directory roles, PIM groups, and Azure roles, and
  never those of users or service principals, which it lists for a person.

The rules:

1. **The built-in baselines are the stack defaults.** Without a baseline the
   Azure runbook holds PT4H, MFA on, justification on, ticket off, approval
   off, which are the defaults of `stacks/azure-pim-governance`; the Entra
   runbook holds PT4H, MFA and justification, no approval, the defaults of
   `modules/entra/pim-role-policy`. A declared pair that inherits the
   defaults already agrees with a sweep.
2. **The baselines are repository files published as Automation variables,
   and they mirror the declared entries.** Each baseline is a JSON document:
   `policies/azure/pim-governance/corp-baseline.json` takes `defaults` from
   the governance cell's tenant-level values and `pairs` in the same shape as
   that cell's `policies` map, entry for entry, so every declared pair is held
   to its own declared values, however differently the same role is declared
   at another scope; `policies/entra/pim-governance/corp-baseline.json`
   carries the approval the Entra cell declares for `PIM Global
   Administrators`, and the runbook's `includegroupnames` lists the three
   privileged groups. `stacks/azure-automation` publishes each file as an
   Automation string variable through `desired_state_files`
   (`PimPolicy_AzureBaseline`, `PimPolicy_EntraBaseline`), exactly as it
   publishes the authentication methods desired state (ADR 0012), and the job
   schedule passes only the variable's name in `baselinevariablename`.

   A baseline is not a job schedule parameter, because a job schedule binds
   only `[bool]`, `[int]`, and `[string]` reliably and the Automation service
   may parse a JSON-looking parameter value before it binds it: JSON text can
   then arrive as `@{...}` or as a space-joined array. A string variable comes
   back exactly as stored. Both runbooks refuse a converted-looking value and
   stop when the variable is missing or unreadable, rather than falling back
   to their built-in defaults, because a silent fallback would drop every
   override. A pull request that changes a policy in either PIM cell changes
   the baseline file in the same pull request; the automation cell and both
   `policies/.../README.md` files say so. `roles` entries apply only to pairs
   nobody declared.
3. **The baseline is a floor.** Both sweeps run in mode `minimum`: a shorter
   window, an extra requirement, or approval the baseline does not ask for is
   compliant, and a patch only ever tightens. With the declared pairs
   mirrored, a live run can only move a declared pair towards its declared
   values, so a Terraform plan after it shows no change the runbook caused.
   Mode `exact`, which can loosen a policy, is a reviewed baseline change,
   never a default.
4. **Each writer keeps to its own rules.** The sweeps patch only the three
   activation rules and only the ones that drifted; the Azure sweep patches
   only a policy that sits at the pair's own scope. Eligibility and
   assignment expiry, notifications, and authentication context stay with
   Terraform or the portal. Where activation relies on a Conditional Access
   authentication context, the Azure sweep reports the pair and does not
   patch it until its entry says `require_multifactor_authentication = false`
   or `report_only`, and the Entra sweep counts the context as meeting the
   MFA requirement and says so in its report.
5. **Terraform keeps the dates it declared.** The renewal runbook excludes, by
   name pattern, every group whose eligibility the governance cell gives an
   end date, so the runbook and the next apply never move one date in
   opposite directions. After a live renewal, the affected cells take a
   `terragrunt apply -refresh-only` and, where needed,
   `scripts/Export-PimEligibilityImports.ps1`, because PIM gives a renewed
   eligibility new schedule IDs.
6. **Order and caps.** Renewal runs at 03:30 UTC and the sweeps at 05:00 and
   05:15, after it and outside the daytime release train. Every write is
   behind a circuit breaker that aborts the whole run before the first write
   (25 policies, 40 rules, 20 renewals), in dry runs too.
7. **Least privilege for the writes.** All three runbooks run on one identity
   of their own, the `pim` tier
   ([ADR 0016](0016-one-identity-per-privilege-tier-in-one-automation-account.md)),
   which holds the `RoleManagementPolicy.*`, `RoleEligibilitySchedule.*`, and
   `PrivilegedEligibilitySchedule.*` application permissions each header
   lists, and nothing the other runbooks need. In Azure it reads with Reader
   and writes with a custom role from the corp roles cell, never with User
   Access Administrator or an unconditioned Role Based Access Control
   Administrator (ADR 0014). There are two such roles, because the two writes
   are not equally dangerous: `PIM Policy Operator` can change how a role is
   activated, which is what the Azure sweep does and all the corp cell grants;
   `PIM Policy and Eligibility Operator` adds
   `roleEligibilityScheduleRequests/write`, which creates an eligibility as
   readily as it extends one and is therefore Owner-equivalent over the scopes
   it covers. The corp cell ships with the renewal's Azure plane off
   (`includeazureresources = "false"`), so nothing holds the second role;
   turning the Azure plane on is the change that grants it.

## Consequences

- A declared pair has two writers that agree by construction. When the
  mirror is stale (a cell loosens a pair and the automation cell is not
  updated), the sweep tightens it every night and every plan of the
  governance cell puts it back. That flap is loud, in the digest and in the
  plan, not silent, and `pairs_report_only` is the escape hatch while the
  mirror catches up. A pipeline check that compares the mirror with the PIM
  cells is the natural next step.
- The mirror repeats about forty lines of the governance cell, now as JSON in
  `policies/` rather than HCL in the automation cell. ADR 0002 accepts
  explicit repetition over a merge hierarchy, and a cell does not read another
  cell's inputs. The file has the further advantage that a workstation dry run
  passes it straight to `-BaselineJson`, so what is reviewed, what is
  published, and what is tested are one text.
- A resource group pair in the mirror carries a `subscription` display name
  that the stack's `policies` shape does not have, because the runbook
  cannot see the provider's default subscription.
- Entra directory role settings now have an owner in code, though not in
  Terraform state; the Entra baseline is where a change to them is reviewed.
- The `pim` tier identity can change PIM settings across the root management
  group and the tenant. The code is reviewed, dry by default, capped, and
  tightens only, but the permission itself does not know that; a change to
  mode `exact`, to the baseline variable, or to the code is a change to what
  that identity will do. Anyone who can write the baseline variable, or
  publish a runbook in the Automation account, has that reach, which is why
  the tier, the variable, and the merge path for `automation/` are all tier 0
  (ADR 0014 and ADR 0016). That list is longer than it looks: Azure RBAC has
  no per-variable scope for Automation, so the `observer` tier's Automation
  Variable Writer role, granted at the account for the job watcher's own
  state, is write on the baseline variables too. ADR 0016 sets out the checks
  that answer it and the alert to add. A PIM eligibility schedule request can create an
  eligibility as well as extend one, which is why the corp cell keeps the
  renewal's Azure plane off until that is a decision someone has made.
- Several API behaviours the runbooks rely on are documented only in part and
  are named in the runbook headers: whether an unfiltered eligibility list
  at a subscription returns resource group schedules, the `roleDefinitionId`
  filter on policy assignments (checked on the client, with a fallback),
  approval turned off without resending its stages, and whether an expired
  eligibility is still listed for renewal. The shipped cell runs all three
  dry, and their counters and reports make each of those visible before a
  live run.
- The first live sweep against a tenant still on Microsoft's defaults is
  expected to trip its cap. The cap is raised for that one run, in a
  reviewed change, after the dry-run report has been read.
