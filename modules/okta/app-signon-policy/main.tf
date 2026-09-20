# App sign-on (authentication) policies keyed by logical name, each with its rules.
#
# Zones and groups are looked up by NAME here rather than passed in as IDs. A cell
# is values only (ADR 0002), so the name is the only thing it can say, and one data
# source per distinct name keeps the lookup count small however many rules share a
# zone or a group. A name that does not exist fails the plan, which is the honest
# failure: the corp Entra tenant provisions the groups and the okta-config cell
# creates the zones, so a missing one is a sequencing mistake, not something to
# paper over with a default.
#
# prevent_destroy is set on the policy itself, as on the session policy. The
# provider warns that destroying an app sign-on policy reassigns every app that
# used it to the org's default policy, which is the permissive one. Requiring an
# engineer to edit this lifecycle block first makes that fall-through an explicit,
# reviewed decision rather than a side effect of dropping a map key. Rules do not
# carry the guard because replacing a rule is a routine, reviewable operation.
#
# The catch-all rule. Okta creates a system rule (system = true) on every app
# sign-on policy that matches whatever the named rules do not, and by default it
# ALLOWS. This module sets catch_all = false so the system rule is created with
# access DENY: every path to ALLOW is then a named rule in this map, which is what
# makes the phishing_resistant_only output a true statement about the policy. The
# system rule is not managed as a resource. Its conditions are immutable, Okta
# never lets it be deleted, and importing it only to hold a DENY that creation
# already set would add a second address for the same fact. Its id is exported for
# audit. The provider applies catch_all at creation only, so a policy imported into
# this module must have its catch-all checked by hand once (see the README).

locals {
  # One entry per distinct zone name and group name across every rule of every
  # policy, so the lookups happen exactly once per name.
  zone_names  = toset(flatten([for p in var.policies : [for r in p.rules : r.network_zone_names]]))
  group_names = toset(flatten([for p in var.policies : [for r in p.rules : r.group_names]]))

  # Flatten policy/rule pairs so a single for_each can address every rule.
  rules = merge([
    for pk, p in var.policies : {
      for rk, r in p.rules : "${pk}/${rk}" => merge(r, { policy_key = pk, rule_key = rk })
    }
  ]...)

  # Authenticator constraints, built from the typed shape into the JSON object the
  # API takes. Only fields the rule actually sets are emitted: a flag left at
  # OPTIONAL is the API default and sending it back explicitly is a perpetual diff
  # on some provider versions. A rule with no constraint content sends null. The
  # pieces are filtered for-expressions rather than conditionals because HCL
  # refuses a conditional whose two branches are objects of different shapes.
  possession_flags = {
    phishing_resistant = "phishingResistant"
    hardware_protected = "hardwareProtected"
    device_bound       = "deviceBound"
    user_presence      = "userPresence"
  }

  possession = {
    for k, r in local.rules : k => merge(
      { for flag, key in local.possession_flags : key => "REQUIRED" if try(r.constraints.possession[flag], "OPTIONAL") == "REQUIRED" },
      { for once in [true] : "types" => r.constraints.possession.types if length(coalesce(try(r.constraints.possession.types, null), [])) > 0 },
    )
  }

  knowledge = {
    for k, r in local.rules : k => merge(
      { for once in [true] : "types" => r.constraints.knowledge.types if length(coalesce(try(r.constraints.knowledge.types, null), [])) > 0 },
      { for once in [true] : "reauthenticateIn" => r.constraints.knowledge.re_authentication_frequency if try(r.constraints.knowledge.re_authentication_frequency, null) != null },
    )
  }

  constraints = {
    for k, r in local.rules : k => length(local.possession[k]) + length(local.knowledge[k]) == 0 ? null : [
      jsonencode(merge(
        { for once in [true] : "possession" => local.possession[k] if length(local.possession[k]) > 0 },
        { for once in [true] : "knowledge" => local.knowledge[k] if length(local.knowledge[k]) > 0 },
      ))
    ]
  }
}

data "okta_network_zone" "by_name" {
  for_each = local.zone_names

  name = each.value
}

data "okta_group" "by_name" {
  for_each = local.group_names

  name = each.value
}

resource "okta_app_signon_policy" "this" {
  for_each = var.policies

  name        = each.value.name
  description = each.value.description
  catch_all   = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "okta_app_signon_policy_rule" "this" {
  for_each = local.rules

  policy_id = okta_app_signon_policy.this[each.value.policy_key].id
  name      = each.value.name
  priority  = each.value.priority
  access    = each.value.access

  # Assurance. Factor mode, re-authentication, and constraints describe what an
  # ALLOW demands, so they are nulled out on a DENY rule to keep the plan free of
  # noise.
  factor_mode                 = each.value.access == "ALLOW" ? each.value.factor_mode : null
  re_authentication_frequency = each.value.access == "ALLOW" ? each.value.re_authentication_frequency : null
  constraints                 = each.value.access == "ALLOW" ? local.constraints[each.key] : null

  # Network condition. Zone lists are only valid when the connection type is ZONE.
  network_connection = each.value.network_connection
  network_includes   = each.value.network_connection == "ZONE" ? [for z in each.value.network_zone_names : data.okta_network_zone.by_name[z].id] : null

  # Device condition. Okta evaluates "managed" only on a registered device, so a
  # managed rule that says nothing about registration gets registered = true.
  device_is_managed    = each.value.device_is_managed
  device_is_registered = each.value.device_is_managed == true ? true : each.value.device_is_registered

  # User types are not in the shape. The provider takes them as ids, which a
  # cell never writes (ADR 0002). A rule that needs one gets a name lookup the
  # way zones and groups have, when that rule arrives.
  groups_included = length(each.value.group_names) > 0 ? [for g in each.value.group_names : data.okta_group.by_name[g].id] : null
}
