variable "container_registries" {
  description = <<-EOT
    Container registries to manage, keyed by a stable logical name (for
    example "orders-api"). The key is part of the Terraform address and should
    never change once applied. Change the visible name with "name".

    name                          : the registry name, which is also its login
                                    server label (<name>.azurecr.io): 5 to 50
                                    letters and digits, globally unique.
                                    Immutable.
    resource_group_name           : existing resource group, by name. Looked up,
                                    never created here.
    location                      : Azure region. Null (default) uses the resource
                                    group's location.
    sku                           : "Basic", "Standard" (default), or "Premium".
                                    Network rules, a retention policy, and zone
                                    redundancy exist only on Premium and are
                                    refused on the other two.
    public_network_access_enabled : true (default) answers on the public login
                                    server; every request still carries an Entra
                                    token, so a registry with no network rules
                                    is reachable by identity only. False refuses
                                    every public address and leaves only private
                                    endpoints, which this module does not
                                    create; Azure allows false on Premium only.
    allowed_ip_ranges             : public IPv4 addresses or CIDR blocks admitted
                                    through the registry firewall (default_action
                                    Deny, one ip_rule per entry). Premium only,
                                    and only meaningful while public network
                                    access is on. Private ranges are refused
                                    because the registry firewall refuses them.
    retention_policy_in_days      : days an untagged manifest is kept before the
                                    registry deletes it. 1 to 365. Null (default)
                                    keeps every manifest. Premium only.
    zone_redundancy_enabled       : true spreads the registry across availability
                                    zones. Premium only, and create-time only:
                                    changing it replaces the registry, which
                                    prevent_destroy refuses. Default false.
    log_analytics_workspace       : { name, resource_group_name } of an existing
                                    Log Analytics workspace, resolved by name.
                                    When set, a diagnostic setting sends every
                                    push, pull, and delete (repository events),
                                    every login (login events), and metrics to
                                    it. Null (default) creates no diagnostic
                                    setting.
    role_assignments              : data-plane role assignments on the registry,
                                    keyed by a stable name:
        role_name   : AcrPull, AcrPush, AcrDelete, or AcrImageSigner. Owner,
                      Contributor, and the role-granting roles are refused.
        principal   : { type = "identity", name = "<key of identity_principal_ids>" }
                      or { type = "group", name = "<Entra security group display name>" }.
        description : recorded on the assignment; what an auditor reads next to it.
    tags                          : tags on the registry, merged over the
                                    module-level tags; the entry wins per key.
  EOT

  type = map(object({
    name                          = string
    resource_group_name           = string
    location                      = optional(string)
    sku                           = optional(string, "Standard")
    public_network_access_enabled = optional(bool, true)
    allowed_ip_ranges             = optional(list(string), [])
    retention_policy_in_days      = optional(number)
    zone_redundancy_enabled       = optional(bool, false)

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
    condition     = alltrue([for cr in var.container_registries : can(regex("^[A-Za-z0-9]{5,50}$", cr.name))])
    error_message = "Every registry name must be 5 to 50 letters and digits, with no hyphens or other punctuation; it is the label of <name>.azurecr.io."
  }

  validation {
    condition     = length(distinct([for cr in var.container_registries : lower(cr.name)])) == length(var.container_registries)
    error_message = "Two entries have the same registry name. A registry name is a global DNS label, so merge them into one entry."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : length(trimspace(cr.resource_group_name)) > 0])
    error_message = "resource_group_name must not be empty."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : contains(["Basic", "Standard", "Premium"], cr.sku)])
    error_message = "sku must be \"Basic\", \"Standard\", or \"Premium\"."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : cr.public_network_access_enabled || cr.sku == "Premium"])
    error_message = "public_network_access_enabled = false needs sku = \"Premium\"; Azure keeps the public login server on for Basic and Standard registries. A Basic or Standard registry is still reachable by identity only, since every request carries an Entra token."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : length(cr.allowed_ip_ranges) == 0 || cr.sku == "Premium"])
    error_message = "allowed_ip_ranges needs sku = \"Premium\"; Azure offers registry network rules on Premium only. Remove the list, or raise the SKU."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : cr.public_network_access_enabled || length(cr.allowed_ip_ranges) == 0])
    error_message = "allowed_ip_ranges has no effect while public_network_access_enabled is false (the registry refuses every public address regardless). Remove the list, or set public_network_access_enabled = true to admit those addresses and nothing else."
  }

  validation {
    condition = alltrue(flatten([
      for cr in var.container_registries : [
        for ip in cr.allowed_ip_ranges : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$", ip))
      ]
    ]))
    error_message = "Every allowed_ip_ranges entry must be an IPv4 address or CIDR block, for example 203.0.113.10 or 203.0.113.0/24."
  }

  validation {
    condition = alltrue(flatten([
      for cr in var.container_registries : [
        for ip in cr.allowed_ip_ranges : !can(regex("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)", ip))
      ]
    ]))
    error_message = "allowed_ip_ranges must hold public addresses. The registry firewall refuses private (10/8, 172.16/12, 192.168/16), loopback, and link-local ranges; a private network reaches a registry through a private endpoint, which this module does not create."
  }

  validation {
    # The shape regex above accepts any prefix length; this is the floor.
    # try() returns true when there is no prefix (a single address) and
    # leaves a malformed prefix to the shape validation's message.
    condition = alltrue(flatten([
      for cr in var.container_registries : [
        for ip in cr.allowed_ip_ranges : !can(regex("^0\\.", ip)) && try(tonumber(split("/", ip)[1]) >= 8, true)
      ]
    ]))
    error_message = "An allowed_ip_ranges entry names a runner or a NAT block: a single public address, or a block no wider than /8. 0.0.0.0 in any form, the 0.0.0.0/8 network, and any prefix shorter than /8 are refused; opening a registry's data plane to the internet is not a value this catalog offers, whatever the firewall's default action."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : cr.retention_policy_in_days == null || cr.sku == "Premium"])
    error_message = "retention_policy_in_days needs sku = \"Premium\"; Azure offers the untagged-manifest retention policy on Premium only. Remove the value, or raise the SKU."
  }

  validation {
    condition = alltrue([
      for cr in var.container_registries :
      cr.retention_policy_in_days == null || try(cr.retention_policy_in_days >= 1 && cr.retention_policy_in_days <= 365 && floor(cr.retention_policy_in_days) == cr.retention_policy_in_days, false)
    ])
    error_message = "retention_policy_in_days must be a whole number from 1 to 365, or null to keep every manifest."
  }

  validation {
    condition     = alltrue([for cr in var.container_registries : !cr.zone_redundancy_enabled || cr.sku == "Premium"])
    error_message = "zone_redundancy_enabled needs sku = \"Premium\"; Azure offers zone redundancy on Premium only. Remove the value, or raise the SKU."
  }

  validation {
    condition = alltrue(flatten([
      for cr in var.container_registries : [
        for a in cr.role_assignments : contains([
          "AcrPull",
          "AcrPush",
          "AcrDelete",
          "AcrImageSigner",
        ], a.role_name)
      ]
    ]))
    error_message = "role_name must be one of the container registry data-plane roles: AcrPull, AcrPush, AcrDelete, or AcrImageSigner. Owner, Contributor, Container Registry Contributor and Data Access Configuration Administrator, and the role-granting roles are management-plane roles and are not offered here."
  }

  validation {
    condition = alltrue(flatten([
      for cr in var.container_registries : [for a in cr.role_assignments : contains(["identity", "group"], a.principal.type)]
    ]))
    error_message = "principal.type must be \"identity\" (a key of identity_principal_ids) or \"group\" (an Entra security group display name)."
  }

  validation {
    condition = alltrue(flatten([
      for cr in var.container_registries : [for a in cr.role_assignments : length(trimspace(a.principal.name)) > 0 && length(trimspace(a.description)) > 0]
    ]))
    error_message = "principal.name and description must not be empty; the description is what an auditor reads next to the assignment."
  }

  validation {
    condition = alltrue([
      for cr in var.container_registries :
      length(distinct([for a in cr.role_assignments : "${a.principal.type}/${lower(a.principal.name)}|${lower(a.role_name)}"])) == length(cr.role_assignments)
    ])
    error_message = "Two entries on the same registry give the same principal the same role. Azure holds one assignment per (scope, role, principal), so merge them."
  }

  validation {
    condition = alltrue([
      for cr in var.container_registries :
      cr.log_analytics_workspace == null || (length(trimspace(try(cr.log_analytics_workspace.name, ""))) > 0 && length(trimspace(try(cr.log_analytics_workspace.resource_group_name, ""))) > 0)
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
  description = "Tags applied to every registry. An entry's own tags are merged over these."
  type        = map(string)
  default     = {}
}
