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
# SAML enterprise applications. The same shape as modules/entra/saml-enterprise-app.
# The token of a token-based SCIM connector is not in it, there or here: it
# arrives through provisioning_secret_tokens below and is passed to the
# module's own sensitive input. Groups inside app_roles_to_groups are NAMES;
# the module looks them up.
# ---------------------------------------------------------------------------

variable "saml_apps" {
  description = <<-EOT
    SAML enterprise applications keyed by logical name. See
    modules/entra/saml-enterprise-app for every attribute and what the module
    refuses about a single entry; this stack adds the checks that only the whole
    map can show (display names, reply URLs and entity IDs unique across apps)
    and owns where the token arrives:

    provisioning : { template_id, base_address }, as the module takes it. The
                   token of a token-based SCIM connector is never in a cell; it
                   arrives as TF_VAR_provisioning_secret_tokens keyed by this
                   map's key and is passed to the module beside the map. A
                   connector that is authorised by an OAuth consent in the
                   portal (Google Workspace) leaves provisioning unset; the
                   README shows the one console step.

    gallery_template_display_name null means a custom, non-gallery SAML app.
    app_roles_to_groups maps an app role display name to group NAMES; a group
    that does not exist in the tenant fails the plan. Fixed by the module and
    not on the menu: assignment required, SAML as the sign-on mode, a signing
    key Entra generates, and the claims mapping policy it renders.
  EOT

  type = map(object({
    display_name                  = string
    gallery_template_display_name = optional(string)
    identifier_uris               = list(string)
    reply_urls                    = list(string)
    sign_on_url                   = string
    logout_url                    = optional(string)
    relay_state                   = optional(string)
    notification_email_addresses  = list(string)

    signing_certificate = object({
      display_name = string
      end_date     = optional(string)
    })

    name_id = optional(object({
      source = optional(string, "mail")
      format = optional(string, "emailAddress")
    }), {})

    claims = optional(list(object({
      name   = string
      source = string
    })), [])

    app_roles_to_groups = optional(map(list(string)), {})
    account_enabled     = optional(bool, true)

    provisioning = optional(object({
      template_id  = optional(string)
      base_address = optional(string)
    }))
  }))
  default = {}

  validation {
    condition     = length(distinct([for a in var.saml_apps : lower(trimspace(a.display_name))])) == length(var.saml_apps)
    error_message = "Two apps in this cell share a display_name (compared without case). Entra's duplicate check is case insensitive and would refuse the second app at apply; the person clicking a tile and the reviewer reading an audit event cannot tell them apart either way."
  }

  validation {
    condition = length(distinct(flatten([
      for a in var.saml_apps : distinct([for u in a.reply_urls : lower(u)])
    ]))) == sum(concat([0], [for a in var.saml_apps : length(distinct([for u in a.reply_urls : lower(u)]))]))
    error_message = "A reply URL appears on two apps in this cell. An assertion consumer service URL belongs to one service provider; the same URL on a second app sends that vendor a signed assertion meant for another audience. Give each app its own vendor's ACS URL."
  }

  validation {
    condition = length(distinct(flatten([
      for a in var.saml_apps : distinct([for u in a.identifier_uris : lower(u)])
    ]))) == sum(concat([0], [for a in var.saml_apps : length(distinct([for u in a.identifier_uris : lower(u)]))]))
    error_message = "An entity ID (identifier_uris) appears on two apps in this cell. Entra requires identifier URIs to be unique in the tenant and would refuse the second app at apply; two apps with one audience is one service provider onboarded twice."
  }
}

# ---------------------------------------------------------------------------
# Provisioning tokens, keyed like saml_apps. Never set in a cell. Supplied
# through the environment as TF_VAR_provisioning_secret_tokens, a map in HCL
# or JSON syntax:
#
#   export TF_VAR_provisioning_secret_tokens='{
#     example-payroll = "CHANGEME"
#   }'
#
# In CI the value is a GitHub environment secret. The stack passes the map to
# the module's own sensitive input unchanged; the endpoint (base_address) is
# the cell's, stated beside template_id, because it is not a secret. A key
# here that names no app of this cell with provisioning set is refused, so a
# token with no job to use it is a failed plan rather than a value written to
# state for nothing. An app whose connector takes a token and has no entry
# here plans a job without a secret, which the vendor's Test connection then
# reports; the stack cannot know which templates need a token and which are
# authorised in the portal.
# ---------------------------------------------------------------------------

variable "provisioning_secret_tokens" {
  description = "Map of saml_apps key to the bearer token of its token-based SCIM connector. Sensitive. Supplied as TF_VAR_provisioning_secret_tokens from the environment, never from a cell, and passed to the module's own sensitive input."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition     = alltrue([for key in keys(var.provisioning_secret_tokens) : try(var.saml_apps[key].provisioning != null, false)])
    error_message = "Every key of provisioning_secret_tokens must be the key of an app in saml_apps that sets provisioning. A token for an app that has no provisioning job, or for a key that is not in this cell, would be written to nowhere; remove it or add provisioning.template_id to the app."
  }
}
