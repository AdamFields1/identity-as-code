# identity-as-code

Okta authentication policy managed the same way as infrastructure: typed Terraform
modules, one deployable stack, values-only tenant cells, and a release train that
promotes a change from dev to prod through a human gate.

This is a portfolio repository by Adam Fields. It exists to show design decisions and
the reasoning behind them, not to be a feature-complete Okta provider wrapper. Every
name, CIDR, and ID in it is a placeholder.

## What it manages

| Object | Module | Resources |
|--------|--------|-----------|
| Network zones (IP and dynamic, policy and blocklist) | `modules/okta/network-zone` | `okta_network_zone` |
| Sign-on policy and rules (session, MFA, network conditions) | `modules/okta/session-policy` | `okta_policy_signon`, `okta_policy_rule_signon` |
| MFA enrollment policy and rules | `modules/okta/mfa-policy` | `okta_policy_mfa`, `okta_policy_rule_mfa` |
| Password policy and rules (complexity, age, lockout, recovery) | `modules/okta/password-policy` | `okta_policy_password`, `okta_policy_rule_password` |

`stacks/okta-config` composes the four modules. `tenants/okta/dev` and
`tenants/okta/prod` point at that stack with different values.

## Layout

```
identity-as-code/
  modules/okta/           reusable, typed, validated building blocks
  stacks/okta-config/     the unit of deployment: composes modules, resolves names to IDs
  tenants/okta/           one directory per tenant, values only, Terragrunt wiring
    root.hcl              remote state, provider generation, adoption hook
    dev/terragrunt.hcl
    prod/terragrunt.hcl
  .github/workflows/      PR validation and the dev -> prod release train
  scripts/                PowerShell helper to adopt an existing tenant
  tests/                  zero-change import gate
  docs/                   architecture diagram and decision records
```

## Why these choices

**Stacks are the unit of deployment.** A stack is the smallest set of resources that
must be planned and applied together to leave a tenant in a consistent state. Zones
and the rules that reference them belong in one plan; splitting them means a rule can
be applied against a zone that does not exist yet. One stack, one state file, one
plan to review. See [ADR 0001](docs/adr/0001-stacks-as-deployment-unit.md).

**Path is environment, via Terragrunt.** `tenants/okta/dev` and `tenants/okta/prod`
are the only places the word "dev" or "prod" appears. There is no `environment`
variable threaded through modules and no `count = var.is_prod ? 1 : 0` anywhere.
Adding a tenant is adding a directory.

**Tenant cells hold values only.** A tenant `terragrunt.hcl` has an include, a source,
and an `inputs` map. No resources, no data sources, no conditionals. Reviewers can
diff dev against prod and see exactly what is stricter in production and nothing else.
See [ADR 0002](docs/adr/0002-values-only-tenant-cells.md).

**State keys derive from the path.** `root.hcl` sets
`key = "okta/${path_relative_to_include()}/terraform.tfstate"`. Nobody types a state
key, so nobody can point two tenants at the same one.

**No long-lived secrets in CI.** AWS access for state uses GitHub OIDC and a role
ARN stored as a repository variable. The Okta API token is a GitHub environment
secret that reaches the provider only through the `OKTA_API_TOKEN` environment
variable, which the provider reads natively. It is never written to a generated file,
a plan artifact, or state. See [ADR 0003](docs/adr/0003-no-long-lived-secrets-in-ci.md).

**Promotion is gated, dev before prod.** A merge to `main` plans and applies dev,
then stops at a soak gate. The gate is a GitHub environment with required reviewers
and a wait timer. When a human approves, prod applies the exact plan file that was
produced at merge time. If prod state moved in the meantime, Terraform refuses the
stale plan and the release is re-run rather than applied blind.

## How to use it

Prerequisites: Terraform 1.9 or later, Terragrunt 0.77 or later, an S3 bucket and
DynamoDB table for state, and an Okta API token with policy and zone scopes.

```bash
export TG_STATE_BUCKET=CHANGEME-tfstate
export TG_STATE_REGION=us-east-1
export TG_LOCK_TABLE=CHANGEME-tflock
export OKTA_API_TOKEN=CHANGEME     # never commit this, never echo it

cd tenants/okta/dev
terragrunt init
terragrunt plan
```

To adopt an existing tenant instead of creating policies from scratch:

1. Run `scripts/Import-OktaPolicies.ps1` against the tenant. It emits `imports.tf`
   and a `values.skeleton.hcl` you paste into the tenant cell.
2. Drop `imports.tf` into the tenant directory. `root.hcl` picks it up automatically.
3. Plan. Adjust values until the plan shows 0 to add, 0 to change, 0 to destroy.
   `tests/README.md` describes the gate that enforces this in CI.
4. Apply (this only records the imports), then delete `imports.tf`.

## Deliberately out of scope

- Users, groups, and memberships. The directory of record owns those. The stack
  looks groups up by name and never creates one.
- Applications, SAML/OIDC integrations, and app sign-on policies.
- Authentication policies for Identity Engine apps (a natural next stack).
- Provisioning the S3 bucket, DynamoDB table, and the AWS OIDC role. That is
  platform bootstrap and lives in a separate repository.
- Azure AD / Entra ID. The layout generalises (a `tenants/entra` tree with its own
  `root.hcl`), but this repository stays focused on one provider.

## Verification status

This repository was written without access to a live Okta tenant or a Terraform
binary. HCL was reviewed by hand for syntax and provider attribute names against the
okta/okta 4.x provider documentation. Before first use, run `terraform validate` on
each module and the stack and confirm attribute names against the provider version
you pin.

## License

MIT. See [LICENSE](LICENSE).
