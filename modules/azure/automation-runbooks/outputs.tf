output "runbook_ids" {
  description = "Map of runbook key to runbook resource ID."
  value       = { for k, r in azurerm_automation_runbook.this : k => r.id }
}

output "runbook_names" {
  description = "Map of runbook key to the runbook name in the account."
  value       = { for k, r in azurerm_automation_runbook.this : k => r.name }
}

output "content_hashes" {
  description = "Map of runbook key to the SHA-256 of the published content (the file, with any library inlined), the same value carried in the content_sha256 tag."
  value       = { for k in keys(var.runbooks) : k => sha256(local.runbook_content[k]) }
}

output "schedule_ids" {
  description = "Map of schedule key to schedule resource ID."
  value       = { for k, s in azurerm_automation_schedule.this : k => s.id }
}

output "job_schedule_ids" {
  description = "Map of job schedule key to the job schedule resource ID."
  value       = { for k, j in azurerm_automation_job_schedule.this : k => j.id }
}
