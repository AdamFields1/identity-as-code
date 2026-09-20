# stacks/aws-account-workloads

The AWS catalog stack: one deployable unit per account that offers three
vetted shapes as values, so an account can get a one-off service role, KMS
key, or S3 bucket without anyone writing Terraform. It composes three
modules, in order, into one plan and one state file per account:

1. `iam-service-role` creates the roles: trust shape, policy names, boundary,
   session limit, and the instance profile for roles EC2 assumes.
2. `kms-key` creates the keys: alias, rotation, and a key policy built from
   role names.
3. `s3-bucket` creates the buckets: encryption, an optional allow list of
   roles, lifecycle numbers, access logging into another bucket of the cell.

Cells live under
`tenants/aws/<partition>/accounts/<account-name>/aws-account-workloads/` and
provide values only. Which account a cell is in, and which partition, is not
a value: it comes from the `account.hcl` and `partition.hcl` locator files
above the cell, which `tenants/aws/root.hcl` turns into the provider's
`allowed_account_ids` and the profile that names the account's deployment
role. A cell holds no account id, no ARN, and no partition literal. See
[ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md).

## What the catalog can express

Each map is keyed by a stable logical name that becomes the resource
address; the visible name is an attribute. The full shape of each entry and
everything it refuses is in the module's `variables.tf` and README; this
stack adds two things to the module shapes and checks the wiring between
them.

| Entry | What a cell says | What the module fixes |
|-------|------------------|-----------------------|
| `service_roles.<k>` | a name, a trust shape (`services` from an allowlist, `account_principals` by 12-digit id, or one GitHub repository by named branches and environments), AWS managed policy names, customer managed policies by name, an optional inline policy, an optional boundary, a session limit, and **`bucket_access`** | no wildcard principal, `AdministratorAccess` only with `allow_admin = true`, partition-aware ARNs, an instance profile for every `ec2` role, `force_detach_policies = false` |
| `kms_keys.<k>` | a bare alias, a description, deletion window and rotation period, `administrator_role_names`, `user_role_names` | symmetric single-region key, rotation on, account root always in the policy, `prevent_destroy` |
| `buckets.<k>` | a name, **`kms_key`** or `kms_key_alias` or neither, `allowed_role_names`, lifecycle numbers, `access_logging` to another bucket of the cell | ACLs disabled, nothing public, versioning on and bounded, TLS required, `force_destroy = false`, `prevent_destroy` |

### `bucket_access`: a role names buckets, the stack writes the policy

The two common shapes, read a bucket and read and write a bucket, are
values on the role, and the stack renders the inline policy from the names
and the partition:

```hcl
app-server = {
  name  = "example-app-server"
  trust = { services = ["ec2"] }
  bucket_access = {
    read       = ["example-prod-config"]
    read_write = ["example-prod-artifacts"]
  }
}
```

`read` grants `s3:ListBucket`, `s3:ListBucketVersions`, and
`s3:GetBucketLocation` on the bucket and `s3:GetObject`,
`s3:GetObjectVersion`, and `s3:GetObjectAttributes` on its objects.
`read_write` implies `read` and adds `s3:PutObject`, `s3:DeleteObject`,
`s3:AbortMultipartUpload`, and `s3:ListMultipartUploadParts` on the objects
and `s3:ListBucketMultipartUploads` on the bucket. A writer never gets
`s3:DeleteObjectVersion`: every catalog bucket is versioned, a delete is a
delete marker, and purging history stays with the bucket's lifecycle rule.
No object ACL action and no bucket management action is granted.

Bucket names may be buckets of this cell or buckets that already exist in
the account; the ARN is the name and the partition, so nothing is looked up
and a bucket created in the same plan is fine. A role that also sets
`inline_policy` gets both: its own statements first, then the generated
ones, in one inline policy (Sids must not collide). The rendered document is
in the `bucket_access_policies` output so a reviewer can read what a role
was granted without rendering it by hand.

### `kms_key`: a bucket names a key of the cell by its map key

```hcl
kms_keys = {
  artifacts = {
    alias           = "example-artifacts"
    user_role_names = ["example-ci-deployer", "svc/example-app-server"]
  }
}

buckets = {
  artifacts = {
    name               = "example-prod-artifacts"
    kms_key            = "artifacts"
    allowed_role_names = ["example-ci-deployer", "example-app-server"]
  }
}
```

The stack hands the bucket module the key's alias, which the module looks
up; the cell never repeats the alias. A key that already exists in the
account and is managed elsewhere is named with `kms_key_alias` instead.
Setting both is refused.

### Roles named in keys and buckets

`allowed_role_names` on a bucket and `administrator_role_names` and
`user_role_names` on a key take role names, of this cell or already in the
account. The bucket module looks a name up, so the ARN carries the role's
real path and a misspelt name fails the plan. The key module builds the ARN
from the name, so a role with a path is written with it in front:
`svc/example-app-server` for a role named `example-app-server` at `/svc/`.
For a role of this cell the stack reads that string back from the roles
module, which is what orders the key policy after the role (below).

### What the stack checks across the maps

Every guardrail on a single entry is in its module. What the stack adds is
the cross-references it can see, so a denial shows up in the plan rather
than in the first request:

- A role whose `bucket_access` names a bucket of this cell with a non-empty
  `allowed_role_names` must be on that list; the bucket policy would deny it
  otherwise.
- A role whose `bucket_access` names a bucket of this cell encrypted with a
  key of this cell must be in that key's `user_role_names`; KMS would deny
  the object read otherwise.
- A bucket's `kms_key` must be a key of the cell, and not be set together
  with `kms_key_alias`.
- A bucket that receives access logs sets neither `kms_key` nor
  `kms_key_alias`.
- A bucket is listed under `read` or `read_write` of a role, not both.

## Order of apply, and what a plan looks like

```
service roles  -->  KMS keys  -->  S3 buckets
```

**Roles before keys.** KMS validates every principal in a key policy when
the policy is written, so a key that names a role of this cell must be
written after the role exists. The edge is made by reading the role's name
back from the roles module rather than from the cell: the value is the same
string, known at plan, and Terraform orders the two without deferring the
key's plan-time reads. A name that is not a role of this cell passes through
and KMS checks it at apply, as the module documents.

**Roles and keys before buckets.** The bucket module resolves
`allowed_role_names` and the KMS alias with data sources at plan time, and a
role or key created in the same plan does not exist yet when the plan runs.
The bucket module therefore carries a module-level `depends_on` on both,
which makes Terraform defer the bucket module's reads to apply whenever roles
or keys have a change pending. That is what lets a new account's first cell
land roles, keys, and buckets in one plan instead of two pull requests.

The cost, stated so nobody is surprised by it: in a plan where any role or
key changes, every bucket's policy and encryption configuration shows as an
in-place update with the value `(known after apply)`, and the two bucket
preconditions are checked at apply instead of plan. At apply the reads
happen, the values resolve to what they were, and the updates are no-ops. A
plan that touches only buckets reads everything at plan time and shows only
the real change. If that noise becomes the normal case for an account
because its roles churn, the buckets belong in a cell of their own, ordered
after this one with a Terragrunt `dependencies` block (the ADR 0005 pattern).

## When to move to an app stack

The catalog offers shapes, not resource types, and the test is whether the
person writing the cell has to know a resource's attribute names
([ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md)). The wiring above is
the whole of what this stack expresses between its entries: a bucket names a
key, a role names buckets, keys and buckets name roles, all by name. A
composition leaves the catalog when it needs:

- a trust policy that names a resource created beside it (a role only a
  specific Lambda function or a specific queue's consumer may assume; the
  catalog's trust is a service, an account, or a repository);
- an output of one entry as an input of another (a bucket notification that
  names a queue, a key whose policy names a service role's session, a
  replication rule to a bucket in another region);
- a resource type the catalog does not offer (a queue, a table, a secret): a
  new module and, if it is one resource with knobs, a new entry here after
  its own review; otherwise an app stack that composes the new module with
  these;
- the same composition in more than one account: that is a stack with
  several cells, and repeating the values per cell is what cells are for
  (ADR 0002).

An app stack is still a stack: values-only cells under the same account
directory, its own state file, the same modules where they fit. What changes
is that its shape is the application's, not the estate's. The reverse also
holds: an app stack that turns out to be one resource with knobs comes back
here as an entry.

The two kinds of cell name each other in one direction only. Within an account
the release train applies the baseline first, then this cell, then the app
stacks (`tools/repo_lint/cells.py` orders the waves), so an app stack may name
a bucket of this cell by name, and an entry here never names a role an app
stack creates. The pattern for an app that reads a catalog bucket is
`reference_bucket_names` on `stacks/apps/aws/orders-api`: the app cell lists
the bucket's name, the stack builds the ARN from the partition it discovers
and grants its task role the read, nothing is looked up, and the wave order
takes care of existence at apply. The trap is the reverse direction: a bucket
here whose `allowed_role_names` lists the app's task role fails the first
release, because this cell is applied before that role exists and the
s3-bucket module resolves every allowed role by name (at plan on a
steady-state run, at apply on a first release, when this cell's own pending
roles defer the lookup), and a role that does not exist fails the run either
way. A bucket that app stacks read therefore has no allow list and its
readers' identity policies decide, while a bucket only a role of this cell
touches (the load-test results in the example-prod cell) keeps one. An entry
that belongs to an application team rather than to the account carries that
team's owner tag over the cell's, so the catalog says who it is for.

## What this stack refuses

- Everything each module refuses (see `modules/aws/iam-service-role`,
  `modules/aws/kms-key`, `modules/aws/s3-bucket`): a wildcard or ARN where a
  name or id is expected, a service off the allowlist, a GitHub trust without
  a branch or environment, `AdministratorAccess` or an inline `*` on `*`
  without `allow_admin`, an `alias/` or `aws/` prefix on a key alias, a
  bucket that logs to itself or to a bucket outside the cell, and the ranges
  on every number.
- A bucket ARN or wildcard in `bucket_access`; a bucket under both `read`
  and `read_write`.
- A role granted a bucket of this cell that the bucket's `allowed_role_names`
  or the key's `user_role_names` would deny.
- `kms_key` and `kms_key_alias` together; a `kms_key` that is not a key of
  the cell; a logging target with either.
- At plan time, in the modules: a customer managed policy, a GitHub OIDC
  provider, a KMS alias, or an allowed role that does not exist in the
  account (roles and keys of this cell excepted, by the ordering above).
- Removing a bucket or a key from a cell. Both are `prevent_destroy` in their
  modules; retiring one is a deliberate change that lifts the flag in a pull
  request that is obviously about deleting it. Roles are not
  `prevent_destroy`; removing one removes its attachments and profile with it.

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "aws"` block
is generated by Terragrunt (`tenants/aws/root.hcl`). For an account cell the
root reads `accounts/<account-name>/account.hcl` and the partition's
`partition.hcl` and generates `allowed_account_ids = ["<account_id>"]` and
`profile = "identity-as-code-<account name>"`, so a plan whose credentials
land in any other account stops before its first resource API call. The
deployment role `arn:<partition>:iam::<account_id>:role/<TG_AWS_DEPLOY_ROLE_NAME>`
is named in that profile, not in the generated file, because a saved plan
carries the file and the plan and apply environments name different roles:
the workflow writes the profile on the runner from the locators, chained
from the GitHub OIDC session, and an engineer defines it once per account
locally. `region` arrives from `partition.hcl` as an input; a cell may set
it to place its resources elsewhere in the partition. Nothing is typed into
a cell.

The deployment roles are platform bootstrap: every account carries a
read-only one trusted only by the partition's plan OIDC role and a writer
trusted only by its apply OIDC role, under the names the `*-plan` and apply
environments give `TG_AWS_DEPLOY_ROLE_NAME`, provisioned in the separate
repository that provisions the state buckets and OIDC roles. So is the
GitHub OIDC provider a role with `trust.oidc_github` looks up. An account
without them fails in the workflow's profile step or at the provider lookup,
which is the honest failure.

What the writer deployment role needs: `iam:*Role*`,
`iam:*InstanceProfile*`, `iam:GetPolicy`, and `iam:GetOpenIDConnectProvider`
for the roles; `kms:CreateKey`, `kms:*Alias*`, `kms:PutKeyPolicy`,
`kms:EnableKeyRotation`, and the describe and tag actions for the keys; and
the `s3:*Bucket*` management actions for the buckets, including
`s3:ListBucket` on each bucket, which is what the provider's read of a
bucket (`HeadBucket`) is authorized as. Never object access: the bucket
policy's role deny covers objects only, so the deployment role manages a
bucket and lists its keys without being in `allowed_role_names` and cannot
read an object. The read-only role needs only the read forms, `s3:ListBucket`
included.

State key (derived by `root.hcl`):
`aws/<partition>/accounts/<account-name>/aws-account-workloads/terraform.tfstate`.

## A cell

A cell for this stack looks like this. The committed one,
`tenants/aws/commercial/accounts/example-prod/aws-account-workloads/terragrunt.hcl`,
differs in the details: one key named `app` that both roles use, a `config`
bucket under that key with an allow list and access logging, and its own
tags.

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-workloads"
}

inputs = {
  tags = {
    owner       = "platform"
    cost_centre = "cc-1111"
  }

  service_roles = {
    app-server = {
      name                 = "example-app-server"
      description          = "EC2 instances of the example application."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      bucket_access = {
        read       = ["example-prod-config"]
        read_write = ["example-prod-artifacts"]
      }
    }

    ci-deployer = {
      name = "example-ci-deployer"
      trust = {
        oidc_github = {
          repository   = "example-org/example-app"
          branches     = ["main"]
          environments = ["production"]
        }
      }
      bucket_access = { read_write = ["example-prod-artifacts"] }
    }
  }

  kms_keys = {
    artifacts = {
      alias           = "example-artifacts"
      description     = "Encrypts the example application's build artifacts."
      user_role_names = ["example-app-server", "example-ci-deployer"]
    }
  }

  buckets = {
    access-logs = {
      name            = "example-prod-access-logs"
      expiration_days = 365
    }

    artifacts = {
      name               = "example-prod-artifacts"
      kms_key            = "artifacts"
      allowed_role_names = ["example-app-server", "example-ci-deployer"]
      access_logging     = { target_bucket = "access-logs" }
    }

    config = {
      name          = "example-prod-config"
      kms_key_alias = "example-shared-config"
    }
  }
}
```

No `region` (the partition locator supplies it), no account id, no ARN, no
partition literal, no policy document. The same cell under
`tenants/aws/govcloud/accounts/<account-name>/` deploys to GovCloud with
every ARN built for `aws-us-gov`.

## Standalone use without Terragrunt

```hcl
provider "aws" {
  region = "us-east-1"
}

module "aws_account_workloads" {
  source = "./stacks/aws-account-workloads"

  region = "us-east-1"

  service_roles = {
    reader = {
      name          = "example-reader"
      trust         = { services = ["lambda"] }
      bucket_access = { read = ["example-prod-config"] }
    }
  }

  buckets = {
    config = {
      name = "example-prod-config"
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `region` | `string` | Region the provider talks to and every bucket and key is created in. From the partition locator via `root.hcl`; a cell that sets it wins. |
| `tags` | `map(string)` | Tags for everything in the cell; an entry's own tags win on the same key. Default `{}`. |
| `service_roles` | `map(object)` | Roles keyed by logical name: the `iam-service-role` shape plus `bucket_access = { read, read_write }` of bucket names. Default `{}`. |
| `kms_keys` | `map(object)` | Keys keyed by logical name: the `kms-key` shape. Roles of this cell are named by name, with their path in front when they have one. Default `{}`. |
| `buckets` | `map(object)` | Buckets keyed by logical name: the `s3-bucket` shape plus `kms_key`, a key of `kms_keys`. Default `{}`. |

## Outputs

| Name | Description |
|------|-------------|
| `partition` | `aws` or `aws-us-gov`, discovered. |
| `account_id` | The account, discovered. |
| `service_roles` | Role key to `{ name, arn, unique_id, path, instance_profile_name, instance_profile_arn }`. |
| `role_arns_by_name` | Role name to ARN. |
| `instance_profiles` | Role key to `{ name, arn }` for `ec2` roles. |
| `bucket_access_policies` | Role key to the generated inline policy JSON. |
| `github_oidc_provider_arn` | The account's GitHub OIDC provider, or null when unused. |
| `kms_keys` | Key key to `{ key_id, arn, alias, alias_name, alias_arn, administrator_role_names, user_role_names }`; the role name lists are what the key policy was written with. |
| `key_arns_by_alias` | Bare alias to key ARN. |
| `buckets` | Bucket key to `{ name, arn, id, region, regional_domain_name, sse_algorithm, kms_key_alias, kms_key_arn, log_target_bucket_name }`; `kms_key_alias` is the resolved alias, null for SSE-S3. |
| `bucket_arns_by_name` | Bucket name to ARN. |

## Import

Each module's README gives the import id of every resource it owns. In this
stack the addresses are prefixed with the module call: `module.service_roles`,
`module.kms_keys`, `module.buckets`.

```hcl
import {
  to = module.service_roles.aws_iam_role.this["app-server"]
  id = "example-app-server"
}

import {
  to = module.kms_keys.aws_kms_alias.this["artifacts"]
  id = "alias/example-artifacts"
}

import {
  to = module.buckets.aws_s3_bucket.this["artifacts"]
  id = "example-prod-artifacts"
}
```

Adopting a bucket or key that already exists is how an account brings a
hand-made resource under the catalog: import it, plan until the plan is
empty, and the next change to it is a diff on a value.
