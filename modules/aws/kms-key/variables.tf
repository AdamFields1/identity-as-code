variable "keys" {
  description = <<-EOT
    KMS keys to manage, keyed by a stable logical name (for example
    "artifacts"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. The visible name is the alias.

    alias                    : alias name WITHOUT the "alias/" prefix, for example
                               "example-artifacts". Letters, digits, slashes,
                               underscores, and hyphens; must not start with "aws/",
                               which is reserved for AWS managed keys. Unique per
                               account and region.
    description              : shown in the console next to the key.
    deletion_window_in_days  : days between ScheduleKeyDeletion and the key being
                               gone, 7 to 30. Default 30, the maximum, because a
                               deleted key takes its ciphertext with it.
    rotation_period_in_days  : days between automatic rotations of the key material,
                               90 to 2560. Default 365. Rotation itself is always on.
    administrator_role_names : IAM role NAMES in this account that may manage the
                               key (policy, aliases, grants, tags, enable, disable,
                               schedule and cancel deletion) but not use it.
    user_role_names          : IAM role NAMES in this account that may use the key
                               (encrypt, decrypt, re-encrypt, generate data keys,
                               describe) and let AWS services create grants on it
                               for resources they manage.
    service_users            : AWS services that use the key under their own
                               service principal rather than under a caller's
                               role, from the allowlist: "logs" (CloudWatch Logs,
                               for log groups in this account and region; the
                               grant is conditioned on the log group ARN that
                               CloudWatch Logs presents as encryption context).
                               S3 and SSM Parameter Store are not on the list
                               because they use the caller's own permissions and
                               need no service grant. Default none.
    cloudtrail_trail_names   : CloudTrail trail NAMES in this account and region
                               that encrypt their log and digest files under this
                               key. Adds the statements the CloudTrail
                               documentation requires for the cloudtrail service
                               principal (GenerateDataKey* under the trail's
                               encryption context, DescribeKey, and Decrypt for a
                               bucket that uses an S3 Bucket Key), scoped with
                               aws:SourceArn to the named trails wherever the
                               documentation allows a condition. Default none.
    tags                     : resource tags on the key.

    Role names may carry a path ("service/deployer"); the module builds the ARN
    with the caller's partition and account id, so the same values deploy to any
    account in either partition. Trail ARNs are built the same way, with the
    provider's region as the trail's home region. The account root principal is
    always a key administrator with kms:*, so the key cannot be orphaned by
    deleting the roles it names.
  EOT

  type = map(object({
    alias                    = string
    description              = optional(string, "Managed by Terraform.")
    deletion_window_in_days  = optional(number, 30)
    rotation_period_in_days  = optional(number, 365)
    administrator_role_names = optional(list(string), [])
    user_role_names          = optional(list(string), [])
    service_users            = optional(list(string), [])
    cloudtrail_trail_names   = optional(list(string), [])
    tags                     = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for k in var.keys : can(regex("^[a-zA-Z0-9/_-]{1,250}$", k.alias)) && !startswith(k.alias, "alias/")])
    error_message = "alias is the alias name without the \"alias/\" prefix: 1 to 250 letters, digits, slashes, underscores, and hyphens. The module adds the prefix."
  }

  validation {
    condition     = alltrue([for k in var.keys : !startswith(k.alias, "aws/")])
    error_message = "Aliases starting with \"aws/\" are reserved for AWS managed keys and cannot be created."
  }

  validation {
    condition     = length(distinct([for k in var.keys : k.alias])) == length(var.keys)
    error_message = "Aliases must be unique within the map; KMS holds one alias per name per account and region."
  }

  validation {
    condition = alltrue([
      for k in var.keys : k.deletion_window_in_days >= 7 && k.deletion_window_in_days <= 30 && floor(k.deletion_window_in_days) == k.deletion_window_in_days
    ])
    error_message = "deletion_window_in_days must be a whole number from 7 to 30."
  }

  validation {
    condition = alltrue([
      for k in var.keys : k.rotation_period_in_days >= 90 && k.rotation_period_in_days <= 2560 && floor(k.rotation_period_in_days) == k.rotation_period_in_days
    ])
    error_message = "rotation_period_in_days must be a whole number from 90 to 2560."
  }

  validation {
    condition = alltrue(flatten([
      for k in var.keys : [
        for n in concat(k.administrator_role_names, k.user_role_names) : can(regex("^([\\w+=,.@-]+/)*[\\w+=,.@-]{1,64}$", n))
      ]
    ]))
    error_message = "administrator_role_names and user_role_names hold IAM role NAMES, optionally with a path such as service/deployer: letters, digits, and + = , . @ _ - per segment. \"*\" is refused because a key policy that names every principal is a public key, and an ARN is refused because the module builds it from the caller's account."
  }

  validation {
    condition = alltrue(flatten([
      for k in var.keys : [for s in k.service_users : contains(["logs"], s)]
    ]))
    error_message = "service_users entries must be from the allowlist: logs (CloudWatch Logs log groups in this account and region). The allowlist is the catalog: a service that is not on it needs a review of its own condition keys, not a free-text service principal."
  }

  validation {
    condition     = alltrue([for k in var.keys : length(distinct(k.service_users)) == length(k.service_users)])
    error_message = "service_users must not list a service twice; each entry is one statement in the key policy."
  }

  validation {
    condition = alltrue(flatten([
      for k in var.keys : [
        for n in k.cloudtrail_trail_names :
        can(regex("^[A-Za-z0-9]([._-]?[A-Za-z0-9])*$", n)) && length(n) >= 3 && length(n) <= 128 && !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", n))
      ]
    ]))
    error_message = "cloudtrail_trail_names holds CloudTrail trail NAMES: 3 to 128 letters, digits, periods, underscores, and hyphens, starting and ending with a letter or digit, no two separators in a row, not an IP address, never an ARN. The module builds each trail's ARN from the caller's partition, region, and account."
  }
}
