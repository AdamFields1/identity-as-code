# modules/aws/ecr-repository

Manages a map of ECR repositories with the posture fixed and the things that
vary as values: which customer managed key encrypts the images, how many
images are kept, and which roles in this account may pull and which may
push. It is the image registry of `stacks/apps/aws/orders-api`; the key it
names comes from `modules/aws/kms-key`, and the roles it names come from
`modules/aws/iam-service-role` in the same stack.

## Design notes

- **Tags are immutable.** A tag names one image forever, and a build that
  wants to publish again publishes under a new tag. A mutable `latest` is a
  name whose meaning changes underneath the task definition that references
  it, so mutability is not offered; a task definition that must float pins a
  digest instead.
- **Every image is scanned on push.** A finding is attached to the build
  that introduced it, not to the incident that found it.
- **Encryption is a customer managed key, and it is required.** A repository
  under the service's own key has no key policy anyone reviews.
  `kms_key_arn` names the key by ARN, not alias, for the same reason
  `modules/aws/log-group` does: the API stores and reports the ARN, and an
  alias would plan a change on every run. ECR creates a grant on the key on
  behalf of whoever creates the repository, so the deploying identity needs
  `kms:CreateGrant`, `kms:RetireGrant`, and `kms:DescribeKey` on it; the
  key's root statement lets the account's IAM policies grant that. The
  roles that pull and push need nothing on the key themselves, because ECR
  encrypts and decrypts layers under its own grant.
- **What is kept is bounded.** Two lifecycle rules: untagged images (the
  layer sets a later build superseded) expire after `untagged_expiry_days`
  (default 7), and beyond `keep_tagged_count` images (default 30) the oldest
  expire whatever their tag. The count rule uses `tagStatus = any` so a
  release tag does not exempt an image from the count; a rule that counted
  only a tag prefix would let everything outside the prefix pile up. ECR
  requires the `any` rule to carry the highest priority, so it is the second
  rule and is evaluated last.
- **Pull and push are role names, and delete is nobody's.** The repository
  policy grants the pull actions (`BatchGetImage`, `GetDownloadUrlForLayer`,
  `BatchCheckLayerAvailability`, `DescribeImages`, `DescribeRepositories`,
  `ListImages`) to `pull_role_names` and the pull actions plus `PutImage`,
  `InitiateLayerUpload`, `UploadLayerPart`, and `CompleteLayerUpload` to
  `push_role_names`. `BatchDeleteImage` is granted to no one: expiring
  images is the lifecycle policy's job, and a publisher that can delete can
  erase the image a task is running. A precondition checks the rendered
  policy never carries it. The ARNs are built from the caller's partition
  and account id as `modules/aws/kms-key` builds them, so the same values
  deploy to any account in either partition (ADR 0009); whether a named
  role exists is checked by ECR when the policy is written, so a role
  created in the same plan is allowed and a misspelt name fails the apply.
  When both lists are empty there is no policy resource and access is
  decided by IAM alone. `ecr:GetAuthorizationToken` is a registry action
  that no repository policy can grant; the stack puts it in each role's own
  policy.
- **`force_delete` is false and the repository is `prevent_destroy`.**
  Images are build artifacts a pipeline can rebuild, but the tags that task
  definitions reference cannot be recreated with the same digests. Retiring
  a workload is a deliberate change that flips the flag first, in a pull
  request that is obviously about deleting it. A name change is a
  replacement that empties the repository and is refused for the same
  reason.
- **Nothing is looked up.** The module reads `data.aws_partition` and
  `data.aws_caller_identity` to build ARNs and nothing else, so a
  repository depends on nothing but the key it names.

## What checkov says, and what is skipped

Nothing is skipped. The three ECR checks are satisfied by what the module
fixes:

| Check | Title | How it is satisfied |
|-------|-------|---------------------|
| `CKV_AWS_136` | Ensure that ECR repositories are encrypted using KMS | `encryption_configuration` is always `KMS` with the caller's key ARN, and a repository with no key is refused. |
| `CKV_AWS_51` | Ensure ECR Image Tags are immutable | `image_tag_mutability` is always `IMMUTABLE`. |
| `CKV_AWS_163` | Ensure ECR image scanning on push is enabled | `scan_on_push` is always true. |

## Usage

```hcl
module "registry" {
  source = "../../modules/aws/ecr-repository"

  repositories = {
    app = {
      name                 = "orders-api/prod"
      kms_key_arn          = module.key.keys["app"].arn
      keep_tagged_count    = 30
      untagged_expiry_days = 7
      pull_role_names      = ["orders-api-prod-task-execution"]
      push_role_names      = ["orders-api-prod-image-publisher"]
      tags                 = { Application = "orders-api" }
    }
  }
}
```

## What this module refuses

- A repository name outside the ECR naming rules (2 to 256 characters of
  lowercase letters, digits, hyphens, underscores, periods, and slashes,
  each segment starting and ending with a letter or digit), or one used
  twice.
- A KMS alias, alias ARN, or bare key id where a key ARN is expected, and a
  repository with no key at all.
- A `keep_tagged_count` outside 1 to 1000, or an `untagged_expiry_days`
  outside 1 to 365; there is no value for "keep everything".
- A role name that is an ARN or a wildcard, a role listed twice in the same
  list, or a role listed under both pull and push.
- A rendered policy that grants `ecr:BatchDeleteImage` (a module invariant,
  checked as a precondition).
- At apply time, from ECR itself: a role name that does not exist in the
  account when the policy is written, and a key whose policy does not let
  the deploying identity create a grant.
- A destroy of a repository without lifting `prevent_destroy` in a
  dedicated change.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `repositories` | `map(object)` | n/a | Repositories keyed by logical name: `name`, `kms_key_arn`, `keep_tagged_count`, `untagged_expiry_days`, `pull_role_names`, `push_role_names`, `tags`. See `variables.tf` for the validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `repositories` | Map of key to `{ name, arn, registry_id, repository_url, kms_key_arn }`. |
| `repository_urls_by_name` | Map of repository name to repository URL. |
| `repository_arns_by_name` | Map of repository name to ARN. |

## Import

Every resource in this module imports by repository name.

```hcl
import {
  to = module.registry.aws_ecr_repository.this["app"]
  id = "orders-api/prod"
}

import {
  to = module.registry.aws_ecr_lifecycle_policy.this["app"]
  id = "orders-api/prod"
}

import {
  to = module.registry.aws_ecr_repository_policy.this["app"]
  id = "orders-api/prod"
}
```
