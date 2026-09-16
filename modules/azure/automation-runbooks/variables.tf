variable "automation_account_name" {
  description = "Name of the Automation account the runbooks are published to."
  type        = string

  validation {
    condition     = length(trimspace(var.automation_account_name)) > 0
    error_message = "automation_account_name must not be empty."
  }
}

variable "resource_group_name" {
  description = "Resource group of the Automation account."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "location" {
  description = "Region of the Automation account. Runbooks are regional resources and must match it."
  type        = string

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "runbooks" {
  description = <<-EOT
    Runbooks keyed by a stable logical name. The key is part of the Terraform
    address; the runbook name in Azure is "name".

    name                     : runbook name in the account. Letters, digits, hyphens,
                               underscores; 63 characters or fewer.
    content_path             : path to the .ps1 file whose content is published.
    description              : optional.
    runbook_type             : PowerShell72 (default), PowerShell, PowerShellWorkflow,
                               Python3, Python2, Graph, GraphPowerShell,
                               GraphPowerShellWorkflow, or Script.
    log_verbose              : keep the verbose stream with the job. Default true,
                               because the runbooks here log through it.
    log_progress             : keep the progress stream. Default false.
    runtime_environment_name : optional runtime environment for accounts that use them.
    tags                     : optional extra tags; content_sha256 is always added.
  EOT

  type = map(object({
    name                     = string
    content_path             = string
    description              = optional(string, "Managed by Terraform. See the identity-as-code repository.")
    runbook_type             = optional(string, "PowerShell72")
    log_verbose              = optional(bool, true)
    log_progress             = optional(bool, false)
    runtime_environment_name = optional(string)
    tags                     = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for r in var.runbooks : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,62}$", r.name))])
    error_message = "Runbook name must start with a letter, contain only letters, digits, hyphens, and underscores, and be 63 characters or fewer."
  }

  validation {
    condition     = length(distinct([for r in var.runbooks : r.name])) == length(var.runbooks)
    error_message = "Runbook names must be unique within the map."
  }

  validation {
    condition = alltrue([
      for r in var.runbooks : contains([
        "PowerShell72", "PowerShell", "PowerShellWorkflow", "Python3", "Python2",
        "Graph", "GraphPowerShell", "GraphPowerShellWorkflow", "Script",
      ], r.runbook_type)
    ])
    error_message = "runbook_type must be one of PowerShell72, PowerShell, PowerShellWorkflow, Python3, Python2, Graph, GraphPowerShell, GraphPowerShellWorkflow, or Script."
  }

  validation {
    condition     = alltrue([for r in var.runbooks : fileexists(r.content_path)])
    error_message = "Every runbook content_path must point at an existing file."
  }
}

variable "schedules" {
  description = <<-EOT
    Schedules keyed by a stable logical name.

    name        : schedule name in the account.
    description : optional.
    frequency   : OneTime, Day, Hour, Week, or Month.
    interval    : number of frequency units between runs. Default 1. Ignored for OneTime.
    timezone    : IANA or Windows time zone name. Default Etc/UTC.
    start_time  : RFC 3339 instant. Must be at least five minutes in the future when the
                  schedule is created. Afterwards it anchors the time of day and, for
                  Week, the day of week, and is only re-sent when the schedule changes.
    expiry_time : optional RFC 3339 instant after which the schedule stops.
    week_days   : for Week only: Monday ... Sunday.
    month_days  : for Month only: 1 to 31, or -1 for the last day.
  EOT

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
  default = {}

  validation {
    condition     = alltrue([for s in var.schedules : contains(["OneTime", "Day", "Hour", "Week", "Month"], s.frequency)])
    error_message = "frequency must be OneTime, Day, Hour, Week, or Month."
  }

  validation {
    condition     = alltrue([for s in var.schedules : s.interval >= 1 && floor(s.interval) == s.interval])
    error_message = "interval must be a whole number of at least 1."
  }

  validation {
    condition     = alltrue([for s in var.schedules : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$", s.start_time))])
    error_message = "start_time must be an RFC 3339 instant such as 2027-01-04T06:00:00Z."
  }

  validation {
    condition = alltrue(flatten([
      for s in var.schedules : [
        for d in s.week_days : contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], d)
      ]
    ]))
    error_message = "week_days entries must be Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, or Sunday."
  }

  validation {
    condition     = alltrue([for s in var.schedules : length(s.week_days) == 0 || s.frequency == "Week"])
    error_message = "week_days is only valid when frequency is Week."
  }

  validation {
    condition     = alltrue([for s in var.schedules : length(s.month_days) == 0 || s.frequency == "Month"])
    error_message = "month_days is only valid when frequency is Month."
  }

  validation {
    condition     = alltrue(flatten([for s in var.schedules : [for d in s.month_days : d == -1 || (d >= 1 && d <= 31)]]))
    error_message = "month_days entries must be 1 to 31, or -1 for the last day of the month."
  }

  validation {
    condition     = length(distinct([for s in var.schedules : s.name])) == length(var.schedules)
    error_message = "Schedule names must be unique within the map."
  }
}

variable "job_schedules" {
  description = <<-EOT
    Links between a runbook and a schedule, keyed by a stable logical name.

    runbook_key  : key into runbooks.
    schedule_key : key into schedules.
    parameters   : runbook parameters as strings. Keys MUST be lowercase; Azure
                   Automation normalises them and a mixed-case key is a permanent diff.
                   Every argument of this resource forces replacement, so a parameter
                   change is a destroy and a create of the link.
    run_on       : optional hybrid worker group name. Null runs in the Azure sandbox.
  EOT

  type = map(object({
    runbook_key  = string
    schedule_key = string
    parameters   = optional(map(string), {})
    run_on       = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for j in var.job_schedules : contains(keys(var.runbooks), j.runbook_key)])
    error_message = "Every job_schedules entry must reference a key in runbooks."
  }

  validation {
    condition     = alltrue([for j in var.job_schedules : contains(keys(var.schedules), j.schedule_key)])
    error_message = "Every job_schedules entry must reference a key in schedules."
  }

  validation {
    condition     = alltrue(flatten([for j in var.job_schedules : [for k in keys(j.parameters) : k == lower(k)]]))
    error_message = "Job schedule parameter keys must be lowercase (dryrun, not DryRun); Azure Automation normalises them and the provider would show a permanent diff."
  }
}

variable "tags" {
  description = "Tags applied to every runbook, merged under each runbook's own tags and the content hash."
  type        = map(string)
  default     = {}
}
