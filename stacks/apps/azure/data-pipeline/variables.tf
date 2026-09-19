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
# The pipeline. app_name and environment are name components and tags, never
# conditionals: nothing here behaves differently in one environment than in
# another (README, "Path is environment"). Every resource name is derived
# from the two in main.tf, so a cell states them once and the names cannot
# disagree with each other.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = <<-EOT
    Short name of the pipeline, the first half of every resource name:
    rg-<app_name>-<environment>, id-<app_name>-<environment>,
    kv-<app_name>-<environment>, and st<app_name without hyphens><environment>.
    2 to 12 lowercase letters, digits, and single hyphens, starting with a
    letter and ending with a letter or digit. The length limit is the
    vault's: kv-<app_name>-<environment> must fit in 24 characters, which it
    does for any app_name and environment that pass their validations.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,10}[a-z0-9]$", var.app_name)) && !strcontains(var.app_name, "--")
    error_message = "app_name must be 2 to 12 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit, for example ledger or sales-etl."
  }
}

variable "environment" {
  description = "Environment the pipeline runs in, the second half of every resource name and, unless github_environment says otherwise, the GitHub environment the identity trusts. 2 to 8 lowercase letters and digits, starting with a letter, for example dev, test, or prod. A name component and a tag, never a conditional."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment must be 2 to 8 lowercase letters and digits, starting with a letter, for example dev, test, or prod."
  }
}

variable "location" {
  description = "Azure region for the resource group and everything in it, in its short form, for example eastus or usgovvirginia. Immutable for the group, the vault, and the account."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,40}$", var.location))
    error_message = "location must be an Azure region name in its short form, for example eastus or usgovvirginia."
  }
}

# ---------------------------------------------------------------------------
# Who may act as the identity: the jobs of one GitHub environment of one
# repository, through a federated credential. No secret exists. See
# modules/azure/managed-identity for why the subject is built rather than
# typed, and README for why only an environment credential is offered here.
# ---------------------------------------------------------------------------

variable "github_organization" {
  description = "GitHub organization (or user) that owns the pipeline's repository."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_organization))
    error_message = "github_organization must be a GitHub organization or user name: letters, digits, and hyphens, starting with a letter or digit, 39 characters or fewer."
  }
}

variable "github_repository" {
  description = "Name of the pipeline's repository, without the organization."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a GitHub repository name without the organization: letters, digits, periods, hyphens, and underscores."
  }
}

variable "github_environment" {
  description = "GitHub environment whose jobs may obtain a token for the identity. Null (default) uses environment, so the prod cell trusts the repository's prod environment. Always an environment credential, never a branch credential: an environment carries protection rules (required reviewers, deployment branches), a branch trusts anyone who can push to it."
  type        = string
  default     = null

  validation {
    condition     = var.github_environment == null || length(trimspace(coalesce(var.github_environment, " "))) > 0
    error_message = "github_environment must not be empty when set; leave it null to use environment."
  }
}

# ---------------------------------------------------------------------------
# Where the audit logs go, and who may reach the data planes.
# ---------------------------------------------------------------------------

variable "log_analytics_workspace" {
  description = "Existing Log Analytics workspace, by name in its resource group, that receives the vault's AuditEvent log and the lake's StorageRead, StorageWrite, and StorageDelete logs, each with its caller. Resolved by name; no workspace ID is typed anywhere."
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
    vault and the lake, for example the NAT address of the self-hosted runners
    the pipeline's jobs run on. Empty (the default) leaves public network
    access off on both, so only Azure trusted services and a private endpoint
    (not created here) can reach them. A non-empty list turns public access on
    for exactly these addresses and nothing else, behind a Deny default. A
    single address is written without a prefix and a block with a prefix of
    /30 or wider, the form both firewalls accept; private, loopback, and
    link-local ranges are refused by the modules. GitHub-hosted runners have
    no fixed address and cannot be listed here.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for ip in var.allowed_ip_ranges : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|30))?$", ip))
    ])
    error_message = "Every allowed_ip_ranges entry must be an IPv4 address without a prefix, or a CIDR block with a prefix of /30 or wider, for example 203.0.113.10 or 203.0.113.0/24. The storage firewall does not accept /31 or /32, so a single address is written bare."
  }

  validation {
    # The shape regex above accepts any prefix from /0 to /30; this is the
    # floor, checked here because one list feeds both firewalls. try()
    # returns true when there is no prefix (a single address) and leaves a
    # malformed prefix to the shape validation's message.
    condition = alltrue([
      for ip in var.allowed_ip_ranges : !can(regex("^0\\.", ip)) && try(tonumber(split("/", ip)[1]) >= 8, true)
    ])
    error_message = "An allowed_ip_ranges entry names a runner or a NAT block: a single public address, or a block no wider than /8. 0.0.0.0 in any form, the 0.0.0.0/8 network, and any prefix shorter than /8 are refused; opening the vault's or the lake's data plane to the internet is not a value this stack offers, whatever the firewall's default action."
  }
}

# ---------------------------------------------------------------------------
# Protection and tags.
# ---------------------------------------------------------------------------

variable "delete_lock" {
  description = "True (default) puts a CanNotDelete management lock on the resource group, so nothing in it can be deleted from the portal, the CLI, or any Terraform plan while the lock exists; the lake holds the pipeline's data and the vault its secrets. False creates no lock. Turning it off is its own change, applied before anything in the group is deleted (see modules/azure/resource-group)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the resource group, the identity, the vault, and the account. The stack adds application = app_name and environment = environment underneath; a cell's own value wins per key."
  type        = map(string)
  default     = {}
}
