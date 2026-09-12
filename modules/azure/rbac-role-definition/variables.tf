variable "roles" {
  description = <<-EOT
    Custom role definitions to manage, keyed by a stable logical name (for example
    "platform-operator"). The key becomes part of the Terraform resource address, so
    renaming a key moves the resource in state. Change the display name with the
    "name" attribute instead.

    name             : role display name as it appears in the portal. Unique per tenant.
    description      : what the role is for and who should hold it. Shown in the portal.
    actions          : control-plane operations the role grants. At least one is required.
    not_actions      : control-plane operations subtracted from actions.
    data_actions     : data-plane operations the role grants.
    not_data_actions : data-plane operations subtracted from data_actions.

    assignable_scope is where the definition is created and the first scope it can
    be assigned at. additional_assignable_scopes widens that list. Each scope is
    { type, name } with type one of "management_group" (display name),
    "subscription" (display name), or "resource_group" (name in the provider's
    subscription). No scope is ever given as an ID.
  EOT

  type = map(object({
    name        = string
    description = string

    actions          = list(string)
    not_actions      = optional(list(string), [])
    data_actions     = optional(list(string), [])
    not_data_actions = optional(list(string), [])

    assignable_scope = object({
      type = string
      name = string
    })

    additional_assignable_scopes = optional(list(object({
      type = string
      name = string
    })), [])
  }))

  validation {
    condition     = alltrue([for r in var.roles : length(r.actions) > 0])
    error_message = "Each role must grant at least one control-plane action. A role with only data_actions is invisible in the portal because the principal cannot read the resource it acts on; grant at least \"*/read\" or a narrower read."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [
        for a in concat(r.actions, r.not_actions, r.data_actions, r.not_data_actions) :
        can(regex("^[A-Za-z0-9*./_-]+$", a))
      ]
    ]))
    error_message = "Action strings must look like \"Microsoft.Compute/virtualMachines/read\" or \"*/read\": letters, digits, dots, slashes, hyphens, underscores, and the * wildcard."
  }

  validation {
    condition = alltrue([
      for r in var.roles :
      contains(["management_group", "subscription", "resource_group"], r.assignable_scope.type)
    ])
    error_message = "assignable_scope.type must be \"management_group\", \"subscription\", or \"resource_group\"."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.roles : [
        for s in r.additional_assignable_scopes :
        contains(["management_group", "subscription", "resource_group"], s.type)
      ]
    ]))
    error_message = "Every additional_assignable_scopes entry must have type \"management_group\", \"subscription\", or \"resource_group\"."
  }

  validation {
    condition     = alltrue([for r in var.roles : length(trimspace(r.description)) > 0])
    error_message = "Each role needs a non-empty description. It is the only place a portal user learns what the role is for."
  }

  validation {
    condition     = length(distinct([for r in var.roles : r.name])) == length(var.roles)
    error_message = "Role display names must be unique within the map; Azure rejects two custom roles with the same name in one tenant."
  }
}
