# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never
# by resources directly. Both are declared by every stack under tenants/azure
# as part of the contract in tenants/azure/root.hcl. The client ID is not a
# variable: the provider reads ARM_CLIENT_ID from the environment and the
# credential itself is a federated token that never touches disk or state.
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Entra tenant ID the providers authenticate to. Supplied by tenants/azure/root.hcl from ARM_TENANT_ID, never typed into a cell."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "Subscription every shape in this cell is created in. Required in practice, because a resource group is a subscription resource; supplied by tenants/azure/root.hcl from the cell's subscriptions/<sub-name>/subscription.hcl locator (docs/adr/0017), or from ARM_SUBSCRIPTION_ID for a cell with no locator above it. Never typed into a cell."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# Values every shape in the cell shares. Stated once.
# ---------------------------------------------------------------------------

variable "location" {
  description = "Azure region, in its short form (eastus, usgovvirginia), for every resource group in this cell whose entry does not set its own. Null (the default) means every resource group entry must say where it is. Identities, vaults, and storage accounts follow their resource group's location unless their entry sets one; this default does not reach them, so a workload's pieces stay together by default."
  type        = string
  default     = null

  validation {
    condition     = var.location == null || can(regex("^[a-z0-9]{3,40}$", var.location))
    error_message = "location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }
}

variable "tags" {
  description = "Tags applied to every resource group, identity, vault, and storage account in this cell. An entry's own tags are merged over these, the entry winning per key."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# The catalog. Four maps, one per shape, keyed by stable logical names. Every
# shape names the resource group it lives in by that group's key here, and a
# vault or storage account names an identity it grants a role to by that
# identity's key. The modules validate the values; this file validates that
# the keys resolve, so the error names the cell rather than a module address.
# ---------------------------------------------------------------------------

variable "resource_groups" {
  description = <<-EOT
    Resource groups this cell owns, keyed by a stable logical name (for example
    "app"). The key is what every identity, vault, and storage account below
    names in its resource_group_key, and it is part of the Terraform address,
    so it should never change once applied. Same shape as
    modules/azure/resource-group, except that location is optional here and
    falls back to the stack's location. See that module's variables.tf for
    attribute semantics.

    name        : the resource group name in Azure. Immutable.
    location    : Azure region. Null (default) uses the stack's location.
    tags        : merged over the stack's tags; the entry wins per key.
    delete_lock : true adds a CanNotDelete management lock on the group.
    lock_notes  : text recorded on the lock, shown to whoever it stops.

    Every group here is created by this cell and carries prevent_destroy, so
    dropping an entry is a refused plan, not a deleted group. A group that
    already exists is adopted with an import block (the adoption hook in
    tenants/azure/root.hcl), never looked up by name: the shapes below can
    only be put in a group this cell owns.
  EOT

  type = map(object({
    name        = string
    location    = optional(string)
    tags        = optional(map(string), {})
    delete_lock = optional(bool, false)
    lock_notes  = optional(string, "Locked by Terraform. Turn delete_lock off in the identity-as-code repository, apply, and then delete.")
  }))
  default = {}

  validation {
    condition     = length(var.resource_groups) > 0
    error_message = "resource_groups is empty. Every shape in this stack lives in a group this cell owns, so a cell with no resource group has nothing to hold; a subscription with no workloads should not have an azure-subscription-workloads cell at all."
  }

  validation {
    condition     = alltrue([for rg in var.resource_groups : rg.location != null || var.location != null])
    error_message = "A resource group entry has no location and the stack-level location is not set. Set location on the entry, or set location once at the top of the cell for every group in it."
  }
}

variable "identities" {
  description = <<-EOT
    User-assigned managed identities, keyed by a stable logical name (for
    example "ci-deploy"). The key is what a vault or storage account role
    assignment names in principal = { type = "identity", name = "<key>" }, and
    it is part of the Terraform address, so it should never change once
    applied. Same shape as modules/azure/managed-identity, except that the
    resource group is named by its key in resource_groups (resource_group_key)
    rather than by name. See that module's variables.tf for attribute
    semantics, including how a federated credential's subject is built from
    organization, repository, and branch or environment, and why tag and
    pull-request subjects are not offered.

    name                  : the identity's name in Azure, also its service
                            principal's display name in Entra. Immutable.
    resource_group_key    : key of the resource_groups entry it is created in.
    location              : Azure region. Null (default) uses the group's.
    tags                  : merged over the stack's tags; the entry wins per key.
    federated_credentials : GitHub Actions contexts that may obtain a token for
                            this identity, keyed by a stable name. No secret
                            exists; the subject is built, never typed.
  EOT

  type = map(object({
    name               = string
    resource_group_key = string
    location           = optional(string)
    tags               = optional(map(string), {})

    federated_credentials = optional(map(object({
      organization = string
      repository   = string
      branch       = optional(string)
      environment  = optional(string)
      issuer       = optional(string, "https://token.actions.githubusercontent.com")
      audience     = optional(string, "api://AzureADTokenExchange")
      name         = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for i in var.identities : contains(keys(var.resource_groups), i.resource_group_key)])
    error_message = "Every identity's resource_group_key must be a key of this cell's resource_groups. The stack creates the group and the identity in one plan; a group this cell does not own is not a place it puts things."
  }
}

variable "key_vaults" {
  description = <<-EOT
    Key vaults, keyed by a stable logical name (for example "app-secrets").
    Same shape as modules/azure/key-vault, except that the resource group is
    named by its key in resource_groups (resource_group_key) rather than by
    name. See that module's variables.tf for attribute semantics: every vault
    uses RBAC authorization, soft delete with purge protection, and a Deny
    firewall with public access off by default, whatever the values.

    name                            : the vault name, a global DNS label. Immutable.
    resource_group_key              : key of the resource_groups entry it is created in.
    location                        : Azure region. Null (default) uses the group's.
    sku_name                        : "standard" (default) or "premium".
    soft_delete_retention_days      : 7 to 90, default 90.
    public_network_access_enabled   : default false.
    allowed_ip_ranges               : public IPv4 addresses or CIDR blocks, only
                                      with public_network_access_enabled = true.
    trusted_services_bypass         : default true.
    enabled_for_deployment, enabled_for_disk_encryption,
    enabled_for_template_deployment : each a service, each off by default.
    log_analytics_workspace         : { name, resource_group_name } of an existing
                                      workspace, resolved by name, for the audit
                                      log. Null (default) sends nothing.
    role_assignments                : data-plane roles on the vault, keyed by a
                                      stable name:
        role_name   : one of the Key Vault data-plane roles (the module lists
                      them and refuses everything else).
        principal   : { type = "identity", name = "<key of identities>" } or
                      { type = "group", name = "<Entra security group display name>" }.
        description : recorded on the assignment.
    tags                            : merged over the stack's tags; the entry wins per key.
  EOT

  type = map(object({
    name                            = string
    resource_group_key              = string
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
    condition     = alltrue([for kv in var.key_vaults : contains(keys(var.resource_groups), kv.resource_group_key)])
    error_message = "Every key vault's resource_group_key must be a key of this cell's resource_groups. The stack creates the group and the vault in one plan; a group this cell does not own is not a place it puts things."
  }

  validation {
    condition = alltrue(flatten([
      for kv in var.key_vaults : [
        for a in kv.role_assignments : a.principal.type != "identity" || contains(keys(var.identities), a.principal.name)
      ]
    ]))
    error_message = "A key vault role assignment names an identity that is not a key of this cell's identities. An identity principal is named by its key in identities, so the stack resolves its object ID and the cell holds no GUID; an Entra group is named by display name with principal.type = \"group\"."
  }
}

variable "storage_accounts" {
  description = <<-EOT
    General-purpose storage accounts, keyed by a stable logical name (for
    example "app-artifacts"). Same shape as modules/azure/storage-account,
    except that the resource group is named by its key in resource_groups
    (resource_group_key) rather than by name. See that module's variables.tf
    for attribute semantics: every account refuses shared keys and SAS, requires
    TLS 1.2 and HTTPS, forbids anonymous access, and sits behind a Deny
    firewall with public access off by default, whatever the values.

    name                                 : 3 to 24 lowercase letters and digits,
                                           globally unique. Immutable.
    resource_group_key                   : key of the resource_groups entry it is
                                           created in.
    location                             : Azure region. Null (default) uses the group's.
    account_replication_type             : LRS, ZRS, GRS (default), RAGRS, GZRS, RAGZRS.
    access_tier                          : Hot (default), Cool, or Cold.
    infrastructure_encryption_enabled    : default true. Create-time only.
    hierarchical_namespace_enabled       : default false. True requires
                                           blob_versioning_enabled = false.
    blob_versioning_enabled              : default true.
    blob_soft_delete_retention_days      : 1 to 365, default 14.
    container_soft_delete_retention_days : 1 to 365, default 14.
    public_network_access_enabled        : default false.
    allowed_ip_ranges                    : public IPv4 addresses or CIDR blocks (no
                                           /31 or /32), only with
                                           public_network_access_enabled = true.
    trusted_services_bypass              : default true.
    containers                           : private blob containers keyed by a stable
                                           name, each with name and optional metadata.
    role_assignments                     : data-plane roles on the account or one
                                           container, keyed by a stable name:
        role_name     : Reader or one of the Storage data-plane roles (the
                        module lists them and refuses everything else).
        principal     : { type = "identity", name = "<key of identities>" } or
                        { type = "group", name = "<Entra security group display name>" }.
        container_key : optional key of this entry's containers; the assignment
                        is then scoped to that container and must be a Storage
                        Blob Data role.
        description   : recorded on the assignment.
    log_analytics_workspace              : { name, resource_group_name } of an
                                           existing workspace, resolved by name,
                                           for the blob audit log. Null (default)
                                           sends nothing.
    tags                                 : merged over the stack's tags; the entry
                                           wins per key.
  EOT

  type = map(object({
    name                                 = string
    resource_group_key                   = string
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
    condition     = alltrue([for sa in var.storage_accounts : contains(keys(var.resource_groups), sa.resource_group_key)])
    error_message = "Every storage account's resource_group_key must be a key of this cell's resource_groups. The stack creates the group and the account in one plan; a group this cell does not own is not a place it puts things."
  }

  validation {
    condition = alltrue(flatten([
      for sa in var.storage_accounts : [
        for a in sa.role_assignments : a.principal.type != "identity" || contains(keys(var.identities), a.principal.name)
      ]
    ]))
    error_message = "A storage account role assignment names an identity that is not a key of this cell's identities. An identity principal is named by its key in identities, so the stack resolves its object ID and the cell holds no GUID; an Entra group is named by display name with principal.type = \"group\"."
  }
}
