variable "storage_accounts" {
  description = <<-EOT
    General-purpose (StorageV2, Standard tier) storage accounts to manage, keyed
    by a stable logical name (for example "app-artifacts"). The key is part of
    the Terraform address and should never change once applied. Change the
    visible name with "name".

    name                                 : 3 to 24 lowercase letters and digits,
                                           globally unique. Immutable.
    resource_group_name                  : existing resource group, by name. Looked
                                           up, never created here.
    location                             : Azure region. Null (default) uses the
                                           resource group's location.
    account_replication_type             : LRS, ZRS, GRS (default), RAGRS, GZRS,
                                           or RAGZRS.
    access_tier                          : Hot (default), Cool, or Cold.
    infrastructure_encryption_enabled    : true (default) encrypts twice with
                                           platform-managed keys. Create-time only:
                                           changing it replaces the account, which
                                           prevent_destroy refuses.
    hierarchical_namespace_enabled       : true makes the account a Data Lake
                                           Storage Gen2 account (directories, POSIX
                                           ACLs, the dfs endpoint). Blob versioning
                                           is not supported with it, so such an
                                           entry sets blob_versioning_enabled = false.
    blob_versioning_enabled              : true (default) keeps every overwritten or
                                           deleted blob as a previous version.
    blob_soft_delete_retention_days      : days a deleted blob stays recoverable.
                                           1 to 365, default 14.
    container_soft_delete_retention_days : days a deleted container stays
                                           recoverable. 1 to 365, default 14.
    public_network_access_enabled        : false (default) refuses every request
                                           from a public address; only private
                                           endpoints reach the account. True opens
                                           the public endpoint to allowed_ip_ranges
                                           and, with trusted_services_bypass, to
                                           trusted Azure services; everything else is
                                           still denied.
    allowed_ip_ranges                    : public IPv4 addresses or CIDR blocks
                                           admitted through the firewall. Only
                                           accepted when public_network_access_enabled
                                           is true. Private ranges are refused
                                           because the storage firewall refuses them.
    trusted_services_bypass              : true (default) lets the trusted Azure
                                           services list through the firewall;
                                           false admits only the listed addresses.
    containers                           : private blob containers keyed by a
                                           stable name, each with the container
                                           name and optional metadata. Every
                                           container is private; the account
                                           forbids anonymous access.
    role_assignments                     : data-plane role assignments, keyed by a
                                           stable name:
        role_name     : one of the Storage data-plane roles (Storage Blob Data
                        Reader, Storage Blob Data Contributor, Storage Queue Data
                        Contributor, ...) or Reader. Management-plane write roles
                        are refused.
        principal     : { type = "identity", name = "<key of identity_principal_ids>" }
                        or { type = "group", name = "<Entra security group display name>" }.
        container_key : optional. A key of this entry's containers; the assignment
                        is then scoped to that container and role_name must be a
                        Storage Blob Data role. Null scopes it to the account.
        description   : recorded on the assignment; what an auditor reads next to it.
    log_analytics_workspace              : { name, resource_group_name } of an
                                           existing Log Analytics workspace,
                                           resolved by name. When set, a diagnostic
                                           setting on the blob service sends every
                                           read, write, and delete with its caller,
                                           plus transaction metrics, to it. Null
                                           (default) creates no diagnostic setting.
    tags                                 : tags on the account, merged over the
                                           module-level tags; the entry wins per key.
  EOT

  type = map(object({
    name                                 = string
    resource_group_name                  = string
    location                             = optional(string)
    account_replication_type             = optional(string, "GRS")
    access_tier                          = optional(string, "Hot")
    infrastructure_encryption_enabled    = optional(bool, true)
    hierarchical_namespace_enabled       = optional(bool, false)
    blob_versioning_enabled              = optional(bool, true)
    blob_soft_delete_retention_days      = optional(number, 14)
    container_soft_delete_retention_days = optional(number, 14)
    public_network_access_enabled        = optional(bool, false)
    allowed_ip_ranges                    = optional(list(string), [])
    trusted_services_bypass              = optional(bool, true)

    containers = optional(map(object({
      name     = string
      metadata = optional(map(string), {})
    })), {})

    role_assignments = optional(map(object({
      role_name = string
      principal = object({
        type = string
        name = string
      })
      container_key = optional(string)
      description   = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    })), {})

    log_analytics_workspace = optional(object({
      name                = string
      resource_group_name = string
    }))

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for sa in var.storage_accounts : can(regex("^[a-z0-9]{3,24}$", sa.name))])
    error_message = "Every storage account name must be 3 to 24 lowercase letters and digits."
  }

  validation {
    condition     = length(distinct([for sa in var.storage_accounts : sa.name])) == length(var.storage_accounts)
    error_message = "Two entries have the same storage account name. The name is a global DNS label, so merge them into one entry."
  }

  validation {
    condition     = alltrue([for sa in var.storage_accounts : length(trimspace(sa.resource_group_name)) > 0])
    error_message = "resource_group_name must not be empty."
  }

  validation {
    condition     = alltrue([for sa in var.storage_accounts : contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], sa.account_replication_type)])
    error_message = "account_replication_type must be LRS, ZRS, GRS, RAGRS, GZRS, or RAGZRS."
  }

  validation {
    condition     = alltrue([for sa in var.storage_accounts : contains(["Hot", "Cool", "Cold"], sa.access_tier)])
    error_message = "access_tier must be Hot, Cool, or Cold."
  }

  validation {
    condition = alltrue([
      for sa in var.storage_accounts :
      sa.blob_soft_delete_retention_days >= 1 && sa.blob_soft_delete_retention_days <= 365 && floor(sa.blob_soft_delete_retention_days) == sa.blob_soft_delete_retention_days
    ])
    error_message = "blob_soft_delete_retention_days must be a whole number from 1 to 365."
  }

  validation {
    condition = alltrue([
      for sa in var.storage_accounts :
      sa.container_soft_delete_retention_days >= 1 && sa.container_soft_delete_retention_days <= 365 && floor(sa.container_soft_delete_retention_days) == sa.container_soft_delete_retention_days
    ])
    error_message = "container_soft_delete_retention_days must be a whole number from 1 to 365."
  }

  validation {
    condition     = alltrue([for sa in var.storage_accounts : !(sa.hierarchical_namespace_enabled && sa.blob_versioning_enabled)])
    error_message = "Blob versioning is not supported on an account with a hierarchical namespace. An entry with hierarchical_namespace_enabled = true must set blob_versioning_enabled = false; soft delete still protects it."
  }

  validation {
    condition     = alltrue([for sa in var.storage_accounts : sa.public_network_access_enabled || length(sa.allowed_ip_ranges) == 0])
    error_message = "allowed_ip_ranges has no effect while public_network_access_enabled is false (the account refuses every public address regardless). Remove the list, or set public_network_access_enabled = true to admit those addresses and nothing else."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for ip in sa.allowed_ip_ranges : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|30))?$", ip))
      ]
    ]))
    error_message = "Every allowed_ip_ranges entry must be an IPv4 address or a CIDR block no smaller than /30, for example 203.0.113.10 or 203.0.113.0/24. The storage firewall does not accept /31 or /32 prefixes; write a single address without a prefix."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for ip in sa.allowed_ip_ranges : !can(regex("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)", ip))
      ]
    ]))
    error_message = "allowed_ip_ranges must hold public addresses. The storage firewall refuses private (10/8, 172.16/12, 192.168/16), loopback, and link-local ranges; a private network reaches an account through a private endpoint or a virtual network rule, neither of which this module creates."
  }

  validation {
    # The shape regex above accepts any prefix from /0 to /30; this is the
    # floor. try() returns true when there is no prefix (a single address)
    # and leaves a malformed prefix to the shape validation's message.
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for ip in sa.allowed_ip_ranges : !can(regex("^0\\.", ip)) && try(tonumber(split("/", ip)[1]) >= 8, true)
      ]
    ]))
    error_message = "An allowed_ip_ranges entry names a runner or a NAT block: a single public address, or a block no wider than /8. 0.0.0.0 in any form, the 0.0.0.0/8 network, and any prefix shorter than /8 are refused; opening an account's data plane to the internet is not a value this catalog offers, whatever the firewall's default action."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for c in sa.containers : can(regex("^[a-z0-9](?:[a-z0-9]|-[a-z0-9]){2,62}$", c.name)) && length(c.name) <= 63
      ]
    ]))
    error_message = "Every container name must be 3 to 63 lowercase letters, digits, and single hyphens, starting and ending with a letter or digit."
  }

  validation {
    condition = alltrue([
      for sa in var.storage_accounts : length(distinct([for c in sa.containers : c.name])) == length(sa.containers)
    ])
    error_message = "Two containers on the same account have the same name."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for a in sa.role_assignments : contains([
          "Reader",
          "Storage Blob Data Reader",
          "Storage Blob Data Contributor",
          "Storage Blob Data Owner",
          "Storage Blob Delegator",
          "Storage Queue Data Reader",
          "Storage Queue Data Contributor",
          "Storage Queue Data Message Processor",
          "Storage Queue Data Message Sender",
          "Storage Table Data Reader",
          "Storage Table Data Contributor",
          "Storage File Data SMB Share Reader",
          "Storage File Data SMB Share Contributor",
          "Storage File Data SMB Share Elevated Contributor",
          "Storage File Data Privileged Reader",
          "Storage File Data Privileged Contributor",
        ], a.role_name)
      ]
    ]))
    error_message = "role_name must be Reader or one of the Storage data-plane roles: Storage Blob Data Reader, Storage Blob Data Contributor, Storage Blob Data Owner, Storage Blob Delegator, Storage Queue Data Reader, Storage Queue Data Contributor, Storage Queue Data Message Processor, Storage Queue Data Message Sender, Storage Table Data Reader, Storage Table Data Contributor, Storage File Data SMB Share Reader, Storage File Data SMB Share Contributor, Storage File Data SMB Share Elevated Contributor, Storage File Data Privileged Reader, or Storage File Data Privileged Contributor. Owner, Contributor, and Storage Account Contributor are management-plane roles and are not offered here."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [for a in sa.role_assignments : contains(["identity", "group"], a.principal.type)]
    ]))
    error_message = "principal.type must be \"identity\" (a key of identity_principal_ids) or \"group\" (an Entra security group display name)."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [for a in sa.role_assignments : length(trimspace(a.principal.name)) > 0 && length(trimspace(a.description)) > 0]
    ]))
    error_message = "principal.name and description must not be empty; the description is what an auditor reads next to the assignment."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for a in sa.role_assignments : a.container_key == null || contains(keys(sa.containers), coalesce(a.container_key, "-"))
      ]
    ]))
    error_message = "A role assignment's container_key must be a key of the same entry's containers map."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for a in sa.role_assignments :
        a.container_key == null || contains(["Storage Blob Data Reader", "Storage Blob Data Contributor", "Storage Blob Data Owner"], a.role_name)
      ]
    ]))
    error_message = "A container-scoped role assignment must use Storage Blob Data Reader, Storage Blob Data Contributor, or Storage Blob Data Owner; the other roles have no meaning at a container."
  }

  validation {
    condition = alltrue([
      for sa in var.storage_accounts :
      length(distinct([
        for a in sa.role_assignments : "${a.container_key == null ? "" : a.container_key}|${a.principal.type}/${lower(a.principal.name)}|${lower(a.role_name)}"
      ])) == length(sa.role_assignments)
    ])
    error_message = "Two entries on the same account give the same principal the same role at the same scope. Azure holds one assignment per (scope, role, principal), so merge them."
  }

  validation {
    condition = alltrue([
      for sa in var.storage_accounts :
      sa.log_analytics_workspace == null || (length(trimspace(try(sa.log_analytics_workspace.name, ""))) > 0 && length(trimspace(try(sa.log_analytics_workspace.resource_group_name, ""))) > 0)
    ])
    error_message = "log_analytics_workspace needs both name and resource_group_name when set."
  }
}

variable "identity_principal_ids" {
  description = "Managed identities a role assignment may name with principal = { type = \"identity\", name = <key> }, as a map of key to service principal object ID. Usually the principal_ids output of modules/azure/managed-identity, so the keys are that module's identity keys."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.identity_principal_ids) : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "Every identity_principal_ids value must be a GUID."
  }
}

variable "tags" {
  description = "Tags applied to every storage account. An entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
