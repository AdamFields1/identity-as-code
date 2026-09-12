# ---------------------------------------------------------------------------
# Tenant baseline. These apply to every policy in the map unless the entry
# overrides them. Defaults are the strict end of what PIM allows for a
# workforce tenant: four-hour activation, MFA and justification on every
# activation, no approval (approval is opted into per tenant or per role).
# ---------------------------------------------------------------------------

variable "activation_maximum_duration" {
  description = "Longest a single activation may last, as an ISO 8601 time duration between PT30M and PT24H. PT4H covers a working session without leaving a standing grant overnight."
  type        = string
  default     = "PT4H"

  validation {
    condition     = can(regex("^PT([0-9]+H)?([0-9]+M)?$", var.activation_maximum_duration)) && var.activation_maximum_duration != "PT"
    error_message = "activation_maximum_duration must be an ISO 8601 time duration such as \"PT30M\", \"PT2H\", or \"PT8H\"."
  }
}

variable "require_multifactor_authentication" {
  description = "Require MFA on activation. Leave true; an activation without MFA is a standing assignment with extra steps."
  type        = bool
  default     = true
}

variable "require_justification" {
  description = "Require a written justification on activation. It lands in the audit log next to the activation."
  type        = bool
  default     = true
}

variable "require_ticket_info" {
  description = "Require a ticket number and system on activation. Off by default; turn on where a change process exists."
  type        = bool
  default     = false
}

variable "require_approval" {
  description = "Require an approver to accept each activation. When true, approver_group_object_ids must name at least one group."
  type        = bool
  default     = false

  validation {
    condition     = !var.require_approval || length(var.approver_group_object_ids) > 0
    error_message = "require_approval is true but approver_group_object_ids is empty."
  }
}

variable "approver_group_object_ids" {
  description = "Object IDs of the Entra groups whose members may approve an activation. Resolved from display names by the calling stack; this module receives IDs so it stays free of the azuread provider."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.approver_group_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Each approver group object ID must be a GUID."
  }
}

variable "eligible_assignment_rules" {
  description = "Baseline for eligible assignments. expiration_required forces an end date on every eligibility; expire_after is the longest allowed, one of P15D, P30D, P90D, P180D, P365D."
  type = object({
    expiration_required = optional(bool, true)
    expire_after        = optional(string, "P365D")
  })
  default = {}

  validation {
    condition     = contains(["P15D", "P30D", "P90D", "P180D", "P365D"], var.eligible_assignment_rules.expire_after)
    error_message = "eligible_assignment_rules.expire_after must be one of P15D, P30D, P90D, P180D, P365D."
  }
}

variable "active_assignment_rules" {
  description = "Baseline for active (standing) assignments made through PIM. Standing access should be rare and short, so the default expires it in 180 days and requires MFA and justification to grant it."
  type = object({
    expiration_required                = optional(bool, true)
    expire_after                       = optional(string, "P180D")
    require_multifactor_authentication = optional(bool, true)
    require_justification              = optional(bool, true)
  })
  default = {}

  validation {
    condition     = contains(["P15D", "P30D", "P90D", "P180D", "P365D"], var.active_assignment_rules.expire_after)
    error_message = "active_assignment_rules.expire_after must be one of P15D, P30D, P90D, P180D, P365D."
  }
}

variable "notification_rules" {
  description = <<-EOT
    Optional admin notification settings, applied to every policy in the map. Kept to
    the admin recipients only; approver and assignee notifications keep the Azure
    defaults. Set to null to leave every notification setting untouched.

    notification_level    : "All" or "Critical".
    default_recipients    : whether the role's default admin recipients are notified.
    additional_recipients : extra mailboxes, for example a shared security inbox.
  EOT

  type = object({
    eligible_assignments = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
    eligible_activations = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
    active_assignments = optional(object({
      admin = optional(object({
        notification_level    = optional(string, "Critical")
        default_recipients    = optional(bool, true)
        additional_recipients = optional(list(string), [])
      }))
    }))
  })
  default = null

  validation {
    condition = var.notification_rules == null || alltrue([
      for section in [
        try(var.notification_rules.eligible_assignments.admin, null),
        try(var.notification_rules.eligible_activations.admin, null),
        try(var.notification_rules.active_assignments.admin, null),
      ] : section == null || contains(["All", "Critical"], section.notification_level)
    ])
    error_message = "notification_level must be \"All\" or \"Critical\"."
  }
}

# ---------------------------------------------------------------------------
# The policies themselves: one entry per (scope, role) pair.
# ---------------------------------------------------------------------------

variable "policies" {
  description = <<-EOT
    Role management policies to manage, keyed by a stable logical name (for example
    "owner-at-root"). The key is part of the Terraform address and should never change.

    role_name : display name of a built-in or custom role, for example "Contributor"
                or "Platform Operator". Resolved at the given scope.
    scope     : { type, name } with type one of "management_group" (display name),
                "subscription" (display name), or "resource_group" (name).

    activation, eligible_assignment_rules, and active_assignment_rules override the
    module-level baseline for this entry only. Every field is optional and a field
    left unset inherits the module default.
  EOT

  type = map(object({
    role_name = string

    scope = object({
      type = string
      name = string
    })

    activation = optional(object({
      maximum_duration                   = optional(string)
      require_multifactor_authentication = optional(bool)
      require_justification              = optional(bool)
      require_ticket_info                = optional(bool)
      require_approval                   = optional(bool)
      approver_group_object_ids          = optional(list(string))
    }), {})

    eligible_assignment_rules = optional(object({
      expiration_required = optional(bool)
      expire_after        = optional(string)
    }), {})

    active_assignment_rules = optional(object({
      expiration_required                = optional(bool)
      expire_after                       = optional(string)
      require_multifactor_authentication = optional(bool)
      require_justification              = optional(bool)
    }), {})
  }))

  validation {
    condition = alltrue([
      for p in var.policies : contains(["management_group", "subscription", "resource_group"], p.scope.type)
    ])
    error_message = "scope.type must be \"management_group\", \"subscription\", or \"resource_group\"."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.activation.maximum_duration == null || (can(regex("^PT([0-9]+H)?([0-9]+M)?$", p.activation.maximum_duration)) && p.activation.maximum_duration != "PT")
    ])
    error_message = "activation.maximum_duration must be an ISO 8601 time duration such as \"PT30M\" or \"PT2H\" when set."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.eligible_assignment_rules.expire_after == null || contains(["P15D", "P30D", "P90D", "P180D", "P365D"], p.eligible_assignment_rules.expire_after)
    ])
    error_message = "eligible_assignment_rules.expire_after must be one of P15D, P30D, P90D, P180D, P365D when set."
  }

  validation {
    condition = alltrue([
      for p in var.policies :
      p.active_assignment_rules.expire_after == null || contains(["P15D", "P30D", "P90D", "P180D", "P365D"], p.active_assignment_rules.expire_after)
    ])
    error_message = "active_assignment_rules.expire_after must be one of P15D, P30D, P90D, P180D, P365D when set."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.policies : [
        for id in coalesce(p.activation.approver_group_object_ids, []) :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
      ]
    ]))
    error_message = "Each approver group object ID must be a GUID."
  }

  validation {
    condition     = length(distinct([for p in var.policies : "${p.scope.type}/${p.scope.name}|${p.role_name}"])) == length(var.policies)
    error_message = "Two entries target the same (scope, role) pair. Azure has exactly one policy per pair, so merge them."
  }
}
