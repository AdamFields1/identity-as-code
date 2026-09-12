variable "applications" {
  description = <<-EOT
    Application registrations to manage, keyed by a stable logical name (for example
    "payroll-api"). The key becomes part of the Terraform resource address, so renaming
    a key moves the resource in state. Change the display name with "display_name".

    display_name             : shown in the portal. Must be unique in the tenant when
                               prevent_duplicate_names is true (it is).
    sign_in_audience         : AzureADMyOrg (default), AzureADMultipleOrgs,
                               AzureADandPersonalMicrosoftAccount, PersonalMicrosoftAccount.
    owners                   : user principal names. Resolved to object IDs by the module.
                               Set at creation only; owners are then free to change them.
    identifier_uris          : optional application ID URIs (api://...).
    web_redirect_uris        : optional web platform redirect URIs. Set at creation only.
    web_homepage_url         : optional. Set at creation only.
    web_logout_url           : optional. Set at creation only.
    tags                     : optional string tags. Set at creation only.
    required_resource_access : API permissions keyed by the published API name as listed
                               by the azuread_application_published_app_ids data source
                               ("MicrosoftGraph", "AzureServiceManagement", ...). Each
                               entry lists permission NAMES, never IDs:
                                 application : app roles (type Role), for example
                                               ["User.Read.All"]
                                 delegated   : OAuth2 scopes (type Scope), for example
                                               ["User.Read", "offline_access"]
    federated_credentials    : GitHub OIDC (or any OIDC issuer) credentials keyed by a
                               logical name. subject is the token subject claim, for
                               GitHub "repo:<org>/<repo>:environment:<env>" or
                               "repo:<org>/<repo>:ref:refs/heads/main".
    enforced_graph_app_roles : Microsoft Graph application permissions that the module
                               grants (admin consents) to the service principal with
                               azuread_app_role_assignment. Every name here must also be
                               declared under required_resource_access.MicrosoftGraph.application.
    service_principal        : settings for the always-created enterprise application.
  EOT

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

  validation {
    condition     = alltrue([for a in var.applications : length(trimspace(a.display_name)) > 0])
    error_message = "Every application must have a non-empty display_name."
  }

  validation {
    condition = alltrue([
      for a in var.applications : contains([
        "AzureADMyOrg", "AzureADMultipleOrgs", "AzureADandPersonalMicrosoftAccount", "PersonalMicrosoftAccount",
      ], a.sign_in_audience)
    ])
    error_message = "sign_in_audience must be AzureADMyOrg, AzureADMultipleOrgs, AzureADandPersonalMicrosoftAccount, or PersonalMicrosoftAccount."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.applications : [for upn in a.owners : can(regex("^[^@\\s]+@[^@\\s]+$", upn))]
    ]))
    error_message = "Owners must be user principal names (user@domain)."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.applications : [for u in a.web_redirect_uris : can(regex("^(https://|http://localhost)", u))]
    ]))
    error_message = "Web redirect URIs must use https, except http://localhost for local development."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.applications : [
        for api, p in a.required_resource_access : (length(p.application) + length(p.delegated)) > 0
      ]
    ]))
    error_message = "Every required_resource_access entry must list at least one application or delegated permission."
  }

  validation {
    condition = alltrue([
      for a in var.applications :
      length(a.enforced_graph_app_roles) == 0 || (
        contains(keys(a.required_resource_access), "MicrosoftGraph") &&
        alltrue([
          for r in a.enforced_graph_app_roles :
          contains(try(a.required_resource_access["MicrosoftGraph"].application, []), r)
        ])
      )
    ])
    error_message = "Every enforced_graph_app_roles entry must also be declared under required_resource_access.MicrosoftGraph.application, so the manifest and the granted consent never disagree."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.applications : [for c in a.federated_credentials : can(regex("^https://", c.issuer))]
    ]))
    error_message = "Federated credential issuer must be an https URL."
  }

  validation {
    condition = alltrue(flatten([
      for a in var.applications : [for c in a.federated_credentials : length(trimspace(c.subject)) > 0]
    ]))
    error_message = "Federated credential subject must not be empty."
  }
}
