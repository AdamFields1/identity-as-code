# Architecture

## Layers

```mermaid
flowchart LR
  subgraph modules["modules/okta (reusable, typed, validated)"]
    NZ[network-zone]
    SP[session-policy]
    MP[mfa-policy]
    PP[password-policy]
  end

  subgraph stack["stacks/okta-config (unit of deployment)"]
    S["composition\ngroup name -> ID\nzone key -> ID"]
  end

  subgraph tenants["tenants/okta (values only)"]
    R[root.hcl]
    DEV[dev/terragrunt.hcl]
    PROD[prod/terragrunt.hcl]
  end

  subgraph pipelines[".github/workflows"]
    PR[okta-pr-validation]
    REL[okta-release]
  end

  NZ --> S
  SP --> S
  MP --> S
  PP --> S
  S --> DEV
  S --> PROD
  R -.include.-> DEV
  R -.include.-> PROD
  DEV --> PR
  PROD --> PR
  DEV --> REL
  PROD --> REL
```

Dependencies only point one way. Modules know nothing about stacks. The stack knows
nothing about tenants. Tenants know nothing about pipelines. A change at any layer
is reviewed in the layer where it happens.

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

## Secrets and identity in CI

| Need | Mechanism | Lifetime |
|------|-----------|----------|
| Read/write state in S3 | GitHub OIDC -> `aws-actions/configure-aws-credentials` -> role from repo variable | Minutes |
| Talk to Okta | GitHub environment secret `OKTA_API_TOKEN` exposed as an env var to the provider | Job |
| Comment on PR | Workflow `GITHUB_TOKEN` with `pull-requests: write` | Job |

No credential is written to disk by the pipeline, and no credential lives in the
repository.
