# Network zones are the building block every other policy points at, so they are
# created first and their IDs are exported for the session, MFA, and password modules.
#
# for_each is keyed by the caller's logical name rather than count, so adding or
# removing a zone in the middle of the map never re-addresses its neighbours.
#
# IP-only and DYNAMIC-only attributes are sent as null when they do not apply.
# Sending an empty list for the wrong zone type produces a perpetual plan diff
# on some provider versions, so the ternaries below keep the API payload clean.

resource "okta_network_zone" "this" {
  for_each = var.zones

  name   = each.value.name
  type   = each.value.type
  usage  = each.value.usage
  status = each.value.status

  # IP zone attributes
  gateways = each.value.type == "IP" && length(each.value.gateways) > 0 ? each.value.gateways : null
  proxies  = each.value.type == "IP" && length(each.value.proxies) > 0 ? each.value.proxies : null

  # DYNAMIC zone attributes
  dynamic_locations  = each.value.type == "DYNAMIC" && length(each.value.dynamic_locations) > 0 ? each.value.dynamic_locations : null
  asns               = each.value.type == "DYNAMIC" && length(each.value.asns) > 0 ? each.value.asns : null
  dynamic_proxy_type = each.value.type == "DYNAMIC" ? each.value.dynamic_proxy_type : null
}
