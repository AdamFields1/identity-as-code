# ADR 0005: Role definitions and role assignments live in separate cells

Status: accepted
Date: 2026-09-12

## Context

ADR 0001 says a stack is the smallest set of resources that must be planned
together to leave the tenant consistent. Read literally, that argues for one Azure
stack: custom role definitions, the PIM policies that govern them, and the
eligibilities that hand them out all reference each other, and Terraform orders a
single graph better than a human orders two.

That reading was tried on paper and rejected, for three reasons that only appear
when you look at who changes what, and how often.

**Cadence and ownership differ.** A custom role definition changes when a product
team needs an action it does not have, a few times a year, and the change is
reviewed by whoever owns the permission model, because a wrong `not_actions` is a
privilege escalation. An eligibility changes when a team forms, a person moves
scope, or a quarterly access review removes someone, and it is reviewed by whoever
owns that scope. In one stack, every eligibility plan carries the role definitions
in its state and every definition plan carries dozens of assignment lines. Reviewers
learn to skim, and skimming a permission model is how a wildcard gets through.

**Blast radius is asymmetric.** Destroying an eligibility by mistake is bad and
recoverable: re-apply and the group is eligible again, nothing was activated in the
meantime. Destroying a definition by mistake, while eligibilities still reference
it, is worse: Azure either refuses and the apply fails half-way, or the
eligibilities are left pointing at a role that no longer resolves. In one state
file, a map edit in the assignments section can take a definition with it in the
same apply. `prevent_destroy` helps but is a lifecycle flag, not a boundary.

**Not every tenant has both.** The subsidiary assigns built-in roles only. In one
stack it would need an empty `custom_roles = {}` and a module that does nothing, or
a `count` on the module, which ADR 0002 forbids in cells and this repository avoids
everywhere.

## Decision

Two stacks, two cells per tenant that needs both, two state files.

- `stacks/azure-rbac-roles` owns custom role definitions and nothing else. Its
  cell is `tenants/azure/<tenant>/azure-rbac-roles`. The definition resource carries
  `prevent_destroy`.
- `stacks/azure-pim-governance` owns role management policies and eligible
  assignments. Its cell is `tenants/azure/<tenant>/azure-pim-governance`. It refers
  to roles, built-in and custom alike, by display name, and resolves the name at
  plan time with `data.azurerm_role_definition` at the assignment's scope.

Nothing is passed between the cells. No `dependency` block reads an output, no
`terraform_remote_state`, no ID in a tenant file. The only coupling is a name, and
the only ordering rule is that the name must resolve when the governance cell plans.

Within the governance stack, policies are applied before eligibilities with an
explicit `depends_on`, because Azure validates an eligibility's expiration against
the policy at write time and the eligibility resource has no attribute that
references the policy resource.

## Consequences

- The governance cell for a tenant with custom roles carries a Terragrunt
  `dependencies { paths = ["../azure-rbac-roles"] }` block. This is the one
  addition to the three-block cell shape in ADR 0002. It is allowed because it
  carries ordering and no values: it makes `terragrunt run --all` apply the roles
  cell first and it reads nothing from it.
- The release workflow applies the corp roles cell before it plans the corp
  governance cell. A pull request that adds a custom role and its first eligibility
  lands in one release because of that ordering, and would take two releases without
  it.
- Retiring a custom role is a two-step change by construction: remove its
  eligibilities and policy from the governance cell, apply, then remove the
  definition from the roles cell with `prevent_destroy` lifted in the same PR. The
  second PR is small and obviously about deleting a role, which is the point.
- `diff` between a tenant's two cells is not meaningful and is not meant to be.
  `diff` between corp and subsidiary governance cells remains the complete answer to
  "what is stricter in the subsidiary".
- A tenant that never needs a custom role never has a roles cell. The subsidiary
  is the worked example.
