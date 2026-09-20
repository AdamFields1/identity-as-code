output "apps" {
  description = "Map of logical key to { id, label, entity_url, http_post_binding, metadata_url, certificate, key_id, status }."
  value = {
    for k, a in okta_app_saml.this : k => {
      id                = a.id
      label             = a.label
      entity_url        = a.entity_url
      http_post_binding = a.http_post_binding
      metadata_url      = a.metadata_url
      certificate       = a.certificate
      key_id            = a.key_id
      status            = a.status
    }
  }
}

output "app_ids_by_label" {
  description = "Map of app label to app ID, for callers that reference apps by their visible name."
  value       = { for k, a in okta_app_saml.this : a.label => a.id }
}

output "vendor_onboarding" {
  description = "Map of logical key to the four values a service provider asks for: entity_id (the Okta issuer), sso_url (the HTTP-POST binding), metadata_url, and the signing certificate. Nothing here is secret; the certificate is the public half of the signing key."
  value = {
    for k, a in okta_app_saml.this : k => {
      entity_id    = a.entity_url
      sso_url      = a.http_post_binding
      metadata_url = a.metadata_url
      certificate  = a.certificate
    }
  }
}
