output "group_ids" {
  description = "Map of logical key to group object ID."
  value       = { for k, g in azuread_group.this : k => g.object_id }
}

output "groups" {
  description = "Map of logical key to { object_id, display_name, assignable_to_role }."
  value = {
    for k, g in azuread_group.this : k => {
      object_id          = g.object_id
      display_name       = g.display_name
      assignable_to_role = g.assignable_to_role
    }
  }
}

output "group_ids_by_display_name" {
  description = "Map of display name to group object ID, for callers that reference groups by name."
  value       = { for k, g in azuread_group.this : g.display_name => g.object_id }
}
