variable "name" {
  description = "Display name of the password policy."
  type        = string

  validation {
    condition     = length(trimspace(var.name)) > 0
    error_message = "Policy name must not be empty."
  }
}

variable "description" {
  description = "Human readable description shown in the Okta admin console."
  type        = string
  default     = "Managed by Terraform. Do not edit in the console."
}

variable "priority" {
  description = "Policy priority. 1 is evaluated first. Leave null to let Okta append it after existing policies."
  type        = number
  default     = null

  validation {
    condition     = var.priority == null || try(var.priority >= 1, false)
    error_message = "Priority must be a positive integer when set."
  }
}

variable "status" {
  description = "Policy status, ACTIVE or INACTIVE."
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.status)
    error_message = "Status must be ACTIVE or INACTIVE."
  }
}

variable "groups_included" {
  description = "List of Okta group IDs the policy applies to."
  type        = list(string)

  validation {
    condition     = length(var.groups_included) > 0
    error_message = "At least one group ID is required."
  }
}

variable "auth_provider" {
  description = "Authentication provider for the policy: OKTA, ACTIVE_DIRECTORY, or LDAP."
  type        = string
  default     = "OKTA"

  validation {
    condition     = contains(["OKTA", "ACTIVE_DIRECTORY", "LDAP"], var.auth_provider)
    error_message = "auth_provider must be OKTA, ACTIVE_DIRECTORY, or LDAP."
  }
}

# ---------------------------------------------------------------------------
# Complexity. Defaults follow NIST SP 800-63B: length over composition rules,
# dictionary screening on, and no forced periodic rotation.
# ---------------------------------------------------------------------------

variable "complexity" {
  description = <<-EOT
    Password complexity settings.
    min_length         : minimum characters. Default 14.
    min_lowercase      : minimum lowercase letters (0 or 1).
    min_uppercase      : minimum uppercase letters (0 or 1).
    min_number         : minimum digits (0 or 1).
    min_symbol         : minimum symbols (0 or 1).
    exclude_username   : reject passwords containing the username.
    exclude_first_name : reject passwords containing the user's first name.
    exclude_last_name  : reject passwords containing the user's last name.
    dictionary_lookup  : reject passwords found in Okta's common password dictionary.
  EOT

  type = object({
    min_length         = optional(number, 14)
    min_lowercase      = optional(number, 1)
    min_uppercase      = optional(number, 1)
    min_number         = optional(number, 1)
    min_symbol         = optional(number, 1)
    exclude_username   = optional(bool, true)
    exclude_first_name = optional(bool, true)
    exclude_last_name  = optional(bool, true)
    dictionary_lookup  = optional(bool, true)
  })
  default = {}

  validation {
    condition     = var.complexity.min_length >= 8 && var.complexity.min_length <= 72
    error_message = "min_length must be between 8 and 72."
  }

  validation {
    condition = alltrue([
      for n in [var.complexity.min_lowercase, var.complexity.min_uppercase, var.complexity.min_number, var.complexity.min_symbol] :
      n == 0 || n == 1
    ])
    error_message = "Okta only supports 0 or 1 for the per-character-class minimums."
  }
}

# ---------------------------------------------------------------------------
# Age and history.
# ---------------------------------------------------------------------------

variable "age" {
  description = <<-EOT
    Password age and history settings.
    max_age_days     : 0 disables expiry. Forced rotation is discouraged by NIST unless there is evidence of compromise.
    expire_warn_days : days before expiry to warn the user. Ignored when max_age_days is 0.
    min_age_minutes  : minimum time between changes, which stops users cycling through history in one sitting.
    history_count    : number of previous passwords that cannot be reused.
  EOT

  type = object({
    max_age_days     = optional(number, 0)
    expire_warn_days = optional(number, 0)
    min_age_minutes  = optional(number, 60)
    history_count    = optional(number, 24)
  })
  default = {}

  validation {
    condition     = var.age.max_age_days >= 0 && var.age.expire_warn_days >= 0 && var.age.min_age_minutes >= 0
    error_message = "Age values must be zero or positive."
  }

  validation {
    condition     = var.age.history_count >= 0 && var.age.history_count <= 30
    error_message = "history_count must be between 0 and 30."
  }

  validation {
    condition     = var.age.max_age_days == 0 || var.age.expire_warn_days < var.age.max_age_days
    error_message = "expire_warn_days must be less than max_age_days when expiry is enabled."
  }
}

# ---------------------------------------------------------------------------
# Lockout.
# ---------------------------------------------------------------------------

variable "lockout" {
  description = <<-EOT
    Account lockout settings.
    max_attempts          : failed attempts before lockout. 0 disables lockout.
    auto_unlock_minutes   : minutes until automatic unlock. 0 requires an admin unlock.
                            The default of 30 limits brute force without turning lockout into a denial-of-service tool.
    show_failures         : tell the user how many attempts remain.
    notification_channels : where to notify the user on lockout, currently only "EMAIL".
  EOT

  type = object({
    max_attempts          = optional(number, 10)
    auto_unlock_minutes   = optional(number, 30)
    show_failures         = optional(bool, true)
    notification_channels = optional(list(string), ["EMAIL"])
  })
  default = {}

  validation {
    condition     = var.lockout.max_attempts >= 0 && var.lockout.auto_unlock_minutes >= 0
    error_message = "Lockout values must be zero or positive."
  }

  validation {
    condition     = alltrue([for c in var.lockout.notification_channels : c == "EMAIL"])
    error_message = "notification_channels currently only supports \"EMAIL\"."
  }
}

# ---------------------------------------------------------------------------
# Recovery. Email is the only channel on by default. SMS and voice are off because
# they are the weakest recovery paths and a common target for SIM swap attacks.
# ---------------------------------------------------------------------------

variable "recovery" {
  description = <<-EOT
    Self-service recovery settings.
    email               : ACTIVE or INACTIVE.
    email_token_minutes : lifetime of the emailed recovery token.
    sms                 : ACTIVE or INACTIVE.
    call                : ACTIVE or INACTIVE.
    question            : ACTIVE or INACTIVE.
    question_min_length : minimum answer length when security questions are enabled.
    skip_unlock         : when true, users cannot self-unlock and must reset instead.
  EOT

  type = object({
    email               = optional(string, "ACTIVE")
    email_token_minutes = optional(number, 60)
    sms                 = optional(string, "INACTIVE")
    call                = optional(string, "INACTIVE")
    question            = optional(string, "INACTIVE")
    question_min_length = optional(number, 8)
    skip_unlock         = optional(bool, false)
  })
  default = {}

  validation {
    condition = alltrue([
      for s in [var.recovery.email, var.recovery.sms, var.recovery.call, var.recovery.question] :
      contains(["ACTIVE", "INACTIVE"], s)
    ])
    error_message = "Recovery channel values must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = var.recovery.email_token_minutes >= 1 && var.recovery.email_token_minutes <= 10080
    error_message = "email_token_minutes must be between 1 and 10080 (7 days)."
  }

  validation {
    condition     = var.recovery.question_min_length >= 4
    error_message = "question_min_length must be at least 4."
  }
}

# ---------------------------------------------------------------------------
# Rules.
# ---------------------------------------------------------------------------

variable "rules" {
  description = <<-EOT
    Password rules keyed by a stable logical name, each with an explicit unique priority.
    password_change    : ALLOW or DENY self-service password change.
    password_reset     : ALLOW or DENY self-service password reset.
    password_unlock    : ALLOW or DENY self-service unlock.
    network_connection : ANYWHERE or ZONE. When ZONE, supply zone_ids_included and/or zone_ids_excluded.
  EOT

  type = map(object({
    name               = string
    priority           = number
    status             = optional(string, "ACTIVE")
    password_change    = optional(string, "ALLOW")
    password_reset     = optional(string, "ALLOW")
    password_unlock    = optional(string, "ALLOW")
    network_connection = optional(string, "ANYWHERE")
    zone_ids_included  = optional(list(string), [])
    zone_ids_excluded  = optional(list(string), [])
    users_excluded     = optional(list(string), [])
  }))

  validation {
    condition     = length(var.rules) > 0
    error_message = "At least one rule is required."
  }

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [
        for v in [r.password_change, r.password_reset, r.password_unlock] : contains(["ALLOW", "DENY"], v)
      ]
    ]))
    error_message = "password_change, password_reset, and password_unlock must be ALLOW or DENY."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ANYWHERE", "ZONE"], r.network_connection)])
    error_message = "Rule network_connection must be ANYWHERE or ZONE."
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.network_connection != "ZONE" || (length(r.zone_ids_included) + length(r.zone_ids_excluded)) > 0
    ])
    error_message = "Rules with network_connection = ZONE must list at least one included or excluded zone ID."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["ACTIVE", "INACTIVE"], r.status)])
    error_message = "Rule status must be ACTIVE or INACTIVE."
  }

  validation {
    condition     = length(distinct([for r in var.rules : r.priority])) == length(var.rules)
    error_message = "Rule priorities must be unique within a policy."
  }
}
