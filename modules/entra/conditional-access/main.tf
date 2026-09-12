# Named locations, authentication strengths, and Conditional Access policies.
#
# Policies reference locations and strengths by the caller's logical key and
# reference groups, roles, and applications by display name. Every ID that
# reaches a policy was resolved here, so a tenant cell never contains one.
#
# The break-glass exclusion group is appended to the excluded groups of every
# policy, unconditionally. A Conditional Access policy that applies to the
# emergency access accounts is the single most common way to lock an entire
# tenant out of its own directory, and it only takes one policy to do it. The
# module makes that mistake impossible to express. See
# docs/adr/0007-break-glass-exclusion-is-mandatory.md.
#
# prevent_destroy is set on every policy. Destroying an enforced policy silently
# removes a control (a legacy-authentication block, an MFA requirement) with no
# trace in the sign-in log. Destroying and recreating one, for example after a
# key rename, produces a moment where the control is absent and then a new
# policy that starts in whatever state the code says, with no report-only soak.
# Both are decisions that belong in a reviewed edit to the lifecycle block.

# ---------------------------------------------------------------------------
# Name resolution.
# ---------------------------------------------------------------------------

locals {
  special_applications = ["All", "None", "Office365", "MicrosoftAdminPortals"]

  group_names = toset(concat(
    [var.break_glass_exclusion_group],
    flatten([for p in var.policies : concat(p.users.included_groups, p.users.excluded_groups)]),
  ))

  role_names = toset(flatten([for p in var.policies : concat(p.users.included_roles, p.users.excluded_roles)]))

  application_names = toset([
    for a in flatten([for p in var.policies : concat(p.applications.included, p.applications.excluded)]) :
    a if !contains(local.special_applications, a)
  ])
}

data "azuread_group" "by_name" {
  for_each = local.group_names

  display_name     = each.value
  security_enabled = true
}

data "azuread_directory_role_templates" "all" {
  count = length(local.role_names) > 0 ? 1 : 0
}

data "azuread_service_principal" "applications" {
  for_each = local.application_names

  display_name = each.value
}

locals {
  group_ids = { for name, g in data.azuread_group.by_name : name => g.object_id }

  role_template_ids = length(local.role_names) > 0 ? {
    for t in data.azuread_directory_role_templates.all[0].role_templates : t.display_name => t.object_id
  } : {}

  # Special values pass through; everything else is an enterprise application
  # resolved to its client ID.
  application_ids = merge(
    { for a in local.special_applications : a => a },
    { for name, sp in data.azuread_service_principal.applications : name => sp.client_id },
  )

  # Graph expects bare named-location object IDs in a policy's location lists;
  # "All" and "AllTrusted" pass through.
  location_ids = merge(
    { All = "All", AllTrusted = "AllTrusted" },
    { for k, l in azuread_named_location.this : k => l.object_id },
  )

  # Every policy excludes the break-glass group. No exceptions, no flag.
  excluded_group_ids = {
    for k, p in var.policies : k => distinct(concat(
      [for g in p.users.excluded_groups : local.group_ids[g]],
      [local.group_ids[var.break_glass_exclusion_group]],
    ))
  }
}

# ---------------------------------------------------------------------------
# Named locations.
# ---------------------------------------------------------------------------

resource "azuread_named_location" "this" {
  for_each = var.named_locations

  display_name = each.value.display_name

  dynamic "ip" {
    for_each = length(each.value.ip_ranges) > 0 ? [1] : []
    content {
      ip_ranges = each.value.ip_ranges
      trusted   = each.value.trusted
    }
  }

  dynamic "country" {
    for_each = length(each.value.countries) > 0 ? [1] : []
    content {
      countries_and_regions                 = each.value.countries
      include_unknown_countries_and_regions = each.value.include_unknown_countries
      country_lookup_method                 = each.value.country_lookup_method
    }
  }
}

# ---------------------------------------------------------------------------
# Authentication strengths.
# ---------------------------------------------------------------------------

resource "azuread_authentication_strength_policy" "this" {
  for_each = var.authentication_strengths

  display_name         = each.value.display_name
  description          = each.value.description
  allowed_combinations = each.value.allowed_combinations
}

# ---------------------------------------------------------------------------
# Policies.
# ---------------------------------------------------------------------------

resource "azuread_conditional_access_policy" "this" {
  for_each = var.policies

  display_name = each.value.display_name
  state        = each.value.state

  conditions {
    client_app_types    = each.value.client_app_types
    sign_in_risk_levels = length(each.value.sign_in_risk_levels) > 0 ? each.value.sign_in_risk_levels : null
    user_risk_levels    = length(each.value.user_risk_levels) > 0 ? each.value.user_risk_levels : null

    applications {
      included_applications = length(each.value.applications.included) > 0 ? [for a in each.value.applications.included : local.application_ids[a]] : null
      excluded_applications = length(each.value.applications.excluded) > 0 ? [for a in each.value.applications.excluded : local.application_ids[a]] : null
      included_user_actions = length(each.value.applications.user_actions) > 0 ? each.value.applications.user_actions : null
    }

    users {
      included_users  = length(each.value.users.included_users) > 0 ? each.value.users.included_users : null
      excluded_users  = length(each.value.users.excluded_users) > 0 ? each.value.users.excluded_users : null
      included_groups = length(each.value.users.included_groups) > 0 ? [for g in each.value.users.included_groups : local.group_ids[g]] : null
      excluded_groups = local.excluded_group_ids[each.key]
      included_roles  = length(each.value.users.included_roles) > 0 ? [for r in each.value.users.included_roles : local.role_template_ids[r]] : null
      excluded_roles  = length(each.value.users.excluded_roles) > 0 ? [for r in each.value.users.excluded_roles : local.role_template_ids[r]] : null
    }

    dynamic "platforms" {
      for_each = each.value.platforms == null ? [] : [each.value.platforms]
      content {
        included_platforms = platforms.value.included
        excluded_platforms = length(platforms.value.excluded) > 0 ? platforms.value.excluded : null
      }
    }

    dynamic "locations" {
      for_each = each.value.locations == null ? [] : [each.value.locations]
      content {
        included_locations = [for l in locations.value.included : local.location_ids[l]]
        excluded_locations = length(locations.value.excluded) > 0 ? [for l in locations.value.excluded : local.location_ids[l]] : null
      }
    }
  }

  dynamic "grant_controls" {
    for_each = each.value.grant_controls == null ? [] : [each.value.grant_controls]
    content {
      operator                          = grant_controls.value.operator
      built_in_controls                 = length(grant_controls.value.built_in_controls) > 0 ? grant_controls.value.built_in_controls : null
      authentication_strength_policy_id = grant_controls.value.authentication_strength == null ? null : azuread_authentication_strength_policy.this[grant_controls.value.authentication_strength].id
    }
  }

  dynamic "session_controls" {
    for_each = each.value.session_controls == null ? [] : [each.value.session_controls]
    content {
      application_enforced_restrictions_enabled = session_controls.value.application_enforced_restrictions_enabled
      cloud_app_security_policy                 = session_controls.value.cloud_app_security_policy
      disable_resilience_defaults               = session_controls.value.disable_resilience_defaults
      persistent_browser_mode                   = session_controls.value.persistent_browser_mode
      sign_in_frequency                         = session_controls.value.sign_in_frequency
      sign_in_frequency_period                  = session_controls.value.sign_in_frequency_period
      sign_in_frequency_authentication_type     = session_controls.value.sign_in_frequency_authentication_type
      sign_in_frequency_interval                = session_controls.value.sign_in_frequency_interval
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for r in concat(each.value.users.included_roles, each.value.users.excluded_roles) : contains(keys(local.role_template_ids), r)
      ])
      error_message = "included_roles and excluded_roles must be built-in Entra directory role names exactly as shown in the portal."
    }
  }
}
