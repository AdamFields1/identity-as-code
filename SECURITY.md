# Security policy

This is a portfolio repository. Nothing in it is deployed anywhere, every
identifier is a placeholder, and no secret is committed by design: the
release trains authenticate with OIDC, the runbooks run on managed
identities, and the repository linter (`tools/repo_lint`) fails a pull
request that introduces a secret-shaped string.

## Reporting a problem

If you find a defect that would matter in a real deployment (a policy that
does not do what its comment says, a permission broader than its rationale,
a guard that can be bypassed, a test that passes without proving its claim),
open a private vulnerability report on this repository rather than a public
issue, so it can be fixed before it is discussed. Include the file, the line,
and the scenario.

Reports are read by the repository owner. Expect an acknowledgement within a
week and a fix or a documented decision in the decision records under
`docs/adr/`.

## What is in scope

- Terraform modules and stacks under `modules/` and `stacks/`
- Terragrunt roots and cells under `tenants/`
- Runbooks, the shared library, and scripts under `automation/` and `scripts/`
- The workflows under `.github/workflows/`
- The tooling under `tools/`

## What is not

- The behaviour of the providers and services themselves
- Placeholder values, which are deliberately not real
