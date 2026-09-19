variable "resource_groups" {
  description = <<-EOT
    Resource groups to manage, keyed by a stable logical name (for example
    "identity-automation"). The key is part of the Terraform address and should
    never change once applied. Change the visible name with "name".

    name        : the resource group name in Azure. 1 to 90 letters, digits,
                  underscores, hyphens, periods, and parentheses, not ending in
                  a period. Immutable (a change replaces the group, which
                  prevent_destroy refuses).
    location    : Azure region, for example "eastus". Immutable for the same
                  reason.
    tags        : tags on the group, merged over the module-level tags; the
                  entry wins per key.
    delete_lock : true adds a CanNotDelete management lock on the group. While
                  the lock exists, nothing in the group can be deleted from the
                  portal, the CLI, or any Terraform plan, including plans of
                  other cells. False (the default) adds no lock.
    lock_notes  : text recorded on the lock, shown to whoever the lock stops.
  EOT

  type = map(object({
    name        = string
    location    = string
    tags        = optional(map(string), {})
    delete_lock = optional(bool, false)
    lock_notes  = optional(string, "Locked by Terraform. Turn delete_lock off in the identity-as-code repository, apply, and then delete.")
  }))
  default = {}

  validation {
    condition     = alltrue([for rg in var.resource_groups : can(regex("^[-\\w.()]{1,90}$", rg.name)) && !endswith(rg.name, ".")])
    error_message = "Every resource group name must be 1 to 90 letters, digits, underscores, hyphens, periods, and parentheses, and must not end in a period."
  }

  validation {
    condition     = length(distinct([for rg in var.resource_groups : lower(rg.name)])) == length(var.resource_groups)
    error_message = "Two entries have the same resource group name. Azure holds one group per name per subscription, so merge them into one entry."
  }

  validation {
    condition     = alltrue([for rg in var.resource_groups : can(regex("^[a-z0-9]{3,40}$", rg.location))])
    error_message = "location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }

  validation {
    condition     = alltrue([for rg in var.resource_groups : length(trimspace(rg.lock_notes)) > 0])
    error_message = "lock_notes must not be empty; it is what the lock shows to whoever it stops."
  }
}

variable "tags" {
  description = "Tags applied to every resource group. An entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
