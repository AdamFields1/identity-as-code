# Custom SAML 2.0 applications and their group assignments, keyed by the caller's
# logical name.
#
# The module is a catalog shape, not a pass-through. A cell says where the service
# provider lives (sso_url, audience), how the subject is named, which attributes
# the assertion carries, and which groups may use the app. Everything a security
# reviewer would otherwise have to check on every app is fixed here: both the
# response and the assertion are signed with RSA-SHA256 and SHA256 digests, the
# app honours a ForceAuthn request from the service provider, self-service
# assignment is off, SAML 1.1 cannot be selected, and there is no inline hook
# input, so no assertion can be rewritten by code outside this repository.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing an app in the middle of the map never re-addresses its neighbours.
#
# Groups are referenced by NAME and resolved here with the okta_group data source.
# Every distinct name across every app is looked up exactly once. The groups are
# provisioned into Okta by the upstream identity provider, not by this module, so
# a name that does not exist fails the plan with the name in the error. That is
# the honest failure: a silently empty assignment would look like a working app
# that nobody can open.

locals {
  # One lookup per distinct group name, shared by every app that names it.
  group_names = toset(flatten([for a in var.apps : a.group_names]))
}

data "okta_group" "this" {
  for_each = local.group_names

  name = each.value
}

resource "okta_app_saml" "this" {
  for_each = var.apps

  label  = each.value.label
  status = each.value.status

  # Service provider endpoints. recipient and destination default to the ACS URL
  # because that is what almost every SP expects; a cell overrides them only when
  # the vendor documents a different value.
  sso_url     = each.value.sso_url
  recipient   = coalesce(each.value.recipient, each.value.sso_url)
  destination = coalesce(each.value.destination, each.value.sso_url)
  audience    = each.value.audience

  # Subject. The template is an Okta expression, so the interpolation is written
  # escaped in the variable default and passed through untouched.
  subject_name_id_template = each.value.subject_name_id_template
  subject_name_id_format   = each.value.subject_name_id_format

  # Fixed by the module. None of these has an input. Weakening any of them is a
  # module change that shows up in code review, not a per-app knob.
  saml_version               = "2.0"
  response_signed            = true
  assertion_signed           = true
  signature_algorithm        = "RSA_SHA256"
  digest_algorithm           = "SHA256"
  authn_context_class_ref    = "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"
  honor_force_authn          = true
  accessibility_self_service = false

  # The app username is the Okta login, which is the provider's own default. It
  # is written out so the contract is visible rather than inherited.
  user_name_template      = "$${source.login}"
  user_name_template_type = "BUILT_IN"

  # Single logout is optional and sent only when the cell supplies all three
  # values, which the variable validation guarantees.
  single_logout_url         = try(each.value.single_logout.url, null)
  single_logout_issuer      = try(each.value.single_logout.issuer, null)
  single_logout_certificate = try(each.value.single_logout.certificate, null)

  hide_ios = each.value.hide_ios
  hide_web = each.value.hide_web

  # The calling stack resolves a policy key to an id and passes it here. Null
  # leaves the app on the org's default app sign-on policy.
  authentication_policy = each.value.authentication_policy_id

  # Attribute statements are typed. An EXPRESSION statement carries values and a
  # GROUP statement carries a filter, so the fields that do not belong to the
  # type are sent as null to keep the API payload and the plan clean.
  dynamic "attribute_statements" {
    for_each = each.value.attribute_statements

    content {
      name         = attribute_statements.value.name
      type         = attribute_statements.value.type
      namespace    = attribute_statements.value.namespace
      values       = attribute_statements.value.type == "EXPRESSION" ? attribute_statements.value.values : null
      filter_type  = attribute_statements.value.type == "GROUP" ? attribute_statements.value.filter_type : null
      filter_value = attribute_statements.value.type == "GROUP" ? attribute_statements.value.filter_value : null
    }
  }

  lifecycle {
    # Branding is the application owner's. The logo is uploaded from the admin
    # console after creation and Terraform never reverts it. Nothing else is
    # ignored: every endpoint, signing setting, attribute statement, and policy
    # binding is enforced on every apply because those are the controls.
    #
    # Terraform requires this list to be static, so it is a module constant
    # rather than a variable. Widening it is a module change and a code review.
    ignore_changes = [
      logo,
    ]
  }
}

# One assignments resource per app holds that app's complete group list, so a
# group removed from the cell is unassigned on the next apply. The provider
# documents this resource as the whole set for an app; keying it by app, not by
# group, is what keeps that contract. Apps with no groups get no resource.
resource "okta_app_group_assignments" "this" {
  for_each = { for k, a in var.apps : k => a if length(a.group_names) > 0 }

  app_id = okta_app_saml.this[each.key].id

  dynamic "group" {
    for_each = each.value.group_names

    content {
      id       = data.okta_group.this[group.value].id
      priority = lookup(each.value.group_assignment_priorities, group.value, null)
    }
  }
}
