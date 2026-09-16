output "automation_account_id" {
  description = "Resource ID of the Automation account."
  value       = module.automation_account.automation_account_id
}

output "identity_principal_id" {
  description = "Object ID of the runbook identity's service principal, the principal the Graph grants and the Exchange application access policy refer to."
  value       = module.automation_account.identity_principal_id
}

output "identity_client_id" {
  description = "Client ID of the runbook identity. The value New-ApplicationAccessPolicy -AppId takes."
  value       = module.automation_account.identity_client_id
}

output "runbook_names" {
  description = "Map of runbook key to runbook name in the account."
  value       = module.runbooks.runbook_names
}

output "runbook_content_hashes" {
  description = "Map of runbook key to SHA-256 of the deployed file."
  value       = module.runbooks.content_hashes
}

output "job_schedule_ids" {
  description = "Map of runbook key to job schedule resource ID."
  value       = module.runbooks.job_schedule_ids
}

output "graph_app_role_assignment_ids" {
  description = "Map of Graph permission name to app role assignment ID."
  value       = module.graph_grants.assignment_ids
}
