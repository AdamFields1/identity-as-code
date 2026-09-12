output "directory_role_eligibility_ids" {
  description = "Map of logical key to directory role eligibility schedule request ID."
  value       = { for k, r in azuread_directory_role_eligibility_schedule_request.this : k => r.id }
}

output "group_eligibility_ids" {
  description = "Map of logical key to PIM group eligibility schedule ID."
  value       = { for k, s in azuread_privileged_access_group_eligibility_schedule.this : k => s.id }
}

output "role_template_ids" {
  description = "Map of directory role display name to role template ID for every role referenced."
  value = {
    for name in distinct([for e in var.directory_role_eligibilities : e.role_display_name]) :
    name => local.role_template_ids[name]
  }
}
