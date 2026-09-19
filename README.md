# identity-as-code

Identity configuration managed the same way as infrastructure: typed Terraform
modules, deployable stacks, values-only tenant cells, and a release train that
promotes a change from the first tenant to the gated one through a human approval.
Four providers, one layout: Okta authentication policy, Entra ID (app registrations,
Conditional Access, PIM for groups and directory roles, and federation to AWS),
Azure resource RBAC (custom roles, PIM policies, eligibilities), and AWS IAM
Identity Center (permission sets and group assignments, in commercial and GovCloud).
Alongside the resources, the identity hygiene and governance that cannot be a
resource because it depends on live data (credential expiry, guest dormancy,
eligibilities about to lapse, subscriptions nobody authorised, PIM settings
nobody declared) runs as Azure Automation runbooks that are themselves
deployed by a stack, with their plumbing in one shared library, a nightly
backup of their own source, and a watcher for their failures; and the one
policy that cannot be a resource because the provider has none for it (the
Entra authentication methods policy) is desired-state JSON enforced by a
script in the release train and watched by a runbook.

This is a portfolio repository by Adam Fields. It exists to show design decisions and
the reasoning behind them, not to be a feature-complete wrapper for any provider.
Every name, CIDR, and ID in it is a placeholder.

## Three layers

Everything in this repository sits in one of three layers, and each layer answers
one question.

**Modules answer how.** A module knows how to build one kind of thing: a permission
set, a Conditional Access policy, an Okta network zone. It takes typed, validated
inputs and knows nothing about which tenant it is in. `modules/` is the only place
that holds a resource block.

**Stacks answer what must change together.** A stack composes modules into the
smallest set of resources that has to be planned and applied as one to leave a
tenant consistent: zones together with the rules that reference them, permission
sets together with the assignments that use them. A stack is where names are
resolved to IDs, so it is the only place with logic. One stack is one state file,
one plan to review, and one blast radius. A stack may compose one module or
several; what makes it a stack is the deployment boundary, not the count.

**Cells answer where, and with what values.** A tenant is a folder of cells. Each
cell is one stack applied for one tenant, and it contains exactly three things: an
include of the shared root, a source pointing at the stack, and an inputs map of
values. No resources, no data sources, no conditionals, no IDs. A cell calls a
stack, never a module, so composition never leaks into the tenant layer and a
tenant file can be reviewed by someone who has never opened the admin console.
Whatever is identical for every cell (state backend, provider generation, the
adoption hook) lives once in that tenant family's `root.hcl`.

The runbooks, policies, and scripts under `automation/`, `policies/`, and `scripts/`
are the governance that cannot be a Terraform resource; they are deployed and
delivered by stacks like everything else. The decision records under `docs/adr/`
carry the reasoning for each of these choices.

## History

The patterns here were developed and used separately over several years, on
different engagements and against different tenants. This repository
consolidates them into one layout with one set of conventions and was assembled
and published in one pass, which is why the early commit history is compact. The
decision records carry the reasoning that the commits do not.

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
| AWS IAM Identity Center gallery app: SAML, signing certificate, group assignments, SCIM provisioning | `modules/entra/aws-identity-center-app` | `azuread_application`, `azuread_service_principal`, `azuread_service_principal_token_signing_certificate`, `azuread_app_role_assignment`, `azuread_synchronization_secret`, `azuread_synchronization_job` |
| Identity Center permission sets with partition-aware managed policies, inline policy, and boundary | `modules/aws/permission-set` | `aws_ssoadmin_permission_set`, `aws_ssoadmin_managed_policy_attachment`, `aws_ssoadmin_customer_managed_policy_attachment`, `aws_ssoadmin_permission_set_inline_policy`, `aws_ssoadmin_permissions_boundary_attachment` |
| Identity Center account assignments parsed from `AWS-<PARTITION>-<accountId>-<PermissionSetName>` group names | `modules/aws/account-assignment` | `aws_ssoadmin_account_assignment` |
| Automation account with one user-assigned identity per privilege tier, account variables, optional module assets | `modules/azure/automation-account` | `azurerm_automation_account`, `azurerm_user_assigned_identity`, `azurerm_automation_variable_string`, `azurerm_automation_variable_bool`, `azurerm_automation_module` |
| Runbooks published from repository files, schedules, and job schedules with parameters | `modules/azure/automation-runbooks` | `azurerm_automation_runbook`, `azurerm_automation_schedule`, `azurerm_automation_job_schedule` |
| Microsoft Graph application permissions for a managed identity, by name | `modules/entra/graph-app-role-grant` | `azuread_app_role_assignment` |
| Standing Azure role assignments for a workload identity, scopes and roles by name, optional ABAC conditions written with name tokens | `modules/azure/workload-role-assignment` | `azurerm_role_assignment` |
| Keyless backup storage: account with shared key access disabled, infrastructure encryption, versioning with a lifecycle rule, private container, container-scoped writer roles | `modules/azure/backup-storage` | `azurerm_storage_account`, `azurerm_storage_container`, `azurerm_storage_management_policy`, `azurerm_role_assignment` |
| PIM activation settings of undeclared Azure pairs and Entra directory roles, group eligibility end dates, restricted-offer subscriptions, the runbooks' own source and job health | `automation/runbooks/*` on `automation/lib/Runbook.Common.ps1` | none: Graph, ARM, and Storage calls from Automation jobs, delivered by `stacks/azure-automation` |
| Entra authentication methods policy (per-method state, targets, and settings; registration campaign; report suspicious activity; system-preferred MFA), groups by display name | `policies/entra/authentication-methods` with `scripts/Set-AuthenticationMethods.ps1` and `automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1` | none: Graph `PATCH` on patch-only singletons; delivered as `azurerm_automation_variable_string` and a pipeline job |

Nine stacks compose those modules into deployable units:

| Stack | Composes | Cells |
|-------|----------|-------|
| `stacks/okta-config` | the four Okta policy modules | `tenants/okta/dev`, `tenants/okta/prod` |
| `stacks/entra-app-registrations` | app registrations and service principals with a drift-detection import contract | `tenants/azure/corp/entra-app-registrations` |
| `stacks/entra-conditional-access` | named locations, authentication strengths, and Conditional Access policies | `tenants/azure/{corp,subsidiary}/entra-conditional-access` |
| `stacks/entra-pim-governance` | role-assignable groups, PIM for groups policies, and Entra role eligibilities | `tenants/azure/{corp,subsidiary}/entra-pim-governance` |
| `stacks/azure-rbac-roles` | custom role definitions only | `tenants/azure/corp/azure-rbac-roles` |
| `stacks/azure-pim-governance` | PIM policies, then eligibilities, in that order | `tenants/azure/{corp,subsidiary}/azure-pim-governance` |
| `stacks/entra-aws-federation` | one Identity Center gallery app per AWS partition, fed from one list of convention-named groups | `tenants/azure/corp/entra-aws-federation` |
| `stacks/aws-identity-center` | permission sets, then account assignments, one assignment per group name | `tenants/aws/{commercial,govcloud}/aws-identity-center` |
| `stacks/azure-automation` | Automation account and one identity per privilege tier, then the runbooks in `automation/runbooks` (with `automation/lib` inlined), the desired-state files in `policies/` as variables, each tier's Graph permissions and Azure role assignments, and optional backup storage | `tenants/azure/corp/azure-automation` |

The subsidiary tenant has no `entra-app-registrations` cell because application
onboarding is confined to corp, no `azure-rbac-roles` cell because it assigns built-in
roles only, no `entra-aws-federation` cell because corp is the identity source
for every Identity Center instance, and no `azure-automation` cell because the
runbooks have not been rolled out to it; when they are, the cell is a copy of
corp's with its own group names and mailbox. Nothing is stubbed to make the
tenants look symmetrical.

## Layout

```
identity-as-code/
  modules/
    okta/                       network-zone, session-policy, mfa-policy, password-policy
    entra/                      app registration, Conditional Access, PIM for groups, AWS Identity Center app, and Graph app role grant building blocks
    azure/                      rbac-role-definition, pim-role-policy, pim-eligible-assignment, automation-account, automation-runbooks, workload-role-assignment, backup-storage
    aws/                        permission-set, account-assignment
  stacks/                       units of deployment: compose modules, resolve names to IDs
    okta-config/
    entra-app-registrations/
    entra-conditional-access/
    entra-pim-governance/
    entra-aws-federation/
    azure-rbac-roles/
    azure-pim-governance/
    azure-automation/
    aws-identity-center/
  automation/
    runbooks/                   PowerShell runbooks deployed by stacks/azure-automation: credential hygiene, guest lifecycle, authentication methods drift,
                                runbook backup, PIM eligibility renewal, subscription guard, Azure PIM policy governance, Entra PIM policy drift, job watcher
    lib/                        Runbook.Common (shared runbook plumbing) and AuthenticationMethods.Common (shared with a script), inlined at deploy time
    tests/                      Pester tests (HTTP mocked) and the runner
  policies/                       desired-state JSON published as Automation variables (no Terraform resource, or no safe job parameter)
    entra/authentication-methods/   the authentication methods policy: policy.json and methods/<Id>.json, groups by display name
    entra/pim-governance/           the Entra PIM baseline the drift runbook compares against
    azure/pim-governance/           the Azure PIM baseline the policy sweep holds every eligible pair to
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
        azure-automation/terragrunt.hcl
        entra-app-registrations/terragrunt.hcl
        entra-aws-federation/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
      subsidiary/
        azure-pim-governance/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
    aws/                        one directory per partition, one cell per stack inside it
      root.hcl                  S3 state per partition, aws provider generation, adoption hook
      commercial/
        aws-identity-center/terragrunt.hcl
      govcloud/
        aws-identity-center/terragrunt.hcl
  .github/workflows/            PR validation and release trains: okta-* (dev -> prod), azure-* (corp -> subsidiary), aws-* (commercial -> govcloud), plus automation-tests (Pester on 5.1 and 7)
  scripts/                      PowerShell helpers to adopt an existing tenant, export drift, import live PIM eligibilities, and enforce the authentication methods policy
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

**The group name is the AWS assignment.** Every AWS access group is named
`AWS-<PARTITION>-<accountId>-<PermissionSetName>`. On the Entra side that name
decides which Identity Center gallery application the group is assigned to, and
therefore which instance SCIM provisions it into. On the AWS side the
account-assignment module parses the same name into "this permission set, in
this account, for this group" and refuses a group for the wrong partition or for
a permission set the cell does not define. An access reviewer reading the group
name in Entra knows what it grants without opening AWS, and provisioning and
assignment derive from one artifact, so they cannot disagree. Users are never
assigned directly. See [ADR 0008](docs/adr/0008-entra-id-as-the-identity-source-for-aws.md).

**Commercial and GovCloud are cells of one stack.** The partition is read from
`data.aws_partition` at plan time, managed policy ARNs are built from it, and a
cell says only which region it is. State bucket and OIDC role are per partition
and arrive through the environment. See
[ADR 0009](docs/adr/0009-partition-aware-aws-cells.md).

**Automation is code, dry by default, on a managed identity.** The work that
depends on live data (which credentials expired, which guests went quiet,
which eligibilities are about to lapse, which subscriptions nobody
authorised) runs as runbooks in `automation/runbooks`, published from their
files by `stacks/azure-automation` onto an Automation account whose
user-assigned identities are created and granted their Graph permissions and
Azure role assignments in the same plan. Every runbook is dry unless the
tenant cell says otherwise, every destructive action has a cap, and a guest's
lifecycle stage is a group membership so every transition is in the audit log
and reversible by a helpdesk agent. The runbooks back up their own published
source every night, restore-verified, and an hourly watcher mails one digest
when a job fails or a scheduled run does not happen. The runbooks have Pester
tests that mock HTTP and assert the boundaries, and CI runs them on Windows
PowerShell 5.1 and PowerShell 7. See
[ADR 0010](docs/adr/0010-automation-runs-on-managed-identity-with-dry-run-defaults.md)
and [ADR 0011](docs/adr/0011-lifecycle-stage-tracked-in-groups.md).

**One identity per privilege tier, not one per account.** Nine runbooks on one
identity meant the backup ran with the permission to rewrite Global
Administrator's PIM policy. The account now carries one user-assigned identity
per tier (`observer`, `lifecycle`, `pim`, `subscription-guard`), each holding
only what its own runbooks use, and each runbook entry names its tier. The
limit is written down rather than glossed over: every identity is attached to
the same Automation account, so anyone who can publish a runbook or start a
job there can use any of them. Tiers contain a runbook defect or a bad
parameter; separate accounts are what contain a person, and the ADR says when
that is warranted. See
[ADR 0016](docs/adr/0016-one-identity-per-privilege-tier-in-one-automation-account.md).

**Runbook plumbing is written once and published in every runbook.** Six of
the runbooks need tokens for three services in two clouds, paging, retries,
scope and group lookups, mail, a breaker, and a summary. That code lives once
in `automation/lib/Runbook.Common.ps1`; each runbook carries two marker lines
around a dot-source of it, and the runbooks module replaces the block with the
library's text at plan time, so the published runbook is still one file, a
library change is a plan diff on every runbook that uses it, and there is no
module package to build or host. The library's tests assemble a sample
runbook exactly as Terraform does and run it. See
[ADR 0013](docs/adr/0013-one-shared-runbook-library-inlined-at-deploy-time.md).

**A managed identity's Azure access is standing, so it is declared and
constrained.** A managed identity cannot activate a PIM role, so a tier's
Azure permissions are role assignments in the automation cell, by scope and
role name. Roles that can assign roles are refused without an ABAC condition.
The subscription guard, which must be an unconditioned Owner of a subscription
at the moment it cancels it, runs on an identity nothing else uses and holds
Role Based Access Control Administrator under a delegation condition that lets
it assign only Owner and only to itself, grants itself Owner on one
subscription, cancels, and removes the grant in the same run. The condition is
written with name tokens that the stack resolves to GUIDs, so the cell still
holds none. What the condition constrains is which role and which principal,
not which scope, so that identity can make itself Owner anywhere under its
management group: it is assigned at a narrow sandbox group, never at the root,
and nothing is canceled until two separate switches are turned. See
[ADR 0014](docs/adr/0014-just-in-time-self-elevation-under-an-abac-delegation-condition.md).

**PIM settings are declared by the stacks and swept by runbooks.** Terraform
owns the (scope, role) pairs and PIM groups a cell names. Runbooks sweep what
no cell names (roles made eligible from the portal, new subscriptions, Entra
directory role settings) every night, against the same baseline: their
built-in defaults are the stacks' defaults, a baseline file under `policies/`
mirrors every declared entry, and they only ever tighten, so a Terraform plan
after a sweep shows no change the sweep caused. That baseline reaches the
runbook as an Automation string variable the stack publishes from the file,
because a job schedule cannot carry JSON safely. Group eligibilities whose
dates Terraform declares are left to Terraform. See
[ADR 0015](docs/adr/0015-runtime-pim-governance-alongside-declarative-stacks.md).

**The authentication methods policy is desired-state JSON, not a resource.**
The azuread provider has no resource for it and the Graph objects are
patch-only singletons with no create, destroy, or import, so
`policies/entra/authentication-methods` holds one JSON file per method
configuration and one for the policy-level settings, written in the Graph
shape with group display names where Graph wants object IDs.
`scripts/Set-AuthenticationMethods.ps1` resolves the names, diffs the files
against one `GET`, and patches the drift; the release train runs it after the
corp governance cell and the pull request workflow runs it read-only with
`-FailOnDrift`. `Invoke-AuthenticationMethodsDrift` runs the same comparison
every Sunday from the same files, published as Automation variables by the
automation stack, and mails a digest when the tenant has moved. The script
never disables the last enabled method and never sends `policyMigrationState`
without an explicit switch, because that one field retires the legacy MFA and
SSPR settings tenant-wide. See
[ADR 0012](docs/adr/0012-authentication-methods-policy-as-desired-state.md).

**Path is environment, via Terragrunt.** `tenants/okta/dev`, `tenants/okta/prod`,
`tenants/azure/corp`, `tenants/azure/subsidiary`, `tenants/aws/commercial`, and
`tenants/aws/govcloud` are the only places those words appear. There is no
`environment` variable threaded through modules and no
`count = var.is_prod ? 1 : 0` anywhere. Adding a tenant is adding a directory.

**Tenant cells hold values only.** A tenant `terragrunt.hcl` has an include, a source,
and an `inputs` map. No resources, no data sources, no conditionals. Reviewers can
diff dev against prod and see exactly what is stricter in production and nothing else.
See [ADR 0002](docs/adr/0002-values-only-tenant-cells.md).

**State keys derive from the path.** Each `root.hcl` sets
`key = "<tree>/${path_relative_to_include()}/terraform.tfstate"`, so
`tenants/okta/prod` writes `okta/prod/terraform.tfstate` and
`tenants/azure/corp/azure-pim-governance` writes
`azure/corp/azure-pim-governance/terraform.tfstate`, and
`tenants/aws/govcloud/aws-identity-center` writes
`aws/govcloud/aws-identity-center/terraform.tfstate` into the GovCloud bucket.
Nobody types a state key, so nobody can point two cells at the same one.

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
generated file, a plan artifact, or state. AWS Identity Center access uses the
same OIDC pattern with a role per partition. The one credential that is a
credential by nature, the SCIM token the AWS console issues, reaches Terraform as
a sensitive `TF_VAR` from a GitHub environment secret and appears in no file;
where the provider stores it is stated rather than hidden. See
[ADR 0003](docs/adr/0003-no-long-lived-secrets-in-ci.md) and
[ADR 0008](docs/adr/0008-entra-id-as-the-identity-source-for-aws.md).

**Promotion is gated, first tenant before the second.** A merge to `main` plans and
applies dev (Okta), corp (Azure), or commercial (AWS), then stops at a gate. The
gate is a GitHub environment with required reviewers and a wait timer. When a
human approves, prod, subsidiary, or GovCloud applies the exact plan file that
was produced at merge time. If that
state moved in the meantime, Terraform refuses the stale plan and the release is
re-run rather than applied blind. The Azure train additionally applies the corp
roles cell before planning the corp governance and automation cells, because
both resolve custom roles by name at plan time, and applies the corp
automation cell after the governance cell so corp is complete before the
subsidiary gate opens.

That ordering has a review cost worth stating: a pull request that introduces
a custom role **and** its first use shows a failing plan for the consuming
cell, because the role is resolved by name and does not exist until the roles
cell is applied on merge. The recommended practice is to land role definitions
in their own pull request first and use them in the next one; where that is not
practical, name the expected red plan in the pull request description.

## How to use it

Prerequisites: Terraform 1.9 or later and Terragrunt 0.77 or later. For the Okta
tree, an S3 bucket and DynamoDB table for state and an Okta API token with policy
and zone scopes. For the Azure tree, a storage account and container for state with
shared key access disabled, `az login` as an identity that holds Storage Blob Data
Contributor on the container and the RBAC needed at the scopes you manage. For the
AWS tree, an S3 bucket and DynamoDB table per partition and an SSO session or
profile in each partition's Identity Center delegated administrator account.

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

The `entra-aws-federation` cell additionally needs the SCIM credentials the AWS
console issued, as a sensitive map keyed by target. They are never in a file:

```bash
export TF_VAR_scim_credentials='{
  commercial = { base_address = "https://scim.us-east-1.amazonaws.com/CHANGEME/scim/v2", secret_token = "CHANGEME" }
  govcloud   = { base_address = "https://scim.us-gov-west-1.amazonaws.com/CHANGEME/scim/v2", secret_token = "CHANGEME" }
}'
```

AWS Identity Center:

```bash
aws sso login --profile CHANGEME-identity-center-admin
export AWS_PROFILE=CHANGEME-identity-center-admin
export TG_AWS_STATE_BUCKET=CHANGEME-tfstate-commercial
export TG_AWS_STATE_REGION=us-east-1
export TG_AWS_LOCK_TABLE=CHANGEME-tflock

cd tenants/aws/commercial/aws-identity-center
terragrunt init
terragrunt plan
```

The GovCloud cell is the same commands with a GovCloud profile, a GovCloud bucket,
and `TG_AWS_STATE_REGION=us-gov-west-1`. Nothing in HCL changes; the modules read
the partition from the credentials they are given. Plan the Entra federation cell
first for a new instance: the AWS cell resolves groups by display name in the
identity store, and they exist there only after SCIM has provisioned them.

To adopt an existing tenant instead of creating policies from scratch:

1. Run `scripts/Import-OktaPolicies.ps1` against the tenant. It emits `imports.tf`
   and a `values.skeleton.hcl` you paste into the tenant cell.
2. Drop `imports.tf` into the tenant directory. `root.hcl` picks it up automatically.
3. Plan. Adjust values until the plan shows 0 to add, 0 to change, 0 to destroy.
   `tests/README.md` describes the gate that enforces this in CI.
4. Apply (this only records the imports), then delete `imports.tf`.

For PIM eligibilities, `scripts/Export-PimEligibilityImports.ps1` does the same
for the `azure-pim-governance` and `entra-pim-governance` cells from the live
schedule instances, with one extra first step: `terragrunt apply -refresh-only`
in the cell, because renewed eligibilities get new schedule IDs and state must
catch up before an import file is trusted. `scripts/Export-EntraDrift.ps1` is
the equivalent for application registrations.

For the authentication methods policy there is nothing to import.
`scripts/Set-AuthenticationMethods.ps1 -Export $true` writes the live policy
into `policies/entra/authentication-methods` with group IDs replaced by
display names; trim the files to the fields you mean to manage, then run the
script without `-Export` and expect an empty drift table, which is the same
zero-change gate applied to an object Terraform cannot hold.

## Deliberately out of scope

- Users and group memberships. The directory of record owns those. Every stack
  looks groups up by name; only the Entra PIM stack creates groups, and only the
  role-assignable ones it governs.
- Okta applications, SAML/OIDC integrations, and app sign-on policies.
- Okta authentication policies for Identity Engine apps (a natural next stack).
- Standing (active) Azure role assignments for people. If a person needs
  standing access, that is a design conversation, not a map entry. The only
  standing grantees are the runbook tier identities, which cannot activate
  PIM, and their assignments are declared and reviewed per tier in the
  automation cell (ADR 0014, ADR 0016).
- The management group hierarchy and subscriptions themselves. The Azure stacks
  resolve them by name and never create one. The subscription guard runbook
  can cancel a subscription; nothing here creates one.
- The AWS organization and its accounts, the Identity Center instances, and the
  customer managed IAM policies a permission set may reference by name.
- Switching an Identity Center instance's identity source to Entra ID and
  enabling automatic provisioning. Both are one-shot console steps with no API
  Terraform can drive; the federation module README gives the order and the
  stack consumes their outputs.
- Users and groups in the Identity Center identity store. SCIM from Entra owns
  them, and the AWS stack only ever looks a group up by display name.
- Provisioning the S3 buckets, DynamoDB tables, AWS OIDC roles (one set per
  partition), Azure storage account, federated credentials, and GitHub
  environments. That is platform bootstrap and lives in a separate repository.
- The three guest lifecycle stage groups, the other groups the runbooks name
  (approvers, the subscription owner allowlist), the shared mailbox the
  runbooks send from, the Exchange application access policies that restrict
  `Mail.Send` to it (no Terraform resource exists for them, and each identity
  that sends mail needs its own), the diagnostic settings that stream
  Automation job output to the SIEM, the activity log alert on the
  subscription guard's role assignment writes, and the second alert that
  watches the job watcher. The automation stack resolves the groups and
  mailbox by name and outputs every tier's client ID, with whether it sends
  mail, for exactly those policies.
- The job watcher's state variable. The watcher creates and rewrites it;
  declaring it would make every plan show drift.

## Verification status

No live tenant of any kind was used to build this repository.

One expected red plan, before the list below: a pull request that adds a
custom role definition **and** its first assignment cannot plan cleanly. The
consuming cell resolves the role by display name at plan time, and the role
exists only after the roles cell is applied, which happens on merge. Land
role definitions in their own pull request first, let the release train apply
`tenants/azure/corp/azure-rbac-roles`, and open the pull request that uses
them next; where the two must travel together, say in the description which
plan is expected to fail and why. The same applies to any cell that names a
custom role: `azure-pim-governance` and `azure-automation` both do
(ADR 0005).

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

The AWS tree (`modules/aws/*`, `stacks/aws-identity-center`) and the Entra
federation pieces (`modules/entra/aws-identity-center-app`,
`stacks/entra-aws-federation`) were written the same way, with Terraform 1.16, and
pass `terraform init -backend=false` and `terraform validate` against the pinned
providers (aws 6.x, azuread 3.x). The Terragrunt root's generated provider block
was rendered through Terraform's template engine to confirm the conditional
`assume_role` output. Four things validate cannot check and a first apply should:
that the gallery template is found under the display name the module defaults to,
that the instantiated service principal publishes a `User` app role (the module
falls back to the default role ID and otherwise fails with the list), that the
synchronization template the gallery application publishes is `aws` (the module
README says how to list it), and that the provider leaves the template's SAML
settings alone when `identifier_uris` and `reply_urls` are set.

The automation pieces (`modules/azure/automation-account`,
`modules/azure/automation-runbooks`, `modules/azure/workload-role-assignment`,
`modules/azure/backup-storage`, `modules/entra/graph-app-role-grant`,
`stacks/azure-automation`) pass `terraform init -backend=false` and
`terraform validate` against the same pinned providers. The stack was also
planned offline with `terraform test` and mocked azurerm and azuread
providers, fed the corp cell's inputs verbatim: each runbook got the client ID
and principal ID of its own tier identity, the Graph grants and role
assignments split per tier, every list reached its job schedule as a semicolon
string with no JSON anywhere, the PIM baselines stayed out of the job
schedules and the variable names went in, the backup container's writer was
derived from the runbook that asks for the storage names, the subscription
guard's condition rendered with both tokens replaced, and the single-identity
form still produced one `default` identity with the shipped union of Graph
permissions. That harness is not committed. Both baseline files were parsed
with the runbooks' own parsers. All nine runbooks, the two libraries, and the
scripts parse cleanly with the PowerShell language parser, and the full Pester
suite (every HTTP call mocked) passes on Pester 3.4.0 under Windows PowerShell
5.1 locally; `.github/workflows/automation-tests.yml` runs the same suite on
`windows-latest` under Windows PowerShell 5.1 and PowerShell 7 with Pester
4.10.1, which is where the PowerShell 7 paths are covered.

What a first live run should confirm, from the logged `Settings` line of the
first dry job of each runbook and from its summary object:

- that `[bool]` parameters bind from the job schedule strings `"true"` and
  `"false"` (`DryRun`, `AllowCancel`, `IncludeAzureResources`, and the rest);
  if one does not, the failure is a job that errors on parameter binding,
  never a live run that was meant to be dry;
- that every semicolon list arrived whole and split into the expected number
  of entries (recipients, quota id patterns, group name patterns, scope names,
  account names), rather than as one space-joined string;
- that each runbook read the Automation variable it was told to read
  (`PimPolicy_AzureBaseline`, `PimPolicy_EntraBaseline`, `AuthMethods_*`), and
  that the baseline it logged has the overrides the repository declares;
- that each job ran as the tier identity it was meant to: the client ID in the
  settings line, and the absence of 403s from a permission the tier should
  hold;
- that the Automation identity endpoint accepts the `client_id` query
  parameter for a user-assigned identity, with several attached to the
  account.

Beyond the first dry runs: that `signInActivity` is licensed in the tenant,
that ARM stores the delegation condition as sent (a diff on the next plan
means it normalised the text), that the storage account's first apply does not
need a data-plane role for the apply identity, that REST Cancel is accepted on
each offer the guard targets and can be reversed, and the PIM and Automation
API behaviours each runbook header lists as unverified. No live tenant was
used.

The authentication methods pieces (`policies/entra/authentication-methods`,
`scripts/Set-AuthenticationMethods.ps1`, `automation/lib`, the drift runbook,
and the `desired_state_files` and `library` inputs of the automation stack)
were written the same way: every field name in the JSON was checked against
the Microsoft Graph reference pages for `authenticationMethodsPolicy` and
each `authenticationMethodConfiguration` subtype, and the tests run the
shipped files against a fixture of the beta `GET` response (36 tests across
two files) and assert zero drift before flipping fields one at a time. What
a first live run should confirm: that a tenant which has migrated to passkey
profiles accepts a Fido2 `includeTargets` entry without `allowedPasskeyProfiles`
(if not, the folder README says what to add), that `PATCH` on the policy
object accepts `policyMigrationState` when the guard is lifted (the reference
lists it as a property but not in the updatable table), and that the
`Recipients` parameter binds from the job schedule's semicolon string. Run
`-Export` into a scratch folder first and diff it against the shipped files.

## License

MIT. See [LICENSE](LICENSE).
