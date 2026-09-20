# okta-config stack
#
# One deployable unit that composes the four Okta policy modules into a coherent
# tenant baseline. Order of dependency:
#
#   network zones  -->  sign-on policy
#                  -->  MFA enrollment policy
#                  -->  password policy
#
# Tenant cells (tenants/okta/<env>/okta-config/terragrunt.hcl) supply values only. This stack
# owns all wiring: group name to ID lookups, zone key to ID lookups, and the
# module composition itself.
#
# Deliberately NOT managed here: users, groups, group memberships, applications.
# The directory of record (HR system, Active Directory, or Okta itself through
# provisioning) owns those. This stack only reads group IDs so policies can be
# scoped, and it never hardcodes an ID.

# ---------------------------------------------------------------------------
# Group lookups. One data source per distinct group name across all policies.
# ---------------------------------------------------------------------------

locals {
  all_group_names = toset(concat(
    var.session_policy.groups_included,
    var.mfa_policy.groups_included,
    var.password_policy.groups_included,
  ))
}

data "okta_group" "by_name" {
  for_each = local.all_group_names

  name = each.value
}

locals {
  group_ids = { for name, g in data.okta_group.by_name : name => g.id }
}

# ---------------------------------------------------------------------------
# Network zones first. Everything else references their IDs.
# ---------------------------------------------------------------------------

module "network_zones" {
  source = "../../modules/okta/network-zone"

  zones = var.network_zones
}

# ---------------------------------------------------------------------------
# Sign-on (session) policy.
# ---------------------------------------------------------------------------

module "session_policy" {
  source = "../../modules/okta/session-policy"

  name            = var.session_policy.name
  description     = var.session_policy.description
  priority        = var.session_policy.priority
  status          = var.session_policy.status
  groups_included = [for name in var.session_policy.groups_included : local.group_ids[name]]

  session_defaults = var.session_policy.session_defaults

  rules = {
    for key, rule in var.session_policy.rules : key => {
      name                = rule.name
      priority            = rule.priority
      status              = rule.status
      access              = rule.access
      authtype            = rule.authtype
      mfa_required        = rule.mfa_required
      mfa_prompt          = rule.mfa_prompt
      mfa_lifetime        = rule.mfa_lifetime
      mfa_remember_device = rule.mfa_remember_device
      network_connection  = rule.network_connection
      zone_ids_included   = [for z in rule.zones_included : module.network_zones.zone_ids[z]]
      zone_ids_excluded   = [for z in rule.zones_excluded : module.network_zones.zone_ids[z]]
      session_idle        = rule.session_idle
      session_lifetime    = rule.session_lifetime
      session_persistent  = rule.session_persistent
      users_excluded      = rule.users_excluded
    }
  }
}

# ---------------------------------------------------------------------------
# MFA enrollment policy.
# ---------------------------------------------------------------------------

module "mfa_policy" {
  source = "../../modules/okta/mfa-policy"

  name            = var.mfa_policy.name
  description     = var.mfa_policy.description
  priority        = var.mfa_policy.priority
  status          = var.mfa_policy.status
  groups_included = [for name in var.mfa_policy.groups_included : local.group_ids[name]]
  is_oie          = var.mfa_policy.is_oie
  authenticators  = var.mfa_policy.authenticators

  rules = {
    for key, rule in var.mfa_policy.rules : key => {
      name               = rule.name
      priority           = rule.priority
      status             = rule.status
      enroll             = rule.enroll
      network_connection = rule.network_connection
      zone_ids_included  = [for z in rule.zones_included : module.network_zones.zone_ids[z]]
      zone_ids_excluded  = [for z in rule.zones_excluded : module.network_zones.zone_ids[z]]
      users_excluded     = rule.users_excluded
      app_include        = rule.app_include
    }
  }
}

# ---------------------------------------------------------------------------
# Password policy.
# ---------------------------------------------------------------------------

module "password_policy" {
  source = "../../modules/okta/password-policy"

  name            = var.password_policy.name
  description     = var.password_policy.description
  priority        = var.password_policy.priority
  status          = var.password_policy.status
  groups_included = [for name in var.password_policy.groups_included : local.group_ids[name]]
  auth_provider   = var.password_policy.auth_provider

  complexity = var.password_policy.complexity
  age        = var.password_policy.age
  lockout    = var.password_policy.lockout
  recovery   = var.password_policy.recovery

  rules = {
    for key, rule in var.password_policy.rules : key => {
      name               = rule.name
      priority           = rule.priority
      status             = rule.status
      password_change    = rule.password_change
      password_reset     = rule.password_reset
      password_unlock    = rule.password_unlock
      network_connection = rule.network_connection
      zone_ids_included  = [for z in rule.zones_included : module.network_zones.zone_ids[z]]
      zone_ids_excluded  = [for z in rule.zones_excluded : module.network_zones.zone_ids[z]]
      users_excluded     = rule.users_excluded
    }
  }
}
