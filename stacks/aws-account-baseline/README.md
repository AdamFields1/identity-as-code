# stacks/aws-account-baseline

The deployable unit for the hardening every account gets. It composes four
modules into one plan and one state file per account:

1. `account-hardening` sets the switches: the IAM account password policy,
   EBS encryption by default (optionally under a customer managed key), the
   account-level S3 Block Public Access, an optional GuardDuty detector, and
   an IAM Access Analyzer with the account as its zone of trust.
2. `kms-key` creates the key the trail encrypts with, naming the trail in
   the key policy.
3. `s3-bucket` creates the bucket the trail delivers to, encrypted with that
   key, TLS-only, versioned, nothing public, naming the trail in the bucket
   policy; and optionally a second bucket that receives the first one's S3
   server access logs.
4. `cloudtrail` creates the multi-region, validated trail that writes to the
   bucket under the key.

Tenant cells under
`tenants/aws/<partition>/accounts/<account-name>/aws-account-baseline/`
point at this stack and provide values only. There is one cell per account,
and the account and partition are the tree, never a value: the account
locator beside the cell addresses the provider, and the modules discover the
account, the partition, and the region from the credentials they are given.
See [ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md) and
[ADR 0009](../../docs/adr/0009-partition-aware-aws-cells.md).

## The model

```
account-hardening        password policy, EBS default encryption,
                         S3 Block Public Access, GuardDuty, Access Analyzer
                         (five switches, independent of everything below)

kms-key ------------->  s3-bucket ------------->  cloudtrail
key policy names the    bucket encrypted with     multi-region, validated,
trail (by name; the     the key (by alias);       writes to the bucket under
module builds the ARN)  bucket policy names the   the key; created last
                        trail the same way        because CloudTrail checks
                                                  both policies at CreateTrail
```

Every switch defaults to on except GuardDuty, so a cell that gives nothing
but a bucket name gets the whole posture. A cell that wants less says so,
and `diff` between two accounts' cells is the complete answer to "what is
weaker there".

## Why one stack

The trail, its bucket, and its key must land together: CloudTrail refuses to
create a trail whose bucket policy or key policy does not name it, the
bucket cannot be encrypted with a key that does not exist, and removing the
trail without its bucket leaves an audit log nobody can see in code. The
switches are singletons per account with no ordering between them, and a
second stack for them would be a second state file and a second plan per
account for no boundary anyone would defend. One stack per account, one plan
that shows the account's whole baseline, and a blast radius of one account
([ADR 0001](../../docs/adr/0001-stacks-as-deployment-unit.md),
[ADR 0017](../../docs/adr/0017-three-kinds-of-stack.md)).

The one piece of ordering that is not a reference is stated with
`depends_on`. The bucket module resolves the key's alias with a data source
at plan time, and on the first plan of an account the key does not exist
yet; `depends_on = [module.trail_key]` makes Terraform defer every data read
inside the bucket module to apply whenever the key has pending changes, so
the first plan succeeds and the alias is read after the key is created. The
cost is visible and worth knowing: in any later plan that changes the key
(a tag, a role name, the rotation period), the bucket policy and encryption
settings show as "known after apply" and are then applied unchanged. A
steady-state plan reads everything at plan time. The trail module has no
data sources, so its `depends_on` on the bucket and key costs nothing.

## What a cell looks like

A cell for this stack looks like this. The committed one,
`tenants/aws/commercial/accounts/example-prod/aws-account-baseline/terragrunt.hcl`,
turns GuardDuty on, names no key user, and carries its own tags:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-baseline"
}

inputs = {
  cloudtrail = {
    bucket_name             = "example-prod-cloudtrail"
    access_log_bucket_name  = "example-prod-cloudtrail-access-logs"
    kms_key_user_role_names = ["example-security-auditor"]
  }

  guardduty = {
    enabled = true
  }

  tags = {
    owner = "platform"
  }
}
```

No region (the partition locator supplies it), no account ID, no ARN, no
partition literal. The state key is
`aws/commercial/accounts/example-prod/aws-account-baseline/terraform.tfstate`.

## Turning things off

Each switch removes its resource when turned off, and the plan shows the
destroy. What that does in the account:

| Switch | Off means |
|--------|-----------|
| `password_policy.enabled` | The account reverts to the AWS default policy (6 characters, nothing required). |
| `ebs_encryption.enabled` | Encryption by default is turned off in this region; a named default key resets to `aws/ebs`. |
| `s3_public_access_block.enabled` | Buckets fall back to their own public access settings. |
| `access_analyzer.enabled` | The analyzer and its findings are deleted; a new one regenerates them. |
| `guardduty.enabled` | Refused. Deleting a detector deletes its findings, so the detector is `prevent_destroy`; suspend it in the console, or lift the flag in a dedicated change. |
| `cloudtrail.enabled` | Refused. The bucket and the key are `prevent_destroy` in their modules, because the bucket holds the audit log and the key is what makes it readable. Retiring a trail is a deliberate two-step change: stop the trail here, then lift the flags. |

## What this stack refuses

- A cell with the trail on (the default) and no `cloudtrail.bucket_name`.
- An access log bucket with the same name as the trail bucket.
- A key alias with the `alias/` prefix or starting with `aws/`.
- A management event type other than `All`, `ReadOnly`, or `WriteOnly`.
- Everything the modules refuse: a password minimum below 14, a password age
  or reuse history outside IAM's ranges, `hard_expiry` with passwords that
  never expire, an EBS key alias while encryption by default is off, a
  GuardDuty frequency GuardDuty does not accept, an analyzer name outside
  its rules, a trail name outside CloudTrail's rules, a key prefix with a
  leading or trailing slash, a bucket name outside S3's rules.
- At plan time: an EBS key alias that does not exist in the account and
  region.
- Turning GuardDuty or the trail off once they have been on.

## Provider configuration

`versions.tf` declares `required_providers` only. The `provider "aws"` block
is generated by Terragrunt (`tenants/aws/root.hcl`) from the cell's
locators: `region` from `partition.hcl`, and for an account cell
`allowed_account_ids = ["<account id>"]` and
`profile = "identity-as-code-<account name>"` from `account.hcl`, so a plan
whose credentials land in any other account stops before its first resource
API call. The deployment role
`arn:<partition>:iam::<account id>:role/<TG_AWS_DEPLOY_ROLE_NAME>` is named
in that profile, not in the generated file, because a saved plan carries the
file and the plan and apply environments name different roles: in CI the
workflow writes the profile from the locators, chained from the GitHub OIDC
session; locally an engineer defines it once per account (repository README,
"How to use it"). Nothing is typed into a cell.

The deployment role needs, for the switches: `iam:*AccountPasswordPolicy`,
`ec2:GetEbsEncryptionByDefault`, `ec2:EnableEbsEncryptionByDefault`,
`ec2:DisableEbsEncryptionByDefault`, `ec2:*EbsDefaultKmsKeyId`,
`s3:GetAccountPublicAccessBlock`, `s3:PutAccountPublicAccessBlock`,
`guardduty:CreateDetector`, `guardduty:GetDetector`,
`guardduty:UpdateDetector`, `guardduty:TagResource`,
`access-analyzer:CreateAnalyzer`, `access-analyzer:GetAnalyzer`,
`access-analyzer:DeleteAnalyzer`, and `kms:DescribeKey` plus
`kms:ListAliases` for an EBS key by alias. For the trail: the KMS key and
alias actions, the S3 bucket and bucket-configuration actions on the named
buckets, and `cloudtrail:CreateTrail`, `cloudtrail:GetTrail`,
`cloudtrail:DescribeTrails`, `cloudtrail:GetTrailStatus`,
`cloudtrail:UpdateTrail`, `cloudtrail:StartLogging`,
`cloudtrail:PutEventSelectors`, `cloudtrail:GetEventSelectors`,
`cloudtrail:AddTags`, `cloudtrail:ListTags`, and `cloudtrail:DeleteTrail`.
The S3 actions include `s3:ListBucket` on the trail bucket, which is what
the provider's read of a bucket is authorized as. The role, and the
read-only one the plan environment names, are platform bootstrap (README,
deliberately out of scope).

## Regions

The password policy, the S3 public access block, and the trail are
account-wide; the trail is multi-region by construction. EBS encryption by
default, GuardDuty, and Access Analyzer are regional and land in the cell's
region, which the partition locator supplies. An account that needs the
regional three in a second region gets a second cell of this stack with its
own directory name and state (for example
`accounts/example-prod/aws-account-baseline-us-west-2/`) that sets `region`
and turns the account-wide items off (`password_policy`,
`s3_public_access_block`, and `cloudtrail` with `enabled = false`), so no
singleton is owned by two state files. That cell is the one place where
`region` appears in a cell under `accounts/`, and it is a value, not an
address.

## Standalone use without Terragrunt

```hcl
provider "aws" {
  region = "us-east-1"
}

module "aws_account_baseline" {
  source = "./stacks/aws-account-baseline"

  region = "us-east-1"

  cloudtrail = {
    bucket_name = "example-prod-cloudtrail"
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `region` | `string` | n/a | Region for the regional parts and the trail's home region. From the partition locator under Terragrunt. |
| `password_policy` | `object` | `{}` | `{ enabled = true, minimum_password_length = 14, require_*, allow_users_to_change_password, max_password_age_days = 90, password_reuse_prevention = 24, hard_expiry }`. |
| `ebs_encryption` | `object` | `{}` | `{ enabled = true, kms_key_alias }`. |
| `s3_public_access_block` | `object` | `{}` | `{ enabled = true }`. |
| `guardduty` | `object` | `{}` | `{ enabled = false, finding_publishing_frequency = "FIFTEEN_MINUTES" }`. |
| `access_analyzer` | `object` | `{}` | `{ enabled = true, name = "account-analyzer" }`. |
| `cloudtrail` | `object` | `{}` | `{ enabled = true, trail_name = "account-trail", bucket_name (required when enabled), s3_key_prefix, kms_key_alias = "cloudtrail", kms_key_administrator_role_names, kms_key_user_role_names, log_expiration_days, access_log_bucket_name, access_log_expiration_days = 400, management_events_read_write_type = "All", exclude_kms_events, exclude_rds_data_api_events }`. |
| `tags` | `map(string)` | `{}` | Tags for every taggable resource. |

## Outputs

| Name | Description |
|------|-------------|
| `account_id` | The account this cell hardened. |
| `partition` | `aws` or `aws-us-gov`. |
| `password_policy` | `{ minimum_password_length, max_password_age_days, password_reuse_prevention, expire_passwords }` or null. |
| `ebs_encryption` | `{ enabled, default_kms_key_arn }`. |
| `s3_public_access_blocked` | Whether the account-level block is managed with all four on. |
| `guardduty_detector` | `{ id, arn }` or null. |
| `access_analyzer` | `{ name, arn }` or null. |
| `trail` | `{ name, arn, home_region, bucket_name, bucket_arn, kms_key_arn, kms_key_alias, access_log_bucket_name }` or null. |

## What a first apply should confirm

Everything here passes `terraform validate` against the pinned provider,
and the stack was planned and applied offline with a mocked provider fed a
cell's inputs. Four things only a real account can confirm:

- That the first plan of an account, with the key not yet created, shows
  the bucket module's policy and encryption settings as "known after apply"
  and the apply then creates key, bucket, and trail in that order without
  `InsufficientS3BucketPolicyException` or
  `InsufficientEncryptionPolicyException`. The offline harness took that
  path for the first apply; a later change to the key re-defers the bucket
  module's reads on an update, which the mocked provider could not replay
  and a real account should confirm once (change a tag on the key and plan).
- That CloudTrail delivers to the bucket with the key's `AllowCloudTrailDecryptLogs`
  statement present. The bucket module enables an S3 Bucket Key on every
  SSE-KMS bucket, and the CloudTrail documentation requires `kms:Decrypt`
  for exactly that case; the statement is written as documented, without a
  condition. Check the trail's last delivery status after the first hour.
- That `max_password_age_days = 0` round-trips as "never expires" with no
  diff on the next plan.
- That a trail with neither exclusion set shows no diff on
  `exclude_management_event_sources` (sent as null, reported back empty).
