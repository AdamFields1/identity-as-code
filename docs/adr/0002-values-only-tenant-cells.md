# ADR 0002: Tenant cells contain values only

Status: accepted
Date: 2026-09-12

## Context

The difference between dev and prod is a small number of values: idle timeout,
whether the corporate network is exempt from MFA, minimum password length. When those
differences are expressed as conditionals inside modules (`var.environment == "prod"
? 15 : 120`), three things go wrong. The module grows a hidden second interface. The
prod behaviour cannot be reviewed without reading every module. And a new environment
means editing every conditional.

Terragrunt's usual answer is a hierarchy of `.hcl` files with `read_terragrunt_config`
and `merge`. That works, but reviewers then need to mentally flatten several files to
know what a tenant actually gets.

## Decision

Each tenant directory contains exactly one `terragrunt.hcl` with three things: an
`include` of the shared root, a `terraform.source` pointing at the stack, and an
`inputs` map. No resources, no data sources, no locals with logic, no conditionals.

Anything with logic belongs in the stack. Anything reusable belongs in a module.
Anything identical across tenants belongs in `root.hcl`.

The stack accepts group names and zone keys, never IDs. Resolving names to IDs is
stack logic, so a tenant file never contains an Okta identifier and can be reviewed
by someone who has never opened the Okta admin console.

## Consequences

- `diff tenants/okta/dev/terragrunt.hcl tenants/okta/prod/terragrunt.hcl` is the
  complete answer to "what is stricter in prod".
- Tenant values are repeated between dev and prod where they are the same (zone
  definitions, for example). This is accepted. Explicit repetition of a dozen lines is
  cheaper to review than a merge hierarchy.
- Adding a tenant is copying a directory and changing values. The state key follows
  from the path automatically.
- Secure defaults live in module variables, so a tenant that omits a settings block
  gets the strict behaviour, not the permissive one.
