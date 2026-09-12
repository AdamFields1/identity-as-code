output "application_object_id" {
  description = "Object ID of the application registration."
  value       = azuread_application.this.object_id
}

output "client_id" {
  description = "Application (client) ID."
  value       = azuread_application.this.client_id
}

output "service_principal_object_id" {
  description = "Object ID of the enterprise application (service principal)."
  value       = azuread_service_principal.this.object_id
}

output "signing_certificate" {
  description = "{ key_id, thumbprint, start_date, end_date } of the SAML signing certificate. The thumbprint is what to compare against the certificate the AWS console shows after metadata upload."
  value = {
    key_id     = azuread_service_principal_token_signing_certificate.this.key_id
    thumbprint = azuread_service_principal_token_signing_certificate.this.thumbprint
    start_date = azuread_service_principal_token_signing_certificate.this.start_date
    end_date   = azuread_service_principal_token_signing_certificate.this.end_date
  }
}

output "app_role_id" {
  description = "App role ID the groups were assigned with: the published default role, or 00000000-0000-0000-0000-000000000000 when the application publishes none."
  value       = local.app_role_id
}

output "assigned_group_ids" {
  description = "Map of assigned group display name to object ID."
  value       = { for name, g in data.azuread_group.assigned : name => g.object_id }
}

output "app_role_assignment_ids" {
  description = "Map of assigned group display name to app role assignment ID."
  value       = { for name, a in azuread_app_role_assignment.groups : name => a.id }
}

output "synchronization_job_id" {
  description = "ID of the SCIM synchronization job, or null when scim_enabled is false."
  value       = try(azuread_synchronization_job.scim["this"].id, null)
}
