variable "groups" {
  description = <<-EOT
    Security groups to manage, keyed by a stable logical name (for example
    "pim-global-admin"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the display name with
    "display_name".

    display_name       : shown in the portal. Unique in the tenant (prevent_duplicate_names).
    description        : optional.
    assignable_to_role : true creates a role-assignable group (isAssignableToRole).
                         This is immutable after creation and requires the caller to hold
                         Privileged Role Administrator. Role-assignable groups cannot have
                         dynamic membership and cannot contain nested groups.
    owners             : user principal names. Resolved to object IDs by the module.
    member_users       : user principal names to add as direct members.
    member_groups      : display names of EXISTING groups to nest as members. Groups
                         managed by the same module call cannot be referenced here.

    When both member lists are empty the module does not manage membership at all
    (the provider attribute is left null). That is required for PIM-enabled groups,
    where activation writes membership and Terraform must not fight it.
  EOT

  type = map(object({
    display_name       = string
    description        = optional(string, "Managed by Terraform.")
    assignable_to_role = optional(bool, false)
    owners             = optional(list(string), [])
    member_users       = optional(list(string), [])
    member_groups      = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for g in var.groups : length(trimspace(g.display_name)) > 0])
    error_message = "Every group must have a non-empty display_name."
  }

  validation {
    condition     = length(distinct([for g in var.groups : g.display_name])) == length(var.groups)
    error_message = "Group display names must be unique within the map."
  }

  validation {
    condition = alltrue(flatten([
      for g in var.groups : [for upn in concat(g.owners, g.member_users) : can(regex("^[^@\\s]+@[^@\\s]+$", upn))]
    ]))
    error_message = "Owners and member_users must be user principal names (user@domain)."
  }

  validation {
    condition = alltrue([
      for g in var.groups : !(g.assignable_to_role && length(g.member_groups) > 0)
    ])
    error_message = "Role-assignable groups cannot contain nested groups. Remove member_groups or set assignable_to_role = false."
  }

  validation {
    condition = alltrue(flatten([
      for g in var.groups : [for name in g.member_groups : !contains([for x in var.groups : x.display_name], name)]
    ]))
    error_message = "member_groups must name groups that already exist outside this module call, not groups defined in the same map."
  }
}
