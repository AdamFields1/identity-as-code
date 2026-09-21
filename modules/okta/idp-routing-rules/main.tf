# Routing rules on the org's identity provider discovery policy, keyed by the
# caller's logical name.
#
# Every Okta org holds exactly one IDP_DISCOVERY policy, and its default rule,
# which routes to Okta itself, is immutable. This module owns the rules that come
# before that default: each one says who (a pattern on the username or a profile
# attribute), from where (a network condition), on what (an application and
# platform condition), and which SAML 2.0 identity providers they are sent to.
# The policy is not created here; the calling stack looks it up by its fixed
# name and passes its id, so the module never carries an Okta object id.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing a rule in the middle of the map never re-addresses its neighbours.
# A map has no order, so every rule carries an explicit priority and the
# priorities are unique.
#
# Identity providers, network zones, and applications are ids here. The calling
# stack resolves names and labels, the way okta-config resolves zones_included,
# so the lookup happens exactly once per stack and a name that does not exist
# fails the plan with the name in the error.
#
# The rule's routing target is fixed to identity providers of type SAML2. An
# OIDC or social identity provider, or a rule that routes back to Okta, is a
# different shape and is out of scope here.

resource "okta_policy_rule_idp_discovery" "this" {
  for_each = var.rules

  policy_id = var.policy_id
  name      = each.value.name
  priority  = each.value.priority
  status    = each.value.status

  # Who. IDENTIFIER matches the patterns against the username the person typed;
  # ATTRIBUTE matches them against one attribute of the Okta profile that
  # username resolves to. The attribute belongs to ATTRIBUTE only; the variable
  # validation refuses it elsewhere and it is sent as null there.
  user_identifier_type      = each.value.user_identifier_type
  user_identifier_attribute = each.value.user_identifier_type == "ATTRIBUTE" ? each.value.user_identifier_attribute : null

  dynamic "user_identifier_patterns" {
    for_each = each.value.patterns

    content {
      match_type = user_identifier_patterns.value.match_type
      value      = user_identifier_patterns.value.value
    }
  }

  # Where to. One provider block per identity provider id, all SAML2.
  dynamic "idp_providers" {
    for_each = each.value.idp_ids

    content {
      id   = idp_providers.value
      type = "SAML2"
    }
  }

  # From where. Zone lists are only valid when the connection type is ZONE, and
  # the provider declares includes and excludes as conflicting, so a rule
  # carries one or the other.
  network_connection = each.value.network_connection
  network_includes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_included) > 0 ? each.value.zone_ids_included : null
  network_excludes   = each.value.network_connection == "ZONE" && length(each.value.zone_ids_excluded) > 0 ? each.value.zone_ids_excluded : null

  # On what. An APP entry carries an id (resolved by the stack from a label)
  # and an APP_TYPE entry carries a name, so the field that does not belong to
  # the type is sent as null to keep the API payload and the plan clean.
  dynamic "app_include" {
    for_each = each.value.app_include

    content {
      type = app_include.value.type
      id   = app_include.value.type == "APP" ? app_include.value.id : null
      name = app_include.value.type == "APP_TYPE" ? app_include.value.name : null
    }
  }

  dynamic "app_exclude" {
    for_each = each.value.app_exclude

    content {
      type = app_exclude.value.type
      id   = app_exclude.value.type == "APP" ? app_exclude.value.id : null
      name = app_exclude.value.type == "APP_TYPE" ? app_exclude.value.name : null
    }
  }

  dynamic "platform_include" {
    for_each = each.value.platform_include

    content {
      type          = platform_include.value.type
      os_type       = platform_include.value.os_type
      os_expression = platform_include.value.os_type == "OTHER" ? platform_include.value.os_expression : null
    }
  }
}
