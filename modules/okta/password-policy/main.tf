# One password policy plus its rules.
#
# Settings are grouped into four objects (complexity, age, lockout, recovery) so a
# tenant can override a single value without restating the rest. The secure defaults
# live in variables.tf and are documented there.
#
# prevent_destroy: deleting a password policy silently reverts the covered groups to
# the tenant default policy, which is usually far weaker. Make that an explicit edit.

resource "okta_policy_password" "this" {
  name            = var.name
  description     = var.description
  priority        = var.priority
  status          = var.status
  groups_included = var.groups_included
  auth_provider   = var.auth_provider

  # Complexity
  password_min_length         = var.complexity.min_length
  password_min_lowercase      = var.complexity.min_lowercase
  password_min_uppercase      = var.complexity.min_uppercase
  password_min_number         = var.complexity.min_number
  password_min_symbol         = var.complexity.min_symbol
  password_exclude_username   = var.complexity.exclude_username
  password_exclude_first_name = var.complexity.exclude_first_name
  password_exclude_last_name  = var.complexity.exclude_last_name
  password_dictionary_lookup  = var.complexity.dictionary_lookup

  # Age and history
  password_max_age_days     = var.age.max_age_days
  password_expire_warn_days = var.age.expire_warn_days
  password_min_age_minutes  = var.age.min_age_minutes
  password_history_count    = var.age.history_count

  # Lockout
  password_max_lockout_attempts          = var.lockout.max_attempts
  password_auto_unlock_minutes           = var.lockout.auto_unlock_minutes
  password_show_lockout_failures         = var.lockout.show_failures
  password_lockout_notification_channels = var.lockout.notification_channels

  # Recovery
  email_recovery       = var.recovery.email
  recovery_email_token = var.recovery.email_token_minutes
  sms_recovery         = var.recovery.sms
  call_recovery        = var.recovery.call
  question_recovery    = var.recovery.question
  question_min_length  = var.recovery.question_min_length
  skip_unlock          = var.recovery.skip_unlock

  lifecycle {
    prevent_destroy = true
  }
}

resource "okta_policy_rule_password" "this" {
  for_each = var.rules

  policy_id = okta_policy_password.this.id
  name      = each.value.name
  priority  = each.value.priority
  status    = each.value.status

  password_change = each.value.password_change
  password_reset  = each.value.password_reset
  password_unlock = each.value.password_unlock

  network_connection = each.value.network_connection
  network_includes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_included) > 0 ? each.value.zone_ids_included : null
  network_excludes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_excluded) > 0 ? each.value.zone_ids_excluded : null

  users_excluded = length(each.value.users_excluded) > 0 ? each.value.users_excluded : null
}
