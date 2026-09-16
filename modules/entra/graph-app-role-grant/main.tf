# Microsoft Graph application permissions (app roles) granted to one service
# principal, expressed by permission name.
#
# The app-registration module already does this for applications it creates,
# but it cannot be reused for a managed identity: a managed identity has a
# service principal and no application registration, so there is no manifest
# to declare required_resource_access on and nothing for that module's
# validation to compare the grant against. This module is the grant alone.
#
# The principal is given either by object ID (the automation-account module
# outputs it) or by display name (a managed identity's service principal
# carries the identity's name). Exactly one is required. Role names are
# resolved against the Microsoft Graph service principal's app_role_ids, so
# a misspelled name fails the plan and no GUID appears in any cell.
#
# Removing a name from app_role_names revokes the grant on the next apply.
# That is the point: what the automation identity may do is reviewed like
# any other change.

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "graph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

data "azuread_service_principal" "principal" {
  for_each = toset(var.principal_display_name == null ? [] : [var.principal_display_name])

  display_name = each.value
}

locals {
  principal_object_id = coalesce(
    var.principal_object_id,
    one([for sp in data.azuread_service_principal.principal : sp.object_id]),
  )
}

resource "azuread_app_role_assignment" "this" {
  for_each = toset(var.app_role_names)

  app_role_id         = data.azuread_service_principal.graph.app_role_ids[each.value]
  principal_object_id = local.principal_object_id
  resource_object_id  = data.azuread_service_principal.graph.object_id

  lifecycle {
    precondition {
      condition     = contains(keys(data.azuread_service_principal.graph.app_role_ids), each.value)
      error_message = "\"${each.value}\" is not a Microsoft Graph application permission. Names are case sensitive, for example Application.Read.All."
    }
  }
}
