# stacks/apps/aws/orders-api

The deployable unit for one deployment of the orders API in one account:
everything a container needs before it can start, and nothing it runs. It
composes five modules into one plan and one state file:

1. `kms-key` creates the application's key, with the task and execution
   roles as users and CloudWatch Logs as a service user.
2. `iam-service-role` creates three roles: the task role and the task
   execution role, both trusting ECS tasks of this account and nothing else,
   with policies scoped to the parameter namespace; and the image publisher
   role, trusting one deployment environment of one GitHub repository
   through OIDC, with the one registry action a repository policy cannot
   grant.
3. `ecr-repository` creates the image repository, encrypted with the key,
   with immutable tags, scanning on push, two lifecycle rules, and a
   repository policy that lets the execution role pull and the publisher
   push.
4. `log-group` creates the CloudWatch log group, encrypted with the key, with
   retention.
5. `ssm-parameter-namespace` reserves `/<app>/<env>/` with one SecureString
   placeholder under the key, whose value is never a secret.

Every resource block is in `modules/aws`; this stack holds the names, the
policies, and the wiring, which is the layer rule the repository README
states under "Three layers".

There is no bucket. An API's artifact is its image, and the image lives in
the repository this stack creates; `payments-api` is the sibling stack for
an application that also reads and writes objects. The compute (the ECS
cluster, service, and task definition) is not managed here either: the
application's deployment pipeline owns it, changes it on every release, and
reads this stack's outputs to write it. The stack is the part that changes
rarely and is reviewed by the people who own the account; the task
definition is the part that changes daily and is reviewed by the people who
own the application. The final section shows the fragment that joins them.

Tenant cells under `tenants/aws/<partition>/accounts/<account-name>/apps/orders-api/`
point at this stack and provide values only: the environment name, the
GitHub organization and repository whose pipeline publishes the image, the
retention knobs, and tags. There is one cell per account the application is
deployed in, and the same stack deploys to the commercial and GovCloud
partitions because nothing in it names a partition, an account, or a region.
See [ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md).

## Why an app stack and not five catalog entries

ADR 0017 draws the line: a shape leaves the catalog when it needs
cross-resource wiring the catalog cannot express. This application needs
four such references, each to something created in the same plan:

- The key policy names the task and execution roles as users, and CloudWatch
  Logs as a service user, so the log group can be encrypted with it.
- The repository policy names the execution role under `AllowPull` and the
  publisher under `AllowPush`, and the repository's encryption names the key
  by ARN.
- The task and execution roles' inline policies name the parameter namespace
  by ARN.
- The log group and the placeholder parameter both name the key, by the key
  module's outputs.

As catalog cells, the roles cell would apply first; then the key cell, whose
policy names the roles; then a registry cell, whose repository policy would
carry the role names typed a second time and whose key would be an ARN typed
into the cell, which is exactly the value
[ADR 0002](../../../../docs/adr/0002-values-only-tenant-cells.md) keeps out
of cells: three releases in a fixed order, and the log group and the
namespace would have no cell at all, because a log group's key is a
key-policy grant and a parameter namespace is only meaningful next to the
policy that grants it. Here every name derives from `app_name` and
`environment` once, the graph orders the creation, and the cell says five
values.

The reverse test in ADR 0017 also holds: none of this is one resource with
knobs, so nothing here goes back into the catalog. The composition is the
kind that is needed once per account the application runs in, which is what
makes it a stack rather than a longer catalog entry. A second account would
be a second cell of the same stack with its own values.

## The model

```
  cell: environment, github organization and repository, retention, tags
          |
          v
  key  alias/<app>-<env> --------------------> log group /ecs/<app>/<env>
   |    users: task, execution                 (encrypted with the key, retention)
   |    service user: logs
   |------------------------------------------> parameter /<app>/<env>/placeholder
   |                                            (SecureString under the key,
   v                                             value never a secret)
  repository <app>-<env>
   KMS with the key; immutable tags; scan on push; keep N, expire untagged
   repository policy: AllowPull execution, AllowPush publisher, delete nobody
          ^                              ^
          | pull                         | push (and pull)
  execution role <app>-<env>-task-execution   publisher <app>-<env>-image-publisher
   trust: ecs-tasks, this account              trust: GitHub OIDC, one repository,
   AmazonECSTaskExecutionRolePolicy                   one environment, no branch
   + ssm: get under /<app>/<env>/              inline: ecr:GetAuthorizationToken on *
                                               (nothing else; push is on the repository)
  task role <app>-<env>-task
   trust: ecs-tasks, this account
   inline: ssm: get under /<app>/<env>/
```

The task role is what the application's code runs as; the execution role is
what the ECS agent uses to pull the image, inject parameters as container
secrets, and ship logs before the container starts. Neither carries a KMS
statement: the key policy grants both roles directly, which is sufficient on
its own and keeps the key's ARN, unknown until the key exists, out of a
document the role module validates at plan time. Both trusts carry
`aws:SourceAccount` for this account, which the role module writes for every
`ecs-tasks` trust.

The publisher is the third identity and the only one that can write to the
repository. Its trust is exactly one subject: one GitHub repository's token
from a job in one deployment environment (the one named by
`publisher_github_environment`, or `environment` by default), through the
account's existing OIDC provider; no secret exists anywhere, and the
`image_publisher_trust_subject` output prints the string the trust matches.
No branch is trusted. A GitHub token's subject carries the ref or the
environment, never both, so a branch subject listed beside the environment
would not be a second condition a job has to meet but a second subject that
is enough on its own, and a job on that branch with no environment would
assume the role without the environment's reviewers. Which branches may
deploy to the environment is the environment's deployment-branch rule on
GitHub, where the reviewers and the branch rule are set together. Its own policy
is one statement, `ecr:GetAuthorizationToken` on `*`, because that is a
registry action evaluated against the caller and not against any
repository, so it cannot be scoped and cannot be granted by a repository
policy. Every action the role takes on the repository (the layer uploads and
`PutImage`) is granted by the repository policy the registry module writes,
scoped to this one repository; `BatchDeleteImage` is granted to nobody,
because expiring images is the lifecycle policy's job and a publisher that
can delete can erase the image a task is running. The publisher is not a
user of the key: ECR encrypts and decrypts layers under the grant it creates
for the repository's creator, so a role that pushes needs nothing on it.

The execution role is listed under `AllowPull` in the repository policy,
which is what a task definition that names this repository relies on. The
AWS managed execution policy also carries the pull actions on `*`, so the
grant is stated twice; the repository policy is the one that is reviewed
next to the repository, and the one that would still hold if the managed
policy were ever replaced with a scoped one.

`environment` is a name segment and, for the publisher's trust, the default
GitHub environment. No resource in this stack is conditional on it and no
module receives it; it appears in names because ECS, ECR, SSM, and
CloudWatch Logs need one namespace per deployment of the application, and
the account name is not always that.

## What this stack refuses

- An `app_name` outside 3 to 25 lowercase letters, digits, and single
  hyphens, or an `environment` outside 1 to 12 lowercase letters and digits.
  The bounds keep every derived name inside the IAM limit with the longest
  suffix, `-image-publisher`, added, and inside the ECR naming rules.
- A `github_organization` or `github_repository` outside GitHub's own naming
  rules, and a `publisher_github_environment` that is empty or carries `*`
  or `?`; the role module refuses a wildcard in any subject a second time.
- An `image_retention_count` outside 1 to 1000, or an
  `untagged_image_expiry_days` outside 1 to 365; there is no value for
  "keep everything". The stack checks both first and the registry module
  checks them again.
- A `log_retention_days` that CloudWatch Logs does not accept, including 0
  (never expire). The stack checks it first and the log-group module checks
  it again.
- `Application` or `Environment` in `tags`; the stack derives both from the
  naming variables so the tags cannot disagree with the names.
- From the modules: a wildcard in a trust policy, an inline statement that
  allows `*` or an IAM write on `*`, a policy ARN where a name is expected,
  a repository name outside the ECR rules, an alias with the `alias/`
  prefix, a service not on the key's allowlist, a parameter prefix outside
  the SSM rules, a repository, a log group, or a placeholder with no
  customer managed key, and a rendered repository policy that grants
  `ecr:BatchDeleteImage`.
- A repository and a log group under different keys, or a task role policy
  that no longer covers the parameter namespace (both preconditions on the
  stack's `log_group_name` and `parameter_prefix` outputs, with the reason
  in the message).
- A destroy of the key, the repository, the log group, or the placeholder
  parameter without lifting `prevent_destroy` in the owning module in a
  dedicated change. The roles are not `prevent_destroy`; a role is recreated
  from code in seconds and holds nothing.

## Nothing is looked up, and the roles come first

Unlike `payments-api`, no module in this stack resolves a name with a data
source at plan time, so there is no `depends_on` and no `(known after
apply)` on a policy. Three orderings still matter, and each is a reference
rather than a `depends_on`, because a reference through a module output
orders resources without deferring the referencing document to apply, so
every plan shows every policy in full:

- The key policy names the task and execution roles by constructed ARN, and
  KMS checks they exist when the policy is written, so the key module is
  handed the role names from the roles module's output. The string is the
  same one the locals hold; the reference is what creates the roles first.
- The repository policy names the execution role and the publisher by
  constructed ARN, and ECR validates every principal when the policy is
  written, so the registry module takes the two names from the roles
  module's output the same way.
- The repository, the log group, and the placeholder take the key's ARN or
  id from the key module's outputs, which creates the key before all three.

The one plan-time read is inside the role module: the account's GitHub OIDC
provider (`token.actions.githubusercontent.com`) is looked up because the
publisher trusts it. Nothing in this repository creates it: it is platform
bootstrap, created once in every account whose roles trust a GitHub
repository, and lives in the separate bootstrap repository with the state
buckets and the deployment roles (repository README, "Deliberately out of
scope"). An account without it fails the first plan of this stack with the
provider's URL in the error, and the fix is in that repository, not in this
stack or the account baseline. The shared-key
precondition on `log_group_name` compares the repository's reported key
with the key module's ARN, which is unknown until the key exists, so it is
checked at apply on the first run and at plan on every run after.

## What the deploying identity needs

The deployment role the account cell's provider runs as
(`TG_AWS_DEPLOY_ROLE_NAME` in CI, through the profile
`identity-as-code-<account-name>`; ADR 0017) needs, beyond the IAM, KMS,
and tagging permissions any of the catalog stacks need:

- For the log group and the namespace, as `payments-api`:
  `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:AssociateKmsKey`,
  `logs:TagResource`, `ssm:PutParameter`, `ssm:GetParameter`,
  `ssm:AddTagsToResource`, and `kms:Encrypt` on the application's key,
  because creating a Standard SecureString parameter encrypts the
  placeholder value with it.
- For the repository: `ecr:CreateRepository`, `ecr:DescribeRepositories`,
  `ecr:PutImageTagMutability`, `ecr:PutImageScanningConfiguration`,
  `ecr:PutLifecyclePolicy`, `ecr:GetLifecyclePolicy`,
  `ecr:DeleteLifecyclePolicy`, `ecr:SetRepositoryPolicy`,
  `ecr:GetRepositoryPolicy`, `ecr:DeleteRepositoryPolicy`,
  `ecr:ListTagsForResource`, `ecr:TagResource`, and `ecr:UntagResource`
  (`ecr:DeleteRepository` only in the dedicated change that lifts
  `prevent_destroy`), and, on the application's key, `kms:CreateGrant`,
  `kms:RetireGrant`, and `kms:DescribeKey`, because ECR creates a grant on
  the key on behalf of whoever creates the repository, as the registry
  module's README says.
- For the publisher's trust: `iam:GetOpenIDConnectProvider`, because the
  role module reads the account's GitHub provider at plan.

The key's root statement is what lets the role's IAM policy grant the
`kms:` actions; nothing in the key policy names the deploying role, and it
is neither a puller nor a pusher, so it manages the repository and cannot
read a layer, which is the intended split. The read-only role that plans
pull requests needs the read forms only, including `ecr:DescribeRepositories`,
`ecr:GetLifecyclePolicy`, `ecr:GetRepositoryPolicy`,
`ecr:ListTagsForResource`, `iam:GetOpenIDConnectProvider`, and
`ssm:GetParameter` on the placeholder.

## The parameter namespace and state

The placeholder is the only parameter this stack declares, and the rule is
one sentence: the placeholder must never hold a real value. The provider
reads a parameter back decrypted on every refresh, so whatever the
placeholder holds at refresh time lands in state and in the prior state of
every plan artifact, where the read-only identity that plans pull requests
can read it. The application's real secrets are siblings under the same
prefix, written by the secrets process; this stack neither declares nor
reads them, so no secret passes through a plan, a cell, or a commit.
`ignore_changes` on the value exists so an accidental overwrite of the
placeholder is not reverted by the next plan (which would put the value in
front of every reviewer of that plan), and for no other reason;
`prevent_destroy` means a map edit never deletes it. If a real value is ever
written into the placeholder, rotate it and overwrite the placeholder with
`placeholder` again (`modules/aws/ssm-parameter-namespace`).

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "aws"` block
is generated by Terragrunt (`tenants/aws/root.hcl`) with `region = var.region`
from the partition locator, `allowed_account_ids` from the account locator,
and `profile = "identity-as-code-<account-name>"`, the profile in which the
account's deployment role is named on the runner or the workstation. No
role ARN is in the generated file: a saved plan carries the file, and the
plan and apply environments name different roles. A plan whose credentials
land in any other account stops before its first resource API call. In CI
the workflow writes the profile from the locators just before Terragrunt
runs; locally it is one an engineer defines once per account (repository
README, "How to use it"). Nothing is typed into a cell.

## The cell

`tenants/aws/commercial/accounts/example-prod/apps/orders-api/terragrunt.hcl`,
without its header comment:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/aws/orders-api"
}

inputs = {
  environment                  = "prod"
  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "production"
  image_retention_count        = 30
  untagged_image_expiry_days   = 7
  log_retention_days           = 365

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
```

No region (the partition locator supplies it), no account id (the account
locator supplies it and the stack discovers it), no ARN, no name any other
resource repeats. `app_name` defaults to `orders-api` because the stack is
this application's; a cell may set it, and a fork of the stack for another
application changes one default. The GitHub organization and repository
are the one thing a cell says that is not a name in this account: they are
the identity of the pipeline the account trusts to publish, and they are
values, not IDs. `publisher_github_environment` names the repository's
`production` environment because that environment is not called `prod`,
the deployment's name; a cell whose GitHub environment shares its
deployment's name may omit the input, and the trust subject is then
`repo:example-org/orders-api:environment:prod`. The two registry knobs are
written out at their defaults (30 images, 7 days) so the dev cell's smaller
values read as a difference and not as an omission. The dev cell in
`example-dev` is the same file with `environment = "dev"`, the
`development` environment, 10 images, 3 days, and 30 days of logs, and
`diff` between the two is the complete answer to "what is different in
prod".

## Standalone use without Terragrunt

```hcl
provider "aws" {
  region = "us-east-1"
}

module "orders_api" {
  source = "./stacks/apps/aws/orders-api"

  region              = "us-east-1"
  environment         = "prod"
  github_organization = "example-org"
  github_repository   = "orders-api"
  log_retention_days  = 365
  tags                = { owner = "orders" }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `region` | `string` | n/a | Region of the application's resources. Supplied by the partition locator for an account cell. |
| `app_name` | `string` | `"orders-api"` | First segment of every resource name. 3 to 25 lowercase letters, digits, and single hyphens. |
| `environment` | `string` | n/a | Deployment name, a name segment and the publisher's default GitHub environment. 1 to 12 lowercase letters and digits. |
| `github_organization` | `string` | n/a | GitHub organization (or user) that owns the application's repository. |
| `github_repository` | `string` | n/a | Name of the application's repository, without the organization. |
| `publisher_github_environment` | `string` | `null` | GitHub environment the publisher trusts, the only subject it matches. Null uses `environment`. |
| `image_retention_count` | `number` | `30` | Newest images the repository keeps, whatever their tag. 1 to 1000. |
| `untagged_image_expiry_days` | `number` | `7` | Days after push that an untagged image expires. 1 to 365. |
| `log_retention_days` | `number` | `90` | Log group retention, one of the values CloudWatch Logs accepts. |
| `tags` | `map(string)` | `{}` | Tags on every resource; `Application` and `Environment` are added by the stack. |

## Outputs

| Name | Description |
|------|-------------|
| `task_role_arn` | ARN of the task role, for the task definition's `taskRoleArn`. |
| `task_execution_role_arn` | ARN of the execution role, for the task definition's `executionRoleArn`. |
| `image_publisher_role_arn` | ARN of the publisher role, for the pipeline's `role-to-assume`. |
| `image_publisher_trust_subject` | The exact token subject the publisher's trust matches, `repo:<org>/<repo>:environment:<env>`, to compare against a failed `AssumeRoleWithWebIdentity`. |
| `role_arns_by_name` | Map of role name to ARN for all three roles. |
| `repository_name` | `<app>-<env>`. |
| `repository_url` | The repository URL, what the task definition's `image` starts with. |
| `repository_arn` | ARN of the repository, to scope another role's `ecr:` actions to it. |
| `kms_key_alias` | Bare alias of the key, `<app>-<env>`. |
| `kms_key_arn` | ARN of the key. |
| `log_group_name` | `/ecs/<app>/<env>`, for the awslogs driver. Carries the shared-key precondition. |
| `parameter_prefix` | `/<app>/<env>`, the namespace both ECS roles are granted. Carries the namespace precondition. |
| `placeholder_parameter_name` | `/<app>/<env>/placeholder`, the parameter that reserves the namespace. |
| `partition` | `aws` or `aws-us-gov`. |
| `account_id` | Account the stack was deployed in. |

## Import

Every resource is in a module and imports as that module's README says; the
addresses below are the ones this stack uses. The three registry resources
all import by repository name.

```hcl
import {
  to = module.registry.aws_ecr_repository.this["app"]
  id = "orders-api-prod"
}

import {
  to = module.registry.aws_ecr_lifecycle_policy.this["app"]
  id = "orders-api-prod"
}

import {
  to = module.registry.aws_ecr_repository_policy.this["app"]
  id = "orders-api-prod"
}

import {
  to = module.log_group.aws_cloudwatch_log_group.this["app"]
  id = "/ecs/orders-api/prod"
}

import {
  to = module.parameters.aws_ssm_parameter.placeholder["app"]
  id = "/orders-api/prod/placeholder"
}

import {
  to = module.roles.aws_iam_role.this["task"]
  id = "orders-api-prod-task"
}

import {
  to = module.roles.aws_iam_role.this["publisher"]
  id = "orders-api-prod-image-publisher"
}

import {
  to = module.key.aws_kms_key.this["app"]
  id = "11111111-1111-1111-1111-111111111111"
}
```

## Consuming the outputs

Documentation only: nothing below is managed by this stack. The
application's deployment pipeline owns the task definition and writes it
from the outputs on every release. The fragment is what a pipeline in
`us-east-1` for the `prod` cell would render, with `<registry id>` the
account id, `<tag>` the immutable tag the publisher pushed, and one secret,
`DATABASE_URL`, whose value the secrets process wrote under the namespace
as `/orders-api/prod/database-url`:

```json
{
  "family": "orders-api-prod",
  "taskRoleArn": "arn:aws:iam::111111111111:role/orders-api-prod-task",
  "executionRoleArn": "arn:aws:iam::111111111111:role/orders-api-prod-task-execution",
  "containerDefinitions": [
    {
      "name": "orders-api",
      "image": "111111111111.dkr.ecr.us-east-1.amazonaws.com/orders-api-prod:<tag>",
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:ssm:us-east-1:111111111111:parameter/orders-api/prod/database-url"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/orders-api/prod",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "orders-api"
        }
      }
    }
  ]
}
```

Line by line, where each value comes from: `taskRoleArn` is
`task_role_arn`; `executionRoleArn` is `task_execution_role_arn`; `image`
is `repository_url` with a colon and the tag behind it, and because tags
are immutable the tag names one image forever; `valueFrom` is a parameter
ARN under `parameter_prefix`, which the execution role may read
(`InjectSecretsUnderNamespace`) and decrypt (the key policy) and which the
task role may also read at run time; `awslogs-group` is `log_group_name`
and `awslogs-region` is the region the cell's partition locator supplied.
The publisher's side is the pipeline's workflow, which assumes
`image_publisher_role_arn` through OIDC from a job in the `production`
environment (`publisher_github_environment`; the token's subject must equal
`image_publisher_trust_subject`, and a job on any branch outside that
environment is refused), logs in to the registry with the token its own
policy lets it get, and pushes to `repository_url` under a new tag. Neither
side names anything this stack did not output.
