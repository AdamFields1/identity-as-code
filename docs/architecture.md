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
    end
    subgraph mazure["modules/azure"]
      ARD[rbac-role-definition]
      APP[pim-role-policy]
      APE[pim-eligible-assignment]
    end
  end

  subgraph stacks["stacks (units of deployment, names resolved to IDs here)"]
    SO[okta-config]
    SEA[entra-app-registrations]
    SEC[entra-conditional-access]
    SEP[entra-pim-governance]
    SAR[azure-rbac-roles]
    SAP[azure-pim-governance]
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

  subgraph pipelines[".github/workflows"]
    OPR[okta-pr-validation]
    OREL[okta-release]
    APR[azure-pr-validation]
    AREL[azure-release]
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
  ARD --> SAR
  APP --> SAP
  APE --> SAP

  SO --> DEV
  SO --> PROD
  SEA --> CORP
  SEC --> CORP
  SEP --> CORP
  SAR --> CORP
  SAP --> CORP
  SEA --> SUB
  SEC --> SUB
  SEP --> SUB
  SAP --> SUB

  RO -.include.-> DEV
  RO -.include.-> PROD
  RA -.include.-> CORP
  RA -.include.-> SUB

  DEV --> OPR
  PROD --> OPR
  DEV --> OREL
  PROD --> OREL
  CORP --> APR
  SUB --> APR
  CORP --> AREL
  SUB --> AREL
```

Dependencies only point one way. Modules know nothing about stacks. Stacks know
nothing about tenants. Tenants know nothing about pipelines. A change at any layer
is reviewed in the layer where it happens.

Two things are deliberately absent from the diagram. `azure-rbac-roles` has no
edge to `azure-pim-governance`: the governance stack refers to custom roles by
display name and resolves them at plan time, so the coupling is a name, not an
output (ADR 0005). And `subsidiary/*` has no `azure-rbac-roles` cell, because the
subsidiary assigns built-in roles only.

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
| `tenants/azure/corp/entra-conditional-access` | `azure/corp/entra-conditional-access/terraform.tfstate` |
| `tenants/azure/subsidiary/azure-pim-governance` | `azure/subsidiary/azure-pim-governance/terraform.tfstate` |

Resource group, storage account, and container are `TG_AZ_STATE_RG`,
`TG_AZ_STATE_SA`, and `TG_AZ_STATE_CONTAINER`. The backend authenticates with the
Entra token (`use_azuread_auth`), so no storage key exists anywhere in the flow
(ADR 0004). Locking uses blob leases; there is no lock table.

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
names at plan time. The subsidiary plan is still taken at merge time, in parallel,
and applied unchanged after the `subsidiary` environment gate. Concurrency groups
are per cell (`azure-cell-corp-azure-pim-governance`), not per tenant, because two
cells of one tenant have separate state files and can safely run side by side.

## Secrets and identity in CI

| Need | Mechanism | Lifetime |
|------|-----------|----------|
| Read/write state in S3 | GitHub OIDC -> `aws-actions/configure-aws-credentials` -> role from repo variable | Minutes |
| Talk to Okta | GitHub environment secret `OKTA_API_TOKEN` exposed as an env var to the provider | Job |
| Read/write state in Azure Storage | GitHub OIDC -> `azure/login@v2` -> federated credential on an app or user-assigned identity; backend uses the Entra token (`use_azuread_auth`) | About an hour |
| Talk to Azure Resource Manager and Microsoft Graph | Same federated identity; `ARM_USE_OIDC=true` lets the providers do the token exchange themselves | About an hour |
| Comment on PR | Workflow `GITHUB_TOKEN` with `pull-requests: write` | Job |

The Azure identity is split by purpose and tenant. `AZ_CLIENT_ID`, `AZ_TENANT_ID`,
and `AZ_SUBSCRIPTION_ID` are repository variables that each GitHub environment
overrides: `corp-plan` and `subsidiary-plan` point at reader identities, `corp` and
`subsidiary-apply` at writers. No client secret exists for any of them.

No credential is written to disk by the pipeline, and no credential lives in the
repository.
