output "apps" {
  description = "Map of logical key to { application_object_id, client_id, display_name, service_principal_object_id, metadata_url, signing_certificate_thumbprint, claims_mapping_policy_id }."
  value = {
    for k, sp in azuread_service_principal.this : k => {
      application_object_id          = local.application_object_ids[k]
      client_id                      = local.application_client_ids[k]
      display_name                   = var.saml_apps[k].display_name
      service_principal_object_id    = sp.object_id
      metadata_url                   = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/federationmetadata/2007-06/federationmetadata.xml?appid=${local.application_client_ids[k]}"
      signing_certificate_thumbprint = azuread_service_principal_token_signing_certificate.this[k].thumbprint
      claims_mapping_policy_id       = azuread_claims_mapping_policy.this[k].id
    }
  }
}

output "client_ids" {
  description = "Map of logical key to application (client) ID."
  value       = local.application_client_ids
}

output "service_principal_object_ids" {
  description = "Map of logical key to enterprise application (service principal) object ID."
  value       = { for k, sp in azuread_service_principal.this : k => sp.object_id }
}

output "saml_endpoints" {
  description = "The tenant's SAML endpoints every vendor asks for, built from the provider's tenant ID: login_url and logout_url (the SingleSignOnService and SingleLogoutService locations the federation metadata publishes) and issuer (the Issuer element of every response). Never typed."
  value = {
    login_url  = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/saml2"
    logout_url = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/saml2"
    issuer     = "https://sts.windows.net/${data.azuread_client_config.current.tenant_id}/"
  }
}

output "vendor_onboarding" {
  description = "Map of logical key to the values a service provider asks for: issuer, login_url, logout_url, metadata_url, signing_certificate_thumbprint, and name_id_format (the NameID format the vendor should request in its NameIDPolicy; Entra decides the emitted format from that request, so it is carried here rather than enforced). Nothing here is secret."
  value = {
    for k, sp in azuread_service_principal.this : k => {
      issuer                         = "https://sts.windows.net/${data.azuread_client_config.current.tenant_id}/"
      login_url                      = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/saml2"
      logout_url                     = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/saml2"
      metadata_url                   = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/federationmetadata/2007-06/federationmetadata.xml?appid=${local.application_client_ids[k]}"
      signing_certificate_thumbprint = azuread_service_principal_token_signing_certificate.this[k].thumbprint
      name_id_format                 = local.name_id_formats[var.saml_apps[k].name_id.format]
    }
  }
}

output "signing_certificates" {
  description = "Map of logical key to { key_id, thumbprint, start_date, end_date } of the SAML signing certificate. The thumbprint is what to compare against the certificate the vendor shows after the metadata import."
  value = {
    for k, c in azuread_service_principal_token_signing_certificate.this : k => {
      key_id     = c.key_id
      thumbprint = c.thumbprint
      start_date = c.start_date
      end_date   = c.end_date
    }
  }
}

output "app_role_ids" {
  description = "Map of logical key to { app role display name => app role ID } the groups were assigned with: the template's published role for a gallery app, the module's declared role for a custom one."
  value       = local.app_role_ids
}

output "assigned_group_ids" {
  description = "Map of assigned group display name to object ID, across every app."
  value       = { for name, g in data.azuread_group.assigned : name => g.object_id }
}

output "app_role_assignment_ids" {
  description = "Map of \"app/role/group\" key to app role assignment ID."
  value       = { for k, a in azuread_app_role_assignment.groups : k => a.id }
}

output "synchronization_job_ids" {
  description = "Map of logical key to provisioning job ID, for the apps that set provisioning."
  value       = { for k, j in azuread_synchronization_job.this : k => j.id }
}
