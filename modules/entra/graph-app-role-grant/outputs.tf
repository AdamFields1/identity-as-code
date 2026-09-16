output "assignment_ids" {
  description = "Map of app role name to app role assignment ID."
  value       = { for name, a in azuread_app_role_assignment.this : name => a.id }
}

output "principal_object_id" {
  description = "Object ID of the service principal the roles were granted to."
  value       = local.principal_object_id
}

output "graph_service_principal_object_id" {
  description = "Object ID of the Microsoft Graph service principal in this tenant, the resource side of every assignment."
  value       = data.azuread_service_principal.graph.object_id
}
