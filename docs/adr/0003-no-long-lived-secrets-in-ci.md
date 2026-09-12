# ADR 0003: No long-lived secrets in CI

Status: accepted
Date: 2026-09-12

## Context

A pipeline that manages authentication policy holds the keys to the front door. The
two credentials it needs are AWS access for remote state and an Okta API token. The
common shortcuts are an AWS access key pair stored as a repository secret and an Okta
token stored the same way, both available to every workflow in the repository.

## Decision

**AWS: OpenID Connect, no static keys.** The workflow requests an OIDC token from
GitHub (`permissions: id-token: write`) and exchanges it for short-lived credentials
with `aws-actions/configure-aws-credentials`. The role ARN is a repository variable,
not a secret, because an ARN is not sensitive on its own. The role's trust policy
restricts which repository, branch, and environment can assume it. Credentials expire
in minutes.

**Okta: environment-scoped secret, exposed only as an environment variable.** The
token is stored as a GitHub environment secret, so a job only sees it when it targets
that environment, and protected environments (prod) require a reviewer before the job
starts. The provider reads `OKTA_API_TOKEN` natively. The Terragrunt-generated
provider block deliberately does not set `api_token`, so the token is never
interpolated into a file on disk, never lands in a plan artifact, and never lands in
state.

**Separate plan and apply identities.** Plan jobs target `dev-plan` and `prod-plan`
environments whose tokens hold read-only Okta scopes and whose AWS role can read
state but not write it. Apply jobs target `dev` and `prod-apply` with tokens that can
write. A compromised PR workflow can read policy, which is not secret, but cannot
change it.

**The repository contains no secrets.** `.gitignore` excludes `*.tfvars` and `.env`.
`detect-private-key` runs in pre-commit. Nothing in this repository is a credential,
and a fork of it is safe to publish.

## Consequences

- A one-time bootstrap creates the OIDC provider, the two roles, and the four GitHub
  environments. That is out of scope here and documented as such.
- Local runs export `OKTA_API_TOKEN` in the shell for the session. The README says so
  and says never to echo it.
- Rotating the Okta token is a change to a GitHub environment secret and nothing else.
- The import helper script reads the token from the same environment variable and
  never writes it to output or logs.
