output "automation_account_id" {
  description = "Resource ID of the Automation account."
  value       = module.automation_account.automation_account_id
}

output "identities" {
  description = "Map of privilege tier to that identity's name, principal_id (what the Graph grants are made to), client_id (what New-ApplicationAccessPolicy -AppId takes, and what the tier's runbooks pass to the identity endpoint), the Graph permissions it holds, and the runbooks that run as it. The single-identity form has one entry, keyed \"default\"."
  value = {
    for tier, identity in local.identity_tiers : tier => {
      name            = module.automation_account.identities[tier].name
      principal_id    = module.automation_account.identities[tier].principal_id
      client_id       = module.automation_account.identities[tier].client_id
      graph_app_roles = identity.graph_app_roles
      sends_mail      = contains(identity.graph_app_roles, "Mail.Send")
      runbooks        = sort([for key, used in local.runbook_identity_keys : var.runbooks[key].name if used == tier])
    }
  }
}

output "identity_principal_id" {
  description = "Object ID of the \"default\" identity's service principal, or null when the account has tiers. Per-tier values are in identities."
  value       = module.automation_account.identity_principal_id
}

output "identity_client_id" {
  description = "Client ID of the \"default\" identity, or null when the account has tiers. Every tier that holds Mail.Send needs its own New-ApplicationAccessPolicy -AppId; identities lists which do."
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
  description = "Map of privilege tier to a map of Graph permission name to app role assignment ID."
  value       = { for tier, grants in module.graph_grants : tier => grants.assignment_ids }
}

output "arm_role_assignment_ids" {
  description = "Map of privilege tier to a map of arm_role_assignments key to role assignment resource ID."
  value       = { for tier, assignments in module.arm_role_assignments : tier => assignments.assignment_ids }
}

output "arm_role_assignment_conditions" {
  description = "Map of privilege tier to a map of arm_role_assignments key to the ABAC condition as sent, with the principal and role tokens replaced. Null where an entry has no condition."
  value       = { for tier, assignments in module.arm_role_assignments : tier => assignments.conditions }
}

output "backup_storage" {
  description = "Backup storage account and container names, the container's RBAC scope, and the tiers allowed to write in it, or null when backup_storage is not set."
  value = var.backup_storage == null ? null : {
    storage_account_id   = module.backup_storage[0].storage_account_id
    storage_account_name = module.backup_storage[0].storage_account_name
    container_name       = module.backup_storage[0].container_name
    container_scope      = module.backup_storage[0].container_scope
    writer_tiers         = sort(tolist(local.backup_writer_tiers))
  }
}
