# ADR 0007: The break-glass exclusion is mandatory on every Conditional Access policy

Status: accepted
Date: 2026-09-12

## Context

The most common way an organisation locks itself out of its own Entra tenant is a
Conditional Access policy that applies to the emergency access accounts. A policy
that requires a compliant device, a phishing-resistant credential, or a trusted
location will, with no exclusion, apply to the account whose entire purpose is to
work when compliant devices, credentials, and locations do not. It takes one policy,
and it is usually the newest one, written by someone who copied the users block from
a policy that already had the exclusion and then edited it.

Microsoft's guidance is to exclude the emergency access accounts from every policy.
Every practitioner knows it. The failure mode is not ignorance; it is that the
exclusion is a per-policy value that has to be remembered per policy.

Two alternatives were considered.

**A convention plus a validation.** Each policy lists its own excluded groups, and a
validation rejects any policy whose list omits the break-glass group. This catches
the mistake, but it still makes the author type the exclusion into every policy, and
the validation itself becomes the thing that gets "temporarily" relaxed when someone
wants a policy that really does apply to everyone.

**A per-policy opt-out flag.** `exclude_break_glass = true` by default, settable to
`false`. The existence of the flag is the problem. There is no policy in this
repository that should apply to the break-glass accounts, so there should be no way
to write one.

## Decision

The `conditional-access` module has a required variable,
`break_glass_exclusion_group`, with no default and a validation that rejects an empty
string. The module resolves it to an object ID once and appends that ID to the
`excluded_groups` of every policy it creates. A policy's own `excluded_groups` is
additive; nothing in the policy shape can remove the break-glass group.

There is no flag. A policy that must apply to the break-glass accounts cannot be
expressed in this module, which is the intended behaviour.

The group itself is looked up, never created, by this stack. `prevent_destroy` on the
security-group module protects it where it is created. Recreating the group would
give it a new object ID and every policy's exclusion would then point at nothing.

## Consequences

- Reviewers do not check for the exclusion in each policy. It is a property of the
  module, checked once.
- The tenant cell says `break_glass_exclusion_group = "SEC Break Glass Accounts"`
  once, at the top, where it is obvious.
- A policy in the tenant cell never lists the break-glass group in
  `excluded_groups`. Doing so is harmless (the module deduplicates) but reads as if
  the exclusion were optional, so the sample cells do not.
- If the break-glass group does not exist in a tenant, every policy in the stack
  fails to plan. That is correct: the emergency access accounts are created before
  the first Conditional Access policy, not after.
- The break-glass accounts still need their own compensating controls (a dedicated
  alert on any sign-in, long random passwords in a physical safe, no MFA method
  that depends on a single person). Those are operational and are not in this
  repository.
