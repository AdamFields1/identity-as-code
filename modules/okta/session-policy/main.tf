# One sign-on policy plus its ordered rules.
#
# prevent_destroy is set on the policy itself. Deleting a sign-on policy in a
# production tenant can lock every user out or, worse, silently fall through to a
# weaker default policy. Requiring an engineer to edit this lifecycle block first is
# deliberate friction: the change shows up in code review as an explicit decision
# rather than as a side effect of a refactor. Rules do not carry the guard because
# replacing a rule is a routine, reviewable operation.

resource "okta_policy_signon" "this" {
  name            = var.name
  description     = var.description
  priority        = var.priority
  status          = var.status
  groups_included = var.groups_included

  lifecycle {
    prevent_destroy = true
  }
}

resource "okta_policy_rule_signon" "this" {
  for_each = var.rules

  policy_id = okta_policy_signon.this.id
  name      = each.value.name
  priority  = each.value.priority
  status    = each.value.status
  access    = each.value.access
  authtype  = each.value.authtype

  # MFA behaviour. Prompt and lifetime are only meaningful when MFA is required, so
  # they are nulled out otherwise to keep the plan free of noise.
  mfa_required        = each.value.mfa_required
  mfa_prompt          = each.value.mfa_required ? each.value.mfa_prompt : null
  mfa_lifetime        = each.value.mfa_required && each.value.mfa_prompt == "SESSION" ? each.value.mfa_lifetime : null
  mfa_remember_device = each.value.mfa_required && each.value.mfa_prompt == "DEVICE" ? each.value.mfa_remember_device : null

  # Network condition. Zone lists are only valid when the connection type is ZONE.
  network_connection = each.value.network_connection
  network_includes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_included) > 0 ? each.value.zone_ids_included : null
  network_excludes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_excluded) > 0 ? each.value.zone_ids_excluded : null

  # Session values fall back to the policy-level defaults when a rule does not override.
  session_idle       = coalesce(each.value.session_idle, var.session_defaults.idle_minutes)
  session_lifetime   = coalesce(each.value.session_lifetime, var.session_defaults.lifetime_minutes)
  session_persistent = coalesce(each.value.session_persistent, var.session_defaults.persistent_cookie)

  users_excluded = length(each.value.users_excluded) > 0 ? each.value.users_excluded : null
}
