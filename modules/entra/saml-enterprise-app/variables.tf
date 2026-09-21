variable "saml_apps" {
  description = <<-EOT
    SAML enterprise applications to manage, keyed by a stable logical name (for
    example "example-payroll"). The key becomes part of the Terraform resource
    address, so renaming a key moves the resource in state. Change the visible
    name with "display_name".

    display_name                  : shown in the portal and on the My Apps tile.
                                    Unique in the tenant (prevent_duplicate_names
                                    is on) and unique across this map.
    gallery_template_display_name : display name of the gallery entry to
                                    instantiate, for example "Google Cloud / G
                                    Suite Connector by Microsoft". The lookup is
                                    case insensitive. Null (the default) creates
                                    a custom, non-gallery SAML application from
                                    Entra's non-gallery template.
    identifier_uris               : the SAML audience (entity ID), one or more.
                                    A URI (https://payroll.example.com) or the
                                    bare identifier some gallery apps require
                                    (google.com). No wildcard, no whitespace.
    reply_urls                    : assertion consumer service URLs, one or more.
                                    https, a host, no wildcard.
    sign_on_url                   : the service provider's sign-on URL. https, a
                                    host, no wildcard. Sets login_url on the
                                    service principal so the My Apps tile starts
                                    an SP-initiated flow.
    logout_url                    : optional single logout URL. https, a host, no
                                    wildcard.
    relay_state                   : optional SAML RelayState for IdP-initiated
                                    sign-in.
    notification_email_addresses  : addresses Entra notifies before the signing
                                    certificate expires. At least one; a shared
                                    mailbox, not a person.
    signing_certificate           : the SAML signing certificate Entra generates.
      display_name                : friendly name. The provider requires it to
                                    start with CN=; the module adds the prefix
                                    when a cell gives a bare name.
      end_date                    : optional RFC3339 expiry; null lets Entra pick
                                    its default validity (three years). Changing
                                    it replaces the certificate, which is a new
                                    metadata import on the vendor side.
    name_id                       : the assertion subject.
      source                      : user attribute the NameID is read from: mail
                                    (default), userPrincipalName, employeeId, or
                                    onPremisesSamAccountName. This is the list
                                    Microsoft permits as a SAML NameID source.
      format                      : emailAddress (default), persistent, or
                                    unspecified. Entra decides the emitted
                                    format from the service provider's
                                    NameIDPolicy request, else from the source's
                                    default; the module cannot enforce it and
                                    surfaces the chosen format in the
                                    vendor_onboarding output for the vendor to
                                    request.
    claims                        : attributes carried in the assertion, in
                                    order, each { name, source }.
      name                        : attribute name as the service provider
                                    expects it. Unique within the app.
      source                      : mail, userPrincipalName, employeeId,
                                    onPremisesSamAccountName, givenName, surname,
                                    displayName, objectId, or groups. A groups
                                    claim must be named "groups": Entra emits it
                                    under its fixed groups claim URI, with the
                                    display names of the groups assigned to this
                                    application.
    app_roles_to_groups           : map of app role display name to the Entra
                                    security group NAMES assigned through it.
                                    Groups are resolved by lookup; a missing
                                    group fails the plan. For a gallery app the
                                    role must be one the template publishes
                                    (usually "User"); for a custom app the keys
                                    become the application's app roles.
    account_enabled               : whether the service principal accepts
                                    sign-ins. False disables federation without
                                    destroying anything. Default true.
    provisioning                  : optional { template_id, base_address }.
                                    template_id is the synchronization template
                                    the gallery application publishes;
                                    base_address the SCIM endpoint (https). The
                                    bearer token is not here: it arrives in
                                    provisioning_secret_tokens, keyed by this
                                    map's key, so this map never holds a secret.
                                    Leave unset for a connector authorised by an
                                    OAuth consent in the portal (Google
                                    Workspace).

    Fixed and not inputs: app_role_assignment_required true,
    preferred_single_sign_on_mode saml, the enterprise feature tag, a signing
    key Entra generates, and a claims mapping policy rendered by the module.
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

  validation {
    condition     = alltrue([for a in var.saml_apps : length(trimspace(a.display_name)) > 0])
    error_message = "Every application must have a non-empty display_name."
  }

  validation {
    condition     = length(distinct([for a in var.saml_apps : a.display_name])) == length(var.saml_apps)
    error_message = "display_name must be unique across apps. Entra refuses a duplicate at apply (prevent_duplicate_names), and two tiles with one name are indistinguishable to the person clicking one."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : a.gallery_template_display_name == null || length(trimspace(coalesce(a.gallery_template_display_name, "x"))) > 0])
    error_message = "gallery_template_display_name must be null (a custom SAML application) or the non-blank display name of a gallery entry."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : length(a.identifier_uris) > 0 && alltrue([
        for u in a.identifier_uris :
        can(regex("^[A-Za-z][A-Za-z0-9+.-]*:[^*\\s]+$", u)) || can(regex("^[A-Za-z0-9][A-Za-z0-9.-]*(/[^*\\s]*)?$", u))
      ])
    ])
    error_message = "identifier_uris must contain at least one entity ID, each a URI (https://payroll.example.com) or the bare identifier a gallery app requires (google.com), with no wildcard and no whitespace. The provider treats an empty set as remove, so the entity ID is required."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : length(a.reply_urls) > 0 && alltrue([
        for u in a.reply_urls : can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", u))
      ])
    ])
    error_message = "reply_urls must contain at least one https URL with a host and no wildcard, for example https://payroll.example.com/saml/acs. http is refused because the assertion would travel in clear; a wildcard is refused because the ACS URL is where Entra posts a signed assertion about a user, and a pattern there is an open redirect for identities."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", a.sign_on_url))
    ])
    error_message = "sign_on_url must be an https URL with a host and no wildcard. It is where the My Apps tile sends the user to start an SP-initiated sign-in."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : a.logout_url == null || can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", coalesce(a.logout_url, "https://")))
    ])
    error_message = "logout_url must be an https URL with a host and no wildcard when set. The logout response carries a signed statement about the session and travels to this address."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : length(a.notification_email_addresses) > 0 && alltrue([
        for e in a.notification_email_addresses : can(regex("^[^@\\s]+@[^@\\s]+$", e))
      ])
    ])
    error_message = "notification_email_addresses must contain at least one email address. Entra mails it before the signing certificate expires; an application nobody is warned about breaks on the expiry date."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : length(trimspace(a.signing_certificate.display_name)) > 0])
    error_message = "signing_certificate.display_name must not be blank."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : a.signing_certificate.end_date == null || can(formatdate("YYYY", coalesce(a.signing_certificate.end_date, "2000-01-01T00:00:00Z")))
    ])
    error_message = "signing_certificate.end_date must be an RFC3339 timestamp when set, for example 2028-01-01T00:00:00Z."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : contains(["mail", "userPrincipalName", "employeeId", "onPremisesSamAccountName"], a.name_id.source)])
    error_message = "name_id.source must be mail, userPrincipalName, employeeId, or onPremisesSamAccountName: the attributes Microsoft permits as a SAML NameID source."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : contains(["emailAddress", "persistent", "unspecified"], a.name_id.format)])
    error_message = "name_id.format must be emailAddress, persistent, or unspecified. The allowlist is the catalog: a format that is not on it needs a review of its own."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [for c in a.claims : length(trimspace(c.name)) > 0 && !can(regex("\\s", c.name))]
    ]))
    error_message = "Every claim needs a non-blank name without whitespace; the service provider matches attributes by it."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : length(distinct([for c in a.claims : c.name])) == length(a.claims)
    ])
    error_message = "Claim names must be unique within an app. Two claims with one name produce an assertion whose meaning depends on which one the service provider reads last."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [
        for c in a.claims : contains(["mail", "userPrincipalName", "employeeId", "onPremisesSamAccountName", "givenName", "surname", "displayName", "objectId", "groups"], c.source)
      ]
    ]))
    error_message = "Claim source must be one of mail, userPrincipalName, employeeId, onPremisesSamAccountName, givenName, surname, displayName, objectId, or groups. Each is a user property the claims mapping policy can read (groups is the application's group claim); anything else needs a review of its own."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [for c in a.claims : c.source != "groups" || c.name == "groups"]
    ]))
    error_message = "A claim with source groups must be named \"groups\". Entra emits the group claim under its fixed groups claim URI through the application's optional claims, not through the claims mapping policy, so the name cannot be changed here; a different name would be silently ignored."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [for c in a.claims : c.name != "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier"]
    ]))
    error_message = "The nameidentifier claim is the NameID and is configured with name_id, not as a claim."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [for role, groups in a.app_roles_to_groups : length(trimspace(role)) > 0]
    ]))
    error_message = "app_roles_to_groups keys must be non-blank app role display names."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : length(distinct([for role in keys(a.app_roles_to_groups) : lower(role)])) == length(a.app_roles_to_groups)
    ])
    error_message = "An app role display name may appear once per app. Two keys that differ only in case would resolve to the same published role on a gallery app and publish two look-alike roles on a custom one."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [
        for role, groups in a.app_roles_to_groups : length(groups) > 0 && alltrue([for g in groups : length(trimspace(g)) > 0])
      ]
    ]))
    error_message = "Every app role in app_roles_to_groups must list at least one non-blank group name. A role with no groups assigns nobody, and silently assigning nobody hides a mistake in the cell."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.saml_apps : [for role, groups in a.app_roles_to_groups : length(distinct(groups)) == length(groups)]
    ]))
    error_message = "A group name may appear once per app role; the assignment set holds each group once."
  }

  validation {
    condition     = alltrue([for a in var.saml_apps : length(a.app_roles_to_groups) > 0])
    error_message = "app_roles_to_groups must name at least one app role with at least one group. Assignment is required on every application this module manages, so an application with no assigned group signs in nobody."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : a.provisioning == null || (
        a.provisioning.template_id != null && can(regex("^[A-Za-z0-9._-]+$", coalesce(a.provisioning.template_id, "")))
      )
    ])
    error_message = "provisioning needs template_id, the synchronization template identifier the gallery application publishes (for example aws), not a display name. A base_address without a template is a credential with no job to use it."
  }

  validation {
    condition = alltrue([
      for a in var.saml_apps : a.provisioning == null || a.provisioning.base_address == null || can(regex("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^*\\s]*)?$", coalesce(a.provisioning.base_address, "https://")))
    ])
    error_message = "provisioning.base_address must be an https URL with a host and no wildcard when set."
  }
}

variable "provisioning_secret_tokens" {
  description = <<-EOT
    Map of saml_apps key to the bearer token of that app's token-based SCIM
    connector. Sensitive, and kept out of saml_apps on purpose: a map that
    holds the token could not drive the module's for_each, and a literal in
    the map would print in every plan. Supplied through the environment
    (TF_VAR_provisioning_secret_tokens) or a sensitive stack variable, never as
    a literal. Every key must name an app of saml_apps that sets provisioning;
    a token for an app with no job to use it is refused rather than written to
    state for nothing. An app whose connector takes a token and has no entry
    here plans a job without a secret, which the vendor's Test connection then
    reports; the module cannot know which templates need a token and which are
    authorised in the portal.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition     = alltrue([for key in keys(var.provisioning_secret_tokens) : try(var.saml_apps[key].provisioning != null, false)])
    error_message = "Every key of provisioning_secret_tokens must be the key of an app in saml_apps that sets provisioning. A token for an app that has no provisioning job, or for a key that is not in the map, would be written to nowhere; remove it or add provisioning.template_id to the app."
  }
}

variable "custom_template_id" {
  description = "Template ID of Entra's non-gallery application template, from which a custom SAML application (gallery_template_display_name null) is instantiated. The default is the ID Microsoft publishes for the global cloud on the applicationTemplate: instantiate page; a US Government or China tenant sets the ID that page lists for it. A published constant, the same in every tenant, never copied from a portal."
  type        = string
  default     = "8adf8e6e-67b2-4cf2-a259-e3dc5476c621"

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.custom_template_id))
    error_message = "custom_template_id must be a lower-case GUID."
  }
}
