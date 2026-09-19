variable "namespaces" {
  description = <<-EOT
    SSM Parameter Store namespaces to reserve, keyed by a stable logical name
    (for example "app"). The key becomes part of the Terraform resource address,
    so renaming a key moves the resource in state. Each entry creates one
    SecureString parameter, <prefix>/placeholder, and nothing else.

    prefix      : the namespace, a parameter path starting with a slash and
                  without a trailing slash, for example /payments-api/prod. Up to
                  14 segments of letters, digits, underscores, periods, and
                  hyphens, so the placeholder stays inside the 15-level limit.
                  Must not start with /aws or /ssm, which are reserved. Immutable
                  (forces replacement, which prevent_destroy refuses).
    description : shown in the console next to the placeholder. The default
                  says what the parameter is for and where real values go.
    kms_key_id  : key id or key ARN of the customer managed KMS key the
                  placeholder is encrypted with, as the key module outputs it.
                  Required: a parameter under the account's default key has no
                  key policy anyone reviews.
    tags        : resource tags on the placeholder.

    Fixed for every namespace: SecureString, Standard tier, value "placeholder"
    written once and then ignored, prevent_destroy. The placeholder must never
    hold a real value; real secrets are siblings under the prefix, written
    outside Terraform.
  EOT

  type = map(object({
    prefix      = string
    description = optional(string, "Reserves this namespace and proves its key and grants end to end. Real secrets are siblings of this parameter, written outside Terraform; this value is never a secret.")
    kms_key_id  = string
    tags        = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for n in var.namespaces : can(regex("^(/[A-Za-z0-9_.-]+){1,14}$", n.prefix))])
    error_message = "prefix must be a parameter path starting with a slash and without a trailing slash, for example /payments-api/prod: 1 to 14 segments of letters, digits, underscores, periods, and hyphens. The module appends /placeholder, which is the fifteenth level SSM allows at most."
  }

  validation {
    condition     = alltrue([for n in var.namespaces : !can(regex("^/(aws|ssm)(/|$)", lower(n.prefix)))])
    error_message = "prefix must not start with /aws or /ssm; those trees are reserved by Systems Manager."
  }

  validation {
    condition     = length(distinct([for n in var.namespaces : n.prefix])) == length(var.namespaces)
    error_message = "Prefixes must be unique within the map; a namespace is reserved once."
  }

  validation {
    condition = alltrue([
      for n in var.namespaces : can(regex("^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$", n.kms_key_id))
    ])
    error_message = "kms_key_id must be a KMS key id or a key ARN (arn:<partition>:kms:<region>:<account>:key/<key id>), not an alias or an alias ARN. SSM stores what it is given and reports it back, so an alias would plan a change on every run. A stack passes the kms-key module's key_id output; a cell never types it."
  }
}
