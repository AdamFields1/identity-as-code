variable "eligibilities" {
  description = <<-EOT
    PIM eligible role assignments to manage, keyed by a stable logical name (for
    example "platform-operators-at-root"). The key is part of the Terraform address
    and should never change once applied.

    group_display_name : Entra security group whose members become eligible.
                         Resolved by display name; the group must already exist.
    role_name          : built-in or custom role display name, resolved at scope.
    scope              : { type, name } with type one of "management_group"
                         (display name), "subscription" (display name), or
                         "resource_group" (name in the provider's subscription).
    justification      : recorded on the eligibility in the PIM audit log.

    expiration is one of two shapes. { duration_days = n } expires the eligibility
    n days after it is applied, within the policy's expire_after. { permanent = true }
    has no end date and is only accepted when the policy for that (scope, role) has
    expiration_required = false. The default is 365 days.
  EOT

  type = map(object({
    group_display_name = string
    role_name          = string

    scope = object({
      type = string
      name = string
    })

    justification = optional(string, "Managed by Terraform. See the identity-as-code repository.")

    expiration = optional(object({
      duration_days = optional(number, 365)
      permanent     = optional(bool, false)
    }), {})
  }))

  validation {
    condition = alltrue([
      for e in var.eligibilities : contains(["management_group", "subscription", "resource_group"], e.scope.type)
    ])
    error_message = "scope.type must be \"management_group\", \"subscription\", or \"resource_group\"."
  }

  validation {
    condition = alltrue([
      for e in var.eligibilities :
      e.expiration.permanent || (e.expiration.duration_days >= 1 && e.expiration.duration_days <= 365)
    ])
    error_message = "expiration.duration_days must be between 1 and 365 unless expiration.permanent is true."
  }

  validation {
    condition     = alltrue([for e in var.eligibilities : length(trimspace(e.group_display_name)) > 0])
    error_message = "group_display_name must not be empty."
  }

  validation {
    condition     = alltrue([for e in var.eligibilities : length(trimspace(e.justification)) > 0])
    error_message = "justification must not be empty; it is what an auditor reads next to the eligibility."
  }

  validation {
    condition = length(distinct([
      for e in var.eligibilities : "${e.scope.type}/${e.scope.name}|${e.role_name}|${e.group_display_name}"
    ])) == length(var.eligibilities)
    error_message = "Two entries give the same group the same role at the same scope. Azure holds one eligibility per (scope, role, principal), so merge them."
  }
}
