# One AWS IAM Identity Center enterprise application in Entra ID: the gallery
# application and its service principal, SAML settings, a signing certificate,
# the group assignments that put people in scope, and SCIM provisioning to the
# instance.
#
# Entra ID is the identity source for Identity Center. Users and groups exist
# in Entra, SCIM copies the assigned ones into the identity store, and the AWS
# side (stacks/aws-identity-center) grants permission sets to those groups.
# The groups are named AWS-<PARTITION>-<accountId>-<PermissionSetName>, and
# the name is the assignment: being assigned to this application provisions
# the group into the instance for its partition, and the AWS cell for that
# instance parses the name into an account assignment. One artifact, both
# sides. See docs/adr/0008.
#
# Two things are deliberately manual and are documented in the README rather
# than faked here: switching the instance's identity source to an external
# provider (a console wizard that consumes this application's federation
# metadata and refuses to run twice), and enabling automatic provisioning
# (which mints the SCIM endpoint and token exactly once). The module consumes
# the outputs of both as variables.
#
# The application is instantiated from the gallery template rather than
# created as a custom SAML app so that it carries the provisioning connector
# for Identity Center; a custom app has no synchronization templates and SCIM
# could not be configured from code.

# ---------------------------------------------------------------------------
# Gallery template and application.
# ---------------------------------------------------------------------------

data "azuread_application_template" "identity_center" {
  display_name = var.gallery_template_display_name
}

resource "azuread_application" "this" {
  display_name            = var.display_name
  template_id             = data.azuread_application_template.identity_center.template_id
  identifier_uris         = var.identifier_uris
  prevent_duplicate_names = true

  web {
    redirect_uris = var.reply_urls
  }

  lifecycle {
    # Same contract as modules/entra/app-registration (ADR 0006): identity and
    # SAML endpoints are enforced; branding, owners, and claims tuning are set
    # by the template or an owner and left alone. Attribute and claim mapping
    # for SAML lives on the service principal and is edited in the portal when
    # ABAC session tags are wanted; it is not modelled here.
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

# ---------------------------------------------------------------------------
# Service principal. The template instantiation already created one;
# use_existing adopts it instead of failing. SAML is the only sign-on mode
# Identity Center supports, and app_role_assignment_required is the control
# that makes "assigned to the application" mean "can sign in and is
# provisioned".
# ---------------------------------------------------------------------------

resource "azuread_service_principal" "this" {
  client_id    = azuread_application.this.client_id
  use_existing = true

  account_enabled               = var.account_enabled
  app_role_assignment_required  = true
  preferred_single_sign_on_mode = "saml"
  login_url                     = var.sign_on_url
  notification_email_addresses  = var.notification_email_addresses
  notes                         = "Managed by Terraform. Identity source for the AWS IAM Identity Center instance named in the display name."

  feature_tags {
    enterprise = true
    gallery    = true
  }

  dynamic "saml_single_sign_on" {
    for_each = var.relay_state != null ? [var.relay_state] : []
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
# SAML signing certificate. Entra generates the key pair; only the public
# certificate leaves the tenant, inside the federation metadata the AWS console
# consumes. Rotation is a new certificate here and a new metadata upload there.
# ---------------------------------------------------------------------------

resource "azuread_service_principal_token_signing_certificate" "this" {
  service_principal_id = azuread_service_principal.this.id
  display_name         = var.signing_certificate.display_name
  end_date             = var.signing_certificate.end_date
}

# ---------------------------------------------------------------------------
# Group assignments, with the application's default app role.
#
# The role is resolved, never typed. azuread_app_role_assignment takes either
# the ID of a role the resource application publishes, or the well-known
# default role ID 00000000-0000-0000-0000-000000000000, which the provider
# documents as valid for an application that publishes no app roles (the
# portal shows it as "Default Access"). Gallery applications generally publish
# a single enabled role for users and groups, named "User", and the AWS
# Identity Center template is expected to; that role is the default one the
# portal picks when a group is assigned. So:
#
#   1. if the instantiated service principal publishes exactly one enabled,
#      user-assignable role with the expected display name, use its ID;
#   2. if it publishes no enabled user-assignable role at all, use the
#      well-known default role ID;
#   3. otherwise fail the plan and list what it does publish, so the caller
#      sets app_role_display_name deliberately instead of the module guessing.
#
# app_roles on the service principal are read after instantiation, so the
# choice is made against what the tenant actually has, not a GUID copied from
# a screenshot.
# ---------------------------------------------------------------------------

data "azuread_group" "assigned" {
  for_each = toset(var.assigned_groups)

  display_name     = each.value
  security_enabled = true
}

locals {
  default_access_role_id = "00000000-0000-0000-0000-000000000000"

  user_assignable_roles = [
    for r in azuread_service_principal.this.app_roles : r
    if r.enabled && contains(r.allowed_member_types, "User")
  ]

  named_role_ids = [for r in local.user_assignable_roles : r.id if r.display_name == var.app_role_display_name]

  app_role_id = (
    length(local.named_role_ids) == 1 ? local.named_role_ids[0] :
    length(local.user_assignable_roles) == 0 ? local.default_access_role_id :
    null
  )
}

resource "azuread_app_role_assignment" "groups" {
  for_each = data.azuread_group.assigned

  app_role_id         = local.app_role_id
  principal_object_id = each.value.object_id
  resource_object_id  = azuread_service_principal.this.object_id

  lifecycle {
    precondition {
      condition     = local.app_role_id != null
      error_message = "The service principal publishes user-assignable app roles but not exactly one named \"${var.app_role_display_name}\". Published: ${join(", ", [for r in local.user_assignable_roles : r.display_name])}. Set app_role_display_name to the default role for this application."
    }
  }
}

# ---------------------------------------------------------------------------
# SCIM provisioning. The secret is written first, then the job is created and
# enabled against the template the gallery application publishes. Both values
# are variables marked sensitive; nothing here is a literal.
# ---------------------------------------------------------------------------

resource "azuread_synchronization_secret" "scim" {
  for_each = var.scim_enabled ? { this = true } : {}

  service_principal_id = azuread_service_principal.this.id

  credential {
    key   = "BaseAddress"
    value = var.scim_base_address
  }

  credential {
    key   = "SecretToken"
    value = var.scim_secret_token
  }
}

resource "azuread_synchronization_job" "scim" {
  for_each = var.scim_enabled ? { this = true } : {}

  service_principal_id = azuread_service_principal.this.id
  template_id          = var.scim_template_id
  enabled              = true

  depends_on = [azuread_synchronization_secret.scim]
}
