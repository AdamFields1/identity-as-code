# ADR 0001: Stacks are the unit of deployment

Status: accepted
Date: 2026-09-12

## Context

Okta configuration has real ordering constraints. A sign-on rule with a network
condition needs a zone ID. A policy needs group IDs. If zones, policies, and rules are
applied from separate root modules, an engineer can apply a rule change before the
zone it references exists, or delete a zone that a rule in another state file still
points at. Terraform cannot see across state files.

Two alternatives were considered.

One root module per resource type (a "zones" root, a "policies" root) gives small
plans, but every cross-reference becomes a `terraform_remote_state` lookup or a
hardcoded ID, and ordering is enforced by convention and tribal knowledge rather than
by the graph.

One root module per tenant that contains everything Okta (zones, policies, apps,
groups, users) keeps the graph complete but makes every plan enormous, mixes fast-moving
objects like group membership with slow-moving objects like password policy, and
gives one blast radius to all of them.

## Decision

A stack is the smallest set of resources that must be planned together to leave the
tenant consistent. `stacks/okta-config` holds zones and the three policy types
because they reference each other. It does not hold users, groups, or apps because
nothing in it needs to create them, only to look them up.

Each tenant applies each stack into its own state file. The stack is the unit of
review, the unit of rollback, and the unit of blast radius.

## Consequences

- Cross-references are ordinary module outputs. Terraform orders the graph.
- The plan for a policy change is a few dozen lines, not a few thousand.
- A second stack (for example `okta-app-auth-policies`) can be added later with its
  own state, and Terragrunt `dependency` blocks can pass IDs between stacks if a
  reference is needed.
- Anything that spans stacks must be explicit. That is the point.
