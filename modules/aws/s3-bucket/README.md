# modules/aws/s3-bucket

Manages a map of S3 general purpose buckets with the posture fixed and the
per-bucket choices as values: encryption (SSE-S3 or a KMS key by alias), an
optional list of roles that are the only principals allowed to touch objects,
lifecycle numbers, optional access logging into another bucket of the same
map, and tags. It is the bucket entry of the AWS catalog stack (ADR 0017).

## Design notes

- **ACLs are disabled.** `BucketOwnerEnforced` object ownership means every
  object belongs to the bucket owner and the bucket policy is the only place
  access is decided. There is no ACL for a grant to hide in.
- **Nothing public, ever.** All four public access block settings are on.
  A policy that would open the bucket is refused by S3, not by a review.
- **Versioning is on, and bounded.** Every overwrite and delete keeps the
  previous version, so a mistake is recoverable. The lifecycle rule expires
  noncurrent versions after `noncurrent_version_expiration_days` (default 30)
  and aborts unfinished multipart uploads after
  `abort_incomplete_multipart_upload_days` (default 7), which is what keeps
  "recoverable" from meaning "kept forever". `expiration_days` optionally
  expires current objects; when it is unset the rule removes expired delete
  markers instead, so a versioned bucket does not accumulate tombstones.
- **TLS is required by policy.** `DenyInsecureTransport` denies every action
  for every principal when `aws:SecureTransport` is false. A precondition
  checks the rendered policy still carries it.
- **Encryption is SSE-S3 unless a key is named.** `kms_key_alias` names a
  KMS alias (without `alias/`) that is looked up in the account; the bucket
  then uses SSE-KMS with a bucket key. The default is SSE-S3 because a bucket
  that receives access logs must be SSE-S3 (S3 would otherwise deliver logs
  encrypted with a key the owner may not read), and because a key is its own
  resource with its own policy (`modules/aws/kms-key`). A key created in the
  same plan is app-stack wiring; the catalog looks aliases up.
- **Role restriction is a deny, scoped to object data.** With
  `allowed_role_names` set, the policy denies `GetObject`, `PutObject`,
  `DeleteObject`, and their version forms on the bucket's objects to every
  principal whose `aws:PrincipalArn` is not one of the named roles. The
  roles are looked up by name with `data.aws_iam_role`, so the ARN carries
  the role's real path and a misspelt name fails the plan.
  `aws:PrincipalArn` carries the role ARN for a role session, so every
  session of a listed role is allowed and no session of any other principal
  is, including the account root. AWS service principals are exempted
  through `aws:PrincipalIsAWSService` so log delivery still lands. Listing
  keys (`s3:ListBucket`, `s3:ListBucketVersions`) is deliberately not in
  the deny and stays with IAM, as bucket management always did: the
  provider reads a bucket with `HeadBucket`, which S3 authorizes as
  `s3:ListBucket`, so a deny on it would fail every refresh by the identity
  that manages the bucket unless that identity were listed, and the release
  train plans as a read-only deployment role and applies as a writer, two
  identities no cell knows. The deploying identity therefore manages the
  bucket and sees key names without being listed, and cannot read an
  object; an unlisted role that IAM lets list the bucket sees key names and
  nothing else. A `management_role_names` input that would let listing be
  denied too is deliberately not offered, because a cell would have to
  type the estate's deployment role names into it.
- **Access logging is a pair the module completes.** A source names its
  target by map key; the module enables logging on the source and adds the
  `logging.s3` grant to the target's policy, conditioned on the source's ARN
  and this account, under the source's prefix (default `<source name>/`).
  Logging is enabled only after the target's policy is written, because S3
  checks it when logging is turned on. A target must be SSE-S3 and must not
  itself log anywhere.
- **CloudTrail delivery is named as a trail, not as a principal.** A bucket
  that receives a trail's log files lists the trail in
  `cloudtrail_delivery.trail_names` (with the trail's `s3_key_prefix` as
  `prefix` when it has one), and the module adds the two statements the
  CloudTrail documentation gives: `AWSCloudTrailAclCheck` (`s3:GetBucketAcl`
  on the bucket) and `AWSCloudTrailWrite` (`s3:PutObject` under
  `[prefix/]AWSLogs/<this account>/*`, only with the
  `bucket-owner-full-control` ACL, which S3 still accepts under
  `BucketOwnerEnforced`). Both are conditioned with `aws:SourceArn` on the
  named trails' ARNs, built from the caller's partition, region, and account,
  so a trail in another account cannot write here and no ARN is typed. A
  precondition checks the rendered policy carries the write statement. The
  bucket policy must exist before the trail is created, because CloudTrail
  checks it at `CreateTrail`; the stack that composes the two orders them.
  With `allowed_role_names` set, CloudTrail still lands because service
  principals are exempt from the data deny.
- **`force_destroy` is false and the bucket is `prevent_destroy`.** A bucket
  holds data nothing in this repository can recreate. Retiring one is a
  deliberate change that flips the flag first, never a side effect of
  removing an entry from a cell. A bucket rename is a replacement and is
  refused for the same reason.
- **Everything is discovered.** Bucket ARNs come from `data.aws_partition`,
  the log delivery condition from `data.aws_caller_identity`, and roles and
  keys are looked up by name. A cell holds no ARN and no id.

## What checkov says, and what is skipped

Two checks are skipped on the bucket and one on the encryption
configuration, each with the reason in an inline `checkov:skip` comment:

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AWS_144` | Ensure that S3 bucket has cross-region replication enabled | Replication needs a second bucket in a second region, a replication role, and a decision about which region. That is a design for the bucket that needs it, in an app stack, not a default for every catalog bucket. |
| `CKV2_AWS_62` | Ensure S3 buckets should have event notifications enabled | Notifications name a queue, topic, or function, which is cross-resource wiring the catalog does not express (ADR 0017). |
| `CKV_AWS_145` | Ensure that S3 buckets are encrypted with KMS by default | SSE-S3 is the default and SSE-KMS is one value away. The default is SSE-S3 because a logging target must be, and because a key is a separate resource with its own policy and cell. |

## Usage

```hcl
module "buckets" {
  source = "../../modules/aws/s3-bucket"

  buckets = {
    access-logs = {
      name            = "example-prod-access-logs"
      expiration_days = 365
    }

    artifacts = {
      name               = "example-prod-artifacts"
      kms_key_alias      = "example-artifacts"
      allowed_role_names = ["example-ci-deployer", "example-app-server"]
      access_logging     = { target_bucket = "access-logs" }
    }

    cloudtrail = {
      name                = "example-prod-cloudtrail"
      kms_key_alias       = "cloudtrail"
      cloudtrail_delivery = { trail_names = ["account-trail"] }
      access_logging      = { target_bucket = "access-logs" }
    }
  }
}
```

## What this module refuses

- A bucket name outside the S3 naming rules, or one used twice.
- A `kms_key_alias` with the `alias/` prefix, or a role name that is an ARN
  or a wildcard.
- A bucket that logs to itself, to a bucket outside the map, to a bucket that
  itself logs somewhere, or to a bucket encrypted with KMS.
- A `cloudtrail_delivery` with no trail names, a trail name outside the
  CloudTrail naming rules or given as an ARN, or a prefix with a leading or
  trailing slash.
- At plan time: a KMS alias or a role that does not exist in the account.
- A rendered policy without the TLS deny, a logging target whose policy
  lacks the delivery grant, or a CloudTrail target whose policy lacks the
  write statement (module invariants, checked as preconditions).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `buckets` | `map(object)` | n/a | Buckets keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `buckets` | Map of key to `{ name, arn, id, region, regional_domain_name, sse_algorithm, kms_key_arn, log_target_bucket_name }`. |
| `bucket_arns_by_name` | Map of bucket name to ARN. |
| `allowed_role_arns` | Map of role name to ARN for every role named in any `allowed_role_names`. |
| `partition` | Partition the buckets were created in. |
| `account_id` | Account the buckets were created in. |

## Import

Every resource in this module imports by bucket name.

```hcl
import {
  to = module.buckets.aws_s3_bucket.this["artifacts"]
  id = "example-prod-artifacts"
}

import {
  to = module.buckets.aws_s3_bucket_policy.this["artifacts"]
  id = "example-prod-artifacts"
}

import {
  to = module.buckets.aws_s3_bucket_lifecycle_configuration.this["artifacts"]
  id = "example-prod-artifacts"
}
```
