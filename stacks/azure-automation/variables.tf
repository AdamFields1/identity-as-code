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
  description = "Name of the single user-assigned managed identity every runbook runs as, created under the tier key \"default\". Leave null and declare identities instead to give each privilege tier its own identity (docs/adr/0016)."
  type        = string
  default     = null
}

variable "identities" {
  description = <<-EOT
    Managed identities for this account, keyed by privilege tier. Each runbook
    names the tier it runs as in its identity_key, and the stack passes that
    identity's client ID to the runbook's clientid parameter (and its
    principal ID wherever a runbook asks for identity_principal_id).

    name                 : identity name in Azure.
    graph_app_roles      : Microsoft Graph application permissions for this identity,
                           by name. Give a tier only what its runbooks use; the
                           permissions each runbook needs are in its header and in
                           automation/README.md.
    arm_role_assignments : Azure role assignments for this identity, in the shape
                           of the arm_role_assignments variable below.

    Empty (the default) keeps the single-identity form: one identity named
    identity_name, keyed "default", holding graph_app_roles and
    arm_role_assignments. Declaring both forms is refused.

    What tiers do and do not buy: every identity here is attached to the same
    Automation account, so anyone who can publish a runbook or start a job in
    the account can ask for a token for any of them. A tier contains a runbook
    defect or a bad parameter, not a compromise of the account (docs/adr/0016).
  EOT

  type = map(object({
    name            = string
    graph_app_roles = optional(list(string), [])

    arm_role_assignments = optional(map(object({
      role_name = string

      scope = object({
        type = string
        name = optional(string, "")
      })

      description       = optional(string, "Runbook identity permission. Managed by Terraform. See the identity-as-code repository.")
      condition         = optional(string)
      condition_version = optional(string)
    })), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for key in keys(var.identities) : can(regex("^[a-z][a-z0-9-]{0,31}$", key))])
    error_message = "identities keys are tier names: lowercase letters, digits, and hyphens, starting with a letter, 32 characters or fewer."
  }

  validation {
    condition     = length(var.identities) > 0 || var.identity_name != null
    error_message = "Set either identities (one entry per privilege tier) or identity_name (one identity for every runbook)."
  }

  validation {
    condition     = length(var.identities) == 0 || (var.identity_name == null && var.graph_app_roles == null && length(var.arm_role_assignments) == 0)
    error_message = "identity_name, graph_app_roles, and arm_role_assignments are the single-identity form. With identities declared, put each tier's permissions inside its own entry."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [
        for a in i.arm_role_assignments : contains(["management_group", "subscription", "resource_group", "automation_account"], a.scope.type)
      ]
    ]))
    error_message = "scope.type must be \"management_group\", \"subscription\", \"resource_group\", or \"automation_account\"."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [
        for a in i.arm_role_assignments : a.scope.type == "automation_account" ? trimspace(a.scope.name) == "" : length(trimspace(a.scope.name)) > 0
      ]
    ]))
    error_message = "scope.name is required for management_group, subscription, and resource_group, and must be omitted for automation_account (the stack supplies the account)."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.identities : [
        for a in i.arm_role_assignments :
        !contains(["owner", "user access administrator", "role based access control administrator"], lower(trimspace(a.role_name))) || a.condition != null
      ]
    ]))
    error_message = "Owner, User Access Administrator, and Role Based Access Control Administrator need a condition. Unconditioned, any of them lets that identity grant itself, or anyone else, anything at the scope, which would also void every condition in this map."
  }
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
  description = "Single-identity form only: Microsoft Graph application permissions granted to the one runbook identity, by name. Null (the default) means the union the shipped runbooks need for live runs, with every permission a runbook documents listed by name even where another entry's ReadWrite form would also be accepted, so removing one runbook's names never takes away another's. With identities declared, each tier lists its own permissions instead and this must stay null."
  type        = list(string)
  default     = null

  validation {
    condition     = var.graph_app_roles == null || length(var.graph_app_roles) > 0
    error_message = "graph_app_roles must list at least one permission when it is set; leave it null for the shipped union."
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
    identity_key : key into identities: the privilege tier this runbook runs as.
                   Required when identities is declared, and its identity's client ID
                   becomes the runbook's clientid. Omit it in the single-identity
                   form, where every runbook runs as "default".
    parameters   : runbook-specific parameters as strings, keys lowercase. The stack
                   adds clientid, environment, sendermailbox, and dryrun, and a cell
                   that passes one of those four keys fails validation. A list is one
                   semicolon-joined string,
                   written join(";", [...]) in the cell, because the Automation
                   service may parse a JSON-looking value before it binds it. An
                   object (a PIM baseline) is not a parameter at all: publish it with
                   desired_state_files and pass the variable's name.
    stack_parameters :
                   optional map of parameter key (lowercase) to the name of a value
                   only the stack knows, so a cell never types it:
                     automation_account_name     this stack's Automation account
                     automation_account_names    the same, as a one-element semicolon list
                     resource_group_name         the account's resource group
                     subscription_id             the account's subscription, as an ID
                     identity_principal_id       object ID of this runbook's own identity
                     backup_storage_account_name backup_storage account (needs backup_storage)
                     backup_container_name       backup_storage container (needs backup_storage)

                   A runbook that asks for a backup value gives its identity the
                   Storage Blob Data Contributor assignment on the container, so the
                   container role follows the runbook that writes backups.
  EOT

  type = map(object({
    name             = string
    file             = string
    library          = optional(string)
    description      = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    schedule_key     = string
    identity_key     = optional(string)
    parameters       = optional(map(string), {})
    stack_parameters = optional(map(string), {})
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
    condition = alltrue([
      for r in var.runbooks : length(var.identities) == 0 ? r.identity_key == null || r.identity_key == "default" : contains(keys(var.identities), coalesce(r.identity_key, ""))
    ])
    error_message = "With identities declared, every runbook's identity_key must be one of its keys. In the single-identity form, leave identity_key unset."
  }

  validation {
    condition = length(var.identities) == 0 || alltrue([
      for key in keys(var.identities) : contains([for r in var.runbooks : coalesce(r.identity_key, "")], key)
    ])
    error_message = "Every identity in identities must be named by at least one runbook's identity_key. An identity no runbook uses is a set of permissions nothing needs."
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

  validation {
    condition = alltrue(flatten([
      for r in var.runbooks : [
        for k, v in r.stack_parameters : k == lower(k) && !contains(["clientid", "environment", "sendermailbox", "dryrun"], k) && !contains(keys(r.parameters), k)
      ]
    ]))
    error_message = "stack_parameters keys must be lowercase, must not be clientid, environment, sendermailbox, or dryrun, and must not also appear in parameters."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.runbooks : [
        for v in values(r.stack_parameters) : contains([
          "automation_account_name", "automation_account_names", "resource_group_name", "subscription_id",
          "identity_principal_id", "backup_storage_account_name", "backup_container_name",
        ], v)
      ]
    ]))
    error_message = "stack_parameters values must be one of automation_account_name, automation_account_names, resource_group_name, subscription_id, identity_principal_id, backup_storage_account_name, backup_container_name."
  }

  validation {
    condition = var.backup_storage != null || alltrue(flatten([
      for r in var.runbooks : [for v in values(r.stack_parameters) : !startswith(v, "backup_")]
    ]))
    error_message = "A runbook asks for backup_storage_account_name or backup_container_name, but backup_storage is not set."
  }

  validation {
    condition = var.backup_storage == null || length(flatten([
      for r in var.runbooks : [for v in values(r.stack_parameters) : v if startswith(v, "backup_")]
    ])) > 0
    error_message = "backup_storage is set, but no runbook asks for backup_storage_account_name or backup_container_name, so no identity would be allowed to write in the container. Add the backup runbook's stack_parameters, or remove backup_storage."
  }
}

# ---------------------------------------------------------------------------
# Azure role assignments for the runbook identity.
# ---------------------------------------------------------------------------

variable "arm_role_assignments" {
  description = <<-EOT
    Single-identity form only: standing Azure role assignments for the one
    runbook identity, keyed by a stable logical name. With identities declared,
    each tier carries its own arm_role_assignments in the same shape and this
    must stay empty. A managed identity cannot activate a PIM role, so this is
    how the runbooks get what they need in Azure Resource Manager
    (docs/adr/0014).

    role_name         : built-in or custom role display name, resolved at the scope.
                        Custom roles are defined in stacks/azure-rbac-roles.
    scope             : { type, name } with type one of "management_group" (display
                        name), "subscription" (display name), "resource_group" (name
                        in the provider's subscription), or "automation_account"
                        (this stack's account; name must be omitted or empty).
    description       : recorded on the assignment.
    condition         : optional Azure ABAC condition. The tokens <principal_id>
                        (the runbook identity) and <role_id:NAME> (a role's GUID) are
                        replaced by modules/azure/workload-role-assignment, so the cell
                        holds no GUID.
    condition_version : "2.0", the default when condition is set.

    Owner, User Access Administrator, and Role Based Access Control Administrator
    are refused without a condition: an unconditioned role that can assign roles
    lets the identity grant itself anything at the scope, which would also void
    every condition here and in every other tier.
  EOT

  type = map(object({
    role_name = string

    scope = object({
      type = string
      name = optional(string, "")
    })

    description       = optional(string, "Runbook identity permission. Managed by Terraform. See the identity-as-code repository.")
    condition         = optional(string)
    condition_version = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for a in var.arm_role_assignments : contains(["management_group", "subscription", "resource_group", "automation_account"], a.scope.type)
    ])
    error_message = "scope.type must be \"management_group\", \"subscription\", \"resource_group\", or \"automation_account\"."
  }

  validation {
    condition = alltrue([
      for a in var.arm_role_assignments : a.scope.type == "automation_account" ? trimspace(a.scope.name) == "" : length(trimspace(a.scope.name)) > 0
    ])
    error_message = "scope.name is required for management_group, subscription, and resource_group, and must be omitted for automation_account (the stack supplies the account)."
  }

  validation {
    condition = alltrue([
      for a in var.arm_role_assignments :
      !contains(["owner", "user access administrator", "role based access control administrator"], lower(trimspace(a.role_name))) || a.condition != null
    ])
    error_message = "Owner, User Access Administrator, and Role Based Access Control Administrator need a condition here. An unconditioned role that can assign roles would void every other condition in this map."
  }
}

# ---------------------------------------------------------------------------
# Optional backup storage for Backup-AutomationRunbooks.
# ---------------------------------------------------------------------------

variable "backup_storage" {
  description = <<-EOT
    Null (default) creates nothing. An object creates a storage account with
    shared key access disabled, TLS 1.2 minimum, infrastructure encryption,
    versioning and soft delete, one private container, and Storage Blob Data
    Contributor on that container for the identity of every runbook that asks
    for a backup value (modules/azure/backup-storage). A runbook entry receives
    the names through stack_parameters (backup_storage_account_name,
    backup_container_name), and asking for one is what gives its tier the
    container role.

    storage_account_name     : 3 to 24 lowercase letters and digits, globally unique.
    container_name           : default "runbook-backups".
    resource_group_name      : default the Automation account's resource group.
    account_replication_type : default "GRS".
    retention_days           : blob and container soft delete, default 14.
    version_retention_days   : lifecycle deletion of previous blob versions, default 30.
  EOT

  type = object({
    storage_account_name     = string
    container_name           = optional(string, "runbook-backups")
    resource_group_name      = optional(string)
    account_replication_type = optional(string, "GRS")
    retention_days           = optional(number, 14)
    version_retention_days   = optional(number, 30)
  })
  default = null

  validation {
    condition     = var.backup_storage == null || can(regex("^[a-z0-9]{3,24}$", var.backup_storage.storage_account_name))
    error_message = "backup_storage.storage_account_name must be 3 to 24 lowercase letters and digits."
  }

}

# ---------------------------------------------------------------------------
# Desired-state files published as Automation variables.
# ---------------------------------------------------------------------------

variable "desired_state_files" {
  description = <<-EOT
    Files to publish as Automation string variables, keyed by variable name,
    each value a path relative to the repository root. The variable holds the
    file's text, and a file edit is a plan diff on the variable, so a runbook
    always reads exactly what the repository says (docs/adr/0012).

    This is also how structured configuration reaches a runbook, because a job
    schedule cannot carry JSON safely: the Automation service may parse a
    JSON-looking parameter value before it is bound. The corp cell publishes

      AuthMethods_Policy, AuthMethods_<Id>  the authentication methods desired state
                                            (policies/entra/authentication-methods)
      PimPolicy_AzureBaseline               Invoke-AzurePimPolicyGovernance's baseline
      PimPolicy_EntraBaseline               Invoke-EntraPimPolicyDrift's baseline

    and each runbook takes the variable's name as a plain string parameter
    (baselinevariablename) and reads the value with Get-AutomationStringVariable.
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
