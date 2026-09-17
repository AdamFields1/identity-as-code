variable "name" {
  description = "Storage account name: 3 to 24 lowercase letters and digits, globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "name must be 3 to 24 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  description = "Existing resource group for the account, by name. Looked up, never created."
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

variable "container_name" {
  description = "Name of the private backup container: 3 to 63 lowercase letters, digits, and single hyphens, starting and ending with a letter or digit."
  type        = string
  default     = "runbook-backups"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9]|-[a-z0-9]){2,62}$", var.container_name)) && length(var.container_name) <= 63
    error_message = "container_name must be 3 to 63 lowercase letters, digits, and single hyphens, starting and ending with a letter or digit."
  }
}

variable "account_replication_type" {
  description = "Replication: LRS, ZRS, GRS (default), RAGRS, GZRS, or RAGZRS. Backups are worth a second region where the platform allows it."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be LRS, ZRS, GRS, RAGRS, GZRS, or RAGZRS."
  }
}

variable "retention_days" {
  description = "Days a deleted blob, and a deleted container, stay recoverable (soft delete). 1 to 365, default 14."
  type        = number
  default     = 14

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 365 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days must be a whole number from 1 to 365."
  }
}

variable "version_retention_days" {
  description = "Days after a blob version was created that the lifecycle rule deletes it. Versioning keeps the content of every blob the writer deletes, so this is what makes the writer's own retention free anything. Default 30, which matches the backup runbook's RetentionDays default; raise it to keep deleted backups longer than the writer does."
  type        = number
  default     = 30

  validation {
    condition     = var.version_retention_days >= 1 && var.version_retention_days <= 3650 && floor(var.version_retention_days) == var.version_retention_days
    error_message = "version_retention_days must be a whole number from 1 to 3650."
  }
}

variable "public_network_access_enabled" {
  description = "Allow the blob endpoint to be reached from public networks. True by default because Azure Automation cloud jobs have no fixed egress; access still needs an Entra token and the container role."
  type        = bool
  default     = true
}

variable "writer_principal_ids" {
  description = "Service principals that write and prune backups, as a map of a stable key (the caller's identity tier) to object ID. Each is granted Storage Blob Data Contributor on the container only. Usually one entry: the identity of the tier that runs the backup runbook."
  type        = map(string)

  validation {
    condition     = length(var.writer_principal_ids) > 0
    error_message = "writer_principal_ids must name at least one principal; a backup container nobody may write to is a misconfiguration."
  }

  validation {
    condition     = alltrue([for id in values(var.writer_principal_ids) : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "Every writer_principal_ids value must be a GUID."
  }
}

variable "tags" {
  description = "Tags applied to the storage account."
  type        = map(string)
  default     = {}
}
