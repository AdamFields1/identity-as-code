variable "name" {
  description = "Name of the Automation account. Six to fifty characters, letters, digits, and hyphens, starting with a letter and ending with a letter or digit."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$", var.name))
    error_message = "name must be 6 to 50 characters of letters, digits, and hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "resource_group_name" {
  description = "Existing resource group the account and its identity are created in. Looked up by name, never created here."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Azure region. Null (default) uses the resource group's location."
  type        = string
  default     = null
}

variable "identity_name" {
  description = "Name of the user-assigned managed identity the account runs as. Three to 128 characters of letters, digits, hyphens, and underscores, starting with a letter or digit."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", var.identity_name))
    error_message = "identity_name must be 3 to 128 characters of letters, digits, hyphens, and underscores, starting with a letter or digit."
  }
}

variable "sku_name" {
  description = "Automation account SKU: Basic (default) or Free."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Free"], var.sku_name)
    error_message = "sku_name must be Basic or Free."
  }
}

variable "local_authentication_enabled" {
  description = "Allow non-Entra (agent registration key) authentication to the account. False by default; nothing in this repository needs it."
  type        = bool
  default     = false
}

variable "public_network_access_enabled" {
  description = "Allow the account's endpoints to be reached from public networks. True by default; set false only with a private endpoint in place."
  type        = bool
  default     = true
}

variable "variables" {
  description = <<-EOT
    Automation account variables keyed by variable name. Each entry:

    type        : "string" or "bool". Selects the provider resource type.
    value       : the value as a string. For "bool" it must be "true" or "false".
    description : optional.
    encrypted   : optional, default false. Encrypted variables cannot be read back
                  by Terraform and are stored in state only as written here; this
                  repository keeps no secret in a variable, so the default stands.
  EOT

  type = map(object({
    type        = string
    value       = string
    description = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    encrypted   = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.variables : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,127}$", k))])
    error_message = "Variable names must start with a letter and contain only letters, digits, hyphens, and underscores."
  }

  validation {
    condition     = alltrue([for v in var.variables : contains(["string", "bool"], v.type)])
    error_message = "Variable type must be \"string\" or \"bool\"."
  }

  validation {
    condition     = alltrue([for v in var.variables : v.type != "bool" || contains(["true", "false"], v.value)])
    error_message = "A bool variable's value must be \"true\" or \"false\"."
  }
}

variable "modules" {
  description = "PowerShell module assets to add to the account, keyed by module name, each with the uri of the .zip or .nupkg and an optional content hash. Empty by default; the runbooks here use REST and need none."
  type = map(object({
    uri = string
    hash = optional(object({
      algorithm = string
      value     = string
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for m in var.modules : can(regex("^https://", m.uri))])
    error_message = "Module uri must be an https URL."
  }
}

variable "tags" {
  description = "Tags applied to the account and the identity."
  type        = map(string)
  default     = {}
}
