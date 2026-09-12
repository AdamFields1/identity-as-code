# ---------------------------------------------------------------------------
# Region. Consumed by the Terragrunt-generated provider block, never by
# resources directly. Identity Center is a regional service with one instance
# per organization, so the region is the address of the instance. Credentials
# are not variables: the provider reads them from the environment (GitHub OIDC
# in CI, a profile or SSO session locally) so nothing touches disk or state.
# ---------------------------------------------------------------------------

variable "region" {
  description = "Region the Identity Center instance lives in, for example us-east-1 or us-gov-west-1. Also selects the partition: a us-gov-* region is the aws-us-gov partition."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as us-east-1 or us-gov-west-1."
  }
}

# ---------------------------------------------------------------------------
# Permission sets. Same shape as modules/aws/permission-set.
# ---------------------------------------------------------------------------

variable "permission_sets" {
  description = "Permission sets keyed by logical name. See modules/aws/permission-set for attribute semantics and defaults."
  type = map(object({
    name             = string
    description      = optional(string, "Managed by Terraform.")
    session_duration = optional(string, "PT1H")
    relay_state      = optional(string)

    aws_managed_policies = optional(list(string), [])

    customer_managed_policies = optional(list(object({
      name = string
      path = optional(string, "/")
    })), [])

    inline_policy = optional(string)

    permissions_boundary = optional(object({
      aws_managed_policy = optional(string)
      customer_managed_policy = optional(object({
        name = string
        path = optional(string, "/")
      }))
    }))

    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for ps in var.permission_sets : can(regex("^[A-Za-z0-9]+$", ps.name))])
    error_message = "Permission set names in this stack are letters and digits only, so they can be carried in a group name (AWS-<PARTITION>-<accountId>-<PermissionSetName>)."
  }
}

# ---------------------------------------------------------------------------
# Groups. The list of convention-named groups is the whole assignment model;
# see modules/aws/account-assignment. Every PermissionSetName carried by a
# group must be a permission set defined above, and this stack checks that
# before the module does so the error names the cell.
# ---------------------------------------------------------------------------

variable "group_display_names" {
  description = "Identity store groups to assign, named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>. See modules/aws/account-assignment for the convention."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.group_display_names : can(regex("^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$", g))])
    error_message = "Every group must be named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>, for example AWS-COM-111111111111-ReadOnly."
  }

  validation {
    condition = alltrue([
      for g in var.group_display_names :
      contains([for ps in var.permission_sets : ps.name], try(regex("^AWS-(GOV|COM)-[0-9]{12}-([A-Za-z0-9]+)$", g)[1], ""))
    ])
    error_message = "Every group's PermissionSetName must be the name of a permission set defined in this cell's permission_sets."
  }
}
