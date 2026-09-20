# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never
# by resources directly. Both are declared by every stack under tenants/azure
# as part of the contract in tenants/azure/root.hcl. Under
# subscriptions/<sub-name>/ the root takes subscription_id from that
# directory's subscription.hcl (docs/adr/0017). Neither value is ever typed
# into a cell, and this stack passes neither to a module.
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
  description = "Subscription the resource group and everything in it are created in. Required in practice, because every resource here is a subscription resource; supplied by tenants/azure/root.hcl from subscriptions/<sub-name>/subscription.hcl, or from ARM_SUBSCRIPTION_ID for a cell with no locator above it. Never typed into a cell."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# The application. app_name and environment are name components and tags,
# never conditionals: nothing here behaves differently in one environment
# than in another (README, "Path is environment"). Every resource name is
# derived from the two in main.tf, so a cell states them once and the names
# cannot disagree with each other. The stack is this application's, so
# app_name has its name as the default; a cell states it only to deploy the
# same composition under another name.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = <<-EOT
    Short name of the application, the first half of every resource name:
    rg-<app_name>-<environment>, id-<app_name>-<environment> and
    id-<app_name>-<environment>-publisher, kv-<app_name>-<environment>, and
    cr<app_name without hyphens><environment>. 2 to 12 lowercase letters,
    digits, and single hyphens, starting with a letter and ending with a
    letter or digit. The length limit is the vault's:
    kv-<app_name>-<environment> must fit in 24 characters, which it does for
    any app_name and environment that pass their validations; the registry
    name (5 to 50 letters and digits) is shorter still once the hyphens are
    removed. The default is the application's own name, orders-api, which is
    10 characters.
  EOT
  type        = string
  default     = "orders-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,10}[a-z0-9]$", var.app_name)) && !strcontains(var.app_name, "--")
    error_message = "app_name must be 2 to 12 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit, for example orders-api or ledger."
  }
}

variable "environment" {
  description = "Environment the application runs in, the second half of every resource name and, unless publisher_github_environment says otherwise, the GitHub environment the publisher identity trusts. 2 to 8 lowercase letters and digits, starting with a letter, for example dev, test, or prod. A name component and a tag, never a conditional."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment must be 2 to 8 lowercase letters and digits, starting with a letter, for example dev, test, or prod."
  }
}

variable "location" {
  description = "Azure region for the resource group and everything in it, in its short form, for example eastus or usgovvirginia. Immutable for the group, the identities, the registry, and the vault."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,40}$", var.location))
    error_message = "location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }
}

# ---------------------------------------------------------------------------
# Who may publish an image: the jobs of one GitHub environment of one
# repository, through a federated credential on the publisher identity. No
# secret exists. See modules/azure/managed-identity for why the subject is
# built rather than typed, and README for why only an environment credential
# is offered here. The runtime identity has no credential of any kind:
# nothing outside Azure obtains a token for it, and the Container App is
# assigned it by its own pipeline (README, "The model").
# ---------------------------------------------------------------------------

variable "github_organization" {
  description = "GitHub organization (or user) that owns the application's repository, the one whose release workflow pushes the image."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_organization))
    error_message = "github_organization must be a GitHub organization or user name: letters, digits, and hyphens, starting with a letter or digit, 39 characters or fewer."
  }
}

variable "github_repository" {
  description = "Name of the application's repository, without the organization."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a GitHub repository name without the organization: letters, digits, periods, hyphens, and underscores."
  }
}

variable "publisher_github_environment" {
  description = "GitHub environment whose jobs may obtain a token for the publisher identity, and so push an image to the registry. Null (default) uses environment, so the prod cell trusts the repository's prod environment. Always an environment credential, never a branch credential: an environment carries protection rules (required reviewers, deployment branches), a branch trusts anyone who can push to it."
  type        = string
  default     = null

  validation {
    condition     = var.publisher_github_environment == null || length(trimspace(coalesce(var.publisher_github_environment, " "))) > 0
    error_message = "publisher_github_environment must not be empty when set; leave it null to use environment."
  }
}

# ---------------------------------------------------------------------------
# The registry. Two knobs, because Azure sells the registry's firewall, its
# untagged-manifest retention policy, and zone redundancy on Premium only,
# and a cell should be able to pick the SKU that fits the application
# without editing the stack. Everything else about the registry is fixed by
# the module: no admin user, no anonymous pull, platform encryption,
# prevent_destroy.
# ---------------------------------------------------------------------------

variable "registry_sku" {
  description = "SKU of the registry: \"Basic\", \"Standard\" (default), or \"Premium\". Basic and Standard differ in storage and throughput only. Premium adds what the module keeps behind it: the IP allow list (this stack passes allowed_ip_ranges to the registry only on Premium), the untagged-manifest retention policy (registry_retention_days), zone redundancy, and private endpoints. The SKU can be raised or lowered in place."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.registry_sku)
    error_message = "registry_sku must be \"Basic\", \"Standard\", or \"Premium\"."
  }
}

variable "registry_retention_days" {
  description = "Days an untagged manifest is kept in the registry before the registry deletes it: the leftovers of a release workflow that pushes the same tag again. A whole number from 1 to 365, or null (default) to keep every manifest. Premium only: Azure offers the retention policy on no other SKU, so a value here needs registry_sku = \"Premium\", and the stack refuses the pair otherwise."
  type        = number
  default     = null

  validation {
    condition     = var.registry_retention_days == null || try(var.registry_retention_days >= 1 && var.registry_retention_days <= 365 && floor(var.registry_retention_days) == var.registry_retention_days, false)
    error_message = "registry_retention_days must be a whole number from 1 to 365, or null to keep every manifest."
  }

  validation {
    # A cross-variable condition, which Terraform allows from 1.9 (the floor
    # this repository pins). The module refuses the same pair in its own
    # words; this one names the cell's two variables so the message says
    # what to change.
    condition     = var.registry_retention_days == null || var.registry_sku == "Premium"
    error_message = "registry_retention_days needs registry_sku = \"Premium\"; Azure offers the untagged-manifest retention policy on Premium only. Remove the value, or raise the SKU."
  }
}

# ---------------------------------------------------------------------------
# Where the audit logs go, and who may reach the data planes.
# ---------------------------------------------------------------------------

variable "log_analytics_workspace" {
  description = "Existing Log Analytics workspace, by name in its resource group, that receives the registry's ContainerRegistryRepositoryEvents and ContainerRegistryLoginEvents logs (every push, pull, delete, and login with the identity that did it) and the vault's AuditEvent log (every data-plane call with its caller). Resolved by name; no workspace ID is typed anywhere."
  type = object({
    name                = string
    resource_group_name = string
  })

  validation {
    condition     = length(trimspace(var.log_analytics_workspace.name)) > 0 && length(trimspace(var.log_analytics_workspace.resource_group_name)) > 0
    error_message = "log_analytics_workspace needs both name and resource_group_name."
  }
}

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public IPv4 addresses or CIDR blocks admitted through the firewall of the
    vault and, on a Premium registry, of the registry: for example the egress
    address of the Container Apps environment the application runs in, or
    the NAT address of the self-hosted runners the release workflow runs on.
    Empty (the default) leaves public network access off on the vault, so
    only Azure trusted services and a private endpoint (not created here)
    can reach it, and writes no rule set on the registry, which stays
    reachable by identity from anywhere (its public login server is on
    whatever the SKU, and every request carries an Entra token). A non-empty
    list turns the vault's public access on for exactly these addresses and
    nothing else, behind a Deny default, and on a Premium registry writes
    the same list behind the same default; on Basic and Standard the registry
    has no firewall and the list is not passed to it. A single address is
    written without a prefix and a block with a prefix of /30 or wider, the
    shape the data-pipeline stack accepts, so one list serves both app
    stacks; private, loopback, and link-local ranges are refused by the
    modules. GitHub-hosted runners have no fixed address and cannot be
    listed here.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for ip in var.allowed_ip_ranges : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|30))?$", ip))
    ])
    error_message = "Every allowed_ip_ranges entry must be an IPv4 address without a prefix, or a CIDR block with a prefix of /30 or wider, for example 203.0.113.10 or 203.0.113.0/24. A single address is written bare, which is the form the Key Vault API returns it in."
  }

  validation {
    # The shape regex above accepts any prefix from /0 to /30; this is the
    # floor, checked here because one list feeds both firewalls. try()
    # returns true when there is no prefix (a single address) and leaves a
    # malformed prefix to the shape validation's message.
    condition = alltrue([
      for ip in var.allowed_ip_ranges : !can(regex("^0\\.", ip)) && try(tonumber(split("/", ip)[1]) >= 8, true)
    ])
    error_message = "An allowed_ip_ranges entry names a runner, an environment's egress, or a NAT block: a single public address, or a block no wider than /8. 0.0.0.0 in any form, the 0.0.0.0/8 network, and any prefix shorter than /8 are refused; opening the vault's or the registry's data plane to the internet is not a value this stack offers, whatever the firewall's default action."
  }
}

# ---------------------------------------------------------------------------
# Protection and tags.
# ---------------------------------------------------------------------------

variable "delete_lock" {
  description = "True (default) puts a CanNotDelete management lock on the resource group, so nothing in it can be deleted from the portal, the CLI, or any Terraform plan while the lock exists; the registry holds every image ever published and the vault the application's secrets. False creates no lock. Turning it off is its own change, applied before anything in the group is deleted (see modules/azure/resource-group)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the resource group, the two identities, the registry, and the vault. The stack adds application = app_name and environment = environment underneath; a cell's own value wins per key."
  type        = map(string)
  default     = {}
}
