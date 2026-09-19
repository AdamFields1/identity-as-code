variable "key_vaults" {
  description = <<-EOT
    Key vaults to manage, keyed by a stable logical name (for example
    "rotation-secrets"). The key is part of the Terraform address and should
    never change once applied. Change the visible name with "name".

    name                            : the vault name, which is also its DNS label
                                      (<name>.vault.azure.net): 3 to 24 letters,
                                      digits, and hyphens, starting with a letter,
                                      ending with a letter or digit, no consecutive
                                      hyphens, globally unique. Immutable.
    resource_group_name             : existing resource group, by name. Looked up,
                                      never created here.
    location                        : Azure region. Null (default) uses the resource
                                      group's location.
    sku_name                        : "standard" (default) or "premium" (HSM-backed keys).
    soft_delete_retention_days      : days a deleted vault, secret, key, or certificate
                                      stays recoverable. 7 to 90, default 90. Immutable
                                      once set.
    public_network_access_enabled   : false (default) refuses every request from a
                                      public address; only private endpoints reach the
                                      vault. True opens the public endpoint to the
                                      addresses in allowed_ip_ranges and, with
                                      trusted_services_bypass, to trusted Azure services;
                                      everything else is still denied.
    allowed_ip_ranges               : public IPv4 addresses or CIDR blocks admitted
                                      through the firewall. Only meaningful, and only
                                      accepted, when public_network_access_enabled is
                                      true. Private (RFC 1918) ranges are refused
                                      because Key Vault refuses them.
    trusted_services_bypass         : true (default) lets the trusted Azure services
                                      list (Azure Backup, Disk Encryption, Resource
                                      Manager template deployment, and the rest)
                                      through the firewall; false admits only the
                                      listed addresses.
    enabled_for_deployment          : let Azure virtual machines read certificates
                                      from the vault. Default false.
    enabled_for_disk_encryption     : let Azure Disk Encryption read secrets and
                                      unwrap keys. Default false.
    enabled_for_template_deployment : let Resource Manager read secrets during a
                                      template deployment. Default false.
    log_analytics_workspace         : { name, resource_group_name } of an existing
                                      Log Analytics workspace, resolved by name.
                                      When set, a diagnostic setting sends the
                                      vault's AuditEvent log (every data-plane call
                                      and its caller) and metrics to it. Null
                                      (default) creates no diagnostic setting.
    role_assignments                : data-plane role assignments on the vault,
                                      keyed by a stable name:
        role_name   : one of the Key Vault built-in data-plane roles (Key Vault
                      Secrets User, Key Vault Reader, ...). Management-plane roles
                      and Key Vault Data Access Administrator are refused.
        principal   : { type = "identity", name = "<key of identity_principal_ids>" }
                      or { type = "group", name = "<Entra security group display name>" }.
        description : recorded on the assignment; what an auditor reads next to it.
    tags                            : tags on the vault, merged over the module-level
                                      tags; the entry wins per key.
  EOT

  type = map(object({
    name                            = string
    resource_group_name             = string
    location                        = optional(string)
    sku_name                        = optional(string, "standard")
    soft_delete_retention_days      = optional(number, 90)
    public_network_access_enabled   = optional(bool, false)
    allowed_ip_ranges               = optional(list(string), [])
    trusted_services_bypass         = optional(bool, true)
    enabled_for_deployment          = optional(bool, false)
    enabled_for_disk_encryption     = optional(bool, false)
    enabled_for_template_deployment = optional(bool, false)

    log_analytics_workspace = optional(object({
      name                = string
      resource_group_name = string
    }))

    role_assignments = optional(map(object({
      role_name = string
      principal = object({
        type = string
        name = string
      })
      description = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    })), {})

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for kv in var.key_vaults : can(regex("^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$", kv.name)) && !strcontains(kv.name, "--")
    ])
    error_message = "Every vault name must be 3 to 24 letters, digits, and hyphens, starting with a letter, ending with a letter or digit, with no consecutive hyphens."
  }

  validation {
    condition     = length(distinct([for kv in var.key_vaults : lower(kv.name)])) == length(var.key_vaults)
    error_message = "Two entries have the same vault name. A vault name is a global DNS label, so merge them into one entry."
  }

  validation {
    condition     = alltrue([for kv in var.key_vaults : length(trimspace(kv.resource_group_name)) > 0])
    error_message = "resource_group_name must not be empty."
  }

  validation {
    condition     = alltrue([for kv in var.key_vaults : contains(["standard", "premium"], kv.sku_name)])
    error_message = "sku_name must be \"standard\" or \"premium\"."
  }

  validation {
    condition = alltrue([
      for kv in var.key_vaults : kv.soft_delete_retention_days >= 7 && kv.soft_delete_retention_days <= 90 && floor(kv.soft_delete_retention_days) == kv.soft_delete_retention_days
    ])
    error_message = "soft_delete_retention_days must be a whole number from 7 to 90."
  }

  validation {
    condition     = alltrue([for kv in var.key_vaults : kv.public_network_access_enabled || length(kv.allowed_ip_ranges) == 0])
    error_message = "allowed_ip_ranges has no effect while public_network_access_enabled is false (the vault refuses every public address regardless). Remove the list, or set public_network_access_enabled = true to admit those addresses and nothing else."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [
        for ip in kv.allowed_ip_ranges : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$", ip))
      ]
    ]))
    error_message = "Every allowed_ip_ranges entry must be an IPv4 address or CIDR block, for example 203.0.113.10 or 203.0.113.0/24."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [
        for ip in kv.allowed_ip_ranges : !can(regex("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)", ip))
      ]
    ]))
    error_message = "allowed_ip_ranges must hold public addresses. Key Vault refuses private (10/8, 172.16/12, 192.168/16), loopback, and link-local ranges in its firewall; a private network reaches a vault through a private endpoint, which this module does not create."
  }

  validation {
    # The shape regex above accepts any prefix length; this is the floor.
    # try() returns true when there is no prefix (a single address) and
    # leaves a malformed prefix to the shape validation's message.
    condition = alltrue(flatten([
      for kv in var.key_vaults : [
        for ip in kv.allowed_ip_ranges : !can(regex("^0\\.", ip)) && try(tonumber(split("/", ip)[1]) >= 8, true)
      ]
    ]))
    error_message = "An allowed_ip_ranges entry names a runner or a NAT block: a single public address, or a block no wider than /8. 0.0.0.0 in any form, the 0.0.0.0/8 network, and any prefix shorter than /8 are refused; opening a vault's data plane to the internet is not a value this catalog offers, whatever the firewall's default action."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [
        for a in kv.role_assignments : contains([
          "Key Vault Administrator",
          "Key Vault Certificates Officer",
          "Key Vault Certificate User",
          "Key Vault Crypto Officer",
          "Key Vault Crypto Service Encryption User",
          "Key Vault Crypto Service Release User",
          "Key Vault Crypto User",
          "Key Vault Reader",
          "Key Vault Secrets Officer",
          "Key Vault Secrets User",
        ], a.role_name)
      ]
    ]))
    error_message = "role_name must be one of the Key Vault data-plane roles: Key Vault Administrator, Key Vault Certificates Officer, Key Vault Certificate User, Key Vault Crypto Officer, Key Vault Crypto Service Encryption User, Key Vault Crypto Service Release User, Key Vault Crypto User, Key Vault Reader, Key Vault Secrets Officer, or Key Vault Secrets User. Owner, Contributor, Key Vault Contributor, and Key Vault Data Access Administrator are management-plane or role-granting roles and are not offered here."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [for a in kv.role_assignments : contains(["identity", "group"], a.principal.type)]
    ]))
    error_message = "principal.type must be \"identity\" (a key of identity_principal_ids) or \"group\" (an Entra security group display name)."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [for a in kv.role_assignments : length(trimspace(a.principal.name)) > 0 && length(trimspace(a.description)) > 0]
    ]))
    error_message = "principal.name and description must not be empty; the description is what an auditor reads next to the assignment."
  }

  validation {
    condition = alltrue([
      for kv in var.key_vaults :
      length(distinct([for a in kv.role_assignments : "${a.principal.type}/${lower(a.principal.name)}|${lower(a.role_name)}"])) == length(kv.role_assignments)
    ])
    error_message = "Two entries on the same vault give the same principal the same role. Azure holds one assignment per (scope, role, principal), so merge them."
  }

  validation {
    condition = alltrue([
      for kv in var.key_vaults :
      kv.log_analytics_workspace == null || (length(trimspace(try(kv.log_analytics_workspace.name, ""))) > 0 && length(trimspace(try(kv.log_analytics_workspace.resource_group_name, ""))) > 0)
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
  description = "Tags applied to every vault. An entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
