# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never
# by resources directly. Both are declared by every stack under tenants/azure
# as part of the contract in tenants/azure/root.hcl.
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
  description = "Subscription the Automation account lives in. Required in practice because the account is a subscription resource; supplied by tenants/azure/root.hcl from ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# Where the account lives.
# ---------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Existing resource group for the Automation account and its identity, by name."
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

variable "automation_account_name" {
  description = "Name of the Automation account. See modules/azure/automation-account for the naming rule."
  type        = string
}

variable "identity_name" {
  description = "Name of the user-assigned managed identity the runbooks run as."
  type        = string
}

variable "tags" {
  description = "Tags applied to the account, the identity, and every runbook."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Values every runbook receives. Stated once per cell.
# ---------------------------------------------------------------------------

variable "tenant_label" {
  description = "Short label for the tenant (corp, subsidiary), stored as an account variable for log context."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,31}$", var.tenant_label))
    error_message = "tenant_label must be lowercase letters, digits, and hyphens, starting with a letter."
  }
}

variable "sender_mailbox" {
  description = "Shared mailbox the runbooks send from, as a user principal name. Mail.Send is restricted to it by an Exchange application access policy applied outside Terraform."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+$", var.sender_mailbox))
    error_message = "sender_mailbox must be a user principal name (mailbox@domain)."
  }
}

variable "dry_run" {
  description = "Passed to every runbook as dryrun. True (default) means every runbook reads, computes, and logs what it would do, and writes nothing. Set false only after the dry-run job output has been reviewed."
  type        = bool
  default     = true
}

variable "graph_environment" {
  description = "National cloud the runbooks talk to: Global or USGov. Passed as environment to every runbook."
  type        = string
  default     = "Global"

  validation {
    condition     = contains(["Global", "USGov"], var.graph_environment)
    error_message = "graph_environment must be Global or USGov."
  }
}

variable "graph_app_roles" {
  description = "Microsoft Graph application permissions granted to the runbook identity, by name. The default is the union the three shipped runbooks need; narrow it in a cell that deploys fewer (a cell that runs the authentication methods runbook dry only needs Policy.Read.AuthenticationMethod in place of Policy.ReadWrite.AuthenticationMethod)."
  type        = list(string)
  default = [
    "Application.ReadWrite.All",
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Mail.Send",
    "Directory.Read.All",
    "AuditLog.Read.All",
    "Policy.ReadWrite.AuthenticationMethod",
  ]

  validation {
    condition     = length(var.graph_app_roles) > 0
    error_message = "graph_app_roles must list at least one permission."
  }
}

# ---------------------------------------------------------------------------
# Runbooks and schedules.
# ---------------------------------------------------------------------------

variable "runbooks" {
  description = <<-EOT
    Runbooks to deploy, keyed by a stable logical name.

    name         : runbook name in the account.
    file         : file name under automation/runbooks in this repository.
    library      : optional file name under automation/lib, inlined into the runbook
                   between its INLINE_LIBRARY marker lines at deploy time.
    description  : optional.
    schedule_key : key into schedules.
    parameters   : runbook-specific parameters as strings, keys lowercase. The stack
                   adds clientid, environment, sendermailbox, and dryrun, and its
                   values win on conflict.
  EOT

  type = map(object({
    name         = string
    file         = string
    library      = optional(string)
    description  = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    schedule_key = string
    parameters   = optional(map(string), {})
  }))

  validation {
    condition     = length(var.runbooks) > 0
    error_message = "At least one runbook is required; a cell with none has no reason to exist."
  }

  validation {
    condition     = alltrue([for r in var.runbooks : can(regex("^[A-Za-z0-9_-]+\\.ps1$", r.file))])
    error_message = "file must be a bare .ps1 file name under automation/runbooks, with no path separators."
  }

  validation {
    condition     = alltrue([for r in var.runbooks : r.library == null || can(regex("^[A-Za-z0-9_.-]+\\.ps1$", r.library))])
    error_message = "library must be a bare .ps1 file name under automation/lib, with no path separators."
  }

  validation {
    condition     = alltrue([for r in var.runbooks : contains(keys(var.schedules), r.schedule_key)])
    error_message = "Every runbook's schedule_key must be a key in schedules."
  }

  validation {
    condition     = alltrue(flatten([for r in var.runbooks : [for k in keys(r.parameters) : k == lower(k)]]))
    error_message = "Runbook parameter keys must be lowercase; Azure Automation normalises them."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.runbooks : [for k in keys(r.parameters) : !contains(["clientid", "environment", "sendermailbox", "dryrun"], k)]
    ]))
    error_message = "clientid, environment, sendermailbox, and dryrun are set by the stack from its own inputs; do not pass them per runbook."
  }
}

# ---------------------------------------------------------------------------
# Desired-state files published as Automation variables.
# ---------------------------------------------------------------------------

variable "desired_state_files" {
  description = <<-EOT
    Files to publish as Automation string variables, keyed by variable name,
    each value a path relative to the repository root. The variable holds the
    file's text. Invoke-AuthenticationMethodsDrift reads AuthMethods_Policy and
    AuthMethods_<Id> for each method it manages; the corp cell lists
    policies/entra/authentication-methods/policy.json and methods/*.json. A
    file edit is a plan diff on the variable, so the runbook always compares
    the tenant against what the repository says (docs/adr/0012).
  EOT

  type    = map(string)
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.desired_state_files) : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,127}$", name))])
    error_message = "desired_state_files keys are Automation variable names: a letter followed by letters, digits, hyphens, and underscores."
  }

  validation {
    condition     = alltrue([for p in values(var.desired_state_files) : can(regex("^[A-Za-z0-9_./-]+\\.json$", p)) && !can(regex("(^|/)\\.\\.(/|$)", p))])
    error_message = "desired_state_files values must be repository-relative paths to .json files, with no parent directory segments."
  }
}

variable "schedules" {
  description = "Schedules keyed by logical name. Same shape as modules/azure/automation-runbooks; start_time must be in the future when the schedule is first created."
  type = map(object({
    name        = string
    description = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    frequency   = string
    interval    = optional(number, 1)
    timezone    = optional(string, "Etc/UTC")
    start_time  = string
    expiry_time = optional(string)
    week_days   = optional(list(string), [])
    month_days  = optional(list(number), [])
  }))

  validation {
    condition     = length(var.schedules) > 0
    error_message = "At least one schedule is required."
  }
}
