output "vendor_onboarding" {
  description = "Map of app key to { issuer, login_url, logout_url, metadata_url, signing_certificate_thumbprint, name_id_format }: what a service provider asks for. Nothing here is secret; the certificate reaches the vendor inside the federation metadata."
  value       = module.saml_apps.vendor_onboarding
}

output "saml_endpoints" {
  description = "The tenant's SAML endpoints, built from the provider's tenant ID and never typed: { login_url, logout_url, issuer }."
  value       = module.saml_apps.saml_endpoints
}

output "apps" {
  description = "Map of app key to { application_object_id, client_id, display_name, service_principal_object_id, metadata_url, signing_certificate_thumbprint, claims_mapping_policy_id }."
  value       = module.saml_apps.apps
}

output "client_ids" {
  description = "Map of app key to application (client) ID, the appid in the metadata URL."
  value       = module.saml_apps.client_ids
}

output "service_principal_object_ids" {
  description = "Map of app key to enterprise application (service principal) object ID, what the portal and Graph address the application by."
  value       = module.saml_apps.service_principal_object_ids
}

output "signing_certificates" {
  description = "Map of app key to { key_id, thumbprint, start_date, end_date } of the SAML signing certificate. The thumbprint is what to compare against the certificate the vendor shows after the metadata import."
  value       = module.saml_apps.signing_certificates
}

output "app_role_ids" {
  description = "Map of app key to { app role display name => app role ID } the groups were assigned with: the template's published role for a gallery app, the module's declared role for a custom one."
  value       = module.saml_apps.app_role_ids
}

output "assigned_group_ids" {
  description = "Map of assigned group display name to object ID, across every app in this cell."
  value       = module.saml_apps.assigned_group_ids
}

output "app_role_assignment_ids" {
  description = "Map of \"app/role/group\" key to app role assignment ID."
  value       = module.saml_apps.app_role_assignment_ids
}

output "synchronization_job_ids" {
  description = "Map of app key to provisioning job ID, for the apps that set provisioning."
  value       = module.saml_apps.synchronization_job_ids
}
