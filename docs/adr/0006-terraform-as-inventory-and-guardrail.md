# ADR 0006: Terraform is the inventory and the guardrail, not the sole editor

Status: accepted
Date: 2026-09-12

## Context

Application registrations are not like Conditional Access policies. A policy has
one owner (the security team) and changes a few times a year. A registration has an
application owner who changes redirect URIs when a new environment appears, adds an
optional claim when a library upgrade needs it, and updates branding when marketing
asks. There are hundreds of registrations and the owners are not in this repository.

Two pure positions were considered.

**Terraform owns everything.** Every redirect URI edit becomes a pull request to this
repository. In practice owners either wait days for a review they do not need, or
edit in the portal and the next pipeline run reverts them, or the pipeline stops
being run because every plan is noisy. The last outcome is the usual one, and it
means the guardrails stop being applied too.

**Terraform owns nothing.** Registrations are created by hand and reviewed by audit.
There is no inventory a reviewer can diff, no way to enforce that a workload uses
federated credentials instead of a secret, and no way to see that an app requested
`Directory.ReadWrite.All` last Tuesday.

## Decision

Terraform manages the attributes that a security reviewer cares about and enforces
them on every apply: which registrations exist, their display name and sign-in
audience, their identifier URIs, the API permissions they request, the Graph roles
that have been consented, the federated credentials they authenticate with, and the
absence of client secrets (the module has no password resource).

Terraform sets and then ignores the attributes an owner routinely edits: owners,
tags, web redirect URIs, public client and SPA redirect URIs, optional claims,
branding URLs, logo, and notes. `lifecycle.ignore_changes` on the application and
service principal resources lists them. The pipeline never reverts a portal edit
to any of them.

The `ignore_changes` list is a module constant. Terraform requires the list to be
static, and that is a feature here: changing what the pipeline enforces is a change
to `modules/entra/app-registration/main.tf` and a code review, not a per-tenant
value.

The gap this opens (drift in attributes Terraform does not track, and registrations
that were never adopted) is closed by `scripts/Export-EntraDrift.ps1`, which
enumerates the tenant, compares it to the managed set, and reports unmanaged
registrations, registrations with client secrets, and managed registrations with no
service principal. It also emits import blocks so an unmanaged registration can be
adopted with a zero-change plan (`tests/README.md`).

## Consequences

- Application owners keep working in the portal. Nothing they can edit there is
  reverted by the pipeline.
- A plan for a registration change is about the registration's identity and
  permissions and nothing else, so it is short enough to review properly.
- A new API permission, a new federated credential, or a change of sign-in audience
  is always a pull request. That is the review point.
- A client secret cannot be created by this repository. One created in the portal
  is visible in the drift report and is a finding, not a plan diff.
- The drift script has to run. It is read-only and needs `Application.Read.All`;
  scheduling it is a pipeline concern documented alongside the release train.
- "0 to change" on a plan does not mean the tenant matches the repository. It means
  the enforced attributes match. The drift report is the other half of the answer.
