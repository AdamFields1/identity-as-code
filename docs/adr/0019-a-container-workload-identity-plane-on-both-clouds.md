# ADR 0019: A container workload's identity plane, as a matched pair on both clouds

Status: accepted
Date: 2026-09-20

## Context

The two app stacks ADR 0017 introduced, `apps/aws/payments-api` and
`apps/azure/data-pipeline`, each hold one application's composition in one
cloud, and each is built around an object store: a bucket the roles write
to, a lake the identity is granted on. The next application is a container.
It has no bucket. What it needs before it can start is a registry to pull
its image from, an identity to run as, an identity that pulls the image and
injects its secrets at start-up, an identity its release pipeline pushes
the image as, a place to put the secrets, a place to send the logs, and a
key where the cloud lets a customer hold one. What it needs after it starts
is compute, and the compute is a different kind of thing.

The compute (an ECS cluster, service, and task definition; a Container Apps
environment and app) changes on every release: a new image tag, a new
environment variable, a new replica count. It is owned and reviewed by the
people who own the application, on the application's cadence. The identity
plane changes rarely and is owned and reviewed by the people who own the
account or subscription, because it is what decides who may pull, who may
push, who may read a secret, and what an image is encrypted with. Managing
both in one stack would put a daily change and a permission-model change in
the same plan and the same approval, and would make the account owners the
reviewers of every deploy. Managing the compute from this repository at all
would also make the repository the application's deployment pipeline, which
it is not.

The application runs on both clouds. The two existing app stacks are
different applications with different shapes, so nothing in the repository
yet showed what "the same thing on both clouds" looks like when the clouds'
primitives do not line up one to one. A pair built for one application, row
by row, is the place to show it: where the shapes match, where they cannot,
and what is said about the gap.

## Decision

`stacks/apps/aws/orders-api` and `stacks/apps/azure/orders-api` are two app
stacks with the same shape, one application, everything a container needs
before it can start and nothing it runs. Names derive from `app_name`
(default `orders-api`) and `environment`; a cell says the environment, the
GitHub organization and repository the publisher trusts, a few knobs, and
tags. Row by row:

| Need | AWS | Azure |
|------|-----|-------|
| Image registry | ECR repository `<app>-<env>`: immutable tags, scan on push, encrypted with the application's key, two lifecycle rules (`modules/aws/ecr-repository`) | Container Registry `cr<app><env>`: admin user off, anonymous pull off, retention policy and network rules on Premium only (`modules/azure/container-registry`) |
| Runtime identity | ECS task role `<app>-<env>-task` | User-assigned identity `id-<app>-<env>`, assigned to the Container App by the application's own pipeline |
| Start-up identity | ECS task execution role `<app>-<env>-task-execution`: pulls the image, injects parameters | The runtime identity itself holds `AcrPull`; Container Apps has no separate start-up principal |
| Image publisher | Role `<app>-<env>-image-publisher`, trusted by one GitHub environment of one repository through OIDC, no branch; may push to this repository only | Identity `id-<app>-<env>-publisher` with one federated credential for one GitHub environment; `AcrPush` on this registry only |
| Secrets | SSM parameter namespace `/<app>/<env>/` under the application's key | Key Vault `kv-<app>-<env>`, the runtime identity as Key Vault Secrets User |
| Logs | Log group `/ecs/<app>/<env>` under the application's key | An existing Log Analytics workspace, named by the cell, receives the registry's and the vault's diagnostics |
| Key | One KMS key, alias `<app>-<env>`, users task and execution, service user CloudWatch Logs; the registry is encrypted with it | None: the registry and the vault use platform encryption |

Neither stack manages a bucket or a storage account, which is what
distinguishes the pair from `payments-api` and `data-pipeline`. Neither
manages the compute. Each stack's README ends with the fragment of a task
definition or a Container App that consumes the stack's outputs, as
documentation only, so the join between the two owners is written down
without being managed here.

The choices that are fixed rather than offered as knobs:

- **On AWS, tags are immutable and every image is scanned on push.** A tag
  names one image forever, so the task definition's reference means what it
  meant when it was reviewed; a finding is attached to the build that
  introduced it. Neither is a cell input. ACR has no registry-level tag
  immutability (repository locks are a data-plane setting the module does
  not write) and scanning there is Defender for Containers, a subscription
  plan rather than a registry property, so the Azure registry keeps tags
  mutable and the prod cell's retention policy covers the manifests a
  re-pushed tag leaves behind.
- **The AWS registry is under the application's customer managed key; the
  Azure registry is under platform encryption for now.** ECR takes a key ARN
  and creates its own grant, so the key that already encrypts the log group
  and the parameters encrypts the images too, and one key policy covers the
  application. A customer managed key on a Container Registry needs a key
  vault key, an identity with wrap and unwrap, and a rotation story, and is
  Premium only; that is a later change with its own plan, and the gap is
  stated rather than closed with a half-built version.
- **The Azure registry's knobs are Premium only, and the stack says so.** The
  IP allow list, the untagged-manifest retention period, and zone redundancy
  exist only on the Premium SKU. The stack passes `allowed_ip_ranges` to the
  registry only when the SKU is Premium (the vault gets it at every SKU), and
  refuses `registry_retention_days` on any other SKU at validate time, so a
  cell that asks for a Premium feature on a Standard registry fails with the
  variables' names rather than at the API.
- **The publisher trusts one GitHub environment, and nothing else.** On both
  clouds the publisher's federated trust is exactly one subject: one
  repository and one environment (`publisher_github_environment`, or
  `environment` by default). An environment is where the repository's own
  reviewers and protection rules sit, so the trust inherits them; a trust on
  a branch alone would be a trust on anyone who can push to it. The brief's
  "named branch and environment" cannot be expressed as a conjunction in
  either cloud's trust: a GitHub token's subject carries the ref or the
  environment, never both (unless the repository customises its subject
  claim, which this repository does not assume), so listing a branch beside
  the environment would make either subject sufficient on its own, and a job
  on that branch with no environment would assume the role without the
  environment's reviewers. The honest choices are environment-only or
  "either", and the pair chooses environment-only on both clouds; which
  branches may deploy to the environment is the environment's own
  deployment-branch rule on GitHub, set beside its reviewers. The AWS role
  module still offers a branch list for roles that want one; this stack does
  not pass it.
- **The AWS publisher pushes and does not deploy.** Its own policy is one
  statement, `ecr:GetAuthorizationToken`, because that is the one registry
  action a repository policy cannot grant; every action on the repository
  comes from the repository policy the registry module writes, scoped to
  that repository, and `BatchDeleteImage` goes to nobody. It holds nothing on
  ECS, nothing on IAM, and nothing on the key. Deploying (registering a task
  definition and updating the service) needs `iam:PassRole` on the task and
  execution roles, and a pipeline identity that can pass roles is a
  different trust decision, made by the account owners in a separate change
  when the application's pipeline is designed. The Azure publisher is the
  same: `AcrPush` on one registry, and no role on the Container App.

## Consequences

- **A second Azure subscription and six release train jobs.** The pair has a
  cell in `example-prod` and `example-dev` on AWS and in `sub-example-prod`
  and `sub-example-dev` on Azure, and `sub-example-dev` did not exist, so it
  arrives with its locator and its own `azure-subscription-baseline` cell,
  because the app cell names the workspace the baseline creates. The AWS
  cells land in wave 3 with no workflow edit, because `aws-release` reads
  its waves from `cells.py`. The Azure train still lists its cells (ADR
  0018), so it gains six jobs: plan and apply for the prod app cell, for
  the dev baseline, and for the dev app cell, with the dev baseline running
  beside the prod one and the subsidiary gate waiting for both app cells.
- **Premium is a cost, and the prod cell pays it.** The prod Azure cell
  raises the registry to Premium for the firewall and the retention policy;
  the dev cell stays on Standard with neither. A Premium registry costs
  several times a Standard one before any storage is counted, and the price
  buys the network posture, not the identity posture: every SKU refuses the
  admin user and anonymous pull and grants only by role assignment. A tenant
  whose registry is reached by identity alone should not raise the SKU for
  this stack's sake.
- **Network is out of scope.** Neither stack creates a VPC, a virtual
  network, a private endpoint, or a VPC endpoint. The Azure firewall admits
  the addresses a cell lists and otherwise the registry is reachable by
  identity from anywhere; the AWS repository has no network posture of its
  own beyond the repository policy. A private-endpoint or interface-endpoint
  posture is the change that needs a network, and it belongs with whoever
  manages one.
- **The compute is not managed, so the join is documentation.** The task
  definition fragment and the Container App fragment in the stack READMEs
  are the contract between the two owners. If the outputs they consume are
  renamed, the fragments must be updated by hand; nothing checks them.
- **What a first apply should confirm.** On AWS: the ECR grant on the key is
  created by the deploying identity, which needs `kms:CreateGrant`,
  `kms:RetireGrant`, and `kms:DescribeKey`; the account's GitHub OIDC
  provider exists before the first plan, because the role module reads it;
  and the shared-key precondition on the log group, which compares the
  repository's reported key to the stack's, is checked at apply on the first
  run because the ARN is unknown at plan. On Azure: a bare address in
  `allowed_ip_ranges` comes back from the vault API, and from the registry
  API on Premium, without a `/32` suffix; a Standard registry with no rule
  set written shows no diff on the computed `network_rule_set` after the
  first apply; and the workspace accepts the registry's two log categories
  and `AllMetrics` without a diff on `log_analytics_destination_type`. Each
  stack's README carries the same list with the module that owns it.
