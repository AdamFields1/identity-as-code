variable "principal_id" {
  description = "Object ID of the service principal every assignment is made to, for example the principal_id output of modules/azure/automation-account. Also the value of the <principal_id> condition token."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.principal_id))
    error_message = "principal_id must be a GUID."
  }
}

variable "assignments" {
  description = <<-EOT
    Role assignments keyed by a stable logical name. The key is part of the
    Terraform address and should never change once applied.

    role_name         : built-in or custom role display name, resolved at the scope.
    scope             : { type, name } with type one of "management_group" (display
                        name), "subscription" (display name), "resource_group" (name in
                        the provider's subscription), or "resource_id" (a full ARM ID
                        in name, for a caller that created the resource in the same plan).
    description       : recorded on the assignment; what an auditor reads next to it.
    condition         : optional Azure ABAC condition text. May use the tokens
                        <principal_id> (the object ID above) and <role_id:NAME> (the
                        GUID of the role named NAME, resolved at the scope). See README.
    condition_version : "2.0", the default whenever condition is set.

    Owner, User Access Administrator, and Role Based Access Control Administrator
    are accepted only with a condition: an unconditioned assignment of any of them
    lets the principal grant itself anything at the scope.
  EOT

  type = map(object({
    role_name = string

    scope = object({
      type = string
      name = string
    })

    description       = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    condition         = optional(string)
    condition_version = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for a in var.assignments : contains(["management_group", "subscription", "resource_group", "resource_id"], a.scope.type)
    ])
    error_message = "scope.type must be \"management_group\", \"subscription\", \"resource_group\", or \"resource_id\"."
  }

  validation {
    condition     = alltrue([for a in var.assignments : length(trimspace(a.scope.name)) > 0 && length(trimspace(a.role_name)) > 0])
    error_message = "scope.name and role_name must not be empty."
  }

  validation {
    condition     = alltrue([for a in var.assignments : length(trimspace(a.description)) > 0])
    error_message = "description must not be empty; it is what an auditor reads next to the assignment."
  }

  validation {
    condition = alltrue([
      for a in var.assignments : a.condition == null || (length(trimspace(coalesce(a.condition, " "))) > 0 && !strcontains(coalesce(a.condition, " "), "<role_id>"))
    ])
    error_message = "condition must not be empty when set, and must not contain \"<role_id>\" (a role token without a name), which the token substitution uses internally."
  }

  validation {
    condition     = alltrue([for a in var.assignments : a.condition_version == null || (a.condition != null && a.condition_version == "2.0")])
    error_message = "condition_version must be \"2.0\" and is only valid together with condition."
  }

  validation {
    condition = alltrue([
      for a in var.assignments :
      !contains(["owner", "user access administrator", "role based access control administrator"], lower(trimspace(a.role_name))) || a.condition != null
    ])
    error_message = "Owner, User Access Administrator, and Role Based Access Control Administrator must carry a condition. Unconditioned, any of them lets the identity grant itself anything at the scope."
  }

  validation {
    condition = length(distinct([
      for a in var.assignments : "${a.scope.type}/${lower(a.scope.name)}|${lower(a.role_name)}"
    ])) == length(var.assignments)
    error_message = "Two entries assign the same role at the same scope to the same principal. Merge them into one entry with one condition."
  }
}
