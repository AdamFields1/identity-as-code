# ---------------------------------------------------------------------------
# Routing rules, after the identity providers they name.
#
# Every attribute is the cell's value handed to the module as is, except the
# ones this stack owns: idps are keys of this cell's identity_providers, and
# the module takes idp_ids; zones_included and zones_excluded are zone NAMES,
# and the module takes ids; an APP entry carries the application's label, and
# the module takes its id. Reading the identity provider ids from the module
# output is what orders the two, so a trust is created before the rule that
# routes to it. The policy id comes from the lookup in main.tf.
# ---------------------------------------------------------------------------

module "routing_rules" {
  source = "../../modules/okta/idp-routing-rules"

  policy_id = data.okta_policy.idp_discovery.id

  rules = {
    for key, r in var.routing_rules : key => {
      name                      = r.name
      priority                  = r.priority
      status                    = r.status
      user_identifier_type      = r.user_identifier_type
      user_identifier_attribute = r.user_identifier_attribute
      patterns                  = r.patterns

      idp_ids = [for idp in r.idps : module.identity_providers.identity_providers[idp].id]

      network_connection = r.network_connection
      zone_ids_included  = [for name in r.zones_included : local.zone_ids[name]]
      zone_ids_excluded  = [for name in r.zones_excluded : local.zone_ids[name]]

      # An APP entry's label becomes its id; an APP_TYPE entry's name passes
      # through. The field that does not belong to the entry's type is null,
      # and the variable validation has already refused an APP entry without
      # a label, so the index below cannot miss.
      app_include = [
        for a in r.app_include : {
          type = a.type
          id   = a.type == "APP" ? local.app_ids[a.label] : null
          name = a.type == "APP_TYPE" ? a.name : null
        }
      ]

      app_exclude = [
        for a in r.app_exclude : {
          type = a.type
          id   = a.type == "APP" ? local.app_ids[a.label] : null
          name = a.type == "APP_TYPE" ? a.name : null
        }
      ]

      platform_include = r.platform_include
    }
  }
}
