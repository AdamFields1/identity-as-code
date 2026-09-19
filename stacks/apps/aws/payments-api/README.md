# stacks/apps/aws/payments-api

The deployable unit for one deployment of the payments API in one account. It
composes five modules into one plan and one state file:

1. `kms-key` creates the application's key, with both roles as users and
   CloudWatch Logs as a service user.
2. `iam-service-role` creates the task role and the task execution role, both
   trusting ECS tasks of this account and nothing else, with policies scoped
   to the bucket and the parameter namespace.
3. `s3-bucket` creates the artifacts bucket, encrypted with the key and with
   objects readable and writable by the task role only.
4. `log-group` creates the CloudWatch log group, encrypted with the key, with
   retention.
5. `ssm-parameter-namespace` reserves `/<app>/<env>/` with one SecureString
   placeholder under the key, whose value is never a secret.

Every resource block is in `modules/aws`; this stack holds the names, the
policies, and the wiring, which is the layer rule the repository README
states under "Three layers".

Tenant cells under `tenants/aws/<partition>/accounts/<account-name>/payments-api/`
point at this stack and provide values only: the environment name, the log
retention, and tags. There is one cell per account the application is
deployed in, and the same stack deploys to the commercial and GovCloud
partitions because nothing in it names a partition, an account, or a region.
See [ADR 0017](../../../../docs/adr/0017-three-kinds-of-stack.md).

## Why an app stack and not five catalog entries

ADR 0017 draws the line: a shape leaves the catalog when it needs
cross-resource wiring the catalog cannot express. This application needs
four such references, each to something created in the same plan:

- The key policy names the two roles as users, and CloudWatch Logs as a
  service user, so the log group can be encrypted with it.
- The bucket's encryption names the key by alias and the bucket policy names
  the task role by name. The bucket module resolves both with data sources
  at plan time.
- The task role's inline policy names the bucket and the parameter namespace
  by ARN.
- The log group and the placeholder parameter both name the key, by the key
  module's outputs.

As catalog cells, the key cell would apply first; then the roles cell, whose
inline policy would carry the bucket's ARN typed into the cell, which is
exactly the value [ADR 0002](../../../../docs/adr/0002-values-only-tenant-cells.md)
keeps out of cells; then the bucket cell, whose lookups fail until the first
two have applied: three releases in a fixed order, and the log group and the
namespace would have no cell at all, because a log group's key is a
key-policy grant and a parameter namespace is only meaningful next to the
policy that grants it. Here every name derives from `app_name` and
`environment` once, the graph orders the creation, and the cell says three
values.

The reverse test in ADR 0017 also holds: none of this is one resource with
knobs, so nothing here goes back into the catalog. The composition is the
kind that is needed once per account the application runs in, which is what
makes it a stack rather than a longer catalog entry. Today it has one cell,
`example-prod`; a second account would be a second cell of the same stack
with its own values, and `example-dev` has none.

## The model

```
  cell: environment, log retention, tags
          |
          v
  key  alias/<app>-<env> --------------------> log group /ecs/<app>/<env>
   |    users: task, execution                 (encrypted with the key, retention)
   |    service user: logs
   |------------------------------------------> parameter /<app>/<env>/placeholder
   |                                            (SecureString under the key,
   v                                             value never a secret)
  bucket <app>-<env>-artifacts-<account id>
   SSE-KMS with the key; objects only for the task role
          ^                              ^
          | s3: list, get, put           | ssm: get under /<app>/<env>/
  task role <app>-<env>-task         execution role <app>-<env>-task-execution
   trust: ecs-tasks, this account      trust: ecs-tasks, this account
   inline: namespace + bucket          AmazonECSTaskExecutionRolePolicy + namespace
```

The task role is what the application's code runs as; the execution role is
what the ECS agent uses to pull the image, inject parameters as container
secrets, and ship logs before the container starts. Neither carries a KMS
statement: the key policy grants both roles directly, which is sufficient on
its own and keeps the key's ARN, unknown until the key exists, out of a
document the role module validates at plan time. Both trusts carry
`aws:SourceAccount` for this account, which the role module writes for every
`ecs-tasks` trust.

`environment` is a name segment and nothing else. No resource in this stack
is conditional on it and no module receives it; it appears in names because
ECS, SSM, and CloudWatch Logs need one namespace per deployment of the
application, and the account name is not always that.

## What this stack refuses

- An `app_name` outside 3 to 25 lowercase letters, digits, and single
  hyphens, or an `environment` outside 1 to 12 lowercase letters and digits.
  The bounds keep every derived name inside the S3 and IAM limits.
- A `log_retention_days` that CloudWatch Logs does not accept, including 0
  (never expire). The stack checks it first and the log-group module checks
  it again.
- `Application` or `Environment` in `tags`; the stack derives both from the
  naming variables so the tags cannot disagree with the names.
- From the modules: a wildcard in a trust policy, an inline statement that
  allows `*` or an IAM write on `*`, a policy ARN where a name is expected, a
  bucket name outside the S3 rules, an alias with the `alias/` prefix, a
  service not on the key's allowlist, a parameter prefix outside the SSM
  rules, a log group or a placeholder with no customer managed key.
- A bucket and a log group under different keys, or a task role policy that
  no longer covers the parameter namespace (both preconditions on the
  stack's `log_group_name` and `parameter_prefix` outputs, with the reason
  in the message).
- A destroy of the key, the bucket, the log group, or the placeholder
  parameter without lifting `prevent_destroy` in the owning module in a
  dedicated change. The roles are not `prevent_destroy`; a role is recreated
  from code in seconds and holds nothing.

## The first plan resolves names that do not exist yet

The bucket module resolves `kms_key_alias` and `allowed_role_names` with
data sources at plan time, which is the right shape for a catalog cell that
names a key or a role created elsewhere. In this stack both are created in
the same plan, so the bucket module carries
`depends_on = [module.key, module.roles]`, which defers every data source in
it to apply whenever the key or a role has pending changes. Two visible
consequences, both accepted:

- On the first plan, and on any plan that changes the key or a role
  (including a tag change), the bucket's encryption configuration and
  bucket policy show as `(known after apply)` rather than as the values
  they will have, and the shared-key precondition on the `log_group_name`
  output is checked at apply rather than at plan. A plan that changes
  nothing on the key or the roles shows the bucket in full.
- The key policy names the two roles by constructed ARN and KMS checks they
  exist when the policy is written, so the key must be created after the
  roles. That ordering is a reference, not a `depends_on`: the key module
  is handed the role names from the roles module's output, which is the
  same string the locals hold, and the reference makes Terraform create
  the roles first without deferring the key policy's document to apply. A
  plan therefore shows the full key policy, every time. (A reference
  through a module output orders resources without deferring data sources;
  a module `depends_on` defers every data source in the module. The bucket
  module needs the latter because its lookups would otherwise run at plan
  against a key and a role that do not exist yet.) The log group and the
  namespace take the key's ARN and id from the key module's outputs the
  same way, and neither module reads a data source, so they cost nothing.

## What the deploying identity needs

The deployment role the account cell's provider runs as
(`TG_AWS_DEPLOY_ROLE_NAME` in CI, through the profile
`identity-as-code-<account-name>`; ADR 0017) needs, beyond the IAM, KMS,
S3, and tagging permissions any of the catalog stacks need:
`logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:AssociateKmsKey`,
`logs:TagResource`, `ssm:PutParameter`, `ssm:GetParameter`,
`ssm:AddTagsToResource`, and `kms:Encrypt` on the application's key,
because creating a Standard SecureString parameter encrypts the placeholder
value with it. The key's root statement is what lets the role's IAM policy
grant that; nothing in the key policy names the deploying role. It is not
in `allowed_role_names`, so it manages the bucket and lists its keys (the
provider reads a bucket through `s3:ListBucket`, which the bucket policy's
role deny leaves to IAM) and cannot read an object, which is the intended
split. The read-only role that plans pull requests needs the read forms
only, including `s3:ListBucket` on the bucket and `ssm:GetParameter` on the
placeholder.

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

`tenants/aws/commercial/accounts/example-prod/payments-api/terragrunt.hcl`,
without its header comment:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/apps/aws/payments-api"
}

inputs = {
  environment        = "prod"
  log_retention_days = 365

  tags = {
    owner       = "payments"
    cost_centre = "cc-3333"
  }
}
```

No region (the partition locator supplies it), no account id (the account
locator supplies it and the stack discovers it), no ARN, no name any other
resource repeats. `app_name` defaults to `payments-api` because the stack is
this application's; a cell may set it, and a fork of the stack for another
application changes one default. A second account would be a second cell of
this stack: the same file with `environment = "dev"` and a shorter
retention, and `diff` between the two would be the complete answer to "what
is different in prod". Today this is the only cell.

## Standalone use without Terragrunt

```hcl
provider "aws" {
  region = "us-east-1"
}

module "payments_api" {
  source = "./stacks/apps/aws/payments-api"

  region             = "us-east-1"
  environment        = "prod"
  log_retention_days = 365
  tags               = { owner = "payments" }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `region` | `string` | n/a | Region of the application's resources. Supplied by the partition locator for an account cell. |
| `app_name` | `string` | `"payments-api"` | First segment of every resource name. 3 to 25 lowercase letters, digits, and single hyphens. |
| `environment` | `string` | n/a | Deployment name, a name segment only. 1 to 12 lowercase letters and digits. |
| `log_retention_days` | `number` | `90` | Log group retention, one of the values CloudWatch Logs accepts. |
| `tags` | `map(string)` | `{}` | Tags on every resource; `Application` and `Environment` are added by the stack. |

## Outputs

| Name | Description |
|------|-------------|
| `task_role_arn` | ARN of the task role, for the task definition's `taskRoleArn`. |
| `task_execution_role_arn` | ARN of the execution role, for the task definition's `executionRoleArn`. |
| `role_arns_by_name` | Map of role name to ARN for both roles. |
| `artifacts_bucket_name` | `<app>-<env>-artifacts-<account id>`. |
| `kms_key_alias` | Bare alias of the key, `<app>-<env>`. |
| `kms_key_arn` | ARN of the key. |
| `log_group_name` | `/ecs/<app>/<env>`, for the awslogs driver. Carries the shared-key precondition. |
| `parameter_prefix` | `/<app>/<env>`, the namespace both roles are granted. Carries the namespace precondition. |
| `placeholder_parameter_name` | `/<app>/<env>/placeholder`, the parameter that reserves the namespace. |
| `partition` | `aws` or `aws-us-gov`. |
| `account_id` | Account the stack was deployed in. |

## Import

Every resource is in a module and imports as that module's README says; the
addresses below are the ones this stack uses.

```hcl
import {
  to = module.log_group.aws_cloudwatch_log_group.this["app"]
  id = "/ecs/payments-api/prod"
}

import {
  to = module.parameters.aws_ssm_parameter.placeholder["app"]
  id = "/payments-api/prod/placeholder"
}

import {
  to = module.roles.aws_iam_role.this["task"]
  id = "payments-api-prod-task"
}

import {
  to = module.key.aws_kms_key.this["app"]
  id = "11111111-1111-1111-1111-111111111111"
}

import {
  to = module.artifacts.aws_s3_bucket.this["artifacts"]
  id = "payments-api-prod-artifacts-111111111111"
}
```
