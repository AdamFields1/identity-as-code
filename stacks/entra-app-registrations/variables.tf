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
# Security groups. Same shape as modules/entra/security-group.
# ---------------------------------------------------------------------------

variable "security_groups" {
  description = "Access groups for the applications in this stack, keyed by logical name. See modules/entra/security-group for attribute semantics."
  type = map(object({
    display_name       = string
    description        = optional(string, "Managed by Terraform.")
    assignable_to_role = optional(bool, false)
    owners             = optional(list(string), [])
    member_users       = optional(list(string), [])
    member_groups      = optional(list(string), [])
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Application registrations. Same shape as modules/entra/app-registration.
# ---------------------------------------------------------------------------

variable "applications" {
  description = "Application registrations keyed by logical name. See modules/entra/app-registration for attribute semantics."
  type = map(object({
    display_name      = string
    description       = optional(string, "Managed by Terraform. Owners may edit redirect URIs, claims, and branding in the portal.")
    sign_in_audience  = optional(string, "AzureADMyOrg")
    owners            = optional(list(string), [])
    identifier_uris   = optional(list(string), [])
    web_redirect_uris = optional(list(string), [])
    web_homepage_url  = optional(string)
    web_logout_url    = optional(string)
    tags              = optional(list(string), [])

    required_resource_access = optional(map(object({
      application = optional(list(string), [])
      delegated   = optional(list(string), [])
    })), {})

    federated_credentials = optional(map(object({
      display_name = string
      description  = optional(string, "Managed by Terraform.")
      issuer       = optional(string, "https://token.actions.githubusercontent.com")
      subject      = string
      audiences    = optional(list(string), ["api://AzureADTokenExchange"])
    })), {})

    enforced_graph_app_roles = optional(list(string), [])

    service_principal = optional(object({
      account_enabled              = optional(bool, true)
      app_role_assignment_required = optional(bool, true)
      notes                        = optional(string, "Managed by Terraform.")
    }), {})
  }))
  default = {}
}
