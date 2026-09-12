# identity-as-code

Identity configuration managed the same way as infrastructure: typed Terraform
modules, deployable stacks, values-only tenant cells, and a release train that
promotes a change from the first tenant to the gated one through a human approval.
Three providers, one layout: Okta authentication policy, Entra ID (app registrations,
Conditional Access, PIM for groups and directory roles), and Azure resource RBAC
(custom roles, PIM policies, eligibilities).

This is a portfolio repository by Adam Fields. It exists to show design decisions and
the reasoning behind them, not to be a feature-complete wrapper for any provider.
Every name, CIDR, and ID in it is a placeholder.

## What it manages

| Object | Module | Resources |
|--------|--------|-----------|
| Network zones (IP and dynamic, policy and blocklist) | `modules/okta/network-zone` | `okta_network_zone` |
| Sign-on policy and rules (session, MFA, network conditions) | `modules/okta/session-policy` | `okta_policy_signon`, `okta_policy_rule_signon` |
| MFA enrollment policy and rules | `modules/okta/mfa-policy` | `okta_policy_mfa`, `okta_policy_rule_mfa` |
| Password policy and rules (complexity, age, lockout, recovery) | `modules/okta/password-policy` | `okta_policy_password`, `okta_policy_rule_password` |
| App registrations and service principals with a drift-detection import contract | `modules/entra/app-registration` | `azuread_application`, `azuread_service_principal`, `azuread_application_federated_identity_credential`, `azuread_app_role_assignment` |
| Named locations, authentication strengths, and Conditional Access policies | `modules/entra/conditional-access` | `azuread_named_location`, `azuread_authentication_strength_policy`, `azuread_conditional_access_policy` |
| Role-assignable security groups | `modules/entra/security-group` | `azuread_group` |
| PIM for groups policies | `modules/entra/pim-role-policy` | `azuread_group_role_management_policy` |
| Entra role and PIM group eligibilities | `modules/entra/pim-eligibility` | `azuread_directory_role_eligibility_schedule_request`, `azuread_privileged_access_group_eligibility_schedule` |
| Custom Azure RBAC role definitions, scopes resolved by name | `modules/azure/rbac-role-definition` | `azurerm_role_definition` |
| PIM role management policies per (scope, role): activation window, MFA, approval, expiration | `modules/azure/pim-role-policy` | `azurerm_role_management_policy` |
| PIM eligible assignments for Entra groups, by group, role, and scope name | `modules/azure/pim-eligible-assignment` | `azurerm_pim_eligible_role_assignment` |

Six stacks compose those modules into deployable units:

| Stack | Composes | Cells |
|-------|----------|-------|
| `stacks/okta-config` | the four Okta policy modules | `tenants/okta/dev`, `tenants/okta/prod` |
| `stacks/entra-app-registrations` | app registrations and service principals with a drift-detection import contract | `tenants/azure/corp/entra-app-registrations` |
| `stacks/entra-conditional-access` | named locations, authentication strengths, and Conditional Access policies | `tenants/azure/{corp,subsidiary}/entra-conditional-access` |
| `stacks/entra-pim-governance` | role-assignable groups, PIM for groups policies, and Entra role eligibilities | `tenants/azure/{corp,subsidiary}/entra-pim-governance` |
| `stacks/azure-rbac-roles` | custom role definitions only | `tenants/azure/corp/azure-rbac-roles` |
| `stacks/azure-pim-governance` | PIM policies, then eligibilities, in that order | `tenants/azure/{corp,subsidiary}/azure-pim-governance` |

The subsidiary tenant has no `entra-app-registrations` cell because application
onboarding is confined to corp, and no `azure-rbac-roles` cell because it assigns built-in
roles only. Nothing is stubbed to make the tenants look symmetrical.

## Layout

```
identity-as-code/
  modules/
    okta/                       network-zone, session-policy, mfa-policy, password-policy
    entra/                      app registration, Conditional Access, and PIM for groups building blocks
    azure/                      rbac-role-definition, pim-role-policy, pim-eligible-assignment
  stacks/                       units of deployment: compose modules, resolve names to IDs
    okta-config/
    entra-app-registrations/
    entra-conditional-access/
    entra-pim-governance/
    azure-rbac-roles/
    azure-pim-governance/
  tenants/
    okta/                       one directory per tenant, values only, Terragrunt wiring
      root.hcl                  S3 state, Okta provider generation, adoption hook
      dev/terragrunt.hcl
      prod/terragrunt.hcl
    azure/                      one directory per tenant, one cell per stack inside it
      root.hcl                  Azure Storage state, azurerm + azuread provider generation, adoption hook
      corp/
        azure-rbac-roles/terragrunt.hcl
        azure-pim-governance/terragrunt.hcl
        entra-app-registrations/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
      subsidiary/
        azure-pim-governance/terragrunt.hcl
        entra-app-registrations/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
  .github/workflows/            PR validation and release trains: okta-* (dev -> prod), azure-* (corp -> subsidiary)
  scripts/                      PowerShell helpers to adopt an existing tenant and export drift
  tests/                        zero-change import gate
  docs/                         architecture diagrams and decision records
```

## Why these choices

**Stacks are the unit of deployment.** A stack is the smallest set of resources that
must be planned and applied together to leave a tenant in a consistent state. Zones
and the rules that reference them belong in one plan; splitting them means a rule can
be applied against a zone that does not exist yet. One stack, one state file, one
plan to review. See [ADR 0001](docs/adr/0001-stacks-as-deployment-unit.md).

**Definitions and assignments are separate cells.** On the Azure side, what a role
*is* (`azure-rbac-roles`) and who may *use* it (`azure-pim-governance`) change at
different speeds, are reviewed by different people, and have very different blast
radii. They live in separate stacks with separate state files, and the second
refers to the first by role name only. A tenant with no custom roles has no roles
cell. See [ADR 0005](docs/adr/0005-definitions-and-assignments-in-separate-cells.md).

**Path is environment, via Terragrunt.** `tenants/okta/dev`, `tenants/okta/prod`,
`tenants/azure/corp`, and `tenants/azure/subsidiary` are the only places those words
appear. There is no `environment` variable threaded through modules and no
`count = var.is_prod ? 1 : 0` anywhere. Adding a tenant is adding a directory.

**Tenant cells hold values only.** A tenant `terragrunt.hcl` has an include, a source,
and an `inputs` map. No resources, no data sources, no conditionals. Reviewers can
diff dev against prod and see exactly what is stricter in production and nothing else.
See [ADR 0002](docs/adr/0002-values-only-tenant-cells.md).

**State keys derive from the path.** Each `root.hcl` sets
`key = "<tree>/${path_relative_to_include()}/terraform.tfstate"`, so
`tenants/okta/prod` writes `okta/prod/terraform.tfstate` and
`tenants/azure/corp/azure-pim-governance` writes
`azure/corp/azure-pim-governance/terraform.tfstate`. Nobody types a state key, so
nobody can point two cells at the same one.

**Azure state lives in Azure Storage, with no storage keys.** The Azure tree keeps
state in a blob container authenticated with the same Entra token the providers use
(`use_azuread_auth`), so there is one identity to bootstrap and audit and no account
key to store or rotate. Shared key access on the account is disabled at bootstrap
so "no keys" is enforced, not assumed. See
[ADR 0004](docs/adr/0004-azure-storage-state-with-oidc.md).

**No long-lived secrets in CI.** AWS access for Okta state uses GitHub OIDC and a
role ARN stored as a repository variable. Azure access for both state and providers
uses GitHub OIDC against a federated credential on an app or user-assigned identity;
there is no client secret because none exists. The Okta API token is a GitHub
environment secret that reaches the provider only through the `OKTA_API_TOKEN`
environment variable, which the provider reads natively. It is never written to a
generated file, a plan artifact, or state. See
[ADR 0003](docs/adr/0003-no-long-lived-secrets-in-ci.md).

**Promotion is gated, first tenant before the second.** A merge to `main` plans and
applies dev (Okta) or corp (Azure), then stops at a gate. The gate is a GitHub
environment with required reviewers and a wait timer. When a human approves, prod
or subsidiary applies the exact plan file that was produced at merge time. If that
state moved in the meantime, Terraform refuses the stale plan and the release is
re-run rather than applied blind. The Azure train additionally applies the corp
roles cell before planning the corp governance cell, because the latter resolves
custom roles by name at plan time.

## How to use it

Prerequisites: Terraform 1.9 or later and Terragrunt 0.77 or later. For the Okta
tree, an S3 bucket and DynamoDB table for state and an Okta API token with policy
and zone scopes. For the Azure tree, a storage account and container for state with
shared key access disabled, `az login` as an identity that holds Storage Blob Data
Contributor on the container and the RBAC needed at the scopes you manage.

Okta:

```bash
export TG_STATE_BUCKET=CHANGEME-tfstate
export TG_STATE_REGION=us-east-1
export TG_LOCK_TABLE=CHANGEME-tflock
export OKTA_API_TOKEN=CHANGEME     # never commit this, never echo it

cd tenants/okta/dev
terragrunt init
terragrunt plan
```

Azure and Entra:

```bash
az login                            # the CLI token is the identity; no secrets exported
export TG_AZ_STATE_RG=CHANGEME-rg-tfstate
export TG_AZ_STATE_SA=CHANGEMEtfstate
export TG_AZ_STATE_CONTAINER=tfstate
export ARM_TENANT_ID=$(az account show --query tenantId -o tsv)
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

cd tenants/azure/corp/azure-rbac-roles
terragrunt init
terragrunt plan
```

`ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` feed the generated provider blocks through
`tenants/azure/root.hcl`; no cell contains either value. Switching tenants is
`az login` to the other tenant and re-exporting the two variables.

To adopt an existing tenant instead of creating policies from scratch:

1. Run `scripts/Import-OktaPolicies.ps1` against the tenant. It emits `imports.tf`
   and a `values.skeleton.hcl` you paste into the tenant cell.
2. Drop `imports.tf` into the tenant directory. `root.hcl` picks it up automatically.
3. Plan. Adjust values until the plan shows 0 to add, 0 to change, 0 to destroy.
   `tests/README.md` describes the gate that enforces this in CI.
4. Apply (this only records the imports), then delete `imports.tf`.

## Deliberately out of scope

- Users and group memberships. The directory of record owns those. Every stack
  looks groups up by name; only the Entra PIM stack creates groups, and only the
  role-assignable ones it governs.
- Okta applications, SAML/OIDC integrations, and app sign-on policies.
- Okta authentication policies for Identity Engine apps (a natural next stack).
- Standing (active) Azure role assignments. If a principal needs standing access,
  that is a design conversation, not a map entry.
- The management group hierarchy and subscriptions themselves. The Azure stacks
  resolve them by name and never create one.
- Provisioning the S3 bucket, DynamoDB table, AWS OIDC role, Azure storage
  account, federated credentials, and GitHub environments. That is platform
  bootstrap and lives in a separate repository.

## Verification status

No live tenant of any kind was used to build this repository.

The Okta tree was written without a Terraform binary. HCL was reviewed by hand for
syntax and provider attribute names against the okta/okta 4.x provider
documentation. Before first use, run `terraform validate` on each module and the
stack and confirm attribute names against the provider version you pin.

The Azure tree (`modules/azure/*`, `stacks/azure-*`) was written with Terraform 1.16
available and every module and stack passes `terraform init -backend=false` and
`terraform validate` against the pinned providers (azurerm 4.x, azuread 3.x), so
attribute names and block shapes are checked against the real provider schema. The
committed `.terraform.lock.hcl` files record the exact versions. What validate cannot
check, and what a first plan against a real tenant should confirm, is import ID
formats and the API's own rules such as the allowed PIM expiration values.

## License

MIT. See [LICENSE](LICENSE).
