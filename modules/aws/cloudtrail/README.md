# modules/aws/cloudtrail

Manages a map of CloudTrail trails with the audit posture fixed and the
delivery as values: which bucket, under which prefix, under which KMS key,
and which management events. It is the trail half of
`stacks/aws-account-baseline`; the bucket and the key it delivers to come
from `modules/aws/s3-bucket` and `modules/aws/kms-key`, whose policies name
the trail.

## Design notes

- **The audit posture is fixed.** Every trail is multi-region, includes
  global service events, has log file validation on, is logging, and is not
  an organization trail. A single-region trail misses what an attacker does
  elsewhere, an unvalidated trail cannot show that a log file was changed
  after delivery, and an organization trail is a different shape (management
  account, `AWSLogs/<org id>/` path) that this module does not offer.
- **The bucket and the key are named, and must be ready first.** CloudTrail
  checks the bucket policy and the key policy at `CreateTrail` and refuses
  with `InsufficientS3BucketPolicyException` or
  `InsufficientEncryptionPolicyException` if either does not name the trail.
  `modules/aws/s3-bucket` adds the bucket statements from
  `cloudtrail_delivery.trail_names`, `modules/aws/kms-key` adds the key
  statements from `cloudtrail_trail_names`, and the stack that composes the
  three orders them with `depends_on`. This module has no data sources, so
  being depended on costs it nothing in a plan.
- **The key is an ARN, not an alias.** CloudTrail stores the key ARN and
  reports it back, so an alias here would plan a change on every run. The
  stack passes the key module's `arn` output; a cell never types it.
- **Management events, with two documented exclusions.** `read_write_type`
  is `All` by default. `exclude_kms_events` and `exclude_rds_data_api_events`
  map to the only two sources CloudTrail lets a trail exclude, named as the
  API names them. Data events and Insights are application choices with
  their own cost and are not offered.
- **No `prevent_destroy`.** The trail holds nothing; its log files live in
  the bucket, which the bucket module refuses to destroy. Removing a trail
  stops logging and is visible as a destroy in the plan.

## What checkov says, and what is skipped

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV2_AWS_10` | Ensure CloudTrail trails are integrated with CloudWatch Logs | Needs a log group and a role CloudTrail can assume with `logs:PutLogEvents`. That is a composition of its own, not a knob on the trail (ADR 0017). |
| `CKV_AWS_252` | Ensure CloudTrail defines an SNS Topic | Names a topic, which is cross-resource wiring this module does not express. |

## Usage

```hcl
module "trail" {
  source = "../../modules/aws/cloudtrail"

  trails = {
    account = {
      name           = "account-trail"
      s3_bucket_name = module.trail_bucket.buckets["trail"].name
      kms_key_arn    = module.trail_key.keys["trail"].arn
      management_events = {
        exclude_kms_events = true
      }
    }
  }

  depends_on = [module.trail_bucket, module.trail_key]
}
```

## What this module refuses

- A trail name outside the CloudTrail naming rules, or one used twice.
- A bucket ARN where a bucket name is expected, or a name outside the S3
  naming rules.
- A key prefix with a leading or trailing slash or longer than 200
  characters.
- A KMS alias, alias ARN, or bare key ID where a key ARN is expected.
- A `read_write_type` other than `All`, `ReadOnly`, or `WriteOnly`.
- At apply time, from CloudTrail itself: a bucket or key whose policy does
  not name the trail.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `trails` | `map(object)` | n/a | Trails keyed by logical name. See `variables.tf` for the full shape and validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `trails` | Map of key to `{ name, arn, home_region, s3_bucket_name, s3_key_prefix, kms_key_arn }`. |
| `trail_arns_by_name` | Map of trail name to ARN. |

## Import

A trail imports by its ARN.

```hcl
import {
  to = module.trail.aws_cloudtrail.this["account"]
  id = "arn:aws:cloudtrail:us-east-1:111111111111:trail/account-trail"
}
```
