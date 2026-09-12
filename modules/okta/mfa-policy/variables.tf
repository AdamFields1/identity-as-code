variable "name" {
  description = "Display name of the MFA enrollment policy."
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

variable "is_oie" {
  description = "True for Okta Identity Engine tenants (authenticator model). False for Classic Engine tenants (factor model). Controls which authenticator keys are valid."
  type        = bool
  default     = true
}

variable "authenticators" {
  description = <<-EOT
    Authenticator enrollment settings keyed by the provider attribute name, for example
    "okta_verify" or "fido_webauthn". Each entry sets:
      enroll       : NOT_ALLOWED, OPTIONAL, or REQUIRED
      consent_type : NONE or TERMS_OF_SERVICE (defaults to NONE)

    Only keys present in the map are sent to Okta. Any authenticator you omit is left
    at the tenant default, which for most authenticators means NOT_ALLOWED.

    Supported keys (OIE): okta_password, okta_email, okta_verify, phone_number,
    fido_webauthn, google_otp, security_question, duo, yubikey_token, symantec_vip,
    rsa_token, onprem_mfa, external_idp, smart_card_idp, hotp.
    Classic-only keys: okta_otp, okta_push, okta_sms, okta_call, okta_question.
  EOT

  type = map(object({
    enroll       = string
    consent_type = optional(string, "NONE")
  }))

  validation {
    condition = alltrue([
      for k, v in var.authenticators : contains([
        "okta_password", "okta_email", "okta_verify", "phone_number", "fido_webauthn",
        "google_otp", "security_question", "duo", "yubikey_token", "symantec_vip",
        "rsa_token", "onprem_mfa", "external_idp", "smart_card_idp", "hotp",
        "okta_otp", "okta_push", "okta_sms", "okta_call", "okta_question",
      ], k)
    ])
    error_message = "Unknown authenticator key. See the variable description for the supported list."
  }

  validation {
    condition     = alltrue([for v in var.authenticators : contains(["NOT_ALLOWED", "OPTIONAL", "REQUIRED"], v.enroll)])
    error_message = "Authenticator enroll must be NOT_ALLOWED, OPTIONAL, or REQUIRED."
  }

  validation {
    condition     = alltrue([for v in var.authenticators : contains(["NONE", "TERMS_OF_SERVICE"], v.consent_type)])
    error_message = "Authenticator consent_type must be NONE or TERMS_OF_SERVICE."
  }

  validation {
    condition     = length([for k, v in var.authenticators : k if v.enroll == "REQUIRED"]) > 0
    error_message = "At least one authenticator must be REQUIRED, otherwise users can complete enrollment with no second factor."
  }
}

variable "rules" {
  description = <<-EOT
    MFA enrollment rules keyed by a stable logical name, each with an explicit unique priority.

    enroll             : when a user is prompted to enroll. LOGIN prompts at next sign-in,
                         CHALLENGE prompts the first time an MFA challenge occurs, NEVER disables prompting.
    network_connection : ANYWHERE or ZONE. When ZONE, supply zone_ids_included and/or zone_ids_excluded.
    users_excluded     : user IDs exempt from the rule.
    app_include        : optional list of app conditions ({ type = "APP" | "APP_TYPE", id = ..., name = ... }).
  EOT

  type = map(object({
    name               = string
    priority           = number
    status             = optional(string, "ACTIVE")
    enroll             = optional(string, "LOGIN")
    network_connection = optional(string, "ANYWHERE")
    zone_ids_included  = optional(list(string), [])
    zone_ids_excluded  = optional(list(string), [])
    users_excluded     = optional(list(string), [])
    app_include = optional(list(object({
      type = string
      id   = optional(string)
      name = optional(string)
    })), [])
  }))

  validation {
    condition     = length(var.rules) > 0
    error_message = "At least one rule is required."
  }

  validation {
    condition     = alltrue([for r in var.rules : contains(["LOGIN", "CHALLENGE", "NEVER"], r.enroll)])
    error_message = "Rule enroll must be LOGIN, CHALLENGE, or NEVER."
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

  validation {
    condition = alltrue(flatten([
      for r in var.rules : [for a in r.app_include : contains(["APP", "APP_TYPE"], a.type)]
    ]))
    error_message = "app_include entries must have type APP or APP_TYPE."
  }
}
