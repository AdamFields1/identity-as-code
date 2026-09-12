variable "group_display_names" {
  description = <<-EOT
    Display names of the identity store groups to assign. Each name follows the
    convention

      AWS-<PARTITION>-<accountId>-<PermissionSetName>

    where PARTITION is COM or GOV, accountId is the 12-digit account ID, and
    PermissionSetName is the name of a permission set managed alongside this
    module. The name IS the assignment: the module parses it and creates exactly
    one account assignment per group, for that permission set, in that account.

    Examples: AWS-COM-111111111111-PlatformAdmin, AWS-GOV-333333333333-ReadOnly.

    Groups are Entra security groups with the same display name, provisioned
    into the identity store by SCIM (stacks/entra-aws-federation). The module
    resolves each name to its identity store group ID; it never takes an ID.
    Principals are groups only; there is no user input.
  EOT

  type = list(string)

  validation {
    condition     = alltrue([for g in var.group_display_names : can(regex("^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$", g))])
    error_message = "Every group must be named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>, for example AWS-COM-111111111111-ReadOnly."
  }

  validation {
    condition     = length(distinct(var.group_display_names)) == length(var.group_display_names)
    error_message = "group_display_names must not repeat a group; Identity Center holds exactly one assignment per (account, permission set, group)."
  }

  validation {
    condition     = length(distinct([for g in var.group_display_names : try(regex("^AWS-(GOV|COM)-", g)[0], "")])) <= 1
    error_message = "A cell serves one partition. Do not mix AWS-GOV-* and AWS-COM-* groups in the same list."
  }
}

variable "permission_set_arns_by_name" {
  description = "Map of permission set NAME to ARN, the permission-set module's permission_set_arns_by_name output. Every PermissionSetName carried by a group must be a key here; a name that is not fails the plan."
  type        = map(string)

  validation {
    condition     = alltrue([for name, arn in var.permission_set_arns_by_name : can(regex("^[\\w+=,.@-]{1,32}$", name))])
    error_message = "permission_set_arns_by_name keys must be permission set names, not ARNs."
  }
}
