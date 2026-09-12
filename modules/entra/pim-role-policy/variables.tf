variable "policies" {
  description = <<-EOT
    PIM for Groups role management policies, keyed by a stable logical name (for
    example "global-admin-member"). Each policy governs how one role (member or owner)
    of one PIM-enabled group is activated and assigned.

    group_display_name : the governed group, resolved to an object ID by the module.
    role               : "member" (default) or "owner".

    activation : rules applied when an eligible principal activates.
      maximum_duration                   : ISO 8601 duration, default PT4H.
      require_multifactor_authentication : default true.
      require_justification              : default true.
      require_ticket_info                : default false.
      require_approval                   : default false. When true, approver_groups is required.
      approver_groups                    : display names of groups whose members approve.

    eligible_assignment : rules for how long a principal can stay eligible.
      expiration_required : default true.
      expire_after        : ISO 8601 duration, default P365D.

    active_assignment : rules for direct (non-PIM) active assignment.
      expiration_required                : default true.
      expire_after                       : ISO 8601 duration, default P180D.
      require_justification              : default true.
      require_multifactor_authentication : default true.

    notifications : minimal admin notification settings.
      admin_notification_level : "All" or "Critical", default "All".
      admin_default_recipients : default true.
      admin_additional_recipients : extra email addresses.

    Durations follow ISO 8601 (P365D, PT4H, PT30M). Days and hours cannot be mixed
    with weeks; Entra rejects P1W together with other components.
  EOT

  type = map(object({
    group_display_name = string
    role               = optional(string, "member")

    activation = optional(object({
      maximum_duration                   = optional(string, "PT4H")
      require_multifactor_authentication = optional(bool, true)
      require_justification              = optional(bool, true)
      require_ticket_info                = optional(bool, false)
      require_approval                   = optional(bool, false)
      approver_groups                    = optional(list(string), [])
    }), {})

    eligible_assignment = optional(object({
      expiration_required = optional(bool, true)
      expire_after        = optional(string, "P365D")
    }), {})

    active_assignment = optional(object({
      expiration_required                = optional(bool, true)
      expire_after                       = optional(string, "P180D")
      require_justification              = optional(bool, true)
      require_multifactor_authentication = optional(bool, true)
    }), {})

    notifications = optional(object({
      admin_notification_level    = optional(string, "All")
      admin_default_recipients    = optional(bool, true)
      admin_additional_recipients = optional(list(string), [])
    }), {})
  }))

  validation {
    condition     = alltrue([for p in var.policies : contains(["member", "owner"], p.role)])
    error_message = "role must be member or owner."
  }

  validation {
    condition     = alltrue([for p in var.policies : length(trimspace(p.group_display_name)) > 0])
    error_message = "group_display_name must not be empty."
  }

  validation {
    condition     = length(distinct([for p in var.policies : "${p.group_display_name}/${p.role}"])) == length(var.policies)
    error_message = "Each group and role combination may appear only once; Entra holds exactly one policy per group per role."
  }

  validation {
    condition = alltrue([
      for p in var.policies : alltrue([
        for d in [p.activation.maximum_duration, p.eligible_assignment.expire_after, p.active_assignment.expire_after] :
        can(regex("^P([0-9]+[YMWD])*(T([0-9]+[HMS])+)?$", d)) && d != "P"
      ])
    ])
    error_message = "maximum_duration and expire_after must be ISO 8601 durations such as PT4H, PT30M, P180D, or P1Y."
  }

  validation {
    condition = alltrue([
      for p in var.policies : !p.activation.require_approval || length(p.activation.approver_groups) > 0
    ])
    error_message = "When require_approval is true, at least one approver group display name is required."
  }

  validation {
    condition     = alltrue([for p in var.policies : contains(["All", "Critical"], p.notifications.admin_notification_level)])
    error_message = "admin_notification_level must be All or Critical."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [for e in p.notifications.admin_additional_recipients : can(regex("^[^@\\s]+@[^@\\s]+$", e))]
    ]))
    error_message = "admin_additional_recipients must be email addresses."
  }
}
