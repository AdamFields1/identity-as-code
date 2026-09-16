variable "principal_object_id" {
  description = "Object ID of the service principal to grant to. Use for a managed identity created in the same plan (the automation-account module outputs it). Exactly one of principal_object_id and principal_display_name is required."
  type        = string
  default     = null

  validation {
    condition     = var.principal_object_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.principal_object_id))
    error_message = "principal_object_id must be a GUID when set."
  }
}

variable "principal_display_name" {
  description = "Display name of the service principal to grant to, resolved with azuread_service_principal. A managed identity's service principal carries the identity's name. Exactly one of principal_object_id and principal_display_name is required."
  type        = string
  default     = null

  validation {
    condition     = (var.principal_object_id == null) != (var.principal_display_name == null)
    error_message = "Set exactly one of principal_object_id or principal_display_name."
  }

  validation {
    condition     = var.principal_display_name == null || length(trimspace(var.principal_display_name)) > 0
    error_message = "principal_display_name must not be empty when set."
  }
}

variable "app_role_names" {
  description = "Microsoft Graph application permission names to grant, for example [\"Application.Read.All\", \"Mail.Send\"]. Case sensitive. Removing a name revokes the grant."
  type        = list(string)

  validation {
    condition     = length(var.app_role_names) > 0
    error_message = "app_role_names must list at least one permission."
  }

  validation {
    condition     = alltrue([for r in var.app_role_names : can(regex("^[A-Za-z0-9]+(\\.[A-Za-z0-9]+)+$", r))])
    error_message = "Each app role name must look like a Graph permission, for example User.Read.All."
  }

  validation {
    condition     = length(distinct(var.app_role_names)) == length(var.app_role_names)
    error_message = "app_role_names must not contain duplicates."
  }
}
