# identity-as-code

Identity configuration managed the same way as infrastructure: typed Terraform
modules, deployable stacks, values-only tenant cells, and a release train that
promotes a change from the first tenant to the gated one through a human approval.
Four providers, one layout: Okta (authentication policy, an application
catalog of SAML and OIDC apps behind app sign-on policies, and federation to
Entra as the upstream identity provider for workforce sign-in), Entra ID (app
registrations, a SAML application catalog, Conditional Access, PIM for groups
and directory roles, and federation to AWS), Azure resource RBAC (custom
roles, PIM policies, eligibilities), and AWS IAM Identity Center (permission
sets and group assignments, in commercial and GovCloud).
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
several; what makes it a stack is the deployment boundary, not the count. A
stack is shared by every tenant of a family (a platform stack), or offers a
menu of vetted shapes to one account or subscription (a catalog stack), or
holds one application's composition (an app stack); the cell rule below is the
same for all three ([ADR 0017](docs/adr/0017-three-kinds-of-stack.md)).

**Cells answer where, and with what values.** A tenant is a folder of cells. Each
cell is one stack applied for one tenant, and it contains exactly three things: an
include of the shared root, a source pointing at the stack, and an inputs map of
values; a catalog cell may split that map into fragment files beside it
(`iam-roles.hcl`, `kms-keys.hcl`, `s3-buckets.hcl`), each an inputs attribute
holding one map and nothing else, brought in by a labeled include and merged by
Terragrunt into the one map the stack sees. No resources, no data sources, no
conditionals, no IDs. A cell calls a
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
| App sign-on policies and rules: factors, re-authentication, phishing-resistant and hardware-protected possession, zones and groups by name, catch-all DENY, single-factor access only with a stated reason | `modules/okta/app-signon-policy` | `okta_app_signon_policy`, `okta_app_signon_policy_rule` |
| Custom SAML 2.0 apps with signed responses and assertions (RSA-SHA256), typed attribute statements, https-only endpoints, no inline hook, group assignments by name, vendor onboarding values as outputs | `modules/okta/app-saml` | `okta_app_saml`, `okta_app_group_assignments` |
| OIDC apps typed web, browser, native, or service: grant and response types derived from the type (code only on the redirect-based types, never implicit), PKCE, `private_key_jwt` by default, refresh token rotation, wildcards off, the client secret never in state, group assignments by name | `modules/okta/app-oauth` | `okta_app_oauth`, `okta_app_group_assignments` |
| Upstream SAML 2.0 identity providers as a map: signed AuthnRequests (SHA-256) and at least SHA-256 on the response signature, https-only issuer and endpoints, one signing key per certificate from the PEM the other side publishes (a comment above the armor is ignored, a second certificate or a private key is refused) with one active kid, a typed subject match, provisioning off unless asked for, account linking on but never unfenced (AUTO is refused without a subject filter or a group restriction), groups as ids the stack resolves | `modules/okta/idp-saml` | `okta_idp_saml`, `okta_idp_saml_key` |
| Routing rules on the org's identity provider discovery policy: username or attribute patterns, SAML2 targets by id, a network condition with zones only under `ZONE`, application and platform conditions typed per entry, unique priorities | `modules/okta/idp-routing-rules` | `okta_policy_rule_idp_discovery` |
| App registrations and service principals with a drift-detection import contract | `modules/entra/app-registration` | `azuread_application`, `azuread_service_principal`, `azuread_application_federated_identity_credential`, `azuread_app_role_assignment` |
| Named locations, authentication strengths, and Conditional Access policies | `modules/entra/conditional-access` | `azuread_named_location`, `azuread_authentication_strength_policy`, `azuread_conditional_access_policy` |
| Role-assignable security groups | `modules/entra/security-group` | `azuread_group` |
| PIM for groups policies | `modules/entra/pim-role-policy` | `azuread_group_role_management_policy` |
| Entra role and PIM group eligibilities | `modules/entra/pim-eligibility` | `azuread_directory_role_eligibility_schedule_request`, `azuread_privileged_access_group_eligibility_schedule` |
| Custom Azure RBAC role definitions, scopes resolved by name | `modules/azure/rbac-role-definition` | `azurerm_role_definition` |
| PIM role management policies per (scope, role): activation window, MFA, approval, expiration | `modules/azure/pim-role-policy` | `azurerm_role_management_policy` |
| PIM eligible assignments for Entra groups, by group, role, and scope name | `modules/azure/pim-eligible-assignment` | `azurerm_pim_eligible_role_assignment` |
| AWS IAM Identity Center gallery app: SAML, signing certificate, group assignments, SCIM provisioning | `modules/entra/aws-identity-center-app` | `azuread_application`, `azuread_service_principal`, `azuread_service_principal_token_signing_certificate`, `azuread_app_role_assignment`, `azuread_synchronization_secret`, `azuread_synchronization_job` |
| SAML enterprise applications, gallery or custom, as a map: service principal in SAML mode with assignment required, an Entra-generated signing certificate with expiry mail, a claims mapping policy rendered from typed NameID and claim values, app roles to groups by name, optional SCIM provisioning, the tenant's SAML endpoints and each app's metadata URL as outputs | `modules/entra/saml-enterprise-app` | `azuread_application`, `azuread_service_principal`, `azuread_service_principal_token_signing_certificate`, `azuread_claims_mapping_policy`, `azuread_service_principal_claims_mapping_policy_assignment`, `azuread_app_role_assignment`, `azuread_synchronization_secret`, `azuread_synchronization_job` |
| Identity Center permission sets with partition-aware managed policies, inline policy, and boundary | `modules/aws/permission-set` | `aws_ssoadmin_permission_set`, `aws_ssoadmin_managed_policy_attachment`, `aws_ssoadmin_customer_managed_policy_attachment`, `aws_ssoadmin_permission_set_inline_policy`, `aws_ssoadmin_permissions_boundary_attachment` |
| Identity Center account assignments parsed from `AWS-<PARTITION>-<accountId>-<PermissionSetName>` group names | `modules/aws/account-assignment` | `aws_ssoadmin_account_assignment` |
| IAM service roles: trust from an allowlisted service, 12-digit accounts, or one GitHub repository by branch and environment; policies by name; boundary; instance profile for EC2 | `modules/aws/iam-service-role` | `aws_iam_role`, `aws_iam_role_policy_attachment`, `aws_iam_role_policy`, `aws_iam_instance_profile` |
| Customer managed KMS keys with rotation and a key policy written from role names, trail names, and service users | `modules/aws/kms-key` | `aws_kms_key`, `aws_kms_alias` |
| S3 buckets: ACLs off, nothing public, versioned, TLS-only, SSE-S3 or SSE-KMS by alias, role allow list, lifecycle, access logging, CloudTrail delivery | `modules/aws/s3-bucket` | `aws_s3_bucket`, `aws_s3_bucket_ownership_controls`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_versioning`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_s3_bucket_lifecycle_configuration`, `aws_s3_bucket_policy`, `aws_s3_bucket_logging` |
| Account hardening switches: password policy, EBS encryption by default, account S3 Block Public Access, GuardDuty, Access Analyzer | `modules/aws/account-hardening` | `aws_iam_account_password_policy`, `aws_ebs_encryption_by_default`, `aws_ebs_default_kms_key`, `aws_s3_account_public_access_block`, `aws_guardduty_detector`, `aws_accessanalyzer_analyzer` |
| Multi-region, validated CloudTrail trails delivering to a named bucket under a named key | `modules/aws/cloudtrail` | `aws_cloudtrail` |
| CloudWatch Logs log groups under a named customer managed key, retention bounded to the values the API accepts and never "never expire" | `modules/aws/log-group` | `aws_cloudwatch_log_group` |
| SSM Parameter Store namespaces: one SecureString placeholder per prefix under a named key, written once and never a secret | `modules/aws/ssm-parameter-namespace` | `aws_ssm_parameter` |
| ECR repositories: immutable tags, scan on push, a customer managed key by ARN, two lifecycle rules, a repository policy that grants pull and push by role name and delete to nobody | `modules/aws/ecr-repository` | `aws_ecr_repository`, `aws_ecr_lifecycle_policy`, `aws_ecr_repository_policy` |
| Automation account with one user-assigned identity per privilege tier, account variables, optional module assets | `modules/azure/automation-account` | `azurerm_automation_account`, `azurerm_user_assigned_identity`, `azurerm_automation_variable_string`, `azurerm_automation_variable_bool`, `azurerm_automation_module` |
| Runbooks published from repository files, schedules, and job schedules with parameters | `modules/azure/automation-runbooks` | `azurerm_automation_runbook`, `azurerm_automation_schedule`, `azurerm_automation_job_schedule` |
| Microsoft Graph application permissions for a managed identity, by name | `modules/entra/graph-app-role-grant` | `azuread_app_role_assignment` |
| Standing Azure role assignments for a workload identity, scopes and roles by name, optional ABAC conditions written with name tokens | `modules/azure/workload-role-assignment` | `azurerm_role_assignment` |
| Keyless backup storage: account with shared key access disabled, infrastructure encryption, versioning with a lifecycle rule, private container, container-scoped writer roles | `modules/azure/backup-storage` | `azurerm_storage_account`, `azurerm_storage_container`, `azurerm_storage_management_policy`, `azurerm_role_assignment` |
| Resource groups with an optional CanNotDelete lock | `modules/azure/resource-group` | `azurerm_resource_group`, `azurerm_management_lock` |
| User-assigned managed identities with GitHub Actions federated credentials, subjects built from organization, repository, and branch or environment | `modules/azure/managed-identity` | `azurerm_user_assigned_identity`, `azurerm_federated_identity_credential` |
| Key vaults: RBAC-only, purge protection, Deny firewall, audit to Log Analytics, data-plane roles for identities by key and Entra groups by name | `modules/azure/key-vault` | `azurerm_key_vault`, `azurerm_monitor_diagnostic_setting`, `azurerm_role_assignment` |
| Storage accounts: no shared keys, TLS 1.2, infrastructure encryption, versioning, private containers, Deny firewall, data-plane roles at account or container scope | `modules/azure/storage-account` | `azurerm_storage_account`, `azurerm_storage_container`, `azurerm_monitor_diagnostic_setting`, `azurerm_role_assignment` |
| Container registries: no admin user, no anonymous pull, platform encryption, a Deny-default IP allow list, untagged-manifest retention, and zone redundancy on Premium only, audit to Log Analytics, data-plane roles for identities by key and Entra groups by name | `modules/azure/container-registry` | `azurerm_container_registry`, `azurerm_monitor_diagnostic_setting`, `azurerm_role_assignment` |
| Subscription baseline: Defender for Cloud plans, activity log export to a Log Analytics workspace (found or created), initiative assignments by display name | `modules/azure/subscription-baseline` | `azurerm_security_center_subscription_pricing`, `azurerm_log_analytics_workspace`, `azurerm_monitor_diagnostic_setting`, `azurerm_subscription_policy_assignment` |
| PIM activation settings of undeclared Azure pairs and Entra directory roles, group eligibility end dates, restricted-offer subscriptions, the runbooks' own source and job health | `automation/runbooks/*` on `automation/lib/Runbook.Common.ps1` | none: Graph, ARM, and Storage calls from Automation jobs, delivered by `stacks/azure-automation` |
| Entra authentication methods policy (per-method state, targets, and settings; registration campaign; report suspicious activity; system-preferred MFA), groups by display name | `policies/entra/authentication-methods` with `scripts/Set-AuthenticationMethods.ps1` and `automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1` | none: Graph `PATCH` on patch-only singletons; delivered as `azurerm_automation_variable_string` and a pipeline job |

Twelve platform stacks compose those modules into deployable units, with a cell in
every tenant or partition of their family:

| Stack | Composes | Cells |
|-------|----------|-------|
| `stacks/okta-config` | the four Okta policy modules | `tenants/okta/dev/okta-config`, `tenants/okta/prod/okta-config` |
| `stacks/okta-applications` | the Okta application catalog: app sign-on policies first, then the SAML and OIDC apps bound to a policy by key, with cross-map checks at plan (the policy key exists, an admin-tier app names a phishing-resistant policy, no label twice) | `tenants/okta/dev/okta-applications`, `tenants/okta/prod/okta-applications`, each after the org's `okta-config` cell, whose zones the rules name |
| `stacks/okta-federation` | Entra as an upstream SAML identity provider for the org: the identity providers and their signing keys first, from a certificate file beside the cell, then the routing rules on the org's `IDP_DISCOVERY` policy that send matched sign-ins to them by key, with groups, zones, and the excluded application resolved by name and label, and cross-map checks at plan (every rule's identity provider is a key of the map, no priority twice, no display name twice) | `tenants/okta/dev/okta-federation`, `tenants/okta/prod/okta-federation`, each after the org's `okta-config` cell, beside `okta-applications` in the same wave |
| `stacks/entra-app-registrations` | app registrations and service principals with a drift-detection import contract | `tenants/azure/corp/entra-app-registrations` |
| `stacks/entra-enterprise-apps` | the Entra application catalog over SAML: gallery and custom enterprise applications as values, groups by name, with cross-map checks at plan (no display name, reply URL, or entity id on two apps; a provisioning token only for an app that provisions) | `tenants/azure/corp/entra-enterprise-apps` |
| `stacks/entra-conditional-access` | named locations, authentication strengths, and Conditional Access policies | `tenants/azure/{corp,subsidiary}/entra-conditional-access` |
| `stacks/entra-pim-governance` | role-assignable groups, PIM for groups policies, and Entra role eligibilities | `tenants/azure/{corp,subsidiary}/entra-pim-governance` |
| `stacks/azure-rbac-roles` | custom role definitions only | `tenants/azure/corp/azure-rbac-roles` |
| `stacks/azure-pim-governance` | PIM policies, then eligibilities, in that order | `tenants/azure/{corp,subsidiary}/azure-pim-governance` |
| `stacks/entra-aws-federation` | one Identity Center gallery app per AWS partition, fed from one list of convention-named groups | `tenants/azure/corp/entra-aws-federation` |
| `stacks/aws-identity-center` | permission sets, then account assignments, one assignment per group name | `tenants/aws/{commercial,govcloud}/aws-identity-center` |
| `stacks/azure-automation` | Automation account and one identity per privilege tier, then the runbooks in `automation/runbooks` (with `automation/lib` inlined), the desired-state files in `policies/` as variables, each tier's Graph permissions and Azure role assignments, and optional backup storage | `tenants/azure/corp/azure-automation` |

The subsidiary tenant has no `entra-app-registrations` or `entra-enterprise-apps`
cell because application onboarding is confined to corp, no `azure-rbac-roles` cell because it assigns built-in
roles only, no `entra-aws-federation` cell because corp is the identity source
for every Identity Center instance, and no `azure-automation` cell because the
runbooks have not been rolled out to it; when they are, the cell is a copy of
corp's with its own group names and mailbox. Nothing is stubbed to make the
tenants look symmetrical.

Eight more stacks are scoped to one account or one subscription rather than to a
tenant, and are planned once per cell under `accounts/<account-name>/` or
`subscriptions/<sub-name>/`, with each app cell one level down under `apps/`
([ADR 0017](docs/adr/0017-three-kinds-of-stack.md)): a baseline and a catalog
for each cloud, and two app stacks for each.

| Stack | Composes | Cells |
|-------|----------|-------|
| `stacks/aws-account-baseline` | password policy, EBS default encryption, S3 Block Public Access, GuardDuty, and Access Analyzer, then a key, the trail bucket (and its access log bucket), and the multi-region trail | `tenants/aws/commercial/accounts/{example-prod,example-dev}/aws-account-baseline` |
| `stacks/aws-account-workloads` | the AWS catalog: service roles, then KMS keys, then S3 buckets, wired to each other by name and checked at plan | `tenants/aws/commercial/accounts/{example-prod,example-dev}/aws-account-workloads`, and one application's own entries in `tenants/aws/commercial/accounts/example-prod/apps/orders-api/catalog`, applied after the account's |
| `stacks/apps/aws/payments-api` | two ECS task roles, a key, an artifacts bucket, an encrypted log group, and a SecureString parameter namespace, every name derived from the application and the environment | `tenants/aws/commercial/accounts/example-prod/apps/payments-api` |
| `stacks/apps/aws/orders-api` | a key, then a task role, a task execution role, and an image publisher role trusted by one GitHub environment of one repository through OIDC, an ECR repository the execution role pulls from and the publisher pushes to, an encrypted log group, and a SecureString parameter namespace, every name derived from the application and the environment; no bucket, and the compute is left to the application's pipeline | `tenants/aws/commercial/accounts/{example-prod,example-dev}/apps/orders-api` |
| `stacks/azure-subscription-baseline` | a locked resource group and a Log Analytics workspace (or an existing workspace by name), then Defender plans, the activity log export, and initiative assignments | `tenants/azure/corp/subscriptions/{sub-example-prod,sub-example-dev}/azure-subscription-baseline` |
| `stacks/azure-subscription-workloads` | the Azure catalog: resource groups, then managed identities, then key vaults and storage accounts, with data-plane roles granted to identities by key and to Entra groups by name | `tenants/azure/corp/subscriptions/sub-example-prod/azure-subscription-workloads` |
| `stacks/apps/azure/data-pipeline` | a locked group, a federated identity, a vault, and a hierarchical-namespace lake with two containers, the identity granted on each, every name derived from the pipeline and the environment | `tenants/azure/corp/subscriptions/sub-example-prod/apps/data-pipeline` |
| `stacks/apps/azure/orders-api` | a locked group, a runtime identity with no credential and a publisher identity federated to one GitHub environment, a container registry with the runtime identity as AcrPull and the publisher as AcrPush, a vault with the runtime identity as Key Vault Secrets User, both audited to a named workspace, and no role on the group, every name derived from the application and the environment; no storage account, and the compute is left to the application's pipeline | `tenants/azure/corp/subscriptions/{sub-example-prod,sub-example-dev}/apps/orders-api` |

## Layout

```
identity-as-code/
  modules/
    okta/                       network-zone, session-policy, mfa-policy, password-policy, app-signon-policy, app-saml, app-oauth, idp-saml, idp-routing-rules
    entra/                      app registration, SAML enterprise app, Conditional Access, PIM for groups, AWS Identity Center app, and Graph app role grant building blocks
    azure/                      rbac-role-definition, pim-role-policy, pim-eligible-assignment, automation-account, automation-runbooks, workload-role-assignment, backup-storage,
                                resource-group, managed-identity, key-vault, container-registry, storage-account, subscription-baseline
    aws/                        permission-set, account-assignment, iam-service-role, kms-key, s3-bucket, account-hardening, cloudtrail,
                                log-group, ssm-parameter-namespace, ecr-repository
  stacks/                       units of deployment: compose modules, resolve names to IDs
    okta-config/
    okta-applications/          the Okta catalog: app sign-on policies, SAML and OIDC apps as values (docs/adr/0020)
    okta-federation/            Entra as an upstream SAML identity provider and the routing rules that send sign-ins to it, as values (docs/adr/0022)
    entra-app-registrations/
    entra-enterprise-apps/      the Entra catalog: SAML enterprise applications, gallery or custom, as values (docs/adr/0021)
    entra-conditional-access/
    entra-pim-governance/
    entra-aws-federation/
    azure-rbac-roles/
    azure-pim-governance/
    azure-automation/
    aws-identity-center/
    aws-account-baseline/       one cell per account: the hardening switches, a key, the trail bucket, the trail
    aws-account-workloads/      one cell per account: the AWS catalog, roles, keys, and buckets as values
    azure-subscription-baseline/   one cell per subscription: Defender plans, activity log export, initiatives
    azure-subscription-workloads/  one cell per subscription: the Azure catalog, groups, identities, vaults, and storage accounts as values
    apps/                       app stacks, one application's composition each, values-only cells (docs/adr/0017)
      aws/payments-api/
      aws/orders-api/           the container pair: registry, runtime and publisher identities, secrets, logs, no compute (docs/adr/0019)
      azure/data-pipeline/
      azure/orders-api/         the same shape in Azure's words (docs/adr/0019)
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
    okta/                       one directory per tenant, one cell per stack inside it, values only
      root.hcl                  S3 state, Okta provider generation, adoption hook
      dev/
        okta-config/terragrunt.hcl
        okta-applications/
          terragrunt.hcl        the root include, one labeled include per fragment, the source, the dependency on okta-config, the org
          signon-policies.hcl   fragment: the signon_policies map, values only, merged into the cell's inputs by Terragrunt (docs/adr/0020)
          saml-apps.hcl         fragment: the saml_apps map
          oauth-apps.hcl        fragment: the oauth_apps map; dev allows a localhost redirect on the console, prod never does
        okta-federation/
          terragrunt.hcl        the root include, one labeled include per fragment, the source, the dependency on okta-config, the org
          identity-providers.hcl  fragment: the identity_providers map, the corp Entra tenant as the upstream identity provider (docs/adr/0022)
          routing-rules.hcl     fragment: the routing_rules map; dev routes the admin console too, so the whole path is proven first
          entra-signing-2026.cer  the identity provider's public signing certificate, read by the fragment with file(); a placeholder here
      prod/
        okta-config/terragrunt.hcl
        okta-applications/
          terragrunt.hcl
          signon-policies.hcl
          saml-apps.hcl         adds the admin-tier vendor console on the phishing-resistant policy
          oauth-apps.hcl        adds the service client, which names no policy
        okta-federation/
          terragrunt.hcl
          identity-providers.hcl  the same identity provider
          routing-rules.hcl     excludes the Okta Admin Console: the break-glass line, administrators sign in to Okta directly
          entra-signing-2026.cer
    azure/                      one directory per tenant, one cell per stack inside it
      root.hcl                  Azure Storage state, azurerm + azuread provider generation from ARM_TENANT_ID and the subscription locator, adoption hook
      corp/
        azure-rbac-roles/terragrunt.hcl
        azure-pim-governance/terragrunt.hcl
        azure-automation/terragrunt.hcl
        entra-app-registrations/terragrunt.hcl
        entra-enterprise-apps/
          terragrunt.hcl        the root include, the one labeled fragment include, the source; no cell-wide values (docs/adr/0021)
          saml-apps.hcl         fragment: the saml_apps map, a gallery app and a custom app, values only
        entra-aws-federation/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
        subscriptions/          subscription-scoped cells, addressed by a locator, never by a value (docs/adr/0017)
          sub-example-prod/
            subscription.hcl    locator: subscription id and name; not a cell
            azure-subscription-baseline/terragrunt.hcl
            azure-subscription-workloads/
              terragrunt.hcl    the root include, one labeled include per fragment, the source, the dependency, the location and tags
              resource-groups.hcl     fragment: the resource_groups map, values only, merged into the cell's inputs by Terragrunt (docs/adr/0017)
              managed-identities.hcl  fragment: the identities map
              key-vaults.hcl          fragment: the key_vaults map
              storage-accounts.hcl    fragment: the storage_accounts map
            apps/               app cells, one directory per application (docs/adr/0017)
              data-pipeline/terragrunt.hcl
              orders-api/terragrunt.hcl
          sub-example-dev/
            subscription.hcl
            azure-subscription-baseline/terragrunt.hcl
            apps/
              orders-api/terragrunt.hcl
      subsidiary/
        azure-pim-governance/terragrunt.hcl
        entra-conditional-access/terragrunt.hcl
        entra-pim-governance/terragrunt.hcl
    aws/                        one directory per partition, one cell per stack inside it
      root.hcl                  S3 state per partition, aws provider generation from the locators (allowed_account_ids and the account's profile), adoption hook
      commercial/
        partition.hcl           locator: ARN partition and default region; not a cell
        aws-identity-center/terragrunt.hcl
        accounts/               account-scoped cells, addressed by a locator, never by a value (docs/adr/0017)
          example-prod/
            account.hcl         locator: account id and name; not a cell
            aws-account-baseline/terragrunt.hcl
            aws-account-workloads/
              terragrunt.hcl    the root include, one labeled include per fragment, the source, the tags
              iam-roles.hcl     fragment: the service_roles map, values only, merged into the cell's inputs by Terragrunt (docs/adr/0017)
              kms-keys.hcl      fragment: the kms_keys map
              s3-buckets.hcl    fragment: the buckets map
            apps/               app cells, one directory per application (docs/adr/0017)
              payments-api/terragrunt.hcl
              orders-api/
                terragrunt.hcl  the app cell
                catalog/        the app's own catalog cell: what orders-api alone uses, applied after the account catalog (docs/adr/0017)
                  terragrunt.hcl
                  iam-roles.hcl
                  s3-buckets.hcl
          example-dev/
            account.hcl
            aws-account-baseline/terragrunt.hcl
            aws-account-workloads/
              terragrunt.hcl
              iam-roles.hcl
              s3-buckets.hcl    no kms-keys.hcl: the cell has no key, so there is no fragment for one
            apps/
              orders-api/terragrunt.hcl
      govcloud/
        partition.hcl
        aws-identity-center/terragrunt.hcl
  .github/workflows/            PR validation and release trains: okta-* (dev -> prod, in the waves cells.py computes), azure-* (corp, then its subscriptions -> subsidiary), aws-* (commercial, then its accounts -> govcloud,
                                in the waves cells.py computes), plus automation-tests (the Pester suite on 5.1 with Pester 3.4.0 and 4.10.1, and on 7 with 4.10.1) and repo-lint (the tool tests, repo_lint, and cells on every pull request)
  scripts/                      PowerShell helpers to adopt an existing tenant, export drift, import live PIM eligibilities, and enforce the authentication methods policy
  tests/                        zero-change import gate: the rule; tools/plan_gate is the program
  tools/                        CI and repository tooling: Python 3.11+, standard library only, tested with pytest (docs/adr/0018)
    plan_gate/                  plan_gate.py: holds a plan's JSON to a profile (adoption, convergence, scoped-replace, report)
    repo_lint/                  repo_lint.py (the rules this README and the ADRs state, as checks) and cells.py (cell discovery, selection, and waves)
  docs/                         architecture diagrams and decision records
```

## Tooling

The workflows and the READMEs had grown logic of their own: plan arithmetic
in `jq`, cell discovery in shell, a release order restated once per train,
and a dozen rules about the repository that only a reader enforced. That
logic now lives in one place, `tools/`, as Python 3.11 or later with no
dependency outside the standard library, tested with pytest, and the
workflows call it ([ADR 0018](docs/adr/0018-ci-tooling-in-python.md)).

| Tool | What it does | Where it runs |
|------|--------------|---------------|
| `tools/plan_gate` | Holds a plan's JSON (`terragrunt show -json`) to a profile: `adoption` (every entry a no-op, importing or not, and the import count matching `imports.tf`), `convergence` (no change and no import), `scoped-replace` (only allowlisted addresses may change), or `report`. Counts a replace as one replace, lists drift apart from changes, names addresses and attributes and never a value. Exit 0 pass, 1 findings, 2 usage or input error. | After every pull request plan, `convergence` as a verdict in the step summary and the comment, and a red job on any import block, because `imports.tf` never rides in a pull request. `adoption`, the zero-change import gate of `tests/README.md`, on the workstation that holds `imports.tf`, at step 3 of adopting a tenant; a `workflow_dispatch` job for it is sketched in the tool's README and not written yet. `report` on every AWS release plan and on the merge-time plan the reviewer approves at the Okta and Azure gates |
| `tools/repo_lint/repo_lint.py` | Nine checks, each carrying the sentence of this README or an ADR it comes from: cell shape, fragment shape, locators, placeholders, ASCII, no secrets, README tables, runbook parameters, the ADR index | `repo-lint` on every pull request and push to `main` |
| `tools/repo_lint/cells.py` | Discovers the cells, selects the ones a change touches, and orders them into waves from the rules the trains state | `repo-lint` (every cell, so a cycle is caught early); the AWS and Okta release trains, whose plan and apply jobs run the waves it emits, and the Okta pull request workflow, which plans the cells it selects for a change |

The runbooks stay PowerShell because Azure Automation runs them: the line is
where the code runs, not a preference (ADR 0018).

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

**Three kinds of stack, and addressing lives in locator files.** The twelve
stacks above are platform stacks: every tenant of a family has a cell for
each, and the tenant's values are the only difference. The next requests were
not tenant-wide: one account needs a role a CI runner can assume, one
subscription needs a vault, one application needs a bucket, a key, and the
roles that use them, in two accounts. Rather than a `main.tf` in the account
or a `roles_by_account` map in a shared stack, the layout keeps the three
layers and the cell rule exactly as they are and drops the unstated assumption
that a stack is shared. A catalog stack (`aws-account-workloads`,
`azure-subscription-workloads`) offers a menu of vetted shapes as values, so
an account or a subscription gets a one-off role, key, bucket, identity, or
vault without anyone writing Terraform, with the guardrails in the modules
and one state file per cell. An app stack (`apps/aws/payments-api`,
`apps/azure/data-pipeline`) holds the composition one application needs when
the catalog cannot express it, with one cell per account or subscription it
is deployed in. The line is drawn twice: a shape leaves the catalog when it
needs cross-resource wiring a value cannot say, and a composition becomes an
app stack when it is needed in more than one place; the catalog offers
shapes, never passthrough policy documents or ARNs. Which account or
subscription a cell is in is addressing, not configuration: it lives in a
locator file in the tree (`partition.hcl`, `account.hcl`,
`subscription.hcl`), never in a cell's inputs, and the roots turn it into
provider configuration (`allowed_account_ids` and a per-account profile on
AWS, the `azurerm` subscription on Azure), so a cell still holds no ID and
cannot be re-aimed by editing a value. The AWS deployment role itself is in
no generated file, because a saved plan carries the generated provider and
the plan and apply environments name different roles; it is named in the
profile, which the workflow writes on the runner. See
[ADR 0017](docs/adr/0017-three-kinds-of-stack.md).

**Applications are catalog shapes with guardrails.** Onboarding an
application over SAML or OIDC is the everyday work of an identity engineer,
and `stacks/okta-applications` makes it an entry in a values-only fragment:
a cell says what the vendor's guide or the developer asks for (the ACS URL
and audience, the redirect URIs, the NameID format, the attribute
statements or the groups claim, the groups, the policy key) and three
modules carry the rest as shapes. What a cell cannot say is fixed and
stated in each module's README: SAML responses and assertions signed with
RSA-SHA256, https endpoints with no wildcard and no inline hook; an OIDC
app's grant and response types derived from its type, so the implicit flow
cannot be requested, PKCE on every redirect-based client, `private_key_jwt` on web
and service clients from a JWKS URI the cell supplies, refresh token
rotation, and `wildcard_redirect` disabled. No secret enters state by
construction: `omit_secret` is fixed true, so even a client that opts into
a shared secret with `allow_client_secret = true` has its secret minted by
Okta and read once from the console, never from a plan or an output. Groups
are named, never id'd, and are provisioned into Okta by the corp Entra
tenant as the upstream identity provider, so a name that does not exist
fails the plan rather than producing an app nobody can open. Sign-on
policies are tiers a cell picks by key (`standard-workforce`,
`admin-phishing-resistant`), the policy module creates every catch-all rule
with DENY so each path to ALLOW is a rule in the diff, and the stack
refuses an admin-tier app whose policy accepts a phishable factor on any
ALLOW rule. After apply, the `saml_vendor_onboarding` output holds the
entity id, SSO URL, metadata URL, and signing certificate a vendor
configures, and `oauth_client_ids` the client id a developer configures,
none of which is secret. See
[ADR 0020](docs/adr/0020-applications-are-catalog-shapes-with-guardrails.md).

**The Entra side has the same catalog, and the same vendor is onboarded
from either identity provider with the same values.**
`stacks/entra-enterprise-apps` is one values-only fragment of SAML service
providers, gallery or custom, and `modules/entra/saml-enterprise-app`
carries the shape: a cell says the entity id, the ACS and sign-on URLs, how
the subject is named, the claims as typed name and source pairs, who is
mailed before the signing certificate expires, and which groups open the
app through which app role. The module fixes what a cell cannot say:
assignment required, SAML as the sign-on mode, a signing key Entra
generates, the claims mapping policy rendered from the typed values so no
cell holds a JSON document, https endpoints with a host and no wildcard,
and a groups claim limited to the groups assigned to the application.
`tenants/azure/corp/entra-enterprise-apps/saml-apps.hcl` onboards the same
fictional payroll vendor as `tenants/okta/prod/okta-applications/saml-apps.hcl`,
with the same entity id, ACS URL, subject, and group names, so the vendor is
configured once and trusts either side (the attributes are each provider's
rendering of the vendor's guide: Okta sends `name` from `displayName`, Entra
sends `firstName` and `lastName`); and beside it a gallery
application (Google Workspace) shows the other kind, whose app roles are
the template's and whose provisioning connector is authorised by a console
consent Terraform cannot perform, stated rather than faked. After apply,
`vendor_onboarding` holds the issuer, the login and logout URLs, the
metadata URL, and the certificate thumbprint, all built from the provider's
tenant id and never typed. See
[ADR 0021](docs/adr/0021-entra-enterprise-applications-as-a-catalog-shape.md).

**Federation between the two identity providers is values and public keys.**
The two catalogs onboard applications into each provider; `stacks/okta-federation`
closes the loop between the providers themselves. The corp Entra tenant
becomes an upstream SAML identity provider for the Okta org (Entra asserts,
Okta is the service provider) and a routing rule on the org's identity
provider discovery policy sends workforce sign-ins, the usernames under the
corp domain, to it. The two sides exchange exactly three values and nothing
is typed from a console screen twice: the issuer and the signing certificate
come from Entra, and the audience and the ACS URL go back from the Okta
cell's `identity_provider_onboarding` output to that org's own application
in the corp `entra-enterprise-apps` cell (`okta-workforce` for prod,
`okta-workforce-dev` for dev: an Entra application carries one audience and
one reply URL, and Okta mints both per trust), which is why the
trust is built in two applies with one download between them (the stack
README gives the order). The certificate is the one file a cell carries
that is not `.hcl`: the identity provider's public signing certificate,
saved beside the cell as `entra-signing-<year>.cer` and read by the
fragment with `file()`, the one function call a cell's inputs may use to
reach outside the cell's own text (an inline value builder such as the AWS
identity center cell's `jsonencode` is a value, not an exception). It
is public key material, not a secret; the private half never leaves Entra,
and the module reads only the text between the `BEGIN` and `END` lines, so
the file can say where it came from above them. Rotation is a second file
and a flip of `active_certificate`, coordinated with Entra's "make
certificate active" step. What the cells cannot choose is fixed in the
modules: Okta signs every AuthnRequest with SHA-256, the identity
provider's signature is verified with at least SHA-256, endpoints are https
with no wildcard, and the routing target is SAML2. Provisioning defaults to
`DISABLED`, the same line `okta-config` draws (the directory of record
provisions users; just-in-time creation is opt-in). Account linking
defaults to `AUTO`, and `AUTO` has to be fenced: the module refuses it
unless the trust also carries the subject filter an asserted username must
match or the group whose members may be linked, because an unfenced `AUTO`
links any asserted subject to whichever Okta account matched it. The prod rule excludes the Okta Admin Console, and that
exclusion is the break-glass line: Okta administrators keep signing in to
Okta directly with the phishing-resistant factors `okta-config` enrolls, so
an Entra outage does not lock the org's administrators out; dev carries the
same rule without the exclusion, so the whole path, console included, is
proven before prod relies on it. Every zone, group, and application a cell
names is a name or a label resolved at plan, and the one value that looks
like an id, the issuer `https://sts.windows.net/<tenant id>/`, is the URL
Entra publishes as the `<Issuer>` of every response, not an Okta object id.
See
[ADR 0022](docs/adr/0022-upstream-identity-providers-are-values-and-public-keys.md).

**The container pair is the worked example of parity.** `apps/aws/orders-api`
and `apps/azure/orders-api` give one application everything a container
needs before it starts, and nothing it runs, in each cloud's own words: an
image registry, a runtime identity, an identity that pulls the image and
injects secrets at start-up, a publisher trusted by one GitHub environment
through OIDC that may push to this registry only, a secrets namespace, and
logs. The rows match one for one, the compute is deliberately not managed
because it changes on every release and belongs to the application's
pipeline, and where the clouds differ (a customer managed key on AWS, the
registry's platform encryption on Azure; a separate execution role on AWS,
the runtime identity holding AcrPull on Azure) the difference is stated
rather than papered over. See
[ADR 0019](docs/adr/0019-a-container-workload-identity-plane-on-both-clouds.md).

**A resource an application needs and that is not in its app stack goes
through one of two doors, and wiring decides which.** A resource nothing of
the application touches is a catalog cell of the application's own, under
its app cell (`apps/orders-api/catalog/`); a resource the application
consumes is an entry of the account catalog the application names from
its own side; only a resource that must itself name something the app
stack creates belongs in the app stack. The app-owned door is a cell of
the same catalog stack (`stacks/aws-account-workloads`) with its own state
file, and three rules make it: it holds only what the application alone
uses and its tags name the application's owner, so the catalog says who
every entry is for; it never names a resource the app stack creates; and
it declares a dependency on the account catalog, so a key or bucket of
the account's that it names by alias or by name exists first. Both doors
are committed for example-prod. The first is
`tenants/aws/commercial/accounts/example-prod/apps/orders-api/catalog/`:
the orders team's load-test harness (the role `orders-api-loadtest-runner`
and the bucket `orders-api-prod-loadtest-results`, `owner = orders`, which
no identity of the orders-api stack reads or writes), with an access-log
bucket of its own, because the catalog refuses a bucket that logs outside
its cell. The second is the data platform's `example-prod-reference-data`
bucket with its publisher role (`owner = data-platform`, no allow list) in
`tenants/aws/commercial/accounts/example-prod/aws-account-workloads/`, the
account catalog, because more than one application reads it; the read
side is
`tenants/aws/commercial/accounts/example-prod/apps/orders-api/terragrunt.hcl`,
which sets `reference_bucket_names = ["example-prod-reference-data"]`.
The direction of any reference between cells follows the release order:
within an account the baseline is applied first, then the catalog cells,
then the app stacks, so an app stack may name a catalog resource by name,
and a catalog entry never names a resource an app stack creates. The task
role's policy builds the bucket ARN from the partition and the name, so
nothing is looked up at plan and the wave order takes care of existence
at apply. The trap both examples teach is the reverse direction: a
catalog bucket whose allow list names the app's task role fails on the
first release, because the catalog is applied before the app exists,
whether that catalog cell sits beside the app or under the account. See
[ADR 0017](docs/adr/0017-three-kinds-of-stack.md).

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

**The repository lints its own rules, and a plan is gated by a program.**
The rules on this page are sentences, and a sentence is enforced by whoever
remembers it. `tools/repo_lint` turns eight of them into checks, each with
the sentence it comes from in its docstring, and runs on every pull request;
its first run found two runbook parameters the automation README had
excepted. `tools/plan_gate` reads a plan's JSON and holds it to a profile,
so the zero-change import gate is a program with one line per offending
address rather than a paragraph, a pull request plan that carries an import
block is a red job, and the plan a reviewer approves at a gate has already
been counted, replaces and drift included. `tools/repo_lint/cells.py` finds the cells and orders them
into waves, and the AWS and Okta release trains read that instead of listing
their cells. All three are Python 3.11 or later with no dependency outside the
standard library, because every runner has that and nothing else; the
runbooks stay PowerShell because Azure Automation runs them. See
[ADR 0018](docs/adr/0018-ci-tooling-in-python.md).

**Path is environment, via Terragrunt.** `tenants/okta/dev`,
`tenants/okta/prod`, `tenants/azure/corp`, `tenants/azure/subsidiary`,
`tenants/aws/commercial`, and `tenants/aws/govcloud` are the only places those
words appear. There is no
`environment` variable threaded through modules and no
`count = var.is_prod ? 1 : 0` anywhere. Adding a tenant is adding a directory.

**Tenant cells hold values only.** A tenant `terragrunt.hcl` has an include, a source,
and an `inputs` map. No resources, no data sources, no conditionals. Reviewers can
diff dev against prod and see exactly what is stricter in production and nothing else.
See [ADR 0002](docs/adr/0002-values-only-tenant-cells.md).

**State keys derive from the path.** Each `root.hcl` sets
`key = "<tree>/${path_relative_to_include()}/terraform.tfstate"`, so
`tenants/okta/prod/okta-config` writes `okta/prod/okta-config/terraform.tfstate` and
`tenants/azure/corp/azure-pim-governance` writes
`azure/corp/azure-pim-governance/terraform.tfstate`, and
`tenants/aws/govcloud/aws-identity-center` writes
`aws/govcloud/aws-identity-center/terraform.tfstate` into the GovCloud bucket.
An account cell is one level deeper and nothing else changes:
`tenants/aws/commercial/accounts/example-prod/aws-account-baseline` writes
`aws/commercial/accounts/example-prod/aws-account-baseline/terraform.tfstate`,
and the locator beside it plays no part in the key.
Nobody types a state key, so nobody can point two cells at the same one. The Okta
cells moved under `okta-config/` before any state was written, so their longer key
replaced nothing.

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
subsidiary gate opens. Both trains then carry the cells that are scoped to
one account or subscription (ADR 0017): the AWS train reads its cells and
their order from `tools/repo_lint/cells.py` and applies them in waves, the
Identity Center cell, then every account's baseline, then the catalogs, then
the app stacks, and the GovCloud gate waits for the last wave; the Azure
train still lists its cells and applies the corp subscription cells after
the corp tenant cells, baseline first because the other cells name the
workspace it creates, and the subsidiary gate waits for them too. The Okta
train reads `cells.py` the same way the AWS train does: dev's `okta-config`
cell applies before its `okta-applications` cell plans, because the
sign-on policy rules name zones the config cell creates; prod's config cell
is planned at merge time and its saved plan waits at the gate; and prod's
applications cell is planned fresh after the gate and applied under
`prod-apply` without a second approval, because the config cell it depends
on has just applied and a merge-time plan of it would be stale by
construction.

That ordering has a review cost worth stating: a pull request that introduces
a custom role **and** its first use shows a failing plan for the consuming
cell, because the role is resolved by name and does not exist until the roles
cell is applied on merge. The recommended practice is to land role definitions
in their own pull request first and use them in the next one; where that is not
practical, name the expected red plan in the pull request description.

## How to use it

Prerequisites: Terraform 1.9 or later and Terragrunt 0.77 or later. For the Okta
tree, an S3 bucket and DynamoDB table for state and an Okta API token with policy,
zone, application, and group-read scopes. For the Azure tree, a storage account and container for state with
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

cd tenants/okta/dev/okta-config
terragrunt init
terragrunt plan
```

The applications cell of the same org (`tenants/okta/dev/okta-applications`)
is the same commands after the config cell has applied, because its sign-on
policy rules name the zones that cell creates and the groups the corp Entra
tenant provisions; a name that does not exist yet fails the plan with the
name in the error.

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

A subscription cell needs the same environment and nothing more: under
`tenants/azure/corp/subscriptions/sub-example-prod/`, `root.hcl` reads the
subscription from `subscription.hcl` beside the cell and ignores
`ARM_SUBSCRIPTION_ID` for that cell, so the identity only has to hold the
roles the stack README lists at that subscription.

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

An account cell is the same commands from the cell's directory plus one
shared config profile per account. `root.hcl` generates
`profile = "identity-as-code-<account-name>"` for every cell under
`accounts/<account-name>/` and no `assume_role`, so the deployment role is
named in that profile on your workstation and never in a generated file
(docs/adr/0017 says why). Define it once per account, chained from the
session that reaches state:

```bash
aws configure set --profile identity-as-code-example-prod role_arn arn:aws:iam::111111111111:role/identity-as-code-deploy
aws configure set --profile identity-as-code-example-prod source_profile CHANGEME-identity-center-admin

cd tenants/aws/commercial/accounts/example-prod/aws-account-baseline
terragrunt init
terragrunt plan
```

The role name is the estate's; in CI it is `TG_AWS_DEPLOY_ROLE_NAME`, which
the `*-plan` environments set to the read-only deployment role and the apply
environments to the writer, and the workflow writes the same profile on the
runner from the cell's locators. An SSO profile that lands directly in the
account works too, under the same name. The state backend keeps using
`AWS_PROFILE`; only the provider uses the account's profile, so the
deployment role never needs the state bucket.

To adopt an existing tenant instead of creating policies from scratch:

1. Run `scripts/Import-OktaPolicies.ps1` against the tenant. It emits `imports.tf`
   and a `values.skeleton.hcl` you paste into the tenant cell.
2. Drop `imports.tf` into the cell directory (`tenants/okta/<tenant>/okta-config`).
   `root.hcl` picks it up automatically.
3. Plan, then hold the plan to the gate: `terragrunt show -json` and
   `tools/plan_gate/plan_gate.py adoption`. Adjust values until it is green: 0 to
   add, 0 to change, 0 to destroy, every import a no-op. `tests/README.md`
   describes the gate; it runs here, on the workstation, because `imports.tf` is
   ignored by git and never reaches a pull request.
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
- Okta authorization servers, scopes, claims, and token lifetimes (a later
  catalog); SWA, bookmark, and basic-auth apps; user profile mappings; and
  the apps' own provisioning of users and groups into the vendor. The
  applications stack creates SAML and OIDC apps and the policies in front of
  them, and stops there.
- On the Entra side: OIDC enterprise applications beyond app registrations
  (`modules/entra/app-registration` covers those), password-based single
  sign-on, linked applications, and the provisioning connectors' OAuth
  authorisations. The enterprise applications stack creates SAML
  applications, gallery or custom, with their certificates, claims, group
  assignments, and token-based provisioning, and stops there; a connector
  such as Google Workspace's is authorised once in the console, and the
  stack README shows the step.
- Between the two identity providers: OIDC upstream identity providers
  (`okta_idp_oidc`) and social identity providers in Okta; Okta as the
  upstream identity provider for Entra (the inverse direction, which Entra
  calls external identities or direct federation); and the Entra-side
  OAuth-consented provisioning connector of either `okta-workforce`
  application.
  The federation stack creates SAML identity providers, their keys, and
  the routing rules that send sign-ins to them, and stops there.
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
  environments, together with the two deployment roles every AWS account
  carries under the names the `*-plan` and apply environments give
  `TG_AWS_DEPLOY_ROLE_NAME` (the read-only one trusted only by the
  partition's plan OIDC role, the writer only by its apply OIDC role,
  neither with access to the state bucket) and the GitHub OIDC provider in
  accounts whose roles trust a repository. That is platform bootstrap and
  lives in a separate repository.
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

The Okta policy tree (`modules/okta/network-zone`, `session-policy`,
`mfa-policy`, `password-policy`, and `stacks/okta-config`) was written without a
Terraform binary. HCL was reviewed by hand for
syntax and provider attribute names against the okta/okta 4.x provider
documentation. Before first use, run `terraform validate` on each module and the
stack and confirm attribute names against the provider version you pin.

The Okta application catalog (`modules/okta/app-signon-policy`, `app-saml`,
`app-oauth`, `stacks/okta-applications`, and the two `okta-applications`
cells) was written with Terraform 1.16 available: every module and the stack
passes `terraform init -backend=false` and `terraform validate` against the
pinned provider (okta/okta 4.20.0, recorded in the committed
`.terraform.lock.hcl` files), and every attribute and block was checked
against that version's schema. The refusals were proven with `terraform
test` and a mocked Okta provider, one run per case: 24 runs on the policy
module (one accepted shape asserting the constraints JSON, the DENY
catch-all, the phishing-resistant fact, and the zone and group lookups, and
23 refusals each confirmed to fail on its own message), 30 on the SAML
module (two accepted shapes and 28 refusals), 30 on the OIDC module (one
catalog of five apps across all four types and 29 refusals, each also run
without `expect_failures` to read its message), and 8 on the stack (the full
composition of the worked examples, then an admin app on a standard policy
over SAML and over OIDC, an admin app with no policy, a missing policy key on
each map, and a label repeated within a map and across the two). Both cells
were rendered offline with `terragrunt render-json` to confirm the state key,
the `okta-config` dependency, and the five merged input keys. Those
harnesses are not committed. What only a live org can confirm: that the
provider applies `catch_all = false` on creation so the system rule is
created with DENY (the policy module README says to check it once after an
import), that a policy whose constraints JSON omits the `OPTIONAL` flags
shows no diff on the second plan, that `omit_secret` leaves the client
secret out of state on the first apply of a client that opted into one, and
that the group names the cells carry have been provisioned by the upstream
identity provider before the first plan.

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

The Entra application catalog (`modules/entra/saml-enterprise-app`,
`stacks/entra-enterprise-apps`, and the corp `entra-enterprise-apps` cell)
was written with Terraform 1.16 available: the module and the stack pass
`terraform init -backend=false` and `terraform validate` against the pinned
provider (azuread 3.9.0, recorded in the committed `.terraform.lock.hcl`
files), and every attribute and block was checked against that version's
schema. The refusals were proven with `terraform test` and a mocked azuread
provider, one run per case: 32 runs on the module (a gallery app planned,
asserting the `CN=` prefix on the certificate name, SAML mode, the gallery
tag, a NameID-only claims schema, and the tenant endpoints; a custom app
planned with provisioning, asserting two derived app roles, the groups
claim, the rendered claims schema, two assignments, and the job; the custom
app applied end to end; a gallery app applied against a mock that publishes
no `User` role, failing on the precondition with the published roles
listed; and 28 refusals each confirmed to fail on its own message) and 6 on
the stack (the composition of both worked examples with a mock that
publishes the gallery role, then a display name repeated with different
case, a reply URL and an entity id shared by two apps, and a provisioning
token for an app that does not provision and for an app that does not
exist). The cell was rendered offline with `terragrunt render-json` to
confirm the state key and the three merged input keys. Those harnesses are
not committed. One thing the stack harness found rather than confirmed: a
token merged into the module's map could not drive the synchronization
secret's `for_each`, because a token that arrives through the stack's
sensitive variable marks whatever map carries it, so a token-based connector
could not plan through the stack. The token is now its own sensitive input
on the module and on the stack (`provisioning_secret_tokens`, keyed by app)
rather than a field of the map, the secret iterates the apps whose
`provisioning` sets an endpoint or whose key has a token, and eight further
runs (seven on the module, one on the stack) prove it: a token through the
module's sensitive map plans, and applies, one secret with both credentials
and one job; a token alone, an endpoint alone, and a template alone each
write only what they have; the stack plans with the token; and a token for
an app without provisioning, or for an app that is not in the map, fails its
validation on the module as it does on the stack. What only a live tenant can
confirm: that the gallery template is found under the display name the cell
gives and publishes a `User` role (checked at apply on the first run of a
new gallery app, at plan afterwards), that the provider accepts the bare
host identifier the Google Workspace gallery entry requires as an identifier
URI, that the second plan of a gallery app shows no diff on its app roles, that the claims mapping policy
issues the mapped claims with the service principal's own signing key and
without `acceptMappedClaims`, that the groups claim carries display names,
and that the group names the cell carries exist before the first plan.

The federation pieces (`modules/okta/idp-saml`, `modules/okta/idp-routing-rules`,
`stacks/okta-federation`, the two `okta-federation` cells, and the
`okta-workforce` and `okta-workforce-dev` entries of the corp
`entra-enterprise-apps` cell) were
written with Terraform 1.16 available: both modules and the stack pass
`terraform init -backend=false` and `terraform validate` against the pinned
provider (okta/okta 4.20.0, recorded in the committed `.terraform.lock.hcl`
files), every attribute and block was checked against that version's
schema, and the meaning of each allowlisted value (subject match types,
provisioning and account-link actions, signature scopes, pattern match
types, user identifier types, network connections) was read from the
provider's registry pages and Okta's Identity Providers API reference and
cited where a value set is fixed. The refusals were proven with `terraform
test` and a mocked Okta provider, one run per case: 48 runs on the identity
provider module (four accepted shapes, one of them applied, asserting that
each key's `x5c` equals the armor-stripped base64 body computed
independently, that the identity provider's `kid` is the active entry's and
not the other, that comment lines above the `BEGIN` line leave the body
unchanged, and every fixed and defaulted attribute; and 44 refusals each
confirmed to fail on its own message), 36 on the routing module (one
accepted apply of two rules and 35 refusals), and 16 on the stack (the
composition of the worked cells under a mocked identity provider id,
asserting the trust-specific ACS URL, its `ORG` variant, the audience
pass-through, and the rule under its key; then a rule naming an identity
provider key that is not in the map, duplicate priorities and display
names, zone names on a non-`ZONE` rule, and the other cross-map refusals).
Both cells were rendered offline with `terragrunt render-json` to confirm
the state key, the `okta-config` dependency, the four merged input keys,
and that the rendered `signing_certificates` entry holds the certificate
file's text, comment lines and armor included; the corp Entra cell was
rendered the same way and carries four applications. The placeholder
certificate in each cell was generated with openssl (rsa:2048, ten years)
with its private key written to the null device, so no key ever existed on
disk, and the module's mocked plan read it through its comment lines. Those
harnesses are not committed. What only a live org can confirm: that the
`ADVANCED_SSO` feature is enabled, since the routing rule resource refuses
an org without it; that the org's discovery policy is found under the name
"Idp Discovery Policy" and the admin console under the label "Okta Admin
Console"; that the audience Okta computes and the ACS URL the stack builds
are what the Entra application accepts as identifier and reply URL, and
that the `thumbprint` output matches the Entra cell's certificate
thumbprint after the first apply; that a workforce sign-in routes through
Entra and an administrator's sign-in to the admin console does not; and
that a `max_clock_skew` of 120000 reads as two minutes in the console.

The account and subscription pieces (`modules/aws/iam-service-role`,
`kms-key`, `s3-bucket`, `account-hardening`, `cloudtrail`, `log-group`,
`ssm-parameter-namespace`, and `ecr-repository`; `modules/azure/resource-group`,
`managed-identity`, `key-vault`, `storage-account`, `container-registry`,
and `subscription-baseline`; the two baseline stacks, the two catalog
stacks, the four app stacks, and the locator handling in both roots) were
written the same way, with Terraform 1.16: every module and stack passes
`terraform init -backend=false` and `terraform validate` against the pinned
providers, the `payments-api` and `data-pipeline` stacks were planned
offline with `terraform test` and a mocked provider fed a cell's inputs
(the `orders-api` pair passed `validate` with each of its four cells'
inputs checked against the stack, and nothing more), and the roots' derived locals and
generated provider blocks were rendered through the HCL engine for an account
cell, a partition-wide cell, a subscription cell, a tenant-wide cell, and each
guard failure. The cells under `accounts/` and `subscriptions/` were checked
the same way: each cell's inputs, verbatim, against its stack with
`terraform validate`, and the AWS cells additionally through a mocked plan.
What only a real account or subscription can confirm: that each deployment
role trusts only its own environment's OIDC role, that the profile the
workflows write chains into the account the locator names (the step checks
with `sts:GetCallerIdentity` before Terragrunt runs), that
`allowed_account_ids` stops a mis-addressed plan before its first resource
API call, that the first apply of an account creates the trail's key,
bucket, and trail in that order, and the first-apply items each stack README
lists. No live account or subscription was used.

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
`windows-latest` three ways, Windows PowerShell 5.1 with the shipped Pester
3.4.0, Windows PowerShell 5.1 with Pester 4.10.1, and PowerShell 7 with Pester
4.10.1, which is where the PowerShell 7 paths and the Pester 4 mock mechanics
are covered.

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

The tooling layer (`tools/plan_gate`, `tools/repo_lint`) was written and run
here, against this tree, with Python 3.12: 80 plan_gate tests and
97 repo_lint and cells tests pass under pytest with no network and no
Terraform binary, `repo_lint.py --all` passes over every file (its first run
found the two `[string[]]` runbook parameters the automation README had
excepted, now semicolon strings like every other list, with Pester tests for
the parsers, and the Pester suite still passes under Windows PowerShell 5.1
with Pester 3.4.0), and `cells.py` finds the 33 cells in six waves (the
six Okta cells in four). What
only a run on GitHub can confirm: the matrix the AWS and Okta release trains
read from `cells.py`, the `fromJson` indexing of their wave jobs and the skip
rules between them (the Okta train's `jq` split of the waves was emulated in
Python against the real `cells.py` output, because `jq` was not on the
workstation), and the step summary and pull request comment the plan gate
writes; every workflow file parses as YAML and was reviewed by reading, not
run.

## License

MIT. See [LICENSE](LICENSE).
