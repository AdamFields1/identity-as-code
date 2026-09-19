# ---------------------------------------------------------------------------
# Region. Consumed by the Terragrunt-generated provider block, never by
# resources directly (the resources read the region they landed in from
# data.aws_region). Under accounts/<account-name>/ the partition locator
# supplies it, so an account cell does not have to say it. Credentials are
# not variables: for an account cell the root gives the provider the shared
# config profile that names the account's deployment role
# (identity-as-code-<account-name>, filled by the workflow or by the
# engineer, never by a cell), so no role ARN enters a plan file, a cell, or
# state.
# ---------------------------------------------------------------------------

variable "region" {
  description = "Region the application's resources live in, for example us-east-1 or us-gov-west-1. Supplied by tenants/aws/<partition>/partition.hcl for an account cell; a cell that sets it wins."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as us-east-1 or us-gov-west-1."
  }
}

# ---------------------------------------------------------------------------
# Naming. Every resource name in this stack derives from app_name and
# environment, so a cell says them once and the roles, the key alias, the
# bucket, the log group, and the parameter namespace agree by construction.
# environment is a name segment and nothing else: no resource in this stack
# is conditional on it, and no module receives it. The path is still the
# environment in this repository; the word appears in names because ECS,
# SSM, and CloudWatch Logs need one namespace per deployment of the
# application, and the account name is not always that.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = "Name of the application, used as the first segment of every resource name: roles <app>-<env>-task and <app>-<env>-task-execution, key alias <app>-<env>, bucket <app>-<env>-artifacts-<account id>, log group /ecs/<app>/<env>, parameters under /<app>/<env>/. The stack is this application's; the default is its name."
  type        = string
  default     = "payments-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}[a-z0-9]$", var.app_name)) && !strcontains(var.app_name, "--")
    error_message = "app_name must be 3 to 25 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit. The bound keeps every derived name inside the S3 (63) and IAM (64) limits with the account id and suffixes added."
  }
}

variable "environment" {
  description = "Deployment of the application this cell is, for example prod or dev. A name segment only: it selects nothing and no module receives it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,12}$", var.environment))
    error_message = "environment must be 1 to 12 lowercase letters and digits, for example prod, dev, or staging."
  }
}

# ---------------------------------------------------------------------------
# Log retention. CloudWatch Logs accepts a fixed set of values; anything else
# is refused by the API after the plan, so it is checked here first. There
# is deliberately no way to say "never expire": a payments log group that
# keeps everything forever is a cost and a records-retention decision, and
# the longest value the API offers (3653 days, ten years) is available.
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Days CloudWatch Logs keeps the application's log events. One of the values the API accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653. Default 90."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, or 3653. Zero (never expire) is not offered."
  }
}

# ---------------------------------------------------------------------------
# Tags. Applied to every taggable resource in the stack, with Application
# and Environment added from the two naming variables so the tags cannot
# disagree with the names.
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every resource in the stack. Application and Environment are added by the stack from app_name and environment and may not be set here."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(setintersection(keys(var.tags), ["Application", "Environment"])) == 0
    error_message = "tags may not set Application or Environment; the stack derives both from app_name and environment so the tags always match the names."
  }
}
