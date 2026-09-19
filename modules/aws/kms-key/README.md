# modules/aws/kms-key

Manages a map of customer managed KMS keys: the key, its alias, and a key
policy built from role names for administrators and users. It is the key entry
of the AWS catalog stack (ADR 0017): a cell names roles and an alias and never
writes a principal ARN or a policy document.

## Design notes

- **The account root is always in the policy.** A KMS key policy grants
  nothing to its account unless it says so, and a key whose only named
  principals have been deleted is unmanageable until AWS Support steps in.
  Every policy here starts with the account root principal holding `kms:*`,
  the same statement AWS puts in every default key policy: it lets IAM
  policies in the account grant access to the key and it means the key cannot
  be orphaned. A precondition checks the rendered policy still carries it.
- **Administrators and users are the console's default shapes.** Roles in
  `administrator_role_names` may manage the key (policy, aliases, grants,
  tags, enable, disable, rotate on demand, schedule and cancel deletion) but
  not use it. Roles in `user_role_names` may encrypt, decrypt, re-encrypt,
  generate data keys, and describe, and may let an AWS service create a grant
  on the key for a resource it manages (`kms:GrantIsForAWSResource`), which
  is what attaching the key to a volume or a database needs. A statement is
  emitted only when it has principals.
- **Role names, not ARNs.** The ARN is built from the caller's partition and
  account id (`data.aws_partition`, `data.aws_caller_identity`), so the same
  values deploy to any account in commercial or GovCloud
  ([ADR 0009](../../../docs/adr/0009-partition-aware-aws-cells.md)). A name may
  carry a path (`service/deployer`). Whether the role exists is checked by
  KMS when the policy is written, which is what allows a role created in the
  same plan to be named; a misspelt name fails the apply with KMS's
  "invalid principals" error rather than the plan.
- **Service users are an allowlist.** A few services use a key under their
  own service principal rather than under the caller's role, and a key
  policy that does not name them refuses them whatever IAM says.
  `service_users` lists those from an allowlist, and each entry renders the
  statement AWS documents for it. Today the list holds `logs`: CloudWatch
  Logs (`logs.<region>.<dns suffix>`, discovered from `data.aws_region` and
  `data.aws_partition`) may encrypt and decrypt with the key, conditioned on
  `kms:EncryptionContext:aws:logs:arn` matching a log group ARN in this
  account and region, so the key cannot be borrowed for a log group anywhere
  else. S3 and SSM Parameter Store are not on the list because they act as
  the caller and need no service grant. A service not on the list needs a
  review of its own condition keys, not a free-text principal.
- **CloudTrail is named as a trail, not as a principal.** A key that
  encrypts a trail's log and digest files lists the trail in
  `cloudtrail_trail_names`, and the module adds the three statements the
  CloudTrail documentation requires for the `cloudtrail` service principal:
  `kms:GenerateDataKey*` under CloudTrail's own encryption context,
  `kms:DescribeKey`, and `kms:Decrypt`. The first two are conditioned with
  `aws:SourceArn` on the named trails' ARNs (built from the caller's
  partition, region, and account, so no ARN is typed), which is what stops
  another account's trail from borrowing the key. `kms:Decrypt` is given
  without a condition because the documentation requires it for a bucket
  that uses an S3 Bucket Key (every SSE-KMS bucket of `modules/aws/s3-bucket`
  does) and the call arrives through S3 with the bucket's encryption context,
  not the trail's. Reading the encrypted log files is `user_role_names`.
- **Rotation is on; the period is the knob.** `enable_key_rotation` is fixed
  to true; `rotation_period_in_days` defaults to 365 and accepts 90 to 2560.
- **Deletion is slow by default.** `deletion_window_in_days` defaults to 30,
  the maximum, because a deleted key takes every ciphertext under it with it.
- **The key is `prevent_destroy`.** Removing an entry from a cell must not be
  able to schedule a key deletion. Retiring a key is a deliberate change that
  flips the flag first.
- **Symmetric, single region, enabled.** There is no input for key spec,
  usage, or multi-region. A signing key or a multi-region key is a different
  shape and gets its own module when one is needed.
- **Aliases are bare names.** `alias` is given without the `alias/` prefix
  and the module adds it; `modules/aws/s3-bucket` takes the same bare name in
  `kms_key_alias`, so a key cell and a bucket cell agree on one string.

## Usage

```hcl
module "keys" {
  source = "../../modules/aws/kms-key"

  keys = {
    artifacts = {
      alias                    = "example-artifacts"
      description              = "Encrypts the example application's build artifacts."
      administrator_role_names = ["example-platform-admin"]
      user_role_names          = ["example-ci-deployer", "example-app-server"]
    }

    backups = {
      alias                   = "example-backups"
      deletion_window_in_days = 30
      rotation_period_in_days = 180
      user_role_names         = ["example-backup-writer"]
    }

    app-logs = {
      alias           = "example-app-logs"
      description     = "Encrypts the example application's log groups."
      service_users   = ["logs"]
      user_role_names = ["example-app-task"]
    }

    cloudtrail = {
      alias                  = "cloudtrail"
      description            = "Encrypts the account trail's log and digest files."
      cloudtrail_trail_names = ["account-trail"]
      user_role_names        = ["example-security-auditor"]
    }
  }
}
```

## What this module refuses

- An alias with the `alias/` prefix, one starting with `aws/`, or one used
  twice.
- A deletion window outside 7 to 30 days, or a rotation period outside 90 to
  2560 days.
- A role name that is an ARN or a wildcard.
- A service in `service_users` that is not on the allowlist (`logs`), or one
  listed twice.
- A trail name in `cloudtrail_trail_names` outside the CloudTrail naming
  rules, or a trail ARN where a name is expected.
- A rendered policy without the account root statement (a module invariant,
  checked as a precondition).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `keys` | `map(object)` | n/a | Keys keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `keys` | Map of key to `{ key_id, arn, alias, alias_name, alias_arn }`. |
| `key_arns_by_alias` | Map of bare alias name to key ARN. |
| `key_ids_by_alias` | Map of bare alias name to key ID. |
| `partition` | Partition the keys were created in. |
| `account_id` | Account the keys were created in. |

## Import

Keys import by key ID, aliases by their full name.

```hcl
import {
  to = module.keys.aws_kms_key.this["artifacts"]
  id = "11111111-1111-1111-1111-111111111111"
}

import {
  to = module.keys.aws_kms_alias.this["artifacts"]
  id = "alias/example-artifacts"
}
```
