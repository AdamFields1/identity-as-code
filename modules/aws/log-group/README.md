# modules/aws/log-group

Manages a map of CloudWatch Logs log groups with the posture fixed and the
two things that vary as values: how long the events are kept, and which
customer managed key encrypts them. It is the log group of
`stacks/apps/aws/payments-api`; the key it names comes from
`modules/aws/kms-key`, whose policy grants the CloudWatch Logs service.

## Design notes

- **Retention is bounded, never "never expire".** `retention_in_days` must
  be one of the values CloudWatch Logs accepts, from one day to ten years,
  and 0 is not offered. A group that keeps everything forever is a cost and
  a records-retention decision; the longest value the API has is available
  and a cell says which one it wants.
- **Encryption is a customer managed key, and it is required.** A group under
  the service's own key has no key policy anyone reviews. `kms_key_arn`
  names the key by ARN, not alias, for the same reason
  `modules/aws/cloudtrail` does: the API stores and reports the ARN, and an
  alias would plan a change on every run. The key's policy must grant the
  CloudWatch Logs service principal for log groups in this account and region
  (`service_users = ["logs"]` in `modules/aws/kms-key`); CloudWatch Logs
  checks that when the key is associated and refuses otherwise, so a stack
  that composes the two orders the key first by handing this module the key
  module's `arn` output.
- **Every group is `prevent_destroy`.** Deleting a group deletes every event
  in it before its retention would have. Retiring a workload is a deliberate
  change that flips the flag first, in a pull request that is obviously about
  deleting it. A name change is a replacement and is refused for the same
  reason.
- **Nothing is looked up.** A log group depends on nothing but the key it
  names, so this module reads no data source and costs nothing when another
  module depends on it.

## What checkov says, and what is skipped

| Check | Title | Why it is skipped here |
|-------|-------|------------------------|
| `CKV_AWS_338` | Ensure CloudWatch log groups retains logs for at least 1 year | Retention is a value the cell sets from its own records-retention decision. The module refuses "never expire" and offers every value the API accepts up to ten years; a year is one of them, not the floor. |

## Usage

```hcl
module "log_group" {
  source = "../../modules/aws/log-group"

  log_groups = {
    app = {
      name              = "/ecs/payments-api/prod"
      retention_in_days = 365
      kms_key_arn       = module.key.keys["app"].arn
      tags              = { Application = "payments-api" }
    }
  }
}
```

## What this module refuses

- A log group name outside the CloudWatch Logs naming rules, or one used
  twice.
- A `retention_in_days` that CloudWatch Logs does not accept, including 0
  (never expire).
- A KMS alias, alias ARN, or bare key id where a key ARN is expected, and a
  group with no key at all.
- At apply time, from CloudWatch Logs itself: a key whose policy does not
  grant the `logs.<region>.<dns suffix>` service principal.
- A destroy of a group without lifting `prevent_destroy` in a dedicated
  change.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `log_groups` | `map(object)` | n/a | Log groups keyed by logical name: `name`, `retention_in_days`, `kms_key_arn`, `tags`. See `variables.tf` for the validation rules. |

## Outputs

| Name | Description |
|------|-------------|
| `log_groups` | Map of key to `{ name, arn, retention_in_days, kms_key_arn }`. |
| `log_group_arns_by_name` | Map of log group name to ARN. |

## Import

A log group imports by name.

```hcl
import {
  to = module.log_group.aws_cloudwatch_log_group.this["app"]
  id = "/ecs/payments-api/prod"
}
```
