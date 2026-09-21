# SAML enterprise applications in Entra ID, keyed by the caller's logical name:
# for each service provider the application (instantiated from a gallery
# template or from Entra's non-gallery template), its service principal in SAML
# mode, a signing certificate, a claims mapping policy built from typed values,
# the app role assignments that put groups in scope, and optional provisioning.
#
# This is the Entra half of the application catalog (docs/adr/0021, on the
# shape docs/adr/0020 set): the same vendor is onboarded from either identity
# provider with the same values. The Okta half is modules/okta/app-saml. What a cell says is where the service
# provider lives (identifier, reply, sign-on and logout URLs), how the subject
# is named, which attributes the assertion carries, and which groups may open
# the app through which app role. What a cell cannot say is fixed here:
# assignment is required, the sign-on mode is SAML, the signing key is one
# Entra generates, and the claims policy is rendered by the module so no cell
# ever writes JSON.
#
# The pattern is modules/entra/aws-identity-center-app generalised to a map.
# That module instantiates one gallery template, adopts the service principal
# the instantiation creates, resolves the template's app role by display name,
# and configures SCIM from variables; every one of those choices is kept here
# and explained where it is made.
#
# Terraform is the inventory and the guardrail, not the sole editor
# (docs/adr/0006): identity, SAML endpoints, the signing certificate, the
# claims policy, and the assignments are enforced on every apply; branding,
# owners, optional claims, and the group membership claim setting are set at
# creation and then left to the application owner.

# ---------------------------------------------------------------------------
# Templates. A gallery app names its template and the template is resolved by
# display name, exactly as the Identity Center module does. A custom app (a
# null gallery_template_display_name) is instantiated from the non-gallery
# template Microsoft publishes for SAML, password and linked sign-on. Its
# display name is not stated on any public documentation page, so the module
# resolves it by its published template ID (a constant that is the same in
# every tenant of the global cloud, see var.custom_template_id) rather than by
# a guessed name; the data source still confirms the template exists at plan.
#
# Source for the ID: Microsoft Graph, applicationTemplate: instantiate,
# https://learn.microsoft.com/en-us/graph/api/applicationtemplate-instantiate
# ("For non-gallery apps, use an application template with one of the
# following IDs", then the global service, US Government and China IDs). The
# global one is the default of var.custom_template_id.
# ---------------------------------------------------------------------------

data "azuread_client_config" "current" {}

locals {
  gallery_apps = { for k, a in var.saml_apps : k => a if a.gallery_template_display_name != null }
  custom_apps  = { for k, a in var.saml_apps : k => a if a.gallery_template_display_name == null }

  # One lookup per distinct template name, shared by every app that names it.
  gallery_template_names = toset([for a in local.gallery_apps : a.gallery_template_display_name])
}

data "azuread_application_template" "gallery" {
  for_each = local.gallery_template_names

  display_name = each.value
}

data "azuread_application_template" "custom" {
  for_each = length(local.custom_apps) > 0 ? { this = true } : {}

  template_id = var.custom_template_id
}

# ---------------------------------------------------------------------------
# Claims. The module renders one claims mapping policy per app from the typed
# name_id and claims values, so the JSON that reaches Entra is built here with
# jsonencode and a cell never writes a policy document (docs/adr/0002).
#
# Definition format: Microsoft Learn, "Claims mapping policy type",
# https://learn.microsoft.com/en-us/entra/identity-platform/reference-claims-mapping-policy-type
# A ClaimsSchema entry is a Source/ID pair (Source "user", ID one of the user
# properties the page lists: mail, userprincipalname, employeeid,
# onpremisessamaccountname, givenname, surname, displayname, objectid) and a
# SamlClaimType, the attribute name the assertion carries. The NameID is the
# entry whose SamlClaimType is the nameidentifier claim URI, which is how the
# Graph SAML tutorial sets it
# (https://learn.microsoft.com/en-us/graph/application-saml-sso-configure-api).
# The same page restricts NameID sources to a short list; the allowlist in
# variables.tf is that list.
#
# The signing certificate created below is the service principal's own key,
# which is the custom signing key the reference page says lifts the restriction
# on mapped claims. The page also says to avoid acceptMappedClaims in the
# manifest, so the api block is not set.
#
# A claim whose source is "groups" is not a ClaimsSchema entry: the reference
# page's Source values are user, application, resource, audience, company and
# transformation. Groups reach a SAML assertion through the application's
# groupMembershipClaims setting and the "groups" optional claim
# (https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims).
# The module sets ApplicationGroup, which emits only the groups assigned to
# this application, with cloud_displayname so the values are group names as
# the Okta side sends them. Both are set at creation and then covered by
# ignore_changes, as the Identity Center module does, so the attribute name
# is Entra's fixed groups claim URI and the cell's claim must be named
# "groups" (a validation says so).
# ---------------------------------------------------------------------------

locals {
  claim_source_ids = {
    mail                     = "mail"
    userPrincipalName        = "userprincipalname"
    employeeId               = "employeeid"
    onPremisesSamAccountName = "onpremisessamaccountname"
    givenName                = "givenname"
    surname                  = "surname"
    displayName              = "displayname"
    objectId                 = "objectid"
  }

  name_id_claim_type = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier"

  name_id_formats = {
    emailAddress = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
    persistent   = "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent"
    unspecified  = "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"
  }

  wants_groups_claim = { for k, a in var.saml_apps : k => anytrue([for c in a.claims : c.source == "groups"]) }

  claims_schema = {
    for k, a in var.saml_apps : k => concat(
      [{
        Source        = "user"
        ID            = local.claim_source_ids[a.name_id.source]
        SamlClaimType = local.name_id_claim_type
      }],
      [
        for c in a.claims : {
          Source        = "user"
          ID            = local.claim_source_ids[c.source]
          SamlClaimType = c.name
        } if c.source != "groups"
      ],
    )
  }
}

# ---------------------------------------------------------------------------
# Applications. Two resources, one per kind, because ignore_changes must be a
# static list and the two kinds disagree about app roles.
#
# A gallery application publishes the roles its template carries and the
# module must not touch them: the provider only writes app roles when the
# app_role block is declared, but it reads them back on every refresh, so a
# gallery application that declared none would plan to remove the template's
# roles on the second run. app_role is ignored on the gallery resource.
#
# A custom application publishes whatever the module declares: the keys of
# app_roles_to_groups become its app roles, each with an ID derived from the
# app key and the role name with uuidv5 (deterministic, so re-applying never
# mints a new role, and never typed). Nothing else publishes roles on a custom
# app, so the module owns the set and enforces it.
#
# Everything else is the same for both kinds. identifier_uris (the entity ID)
# and the web block (reply and logout URLs) are enforced on every apply
# because they are where the assertion goes. Owners, tags, branding, optional
# claims and the group membership claim setting are set at creation and then
# left to the owner, the same contract as the Identity Center module
# (docs/adr/0006).
# ---------------------------------------------------------------------------

resource "azuread_application" "gallery" {
  for_each = local.gallery_apps

  display_name            = each.value.display_name
  template_id             = data.azuread_application_template.gallery[each.value.gallery_template_display_name].template_id
  identifier_uris         = each.value.identifier_uris
  group_membership_claims = local.wants_groups_claim[each.key] ? ["ApplicationGroup"] : null
  prevent_duplicate_names = true

  web {
    redirect_uris = each.value.reply_urls
    logout_url    = each.value.logout_url
  }

  dynamic "optional_claims" {
    for_each = local.wants_groups_claim[each.key] ? [1] : []
    content {
      saml2_token {
        name                  = "groups"
        additional_properties = ["cloud_displayname"]
      }
    }
  }

  lifecycle {
    # Same contract as modules/entra/aws-identity-center-app (ADR 0006):
    # identity and SAML endpoints are enforced; branding, owners, claims tuning
    # and the template's app roles are set by the template or an owner and
    # left alone.
    ignore_changes = [
      owners,
      tags,
      app_role,
      optional_claims,
      group_membership_claims,
      logo_image,
      marketing_url,
      privacy_statement_url,
      support_url,
      terms_of_service_url,
      notes,
    ]
  }
}

resource "azuread_application" "custom" {
  for_each = local.custom_apps

  display_name            = each.value.display_name
  template_id             = data.azuread_application_template.custom["this"].template_id
  identifier_uris         = each.value.identifier_uris
  group_membership_claims = local.wants_groups_claim[each.key] ? ["ApplicationGroup"] : null
  prevent_duplicate_names = true

  web {
    redirect_uris = each.value.reply_urls
    logout_url    = each.value.logout_url
  }

  dynamic "app_role" {
    for_each = toset(keys(each.value.app_roles_to_groups))
    content {
      id                   = local.custom_role_ids[each.key][app_role.value]
      display_name         = app_role.value
      description          = "${app_role.value} access to ${each.value.display_name}. Managed by Terraform."
      allowed_member_types = ["User"]
      enabled              = true
    }
  }

  dynamic "optional_claims" {
    for_each = local.wants_groups_claim[each.key] ? [1] : []
    content {
      saml2_token {
        name                  = "groups"
        additional_properties = ["cloud_displayname"]
      }
    }
  }

  lifecycle {
    # As above, minus app_role: a custom application's roles are the module's
    # and are enforced on every apply.
    ignore_changes = [
      owners,
      tags,
      optional_claims,
      group_membership_claims,
      logo_image,
      marketing_url,
      privacy_statement_url,
      support_url,
      terms_of_service_url,
      notes,
    ]
  }
}

locals {
  application_client_ids = merge(
    { for k, a in azuread_application.gallery : k => a.client_id },
    { for k, a in azuread_application.custom : k => a.client_id },
  )

  application_object_ids = merge(
    { for k, a in azuread_application.gallery : k => a.object_id },
    { for k, a in azuread_application.custom : k => a.object_id },
  )
}

# ---------------------------------------------------------------------------
# Service principals. The template instantiation already created one;
# use_existing adopts it instead of failing. SAML is the only sign-on mode
# this module offers, and app_role_assignment_required is the control that
# makes "assigned to the application" mean "can sign in".
# ---------------------------------------------------------------------------

resource "azuread_service_principal" "this" {
  for_each = var.saml_apps

  client_id    = local.application_client_ids[each.key]
  use_existing = true

  account_enabled               = each.value.account_enabled
  app_role_assignment_required  = true
  preferred_single_sign_on_mode = "saml"
  login_url                     = each.value.sign_on_url
  notification_email_addresses  = each.value.notification_email_addresses
  notes                         = "Managed by Terraform. SAML enterprise application from the application catalog (modules/entra/saml-enterprise-app)."

  feature_tags {
    enterprise            = true
    gallery               = contains(keys(local.gallery_apps), each.key)
    custom_single_sign_on = contains(keys(local.custom_apps), each.key)
  }

  dynamic "saml_single_sign_on" {
    for_each = each.value.relay_state != null ? [each.value.relay_state] : []
    content {
      relay_state = saml_single_sign_on.value
    }
  }

  lifecycle {
    ignore_changes = [
      owners,
      notes,
    ]
  }
}

# ---------------------------------------------------------------------------
# SAML signing certificates. Entra generates the key pair; only the public
# certificate leaves the tenant, inside the federation metadata the vendor
# consumes. Rotation is a new certificate here and a new metadata import
# there. The provider requires the display name to start with CN=, so a bare
# name from the cell is prefixed here.
# ---------------------------------------------------------------------------

resource "azuread_service_principal_token_signing_certificate" "this" {
  for_each = var.saml_apps

  service_principal_id = azuread_service_principal.this[each.key].id
  display_name         = startswith(each.value.signing_certificate.display_name, "CN=") ? each.value.signing_certificate.display_name : "CN=${each.value.signing_certificate.display_name}"
  end_date             = each.value.signing_certificate.end_date
}

# ---------------------------------------------------------------------------
# Claims mapping policies, one per app, bound to the service principal.
# ---------------------------------------------------------------------------

resource "azuread_claims_mapping_policy" "this" {
  for_each = var.saml_apps

  display_name = "${each.value.display_name} SAML claims"

  definition = [
    jsonencode({
      ClaimsMappingPolicy = {
        Version              = 1
        IncludeBasicClaimSet = "true"
        ClaimsSchema         = local.claims_schema[each.key]
      }
    }),
  ]
}

resource "azuread_service_principal_claims_mapping_policy_assignment" "this" {
  for_each = var.saml_apps

  claims_mapping_policy_id = azuread_claims_mapping_policy.this[each.key].id
  service_principal_id     = azuread_service_principal.this[each.key].id
}

# ---------------------------------------------------------------------------
# Group assignments, one azuread_app_role_assignment per app, role and group.
#
# Roles are resolved, never typed. For a custom app the role IDs are the ones
# the module declared above, known at plan. For a gallery app the module reads
# app_roles from the instantiated service principal, as the Identity Center
# module does, and picks the one enabled user-assignable role whose display
# name matches; a precondition fails the plan naming the missing role and
# listing what the template publishes. The limit: the service principal's
# app_roles are computed, so on the first plan of a new gallery app they are
# unknown and Terraform defers the check to apply. The application, service
# principal and certificate apply first; the assignment fails with the message
# and the corrected name completes on the next run. On every later plan the
# roles are known and the check runs at plan.
#
# Groups are referenced by NAME and resolved here, once per distinct name
# across every app. They are created in stacks/entra-app-registrations or
# provisioned elsewhere, so a name that does not exist fails the plan with the
# name in the error. That is the honest failure: an empty assignment would look
# like a working app that nobody can open.
# ---------------------------------------------------------------------------

locals {
  group_names = toset(flatten([for a in var.saml_apps : flatten(values(a.app_roles_to_groups))]))

  # Flattened "app/role/group" map for the assignment resource.
  role_assignments = merge(flatten([
    for app_key, a in var.saml_apps : [
      for role, groups in a.app_roles_to_groups : {
        for g in groups :
        "${app_key}/${role}/${g}" => { app_key = app_key, role = role, group = g }
      }
    ]
  ])...)

  custom_role_ids = {
    for k, a in local.custom_apps : k => {
      for role in keys(a.app_roles_to_groups) :
      role => uuidv5("url", "urn:identity-as-code:entra-saml-app:${k}:app-role:${role}")
    }
  }

  gallery_user_roles = {
    for k in keys(local.gallery_apps) : k => [
      for r in azuread_service_principal.this[k].app_roles : r
      if r.enabled && contains(r.allowed_member_types, "User")
    ]
  }

  gallery_role_matches = {
    for k, a in local.gallery_apps : k => {
      for role in keys(a.app_roles_to_groups) :
      role => [for r in local.gallery_user_roles[k] : r.id if r.display_name == role]
    }
  }

  app_role_ids = merge(
    local.custom_role_ids,
    {
      for k, matches in local.gallery_role_matches : k => {
        for role, ids in matches : role => length(ids) == 1 ? ids[0] : null
      }
    },
  )
}

data "azuread_group" "assigned" {
  for_each = local.group_names

  display_name     = each.value
  security_enabled = true
}

resource "azuread_app_role_assignment" "groups" {
  for_each = local.role_assignments

  app_role_id         = local.app_role_ids[each.value.app_key][each.value.role]
  principal_object_id = data.azuread_group.assigned[each.value.group].object_id
  resource_object_id  = azuread_service_principal.this[each.value.app_key].object_id

  lifecycle {
    precondition {
      condition     = local.app_role_ids[each.value.app_key][each.value.role] != null
      error_message = "The application \"${var.saml_apps[each.value.app_key].display_name}\" does not publish exactly one enabled user-assignable app role named \"${each.value.role}\". Published: ${join(", ", [for r in try(local.gallery_user_roles[each.value.app_key], []) : r.display_name])}. Use a role display name the gallery template carries."
    }
  }
}

# ---------------------------------------------------------------------------
# Provisioning. Optional per app, as the Identity Center module does it: the
# secret is written first, then the job is created and enabled against the
# template the gallery application publishes. A connector that is authorised
# by an OAuth consent in the portal (Google Workspace is one) has nothing
# Terraform can write, so its cell leaves provisioning unset and the README
# shows the one console step.
#
# The bearer token is not part of the saml_apps map. It arrives in its own
# sensitive variable, provisioning_secret_tokens, keyed by app, so a literal
# in the map is impossible and the map stays printable. Terraform refuses a
# for_each over a value derived from a sensitive one, and a map that holds the
# token is such a value, which is why the token is kept out of the map and
# why the only unmark below is on the variable's keys: the keys are app names
# and say nothing about the token, so which apps carry a token is derived
# from them, and the token itself is read only where it is written.
# ---------------------------------------------------------------------------

locals {
  provisioned = { for k, a in var.saml_apps : k => a.provisioning if a.provisioning != null }

  # App keys that have a token. The keys of the sensitive map are the app
  # names, not the secrets; this is the one honest nonsensitive() here.
  token_keys = nonsensitive(toset(keys(var.provisioning_secret_tokens)))

  provisioned_with_credentials = {
    for k, p in local.provisioned : k => p if p.base_address != null || contains(local.token_keys, k)
  }
}

resource "azuread_synchronization_secret" "this" {
  for_each = local.provisioned_with_credentials

  service_principal_id = azuread_service_principal.this[each.key].id

  dynamic "credential" {
    for_each = each.value.base_address != null ? ["BaseAddress"] : []
    content {
      key   = credential.value
      value = each.value.base_address
    }
  }

  dynamic "credential" {
    for_each = contains(local.token_keys, each.key) ? ["SecretToken"] : []
    content {
      key   = credential.value
      value = var.provisioning_secret_tokens[each.key]
    }
  }
}

resource "azuread_synchronization_job" "this" {
  for_each = local.provisioned

  service_principal_id = azuread_service_principal.this[each.key].id
  template_id          = each.value.template_id
  enabled              = true

  depends_on = [azuread_synchronization_secret.this]
}
