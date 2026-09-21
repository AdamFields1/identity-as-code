output "idp_discovery_policy_id" {
  description = "ID of the org's IDP_DISCOVERY policy, looked up by name. Import addresses for routing rules are <this id>/<rule id>."
  value       = data.okta_policy.idp_discovery.id
}

output "identity_provider_onboarding" {
  description = "Map of identity provider key to { audience, acs_url }: the two values the other side configures. For the Entra enterprise application they are identifier_uris (audience, the SP entity id Okta computed) and reply_urls (acs_url, built from the org URL and the trust's id). Nothing here is secret. A trust with issuer_mode CUSTOM_URL is published on the custom domain instead, which this stack does not know; substitute the host."
  value = {
    for key, p in module.identity_providers.identity_providers : key => {
      audience = p.audience
      acs_url  = local.acs_urls[key]
    }
  }
}

output "identity_providers" {
  description = "Map of identity provider key to { id, name, status, audience, acs_url, active_certificate, kid, thumbprint, keys }. kid and thumbprint (x5t_s256) are the active certificate's; keys maps every certificate name to { kid, x5t_s256, expires_at }, so a rotation in progress shows both. Nothing here is secret: a kid is a reference and a thumbprint is a hash of a public certificate."
  value = {
    for key, p in module.identity_providers.identity_providers : key => {
      id                 = p.id
      name               = p.name
      status             = p.status
      audience           = p.audience
      acs_url            = local.acs_urls[key]
      active_certificate = p.active_certificate
      kid                = p.kid
      thumbprint         = p.keys[p.active_certificate].x5t_s256
      keys               = p.keys
    }
  }
}

output "identity_provider_ids" {
  description = "Map of identity provider key to Okta identity provider ID, the string after the last slash of the ACS URL."
  value       = { for key, p in module.identity_providers.identity_providers : key => p.id }
}

output "routing_rule_ids" {
  description = "Map of routing rule key to rule ID on the identity provider discovery policy."
  value       = module.routing_rules.rule_ids
}
