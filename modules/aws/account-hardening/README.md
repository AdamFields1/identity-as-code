# modules/aws/account-hardening

Manages the account-level settings that exist once per account or once per
account and region and take a switch rather than a map: the IAM account
password policy, EBS encryption by default (with an optional customer managed
default key, by alias), the account-level S3 Block Public Access setting, a
GuardDuty detector, and an IAM Access Analyzer with the account as its zone
of trust. It is the switches half of `stacks/aws-account-baseline`; the
trail half is `modules/aws/cloudtrail` with `modules/aws/s3-bucket` and
`modules/aws/kms-key`.

## Design notes

- **Every setting is a switch, and every switch has a strict default.** Each
  `enabled` defaults to true except GuardDuty's, so a cell that says nothing
  gets the password policy, encryption by default, the public access block,
  and the analyzer. Turning a switch off removes its resource, with the
  effect the provider documents: the password policy reverts to the AWS
  default, S3 public access is no longer blocked account-wide, EBS
  encryption by default is turned off, and the default EBS key resets to
  `aws/ebs`. Each shows as a destroy in the plan.
- **The password policy floor is CIS.** Defaults are 14 characters, all four
  character classes, 24 passwords of history, 90 days of age, users may
  change their own password. `minimum_password_length` refuses anything
  below 14 (CIS AWS Foundations 1.8); the other numbers are validated to the
  ranges IAM accepts, so a cell can loosen them and the diff shows it.
  `max_password_age_days = 0` is IAM's own "never expires" and is accepted
  as such. IAM holds one policy per account and replaces it whole, so
  adopting an account takes over whatever policy it had.
- **EBS encryption by default is regional.** It applies to the region the
  provider is pointed at. `kms_key_alias` optionally names a customer managed
  key (without `alias/`) as the region's default EBS key; the alias is
  resolved with `data.aws_kms_alias` at plan time, so a misspelt name fails
  the plan with the name in the error, and a key created in the same plan
  cannot be named (that is app-stack wiring, ADR 0017).
- **S3 Block Public Access is account-wide and has no knobs.** All four
  blocks are on. A bucket policy or ACL that would open a bucket is refused
  by S3 anywhere in the account, whatever the bucket's own settings say.
- **GuardDuty is off by default, and on is one-way.** GuardDuty is priced
  on the logs it inspects and is normally enabled estate-wide from a
  delegated administrator account, so a cell opts in. Deleting a detector
  deletes every finding it holds, so the detector is `prevent_destroy`:
  turning `guardduty.enabled` back to false fails the plan until the flag is
  lifted in a dedicated change, the same rule buckets and keys follow.
  Suspending the detector in the console keeps the findings and stops the
  bill; that is the reversible operation. Protection plans (S3, EKS, malware,
  runtime) are left at the service's defaults for a new detector; each is a
  feature resource with its own cost and is a decision of its own.
- **Access Analyzer is the account zone of trust.** `type = "ACCOUNT"`,
  regional. Organization, unused-access, and internal-access analyzers are
  different shapes with different scopes and are not offered. Findings are
  derived from the current policies, so the analyzer holds nothing a
  re-creation would not produce again; no `prevent_destroy`.
- **Everything is discovered.** Partition and account come from
  `data.aws_partition` and `data.aws_caller_identity`; a cell holds no ID.

## Usage

```hcl
module "account_hardening" {
  source = "../../modules/aws/account-hardening"

  password_policy = {
    minimum_password_length = 16
    max_password_age_days   = 60
  }

  ebs_encryption = {
    kms_key_alias = "example-ebs"
  }

  guardduty = {
    enabled = true
  }

  access_analyzer = {
    name = "example-prod-analyzer"
  }

  tags = { owner = "platform" }
}
```

A cell that wants every default passes nothing at all.

## What this module refuses

- A minimum password length below 14 or above 128, a password age outside
  0 to 1095, or a reuse history outside 1 to 24.
- `hard_expiry` with passwords that never expire.
- An EBS key alias with the `alias/` prefix, or one given while encryption
  by default is off.
- A GuardDuty publishing frequency other than the three GuardDuty accepts.
- An analyzer name outside Access Analyzer's naming rules.
- At plan time: an EBS key alias that does not exist in the account and
  region.
- Turning GuardDuty off once it has been on (`prevent_destroy`).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `password_policy` | `object` | `{}` | `{ enabled, minimum_password_length, require_*_characters, require_numbers, require_symbols, allow_users_to_change_password, max_password_age_days, password_reuse_prevention, hard_expiry }`. See `variables.tf`. |
| `ebs_encryption` | `object` | `{}` | `{ enabled, kms_key_alias }`. |
| `s3_public_access_block` | `object` | `{}` | `{ enabled }`. |
| `guardduty` | `object` | `{}` | `{ enabled (default false), finding_publishing_frequency }`. |
| `access_analyzer` | `object` | `{}` | `{ enabled, name }`. |
| `tags` | `map(string)` | `{}` | Tags for the detector and the analyzer. |

## Outputs

| Name | Description |
|------|-------------|
| `password_policy` | `{ minimum_password_length, max_password_age_days, password_reuse_prevention, expire_passwords }` or null. |
| `ebs_encryption` | `{ enabled, default_kms_key_arn }`. |
| `s3_public_access_blocked` | Whether the account-level block is managed with all four on. |
| `guardduty_detector` | `{ id, arn }` or null. |
| `access_analyzer` | `{ name, arn }` or null. |
| `partition` | Partition the account is in. |
| `account_id` | The account being hardened. |

## Import

Every resource here is a singleton with a fixed import ID except the
detector (its ID) and the analyzer (its name).

```hcl
import {
  to = module.account_hardening.aws_iam_account_password_policy.this[0]
  id = "iam-account-password-policy"
}

import {
  to = module.account_hardening.aws_ebs_encryption_by_default.this[0]
  id = "default"
}

import {
  to = module.account_hardening.aws_ebs_default_kms_key.this[0]
  id = "arn:aws:kms:us-east-1:111111111111:key/11111111-1111-1111-1111-111111111111"
}

import {
  to = module.account_hardening.aws_s3_account_public_access_block.this[0]
  id = "111111111111"
}

import {
  to = module.account_hardening.aws_guardduty_detector.this[0]
  id = "11111111111111111111111111111111"
}

import {
  to = module.account_hardening.aws_accessanalyzer_analyzer.this[0]
  id = "account-analyzer"
}
```
