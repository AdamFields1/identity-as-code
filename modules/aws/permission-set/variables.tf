variable "permission_sets" {
  description = <<-EOT
    Permission sets to manage, keyed by a stable logical name (for example
    "platform-admin"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the visible name with "name".

    name                      : the permission set name in Identity Center. Immutable
                                (forces replacement). 1 to 32 characters from the IAM
                                name character set.
    description               : shown in the console and the access portal.
    session_duration          : ISO 8601 duration for the console and CLI session a
                                user gets when they assume this permission set. AWS
                                allows PT1H to PT12H. Default PT1H, the AWS default
                                and the module's secure default. This is a security
                                control: it bounds how long a stolen session is
                                usable. Set it per permission set, not per tenant.
    relay_state               : optional console URL to land on after federation.
    aws_managed_policies      : AWS managed policy NAMES (for example
                                "ReadOnlyAccess" or "job-function/Billing"). The
                                module builds the ARN with the current partition, so
                                the same value works in commercial and GovCloud.
    customer_managed_policies : customer managed policies that must already exist,
                                with the same name and path, in every account the
                                permission set is assigned to. Identity Center
                                references them by name and path, never by ARN.
    inline_policy             : optional IAM policy document as a JSON string. One per
                                permission set; Identity Center allows only one.
    permissions_boundary      : optional boundary. Exactly one of aws_managed_policy
                                (a policy NAME, partition-aware like
                                aws_managed_policies) or customer_managed_policy
                                ({ name, path }).
    tags                      : resource tags on the permission set.
  EOT

  type = map(object({
    name             = string
    description      = optional(string, "Managed by Terraform.")
    session_duration = optional(string, "PT1H")
    relay_state      = optional(string)

    aws_managed_policies = optional(list(string), [])

    customer_managed_policies = optional(list(object({
      name = string
      path = optional(string, "/")
    })), [])

    inline_policy = optional(string)

    permissions_boundary = optional(object({
      aws_managed_policy = optional(string)
      customer_managed_policy = optional(object({
        name = string
        path = optional(string, "/")
      }))
    }))

    tags = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for ps in var.permission_sets : can(regex("^[\\w+=,.@-]{1,32}$", ps.name))])
    error_message = "Permission set names must be 1 to 32 characters of letters, digits, and + = , . @ _ -."
  }

  validation {
    condition     = length(distinct([for ps in var.permission_sets : ps.name])) == length(var.permission_sets)
    error_message = "Permission set names must be unique; Identity Center holds one permission set per name per instance."
  }

  validation {
    condition = alltrue([
      for ps in var.permission_sets : can(regex("^PT(([1-9]|1[01])H([1-5]?[0-9]M)?|12H|[6-9][0-9]M|[1-9][0-9]{2}M)$", ps.session_duration))
    ])
    error_message = "session_duration must be an ISO 8601 duration between PT1H and PT12H, for example PT1H, PT4H, PT8H, or PT1H30M."
  }

  validation {
    condition = alltrue([
      for ps in var.permission_sets : ps.relay_state == null || can(regex("^https://", coalesce(ps.relay_state, "https://")))
    ])
    error_message = "relay_state must be an https URL when set."
  }

  validation {
    condition = alltrue(flatten([
      for ps in var.permission_sets : [for p in ps.aws_managed_policies : can(regex("^[\\w+=,.@/-]+$", p)) && !startswith(p, "arn:")]
    ]))
    error_message = "aws_managed_policies lists policy NAMES (optionally with a path prefix such as job-function/Billing), never ARNs. The module adds the partition-aware ARN prefix."
  }

  validation {
    condition = alltrue(flatten([
      for ps in var.permission_sets : [for p in ps.customer_managed_policies : can(regex("^/([\\w+=,.@-]+/)*$", p.path))]
    ]))
    error_message = "customer_managed_policies path must start and end with a slash, for example / or /platform/."
  }

  validation {
    condition     = alltrue([for ps in var.permission_sets : ps.inline_policy == null || can(jsondecode(coalesce(ps.inline_policy, "{}")))])
    error_message = "inline_policy must be a valid JSON policy document when set."
  }

  validation {
    condition = alltrue([
      for ps in var.permission_sets : ps.permissions_boundary == null || (
        (try(ps.permissions_boundary.aws_managed_policy, null) != null) != (try(ps.permissions_boundary.customer_managed_policy, null) != null)
      )
    ])
    error_message = "permissions_boundary must set exactly one of aws_managed_policy or customer_managed_policy."
  }

  validation {
    condition = alltrue([
      for ps in var.permission_sets : try(ps.permissions_boundary.aws_managed_policy, null) == null || !startswith(coalesce(try(ps.permissions_boundary.aws_managed_policy, null), ""), "arn:")
    ])
    error_message = "permissions_boundary.aws_managed_policy is a policy NAME, never an ARN."
  }
}
