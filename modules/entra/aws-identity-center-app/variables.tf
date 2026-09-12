variable "display_name" {
  description = "Display name of the enterprise application in Entra ID, for example \"AWS IAM Identity Center (commercial)\". Unique in the tenant."
  type        = string

  validation {
    condition     = length(trimspace(var.display_name)) > 0
    error_message = "display_name must not be empty."
  }
}

variable "partition_token" {
  description = "Naming convention token of the partition this application federates: COM for the commercial instance (arn:aws), GOV for GovCloud (arn:aws-us-gov). Every assigned group must carry the same token."
  type        = string

  validation {
    condition     = contains(["COM", "GOV"], var.partition_token)
    error_message = "partition_token must be COM or GOV."
  }
}

variable "gallery_template_display_name" {
  description = "Display name of the gallery application template to instantiate. The lookup is case insensitive. Change only if Microsoft renames the gallery entry."
  type        = string
  default     = "AWS IAM Identity Center (successor to AWS Single Sign-On)"
}

variable "identifier_uris" {
  description = "SAML audience (Entity ID) values. For Identity Center this is the issuer URL from the instance's service provider metadata, https://<region>.signin.aws.amazon.com/platform/saml/<instance id> in commercial. Required: the gallery template does not preset it, and an empty set would strip whatever the portal has."
  type        = list(string)

  validation {
    condition     = length(var.identifier_uris) > 0 && alltrue([for u in var.identifier_uris : can(regex("^https://", u))])
    error_message = "identifier_uris must contain at least one https URL: the Identity Center issuer URL from the AWS console."
  }
}

variable "reply_urls" {
  description = "SAML assertion consumer service URLs. For Identity Center this is https://<region>.signin.aws.amazon.com/platform/saml/acs/<instance id> in commercial, one per enabled region. Required, as for identifier_uris."
  type        = list(string)

  validation {
    condition     = length(var.reply_urls) > 0 && alltrue([for u in var.reply_urls : can(regex("^https://", u))])
    error_message = "reply_urls must contain at least one https URL: the Identity Center ACS URL from the AWS console."
  }
}

variable "sign_on_url" {
  description = "Optional service-provider-initiated sign-on URL, the AWS access portal sign-in URL. Sets login_url on the service principal so the My Apps tile starts an SP-initiated flow."
  type        = string
  default     = null

  validation {
    condition     = var.sign_on_url == null || can(regex("^https://", coalesce(var.sign_on_url, "https://")))
    error_message = "sign_on_url must be an https URL when set."
  }
}

variable "relay_state" {
  description = "Optional SAML RelayState for IdP-initiated sign-in, for example a console URL to land on."
  type        = string
  default     = null
}

variable "notification_email_addresses" {
  description = "Addresses Entra notifies before the SAML signing certificate expires. A shared mailbox, not a person."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.notification_email_addresses : can(regex("^[^@\\s]+@[^@\\s]+$", e))])
    error_message = "notification_email_addresses must be email addresses."
  }
}

variable "assigned_groups" {
  description = <<-EOT
    Display names of the Entra security groups assigned to the application.
    Assignment is what puts a group, and its direct members, in scope for SCIM
    provisioning and for sign-in; nothing else does. Resolved to object IDs by
    the module.

    Every name follows the convention shared with the AWS side:

      AWS-<PARTITION>-<accountId>-<PermissionSetName>

    PARTITION must equal partition_token. The AWS cell for the same instance
    parses the rest of the name into an account assignment, so a group listed
    here is provisioned and, once the AWS cell is applied, granted exactly what
    its name says. See docs/adr/0008.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.assigned_groups) > 0
    error_message = "assigned_groups must name at least one group; an Identity Center application with no assigned group provisions nobody and signs in nobody."
  }

  validation {
    condition     = length(distinct(var.assigned_groups)) == length(var.assigned_groups)
    error_message = "assigned_groups must not repeat a group."
  }

  validation {
    condition     = alltrue([for g in var.assigned_groups : can(regex("^AWS-(GOV|COM)-[0-9]{12}-[A-Za-z0-9]+$", g))])
    error_message = "Every assigned group must be named AWS-<GOV|COM>-<12-digit account id>-<PermissionSetName>, for example AWS-COM-111111111111-ReadOnly."
  }

  validation {
    condition     = alltrue([for g in var.assigned_groups : try(regex("^AWS-(GOV|COM)-", g)[0], "") == var.partition_token])
    error_message = "Every assigned group must carry this application's partition_token (AWS-COM-* for the commercial application, AWS-GOV-* for GovCloud). A group provisioned into the wrong instance can never be assigned there."
  }
}

variable "app_role_display_name" {
  description = "Display name of the published app role to assign groups with. Gallery applications publish one enabled role for users and groups, named \"User\", which the portal assigns by default. If the instantiated service principal publishes no user-assignable role, the module uses the well-known default role ID instead; if it publishes several and none matches, the plan fails listing them."
  type        = string
  default     = "User"

  validation {
    condition     = length(trimspace(var.app_role_display_name)) > 0
    error_message = "app_role_display_name must not be empty."
  }
}

variable "signing_certificate" {
  description = "SAML token signing certificate Entra generates for this application. display_name must start with CN=. end_date is RFC3339; null lets Entra pick its default validity (three years). Changing end_date replaces the certificate, which is a new metadata upload in the AWS console."
  type = object({
    display_name = optional(string, "CN=AWS IAM Identity Center SAML signing")
    end_date     = optional(string)
  })
  default = {}

  validation {
    condition     = startswith(var.signing_certificate.display_name, "CN=")
    error_message = "signing_certificate.display_name must start with CN=."
  }

  validation {
    condition     = var.signing_certificate.end_date == null || can(formatdate("YYYY", coalesce(var.signing_certificate.end_date, "2000-01-01T00:00:00Z")))
    error_message = "signing_certificate.end_date must be an RFC3339 timestamp when set."
  }
}

variable "account_enabled" {
  description = "Whether the service principal accepts sign-ins. False disables federation and provisioning without destroying anything, for an incident or a planned cutover."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# SCIM provisioning. The endpoint and token are issued by the AWS console when
# automatic provisioning is enabled on the instance; that step is manual by
# construction (see README). Both values arrive through variables marked
# sensitive and are never literals in any file of this repository.
# ---------------------------------------------------------------------------

variable "scim_enabled" {
  description = "Whether to configure SCIM provisioning (synchronization secret and job). False leaves the SAML application in place with no provisioning, which is the state to apply before the AWS console has issued a token."
  type        = bool
  default     = true
}

variable "scim_template_id" {
  description = "Synchronization template ID published by the gallery application, as returned by GET /servicePrincipals/{id}/synchronization/templates. \"aws\" is the ID Microsoft documents for the AWS provisioning connector; confirm it against the instantiated service principal before first apply (README)."
  type        = string
  default     = "aws"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.scim_template_id))
    error_message = "scim_template_id must be a template identifier such as aws, not a display name."
  }
}

variable "scim_base_address" {
  description = "SCIM endpoint of the Identity Center instance (the Tenant URL in the portal), https://scim.<region>.amazonaws.com/<id>/scim/v2. Sensitive: it identifies the instance and, with the token, is the whole credential."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.scim_enabled || can(regex("^https://.+/scim/v2/?$", var.scim_base_address))
    error_message = "scim_base_address must be the Identity Center SCIM endpoint (https://.../scim/v2) when scim_enabled is true. It is supplied through the environment, never as a literal."
  }
}

variable "scim_secret_token" {
  description = "SCIM bearer token issued by the Identity Center console alongside the endpoint. Sensitive. Supplied through the environment; rotated from the AWS console."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.scim_enabled || length(var.scim_secret_token) > 0
    error_message = "scim_secret_token must be set when scim_enabled is true. It is supplied through the environment, never as a literal."
  }
}
