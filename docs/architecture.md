# Architecture

## Layers

```mermaid
flowchart LR
  subgraph modules["modules (reusable, typed, validated)"]
    subgraph mokta["modules/okta"]
      NZ[network-zone]
      SP[session-policy]
      MP[mfa-policy]
      PP[password-policy]
    end
    subgraph mentra["modules/entra"]
      EAR[app-registration]
      ECA[conditional-access]
      ESG[security-group]
      EPP[pim-role-policy]
      EPE[pim-eligibility]
      EAI[aws-identity-center-app]
      EGG[graph-app-role-grant]
    end
    subgraph mazure["modules/azure"]
      ARD[rbac-role-definition]
      APP[pim-role-policy]
      APE[pim-eligible-assignment]
      AAC[automation-account]
      ARB[automation-runbooks]
    end
    subgraph maws["modules/aws"]
      WPS[permission-set]
      WAA[account-assignment]
    end
  end

  subgraph stacks["stacks (units of deployment, names resolved to IDs here)"]
    SO[okta-config]
    SEA[entra-app-registrations]
    SEC[entra-conditional-access]
    SEP[entra-pim-governance]
    SEF[entra-aws-federation]
    SAR[azure-rbac-roles]
    SAP[azure-pim-governance]
    SAA[azure-automation]
    SWI[aws-identity-center]
  end

  subgraph runbooks["automation/runbooks (PowerShell, published by the stack)"]
    RB1[Invoke-AppCredentialHygiene]
    RB2[Invoke-GuestLifecycle]
  end

  subgraph tokta["tenants/okta (values only)"]
    RO[root.hcl]
    DEV[dev]
    PROD[prod]
  end

  subgraph tazure["tenants/azure (values only, one cell per stack)"]
    RA[root.hcl]
    CORP[corp/*]
    SUB[subsidiary/*]
  end

  subgraph taws["tenants/aws (values only, one cell per partition)"]
    RW[root.hcl]
    COMM[commercial/*]
    GOVC[govcloud/*]
  end

  subgraph pipelines[".github/workflows"]
    OPR[okta-pr-validation]
    OREL[okta-release]
    APR[azure-pr-validation]
    AREL[azure-release]
    WPR[aws-pr-validation]
    WREL[aws-release]
  end

  NZ --> SO
  SP --> SO
  MP --> SO
  PP --> SO
  EAR --> SEA
  ECA --> SEC
  ESG --> SEP
  EPP --> SEP
  EPE --> SEP
  EAI --> SEF
  ARD --> SAR
  APP --> SAP
  APE --> SAP
  AAC --> SAA
  ARB --> SAA
  EGG --> SAA
  RB1 -.file.-> SAA
  RB2 -.file.-> SAA
  WPS --> SWI
  WAA --> SWI

  SO --> DEV
  SO --> PROD
  SEA --> CORP
  SEC --> CORP
  SEP --> CORP
  SEF --> CORP
  SAR --> CORP
  SAP --> CORP
  SAA --> CORP
  SEC --> SUB
  SEP --> SUB
  SAP --> SUB
  SWI --> COMM
  SWI --> GOVC

  RO -.include.-> DEV
  RO -.include.-> PROD
  RA -.include.-> CORP
  RA -.include.-> SUB
  RW -.include.-> COMM
  RW -.include.-> GOVC

  DEV --> OPR
  PROD --> OPR
  DEV --> OREL
  PROD --> OREL
  CORP --> APR
  SUB --> APR
  CORP --> AREL
  SUB --> AREL
  COMM --> WPR
  GOVC --> WPR
  COMM --> WREL
  GOVC --> WREL
```

Dependencies only point one way. Modules know nothing about stacks. Stacks know
nothing about tenants. Tenants know nothing about pipelines. A change at any layer
is reviewed in the layer where it happens.

Three things are deliberately absent from the diagram. `azure-rbac-roles` has no
edge to `azure-pim-governance`: the governance stack refers to custom roles by
display name and resolves them at plan time, so the coupling is a name, not an
output (ADR 0005). `subsidiary/*` has no `azure-rbac-roles`,
`entra-app-registrations`, `entra-aws-federation`, or `azure-automation` cell,
because the subsidiary assigns built-in roles only, registers no applications,
reaches AWS through corp groups, and has not had the runbooks rolled out. And
`entra-aws-federation` has no edge to `aws-identity-center`
even though one feeds the other: the coupling is the group name
`AWS-<PARTITION>-<accountId>-<PermissionSetName>`, listed in both cells and
resolved on each side at plan time (ADR 0008), not a cross-cloud dependency.

The runbooks are a fourth kind of input. They are not modules (a stack does
not call them) and not tenant values (a cell names a file, never a body); the
`azure-automation` stack reads each file and publishes it, so a runbook edit
is a plan diff like any other.

## Inside the stack

```mermaid
flowchart TB
  G["data okta_group (by name)"]
  Z["module network_zones"]
  S["module session_policy"]
  M["module mfa_policy"]
  P["module password_policy"]

  G -->|group IDs| S
  G -->|group IDs| M
  G -->|group IDs| P
  Z -->|zone IDs| S
  Z -->|zone IDs| M
  Z -->|zone IDs| P
```

Zones are created first because every policy rule with a network condition needs a
zone ID. Group IDs are resolved once and shared. Tenants refer to zones by logical key
and to groups by name, so no tenant file ever contains an Okta ID.

## Inside the Azure stacks

```mermaid
flowchart TB
  subgraph roles["stacks/azure-rbac-roles (cell 1)"]
    MG1["data azurerm_management_group (by display name)"]
    SB1["data azurerm_subscriptions (by display name)"]
    RD["module custom_roles\nazurerm_role_definition\nprevent_destroy"]
    MG1 -->|scope IDs| RD
    SB1 -->|scope IDs| RD
  end

  subgraph gov["stacks/azure-pim-governance (cell 2)"]
    AG["data azuread_group (approvers, by display name)"]
    MG2["data azurerm_management_group (by display name)"]
    SB2["data azurerm_subscriptions (by display name)"]
    RDD["data azurerm_role_definition (by name, at scope)"]
    EG["data azuread_group (eligible groups, by display name)"]
    POL["module pim_role_policy\nazurerm_role_management_policy"]
    ELG["module pim_eligible_assignment\nazurerm_pim_eligible_role_assignment"]
    AG -->|approver object IDs| POL
    MG2 -->|scope IDs| RDD
    SB2 -->|scope IDs| RDD
    RDD -->|role definition IDs| POL
    RDD -->|role definition IDs| ELG
    EG -->|principal IDs| ELG
    POL -.depends_on.-> ELG
  end

  RD -.role display name only.-> RDD
```

Policies are written before eligibilities because Azure validates an eligibility's
expiration against the policy at write time, and nothing in the eligibility resource
references the policy resource, so the graph needs an explicit `depends_on`. The
roles cell is applied before the governance cell plans because the role name is
resolved at plan time. Every scope, role, and group is given by name in the tenant
cell, so no cell ever contains a GUID or a management group ID.

## Inside the automation stack

```mermaid
flowchart TB
  subgraph auto["stacks/azure-automation (one cell per tenant)"]
    RG["data azurerm_resource_group (by name)"]
    UAI["module automation_account\nazurerm_user_assigned_identity"]
    AA["module automation_account\nazurerm_automation_account\n+ variables"]
    FILES["automation/runbooks/*.ps1\nfile() + filesha256()"]
    RBK["module runbooks\nazurerm_automation_runbook\nazurerm_automation_schedule\nazurerm_automation_job_schedule"]
    GSP["data azuread_service_principal\n(Microsoft Graph, app_role_ids by name)"]
    GRANT["module graph_grants\nazuread_app_role_assignment"]
    RG --> UAI
    RG --> AA
    UAI -->|identity_ids| AA
    AA -->|account name, location| RBK
    UAI -->|client_id into every job schedule as clientid| RBK
    FILES -->|content| RBK
    UAI -->|principal_id| GRANT
    GSP -->|role IDs| GRANT
  end

  subgraph run["at run time (Azure Automation sandbox)"]
    JOB["job: runbook + schedule parameters\n(dryrun, environment, sendermailbox, clientid, thresholds, caps)"]
    IDE["Automation identity endpoint\ntoken for Graph with client_id"]
    GRAPH["Microsoft Graph\n(global or US Government)"]
    JOB --> IDE --> GRAPH
  end

  RBK -.schedule fires.-> JOB
  GRANT -.what the token may do.-> GRAPH
```

The account and its identity come first because both leaves key off them: the
runbooks module needs the account name and location, and the Graph grants need
the identity's principal ID. The identity's client ID is the one value a cell
cannot know and every runbook needs, so the stack injects it into every job
schedule's parameters along with the cloud, the sender mailbox, and the dry-run
flag; a cell states those once and cannot give two runbooks different answers.
The runbook body is the file in the repository, hashed into a tag so the plan
and the portal both show the deployed revision. What the identity may do is a
list of Graph permission names in the cell (ADR 0010); where a guest is on the
lifecycle ladder is a group membership the runbook resolves by display name
(ADR 0011).

## Across the two clouds: Entra to Identity Center

```mermaid
flowchart LR
  subgraph corp["tenants/azure/corp/entra-aws-federation (one cell)"]
    GL["aws_groups\nAWS-COM-111111111111-PlatformAdmin\nAWS-COM-222222222222-PowerUser\nAWS-GOV-111111111111-PlatformAdmin\nAWS-GOV-333333333333-ReadOnly"]
    AGC["data azuread_group (by display name)"]
    APPC["module identity_center[commercial]\ngallery app, SAML, cert,\napp role assignments, SCIM job"]
    APPG["module identity_center[govcloud]\ngallery app, SAML, cert,\napp role assignments, SCIM job"]
    GL -->|AWS-COM-*| APPC
    GL -->|AWS-GOV-*| APPG
    AGC --> APPC
    AGC --> APPG
  end

  subgraph comm["tenants/aws/commercial/aws-identity-center"]
    ISC["data aws_identitystore_group (by DisplayName)"]
    PSC["module permission_sets\naws_ssoadmin_permission_set + attachments"]
    AAC["module account_assignments\nparse name -> account, set\naws_ssoadmin_account_assignment"]
    ISC --> AAC
    PSC -->|ARNs by name| AAC
  end

  subgraph gov["tenants/aws/govcloud/aws-identity-center"]
    ISG["data aws_identitystore_group (by DisplayName)"]
    PSG["module permission_sets\npartition from data aws_partition"]
    AAG["module account_assignments\nrejects AWS-COM-* here"]
    ISG --> AAG
    PSG -->|ARNs by name| AAG
  end

  APPC -.SCIM, same display names.-> ISC
  APPG -.SCIM, same display names.-> ISG
```

The Entra cell lists every AWS access group once; the stack hands each
Identity Center application the groups whose partition token matches. Being
assigned to the application is what provisions a group, over SCIM, into that
instance's identity store. The AWS cell for the same instance lists the same
names and parses each into one account assignment. The two cells are in
different trees with different state backends and different credentials, and
nothing passes between them at plan time; the group name is the whole contract,
checked on both sides (ADR 0008). The identity source switch and the SCIM
enablement in the AWS console are manual and one-shot, and the module README
gives the order.

## State key scheme

`tenants/okta/root.hcl` derives the key from the tenant's path:

```
key = "okta/${path_relative_to_include()}/terraform.tfstate"
```

| Tenant directory | State key |
|------------------|-----------|
| `tenants/okta/dev` | `okta/dev/terraform.tfstate` |
| `tenants/okta/prod` | `okta/prod/terraform.tfstate` |
| `tenants/okta/sandbox` (future) | `okta/sandbox/terraform.tfstate` |

Bucket, region, and lock table are environment variables (`TG_STATE_BUCKET`,
`TG_STATE_REGION`, `TG_LOCK_TABLE`), never HCL literals. The same repository can be
planned from a laptop and from CI against different state backends with no edits.

`tenants/azure/root.hcl` does the same against Azure Storage, one level deeper
because each tenant holds one cell per stack:

```
key = "azure/${path_relative_to_include()}/terraform.tfstate"
```

| Cell directory | State key |
|----------------|-----------|
| `tenants/azure/corp/azure-rbac-roles` | `azure/corp/azure-rbac-roles/terraform.tfstate` |
| `tenants/azure/corp/azure-pim-governance` | `azure/corp/azure-pim-governance/terraform.tfstate` |
| `tenants/azure/corp/azure-automation` | `azure/corp/azure-automation/terraform.tfstate` |
| `tenants/azure/corp/entra-conditional-access` | `azure/corp/entra-conditional-access/terraform.tfstate` |
| `tenants/azure/subsidiary/azure-pim-governance` | `azure/subsidiary/azure-pim-governance/terraform.tfstate` |

Resource group, storage account, and container are `TG_AZ_STATE_RG`,
`TG_AZ_STATE_SA`, and `TG_AZ_STATE_CONTAINER`. The backend authenticates with the
Entra token (`use_azuread_auth`), so no storage key exists anywhere in the flow
(ADR 0004). Locking uses blob leases; there is no lock table.

`tenants/aws/root.hcl` is S3 again, with its own variable names because the bucket
is per partition rather than shared with the Okta tree:

```
key = "aws/${path_relative_to_include()}/terraform.tfstate"
```

| Cell directory | State key | Bucket |
|----------------|-----------|--------|
| `tenants/aws/commercial/aws-identity-center` | `aws/commercial/aws-identity-center/terraform.tfstate` | commercial `TG_AWS_STATE_BUCKET` |
| `tenants/aws/govcloud/aws-identity-center` | `aws/govcloud/aws-identity-center/terraform.tfstate` | GovCloud `TG_AWS_STATE_BUCKET` |

`TG_AWS_STATE_BUCKET`, `TG_AWS_STATE_REGION`, and `TG_AWS_LOCK_TABLE` are set per
GitHub environment, because a GovCloud identity cannot reach a commercial bucket
and the reverse. The keys do not collide, so the two could share a bucket if the
partitions ever did (ADR 0009). Locking is DynamoDB because the repository allows
Terraform 1.9, which predates the S3 lock file.

## Promotion flow

```mermaid
sequenceDiagram
  participant Dev as Engineer
  participant PR as okta-pr-validation
  participant Main as main branch
  participant Rel as okta-release
  participant Gate as prod environment (reviewers + wait timer)
  participant Okta as Okta tenants

  Dev->>PR: open pull request
  PR->>PR: fmt, tflint, checkov, validate
  PR->>Okta: terragrunt plan (changed tenants, read-only token)
  PR-->>Dev: plan summary as PR comment + artifact
  Dev->>Main: merge
  Main->>Rel: push event
  par at merge time
    Rel->>Okta: plan dev
    Rel->>Okta: plan prod (artifact saved)
  end
  Rel->>Okta: apply dev
  Rel->>Gate: soak gate waits
  Gate-->>Rel: human approval after wait timer
  Rel->>Okta: apply prod from the merge-time plan artifact
  Note over Rel,Okta: stale plan (state moved) is refused, release is re-run
```

Two properties matter here:

1. Prod applies the plan file that was produced when the change merged, not a fresh
   plan taken after approval. What the reviewer approved is what runs.
2. Every tenant has its own concurrency group. A PR plan and a release apply for the
   same tenant never overlap, so state locks are never contested by the pipeline
   itself.

`azure-release` has the same shape with corp in the dev position and subsidiary in
the prod position, and one extra rule: the corp roles cell is applied before the
corp governance cell is planned, because the governance cell resolves custom role
names at plan time. The corp automation cell is planned and applied after the
governance cell, not because anything is resolved from it but so that corp is
completely applied before the gate opens; the gate needs both applies. The
subsidiary plan is still taken at merge time, in parallel, and applied unchanged
after the `subsidiary` environment gate. Concurrency groups are per cell
(`azure-cell-corp-azure-pim-governance`), not per tenant, because two cells of
one tenant have separate state files and can safely run side by side. A change
under `automation/runbooks` triggers the train like a module change, because the
runbook body is what the automation cell publishes.

`aws-release` has the same shape with commercial in the dev position and GovCloud
in the prod position. Each job names its GitHub environment, and the environment
supplies that partition's OIDC role and state bucket, so the two halves of the
train never hold a credential that works in the other partition. The federation
cell on the Azure side is not in any release train yet: the Azure workflows do
not map the SCIM credentials into `TF_VAR_scim_credentials`, and until they do
that cell is applied from a workstation (ADR 0008).

## Secrets and identity in CI

| Need | Mechanism | Lifetime |
|------|-----------|----------|
| Read/write state in S3 | GitHub OIDC -> `aws-actions/configure-aws-credentials` -> role from repo variable | Minutes |
| Talk to Okta | GitHub environment secret `OKTA_API_TOKEN` exposed as an env var to the provider | Job |
| Read/write state in Azure Storage | GitHub OIDC -> `azure/login@v2` -> federated credential on an app or user-assigned identity; backend uses the Entra token (`use_azuread_auth`) | About an hour |
| Talk to Azure Resource Manager and Microsoft Graph | Same federated identity; `ARM_USE_OIDC=true` lets the providers do the token exchange themselves | About an hour |
| Read/write state in S3 and talk to Identity Center, per partition | GitHub OIDC -> `aws-actions/configure-aws-credentials` -> role from the partition's environment variables (`AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`) | Minutes |
| Provision users and groups into Identity Center | SCIM endpoint and token issued by the AWS console, held as a GitHub environment secret, passed as the sensitive `TF_VAR_scim_credentials`; stored by the provider in state and in saved plans, rotated from the AWS console | Until rotated |
| Run scheduled identity hygiene against Graph (outside CI) | User-assigned managed identity on the Automation account, created by Terraform; Graph app roles granted by Terraform; each job asks the Automation identity endpoint for a token with the identity's `client_id` | About an hour, per job |
| Comment on PR | Workflow `GITHUB_TOKEN` with `pull-requests: write` | Job |

The Azure identity is split by purpose and tenant. `AZ_CLIENT_ID`, `AZ_TENANT_ID`,
and `AZ_SUBSCRIPTION_ID` are repository variables that each GitHub environment
overrides: `corp-plan` and `subsidiary-plan` point at reader identities, `corp` and
`subsidiary-apply` at writers. No client secret exists for any of them.

The AWS identity is split by purpose and partition the same way. `AWS_PLAN_ROLE_ARN`
and `AWS_APPLY_ROLE_ARN` are repository variables that each GitHub environment
overrides: `commercial-plan` and `govcloud-plan` point at reader roles, `commercial`
and `govcloud-apply` at writers, and the GovCloud ones are `arn:aws-us-gov` roles in
the GovCloud delegated administrator account.

No credential is written to disk by the pipeline, and no credential lives in the
repository.
