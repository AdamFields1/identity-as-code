# One MFA enrollment policy plus its rules.
#
# The provider models each authenticator as its own map(string) attribute
# (okta_verify = { enroll = "REQUIRED", consent_type = "NONE" }). Callers pass a
# single map keyed by authenticator name and this module fans it out. Any key not
# present is sent as null, which leaves that authenticator untouched.
#
# prevent_destroy: removing an MFA policy can drop users back to a default policy
# with weaker enrollment requirements. See the session-policy module for the
# reasoning behind making that an explicit, reviewed edit.

locals {
  # Normalise to plain string maps so the object type converts cleanly to the
  # provider's map(string) attributes.
  auth = {
    for k, v in var.authenticators : k => {
      enroll       = v.enroll
      consent_type = v.consent_type
    }
  }
}

resource "okta_policy_mfa" "this" {
  name            = var.name
  description     = var.description
  priority        = var.priority
  status          = var.status
  groups_included = var.groups_included
  is_oie          = var.is_oie

  # OIE authenticators
  okta_password     = lookup(local.auth, "okta_password", null)
  okta_email        = lookup(local.auth, "okta_email", null)
  okta_verify       = lookup(local.auth, "okta_verify", null)
  phone_number      = lookup(local.auth, "phone_number", null)
  fido_webauthn     = lookup(local.auth, "fido_webauthn", null)
  google_otp        = lookup(local.auth, "google_otp", null)
  security_question = lookup(local.auth, "security_question", null)
  duo               = lookup(local.auth, "duo", null)
  yubikey_token     = lookup(local.auth, "yubikey_token", null)
  symantec_vip      = lookup(local.auth, "symantec_vip", null)
  rsa_token         = lookup(local.auth, "rsa_token", null)
  onprem_mfa        = lookup(local.auth, "onprem_mfa", null)
  external_idp      = lookup(local.auth, "external_idp", null)
  smart_card_idp    = lookup(local.auth, "smart_card_idp", null)
  custom_app        = lookup(local.auth, "custom_app", null)
  hotp              = lookup(local.auth, "hotp", null)

  # Classic Engine factors
  okta_otp      = lookup(local.auth, "okta_otp", null)
  okta_push     = lookup(local.auth, "okta_push", null)
  okta_sms      = lookup(local.auth, "okta_sms", null)
  okta_call     = lookup(local.auth, "okta_call", null)
  okta_question = lookup(local.auth, "okta_question", null)

  lifecycle {
    prevent_destroy = true
  }
}

resource "okta_policy_rule_mfa" "this" {
  for_each = var.rules

  policy_id = okta_policy_mfa.this.id
  name      = each.value.name
  priority  = each.value.priority
  status    = each.value.status
  enroll    = each.value.enroll

  network_connection = each.value.network_connection
  network_includes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_included) > 0 ? each.value.zone_ids_included : null
  network_excludes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_excluded) > 0 ? each.value.zone_ids_excluded : null

  users_excluded = length(each.value.users_excluded) > 0 ? each.value.users_excluded : null

  dynamic "app_include" {
    for_each = each.value.app_include
    content {
      type = app_include.value.type
      id   = app_include.value.id
      name = app_include.value.name
    }
  }
}
