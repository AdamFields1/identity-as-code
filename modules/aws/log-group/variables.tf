variable "log_groups" {
  description = <<-EOT
    CloudWatch Logs log groups to manage, keyed by a stable logical name (for
    example "app"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. The group name is "name".

    name              : the log group name, 1 to 512 characters of letters, digits,
                        underscores, hyphens, slashes, periods, and hash signs, for
                        example /ecs/payments-api/prod. Immutable (forces
                        replacement, which prevent_destroy refuses).
    retention_in_days : days the events are kept, one of the values CloudWatch Logs
                        accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365,
                        400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653.
                        "Never expire" (0) is not offered.
    kms_key_arn       : ARN of the customer managed KMS key the events are encrypted
                        with. Required. The key's policy must grant the CloudWatch
                        Logs service principal for log groups in this account and
                        region (modules/aws/kms-key, service_users = ["logs"]); the
                        API refuses the association otherwise. A key ARN, not an
                        alias: CloudWatch Logs stores and reports the ARN, and an
                        alias would plan a change on every run.
    tags              : resource tags on the group.

    Fixed for every group: prevent_destroy.
  EOT

  type = map(object({
    name              = string
    retention_in_days = number
    kms_key_arn       = string
    tags              = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for g in var.log_groups : can(regex("^[A-Za-z0-9_./#-]{1,512}$", g.name))])
    error_message = "Log group names must be 1 to 512 characters of letters, digits, underscores, hyphens, slashes, periods, and hash signs, for example /ecs/payments-api/prod."
  }

  validation {
    condition     = length(distinct([for g in var.log_groups : g.name])) == length(var.log_groups)
    error_message = "Log group names must be unique within the map; CloudWatch Logs holds one group per name per account and region."
  }

  validation {
    condition = alltrue([
      for g in var.log_groups : contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], g.retention_in_days)
    ])
    error_message = "retention_in_days must be one of the values CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653. Zero (never expire) is not offered: a group that keeps everything forever is a records-retention decision, and ten years is the longest value the API has."
  }

  validation {
    condition = alltrue([
      for g in var.log_groups : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", g.kms_key_arn))
    ])
    error_message = "kms_key_arn must be a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<key id>), not an alias, an alias ARN, or a bare key id. CloudWatch Logs stores the key ARN, and anything else here would plan a change on every run. A stack passes the kms-key module's arn output; a cell never types it."
  }
}
