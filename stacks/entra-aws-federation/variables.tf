# ---------------------------------------------------------------------------
# Tenant identity. Consumed by the Terragrunt-generated provider blocks, never by
# resources directly. Credentials are not variables: the providers use OIDC
# (use_oidc) so no secret touches disk or state.
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Entra tenant ID (GUID). Not a secret; a tenant ID is discoverable from any of its domains."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "subscription_id" {
  description = "Azure subscription ID for the azurerm provider. Unused by this Entra-only stack but required by the generated provider block."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID when set."
  }
}

# ---------------------------------------------------------------------------
# Groups. One list for every Identity Center instance this tenant feeds. Each
# name carries its partition (AWS-COM-* or AWS-GOV-*), and the stack hands
# each target the groups for its partition. The cell lists a group once; which
# application it is assigned to follows from its name.
# ---------------------------------------------------------------------------

variable "aws_groups" {
  description = "Display names of every AWS access group in the tenant, named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>. The stack assigns each to the target whose partition_token matches. See modules/entra/aws-identity-center-app."
  type        = list(string)

  validation {
    condition     = alltrue([for g in var.aws_groups : can(regex("^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$", g))])
    error_message = "Every group must be named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>, for example AWS-COM-111111111111-ReadOnly."
  }

  validation {
    condition     = length(distinct(var.aws_groups)) == length(var.aws_groups)
    error_message = "aws_groups must not repeat a group."
  }
}

# ---------------------------------------------------------------------------
# Identity Center targets. One entry per Identity Center instance this tenant
# is the identity source for, keyed by the same name as the AWS cell
# (tenants/aws/<key>/aws-identity-center). Same shape as
# modules/entra/aws-identity-center-app, minus the group list (derived from
# aws_groups by partition_token) and the SCIM credentials (which arrive
# separately so this map is safe to print).
# ---------------------------------------------------------------------------

variable "targets" {
  description = "Identity Center instances to federate, keyed by partition name (commercial, govcloud). See modules/entra/aws-identity-center-app for attribute semantics."
  type = map(object({
    display_name                 = string
    partition_token              = string
    identifier_uris              = list(string)
    reply_urls                   = list(string)
    sign_on_url                  = optional(string)
    relay_state                  = optional(string)
    notification_email_addresses = optional(list(string), [])
    app_role_display_name        = optional(string, "User")
    account_enabled              = optional(bool, true)

    signing_certificate = optional(object({
      display_name = optional(string, "CN=AWS IAM Identity Center SAML signing")
      end_date     = optional(string)
    }), {})

    scim = optional(object({
      enabled     = optional(bool, true)
      template_id = optional(string, "aws")
    }), {})
  }))

  validation {
    condition     = alltrue([for k in keys(var.targets) : can(regex("^[a-z][a-z0-9-]*$", k))])
    error_message = "Target keys must be lowercase partition names such as commercial or govcloud; they double as the TF_VAR_scim_credentials keys."
  }

  validation {
    condition     = alltrue([for t in var.targets : contains(["COM", "GOV"], t.partition_token)])
    error_message = "Every target's partition_token must be COM or GOV."
  }

  validation {
    condition     = length(distinct([for t in var.targets : t.partition_token])) == length(var.targets)
    error_message = "Each partition_token may appear on one target only; one Entra tenant feeds one Identity Center instance per partition."
  }

  validation {
    condition     = length(distinct([for t in var.targets : t.display_name])) == length(var.targets)
    error_message = "Every target must have a distinct display_name."
  }

  validation {
    condition = alltrue([
      for g in var.aws_groups : contains([for t in var.targets : t.partition_token], try(regex("^AWS-(GOV|COM)-", g)[0], ""))
    ])
    error_message = "Every group in aws_groups must belong to a partition that has a target. A group for a partition with no Identity Center instance would be provisioned nowhere."
  }
}

# ---------------------------------------------------------------------------
# SCIM credentials, keyed like targets. Never set in a cell. Supplied through
# the environment as TF_VAR_scim_credentials, a map in HCL or JSON syntax:
#
#   export TF_VAR_scim_credentials='{
#     commercial = { base_address = "https://scim.us-east-1.amazonaws.com/CHANGEME/scim/v2", secret_token = "CHANGEME" }
#     govcloud   = { base_address = "https://scim.us-gov-west-1.amazonaws.com/CHANGEME/scim/v2", secret_token = "CHANGEME" }
#   }'
#
# In CI the value is a GitHub environment secret. A target whose scim.enabled
# is true and has no entry here fails the module's validation with a message
# naming the target, so a missing secret is a failed plan, never a destroyed
# provisioning job.
# ---------------------------------------------------------------------------

variable "scim_credentials" {
  description = "Map of target key to { base_address, secret_token } for SCIM provisioning. Sensitive. Supplied as TF_VAR_scim_credentials from the environment, never from a cell."
  type = map(object({
    base_address = string
    secret_token = string
  }))
  default   = {}
  sensitive = true
}
