# Application registrations, their service principals, and their federated
# credentials, keyed by the caller's logical name.
#
# Terraform is the inventory and the guardrail here, not the sole editor. The
# things a security reviewer cares about (which apps exist, who they can sign in,
# which API permissions they request, which Graph roles have been consented, and
# that no client secret exists) are managed and enforced. The things application
# owners change week to week (redirect URIs, optional claims, branding, tags,
# owners) are set at creation and then handed over: ignore_changes stops Terraform
# from reverting a legitimate portal edit on the next apply. See
# docs/adr/0006-terraform-as-inventory-and-guardrail.md.
#
# azuread_application_password is deliberately absent from this module. Workload
# identity is federated (GitHub OIDC or another issuer) so that no long-lived
# secret is ever created, stored in state, or rotated by hand. A secret added in
# the portal is outside Terraform's view; scripts/Export-EntraDrift.ps1 reports it.

# ---------------------------------------------------------------------------
# Name resolution. Owners by user principal name, APIs by published name, and
# permission names by the target API's service principal. Every ID that reaches
# a resource below was resolved here from a name in the caller's values.
# ---------------------------------------------------------------------------

locals {
  owner_upns = toset(flatten([for a in var.applications : a.owners]))

  # Microsoft Graph is always resolved because enforced app-role grants target it.
  api_names = toset(concat(
    ["MicrosoftGraph"],
    flatten([for a in var.applications : keys(a.required_resource_access)]),
  ))
}

data "azuread_user" "owners" {
  for_each = local.owner_upns

  user_principal_name = each.value
}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "apis" {
  for_each = local.api_names

  client_id = data.azuread_application_published_app_ids.well_known.result[each.value]

  lifecycle {
    precondition {
      condition     = contains(keys(data.azuread_application_published_app_ids.well_known.result), each.value)
      error_message = "required_resource_access keys must be published API names known to the azuread provider, for example MicrosoftGraph or AzureServiceManagement."
    }
  }
}

locals {
  owner_ids = { for upn, u in data.azuread_user.owners : upn => u.object_id }

  # app key => list of owner object IDs, null when none so the provider leaves the
  # attribute alone rather than enforcing an empty set.
  app_owner_ids = {
    for k, a in var.applications :
    k => length(a.owners) > 0 ? [for upn in a.owners : local.owner_ids[upn]] : null
  }

  # Flattened "app/credential" map for the federated credential resource.
  federated_credentials = merge([
    for app_key, a in var.applications : {
      for cred_key, c in a.federated_credentials :
      "${app_key}/${cred_key}" => merge(c, { app_key = app_key })
    }
  ]...)

  # Flattened "app/role" map for enforced Graph app-role grants.
  enforced_graph_roles = merge([
    for app_key, a in var.applications : {
      for role in a.enforced_graph_app_roles :
      "${app_key}/${role}" => { app_key = app_key, role = role }
    }
  ]...)
}

# ---------------------------------------------------------------------------
# Application registration.
# ---------------------------------------------------------------------------

resource "azuread_application" "this" {
  for_each = var.applications

  display_name            = each.value.display_name
  description             = each.value.description
  sign_in_audience        = each.value.sign_in_audience
  owners                  = local.app_owner_ids[each.key]
  identifier_uris         = length(each.value.identifier_uris) > 0 ? each.value.identifier_uris : null
  tags                    = length(each.value.tags) > 0 ? each.value.tags : null
  prevent_duplicate_names = true

  dynamic "web" {
    for_each = (length(each.value.web_redirect_uris) > 0 || each.value.web_homepage_url != null || each.value.web_logout_url != null) ? [1] : []
    content {
      redirect_uris = length(each.value.web_redirect_uris) > 0 ? each.value.web_redirect_uris : null
      homepage_url  = each.value.web_homepage_url
      logout_url    = each.value.web_logout_url
    }
  }

  # API permissions, expressed by name in the caller's values and resolved to the
  # target API's role and scope IDs here. Two dynamic blocks with the same name
  # are concatenated by Terraform.
  dynamic "required_resource_access" {
    for_each = each.value.required_resource_access
    content {
      resource_app_id = data.azuread_application_published_app_ids.well_known.result[required_resource_access.key]

      dynamic "resource_access" {
        for_each = required_resource_access.value.application
        content {
          id   = data.azuread_service_principal.apis[required_resource_access.key].app_role_ids[resource_access.value]
          type = "Role"
        }
      }

      dynamic "resource_access" {
        for_each = required_resource_access.value.delegated
        content {
          id   = data.azuread_service_principal.apis[required_resource_access.key].oauth2_permission_scope_ids[resource_access.value]
          type = "Scope"
        }
      }
    }
  }

  lifecycle {
    # Terraform is the inventory and guardrail; owners keep post-provisioning
    # control of everything listed here. Terraform sets these at creation and
    # never reverts a later portal edit. Not listed, and therefore enforced on
    # every apply: display_name, sign_in_audience, identifier_uris, and
    # required_resource_access.
    #
    # Terraform requires this list to be static, so it is a module constant
    # rather than a variable. Narrowing it is a module change and a code review.
    ignore_changes = [
      owners,
      tags,
      web,
      public_client,
      single_page_application,
      optional_claims,
      logo_image,
      marketing_url,
      privacy_statement_url,
      support_url,
      terms_of_service_url,
      notes,
    ]

    precondition {
      condition = alltrue(flatten([
        for api, p in each.value.required_resource_access : concat(
          [for r in p.application : contains(keys(data.azuread_service_principal.apis[api].app_role_ids), r)],
          [for s in p.delegated : contains(keys(data.azuread_service_principal.apis[api].oauth2_permission_scope_ids), s)],
        )
      ]))
      error_message = "One or more permission names under required_resource_access do not exist on the target API. Names are case sensitive (User.Read.All, not user.read.all)."
    }
  }
}

# ---------------------------------------------------------------------------
# Service principal (enterprise application). Always created so the registration
# can be assigned, consented, and signed into from day one.
# ---------------------------------------------------------------------------

resource "azuread_service_principal" "this" {
  for_each = var.applications

  client_id                    = azuread_application.this[each.key].client_id
  account_enabled              = each.value.service_principal.account_enabled
  app_role_assignment_required = each.value.service_principal.app_role_assignment_required
  notes                        = each.value.service_principal.notes
  owners                       = local.app_owner_ids[each.key]

  lifecycle {
    # Same contract as the registration: owners manage SSO settings, branding,
    # and notification recipients after creation. account_enabled and
    # app_role_assignment_required stay enforced because they are the controls.
    ignore_changes = [
      owners,
      tags,
      notification_email_addresses,
      login_url,
      preferred_single_sign_on_mode,
      saml_single_sign_on,
      feature_tags,
    ]
  }
}

# ---------------------------------------------------------------------------
# Federated identity credentials. The replacement for client secrets.
# ---------------------------------------------------------------------------

resource "azuread_application_federated_identity_credential" "this" {
  for_each = local.federated_credentials

  application_id = azuread_application.this[each.value.app_key].id
  display_name   = each.value.display_name
  description    = each.value.description
  issuer         = each.value.issuer
  subject        = each.value.subject
  audiences      = each.value.audiences
}

# ---------------------------------------------------------------------------
# Enforced Microsoft Graph app-role grants (admin consent as code). Removing a
# role from the caller's list revokes the grant on the next apply.
# ---------------------------------------------------------------------------

resource "azuread_app_role_assignment" "graph" {
  for_each = local.enforced_graph_roles

  app_role_id         = data.azuread_service_principal.apis["MicrosoftGraph"].app_role_ids[each.value.role]
  principal_object_id = azuread_service_principal.this[each.value.app_key].object_id
  resource_object_id  = data.azuread_service_principal.apis["MicrosoftGraph"].object_id
}
