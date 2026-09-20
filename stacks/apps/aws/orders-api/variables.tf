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
# repository, the log group, and the parameter namespace agree by
# construction. environment is a name segment and nothing else: no resource
# in this stack is conditional on it, and no module receives it. The one
# place it is read for anything but a name is the publisher's trust, where
# it is the default GitHub environment (publisher_github_environment
# below). The path is still the environment in this repository; the word
# appears in names because ECS, ECR, SSM, and CloudWatch Logs need one
# namespace per deployment of the application, and the account name is not
# always that.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = "Name of the application, used as the first segment of every resource name: roles <app>-<env>-task, <app>-<env>-task-execution, and <app>-<env>-image-publisher, key alias <app>-<env>, repository <app>-<env>, log group /ecs/<app>/<env>, parameters under /<app>/<env>/. The stack is this application's; the default is its name."
  type        = string
  default     = "orders-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}[a-z0-9]$", var.app_name)) && !strcontains(var.app_name, "--")
    error_message = "app_name must be 3 to 25 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit. The bound keeps every derived name inside the IAM (64) limit with the environment and the longest suffix, -image-publisher, added, and inside the ECR naming rules, which accept exactly this character set."
  }
}

variable "environment" {
  description = "Deployment of the application this cell is, for example prod or dev. A name segment, and the GitHub environment the publisher trusts unless publisher_github_environment says otherwise; it selects nothing and no module receives it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,12}$", var.environment))
    error_message = "environment must be 1 to 12 lowercase letters and digits, for example prod, dev, or staging."
  }
}

# ---------------------------------------------------------------------------
# Who may publish the image: the jobs of one GitHub repository that run in
# one of its deployment environments, through the account's existing OIDC
# provider. No secret exists, and no branch is trusted: an environment
# carries the protection rules (required reviewers, which branches may
# deploy to it), and a branch subject beside it would be a way around them.
# The role module builds the subject condition from these three values and
# refuses a wildcard in any of them;
# the repository is named as two variables rather than one "org/repo"
# string so each half is checked against GitHub's own rules before the
# module sees it, as stacks/apps/azure/data-pipeline does.
# ---------------------------------------------------------------------------

variable "github_organization" {
  description = "GitHub organization (or user) that owns the application's repository, the one whose pipeline pushes the image."
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
  description = "GitHub environment whose jobs may assume the image publisher role: the only subject the trust matches. Null (default) uses environment, so a cell whose GitHub environment shares its deployment's name says nothing. An environment carries the protection rules (required reviewers, deployment branches), so restricting publishing to main is that environment's deployment-branch rule on GitHub; a branch trust is not offered, because a token carries the ref or the environment, never both, and a branch subject beside the environment would skip its rules."
  type        = string
  default     = null

  validation {
    condition     = var.publisher_github_environment == null || can(regex("^[^*?]+$", coalesce(var.publisher_github_environment, "*")))
    error_message = "publisher_github_environment must not be empty and must not contain * or ? when set; leave it null to use environment. The trust condition is an exact match on the token subject."
  }
}

# ---------------------------------------------------------------------------
# What the registry keeps. Both knobs are the registry module's lifecycle
# rules and carry its bounds; there is no value for "keep everything",
# because a repository that keeps every build forever is a cost and a
# records decision the pipeline never makes on purpose.
# ---------------------------------------------------------------------------

variable "image_retention_count" {
  description = "How many of the newest images the repository keeps, whatever their tag; beyond it the oldest expire. 1 to 1000. Default 30."
  type        = number
  default     = 30

  validation {
    condition     = var.image_retention_count >= 1 && var.image_retention_count <= 1000 && floor(var.image_retention_count) == var.image_retention_count
    error_message = "image_retention_count must be a whole number from 1 to 1000. It bounds how many images the repository holds; there is no value for \"keep everything\"."
  }
}

variable "untagged_image_expiry_days" {
  description = "Days after push that an untagged image (a layer set a later build superseded) expires. 1 to 365. Default 7."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_image_expiry_days >= 1 && var.untagged_image_expiry_days <= 365 && floor(var.untagged_image_expiry_days) == var.untagged_image_expiry_days
    error_message = "untagged_image_expiry_days must be a whole number from 1 to 365. An untagged image is a layer set a later build superseded, and a year is longer than any rollback needs."
  }
}

# ---------------------------------------------------------------------------
# Log retention. CloudWatch Logs accepts a fixed set of values; anything else
# is refused by the API after the plan, so it is checked here first. There
# is deliberately no way to say "never expire": a log group that keeps
# everything forever is a cost and a records-retention decision, and the
# longest value the API offers (3653 days, ten years) is available.
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
# Reference data the task role reads. The buckets are not this stack's: they
# are catalog entries in the account's aws-account-workloads cell, which is
# applied in the wave before the app stacks, so an app cell may name a
# catalog bucket and the bucket exists by the time this policy is applied.
# The reverse direction, a catalog bucket whose allow list names this
# stack's task role, fails on the first release because the catalog is
# applied before the role exists; a bucket read from here therefore has no
# allow list, and its readers are named in their own stacks.
# ---------------------------------------------------------------------------

variable "reference_bucket_names" {
  description = "Names of S3 buckets in this account, created and owned elsewhere (the account's catalog cell, in the wave before this one), whose objects the task role may read. Names, never ARNs: the stack builds the ARN from the partition it discovers, so nothing is looked up and no dependency is declared. Empty (default) grants nothing and leaves the task role's policy exactly as it was."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.reference_bucket_names : !startswith(n, "arn:") && !strcontains(n, "*") && !strcontains(n, "?")])
    error_message = "reference_bucket_names holds bucket NAMES, never ARNs and never a wildcard. The stack builds the ARN from the name and the partition it discovers; an ARN would carry a partition the cell should not know, and a wildcard would grant buckets the cell did not name."
  }

  validation {
    condition = alltrue([
      for n in var.reference_bucket_names :
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", n)) && !strcontains(n, "..") && !startswith(n, "xn--") && !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", n))
    ])
    error_message = "Every entry in reference_bucket_names must be an S3 bucket name as the s3-bucket module accepts it: 3 to 63 lowercase letters, digits, dots, and hyphens, starting and ending with a letter or digit, not containing \"..\", not starting with \"xn--\", and not shaped like an IP address."
  }

  validation {
    condition     = length(distinct(var.reference_bucket_names)) == length(var.reference_bucket_names)
    error_message = "reference_bucket_names lists a bucket twice. Each name renders one ARN in the task role's policy; list it once so the diff says what was granted."
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
