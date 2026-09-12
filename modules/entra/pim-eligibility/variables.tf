variable "directory_role_eligibilities" {
  description = <<-EOT
    Entra directory role eligibilities granted to role-assignable groups, keyed by a
    stable logical name (for example "global-admin"). Each entry makes every member
    of the group eligible to activate the role through PIM.

    role_display_name  : built-in directory role name as shown in the portal, for
                         example "Global Administrator". Resolved to the role template
                         ID by the module.
    group_display_name : the role-assignable group. Resolved to an object ID.
    directory_scope_id : "/" (default) for tenant-wide, or an administrative unit
                         scope such as "/administrativeUnits/<id>".
    justification      : recorded on the schedule request.
  EOT

  type = map(object({
    role_display_name  = string
    group_display_name = string
    directory_scope_id = optional(string, "/")
    justification      = optional(string, "Managed by Terraform. See the identity-as-code repository.")
  }))
  default = {}

  validation {
    condition = alltrue([
      for e in var.directory_role_eligibilities :
      length(trimspace(e.role_display_name)) > 0 && length(trimspace(e.group_display_name)) > 0
    ])
    error_message = "role_display_name and group_display_name must not be empty."
  }

  validation {
    condition = length(distinct([
      for e in var.directory_role_eligibilities : "${e.role_display_name}/${e.group_display_name}/${e.directory_scope_id}"
    ])) == length(var.directory_role_eligibilities)
    error_message = "Each role, group, and scope combination may appear only once."
  }

  validation {
    condition     = alltrue([for e in var.directory_role_eligibilities : can(regex("^/", e.directory_scope_id))])
    error_message = "directory_scope_id must start with / (use \"/\" for tenant-wide)."
  }
}

variable "group_eligibilities" {
  description = <<-EOT
    PIM for Groups eligibilities, keyed by a stable logical name. Each entry makes a
    user or a group eligible for membership (or ownership) of a PIM-enabled group.

    group_display_name : the PIM-enabled target group. Resolved to an object ID.
    principal_user     : user principal name of an eligible user. Exactly one of
                         principal_user or principal_group is required.
    principal_group    : display name of an eligible group.
    assignment_type    : "member" (default) or "owner".
    permanent          : true (default) for an eligibility with no end date.
    duration           : ISO 8601 duration for a time-bound eligibility. Setting it
                         implies permanent = false.
    justification      : recorded on the schedule.
  EOT

  type = map(object({
    group_display_name = string
    principal_user     = optional(string)
    principal_group    = optional(string)
    assignment_type    = optional(string, "member")
    permanent          = optional(bool, true)
    duration           = optional(string)
    justification      = optional(string, "Managed by Terraform. See the identity-as-code repository.")
  }))
  default = {}

  validation {
    condition = alltrue([
      for e in var.group_eligibilities : (e.principal_user != null) != (e.principal_group != null)
    ])
    error_message = "Each group eligibility must set exactly one of principal_user or principal_group."
  }

  validation {
    condition = alltrue([
      for e in var.group_eligibilities : e.principal_user == null || can(regex("^[^@\\s]+@[^@\\s]+$", e.principal_user))
    ])
    error_message = "principal_user must be a user principal name (user@domain)."
  }

  validation {
    condition     = alltrue([for e in var.group_eligibilities : contains(["member", "owner"], e.assignment_type)])
    error_message = "assignment_type must be member or owner."
  }

  validation {
    condition = alltrue([
      for e in var.group_eligibilities : e.duration == null || (can(regex("^P([0-9]+[YMWD])*(T([0-9]+[HMS])+)?$", e.duration)) && e.duration != "P")
    ])
    error_message = "duration must be an ISO 8601 duration such as P180D or PT8H when set."
  }

  validation {
    condition = alltrue([
      for e in var.group_eligibilities : e.permanent || e.duration != null
    ])
    error_message = "A non-permanent eligibility must set duration."
  }

  validation {
    condition = length(distinct([
      for e in var.group_eligibilities : "${e.group_display_name}/${e.assignment_type}/${coalesce(e.principal_user, e.principal_group)}"
    ])) == length(var.group_eligibilities)
    error_message = "Each group, assignment_type, and principal combination may appear only once."
  }
}
