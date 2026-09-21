output "identity_providers" {
  description = "Map of logical key to { id, name, status, audience, acs_type, active_certificate, kid, keys }. audience is the SP entity id Okta computed for the trust; kid is the key in use; keys maps every certificate name to { kid, x5t_s256, expires_at }. x5t_s256 is Okta's thumbprint form, the base64url SHA-256 of the certificate's DER, which is not the hex SHA-1 fingerprint other tools print. Nothing here is secret: a kid is a reference and a thumbprint is a hash of a public certificate."
  value = {
    for k, p in okta_idp_saml.this : k => {
      id                 = p.id
      name               = p.name
      status             = p.status
      audience           = p.audience
      acs_type           = p.acs_type
      active_certificate = var.identity_providers[k].active_certificate
      kid                = p.kid
      keys = {
        for cert_name in keys(var.identity_providers[k].signing_certificates) : cert_name => {
          kid        = okta_idp_saml_key.this[local.certificate_keys["${k}/${cert_name}"]].kid
          x5t_s256   = okta_idp_saml_key.this[local.certificate_keys["${k}/${cert_name}"]].x5t_s256
          expires_at = okta_idp_saml_key.this[local.certificate_keys["${k}/${cert_name}"]].expires_at
        }
      }
    }
  }
}

output "identity_provider_ids_by_name" {
  description = "Map of identity provider display name to identity provider ID, for callers that reference trusts by their visible name."
  value       = { for k, p in okta_idp_saml.this : p.name => p.id }
}
