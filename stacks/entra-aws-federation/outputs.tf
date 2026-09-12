output "targets" {
  description = "Map of target key to { client_id, service_principal_object_id, app_role_id, signing_certificate_thumbprint, synchronization_job_id }."
  value = {
    for k, m in module.identity_center : k => {
      client_id                      = m.client_id
      service_principal_object_id    = m.service_principal_object_id
      app_role_id                    = m.app_role_id
      signing_certificate_thumbprint = m.signing_certificate.thumbprint
      synchronization_job_id         = m.synchronization_job_id
    }
  }
}

output "federation_metadata_urls" {
  description = "Map of target key to the federation metadata URL to upload in the AWS console's Change identity source wizard."
  value = {
    for k, m in module.identity_center :
    k => "https://login.microsoftonline.com/${var.tenant_id}/federationmetadata/2007-06/federationmetadata.xml?appid=${m.client_id}"
  }
}

output "assigned_groups" {
  description = "Map of target key to the list of group display names assigned to that instance's application, as derived from aws_groups by partition."
  value       = local.groups_by_partition
}

output "assigned_group_ids" {
  description = "Map of target key to { group display name => object ID } for every group in scope for that instance."
  value       = { for k, m in module.identity_center : k => m.assigned_group_ids }
}
