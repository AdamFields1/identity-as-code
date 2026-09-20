output "container_registries" {
  description = "Map of logical key to { id, name, login_server, sku, resource_group_name, location, public_network_access_enabled, diagnostics }."
  value = {
    for key, cr in azurerm_container_registry.this : key => {
      id                            = cr.id
      name                          = cr.name
      login_server                  = cr.login_server
      sku                           = cr.sku
      resource_group_name           = cr.resource_group_name
      location                      = cr.location
      public_network_access_enabled = cr.public_network_access_enabled
      diagnostics                   = contains(keys(azurerm_monitor_diagnostic_setting.this), key)
    }
  }
}

output "container_registry_ids" {
  description = "Map of logical key to registry resource ID, the scope of every role assignment on it."
  value       = { for key, cr in azurerm_container_registry.this : key => cr.id }
}

output "login_servers" {
  description = "Map of logical key to the registry's login server (<name>.azurecr.io), what an image reference and a docker login name."
  value       = { for key, cr in azurerm_container_registry.this : key => cr.login_server }
}

output "login_servers_by_name" {
  description = "Map of registry name to login server, for a consumer that knows the registry by its visible name rather than its key."
  value       = { for key, cr in azurerm_container_registry.this : cr.name => cr.login_server }
}

output "role_assignment_ids" {
  description = "Map of \"<registry key>/<assignment key>\" to the role assignment's resource ID."
  value       = { for key, a in azurerm_role_assignment.this : key => a.id }
}

output "role_assignments" {
  description = "Map of \"<registry key>/<assignment key>\" to { registry_key, role_name, principal_type, principal_name, principal_id }: what was granted to whom, resolved."
  value = {
    for key, a in azurerm_role_assignment.this : key => {
      registry_key   = local.role_assignments[key].registry_key
      role_name      = local.role_assignments[key].role_name
      principal_type = local.role_assignments[key].principal_type
      principal_name = local.role_assignments[key].principal_name
      principal_id   = a.principal_id
    }
  }
}

output "diagnostic_setting_ids" {
  description = "Map of logical key to the diagnostic setting's resource ID, for the registries that name a workspace."
  value       = { for key, d in azurerm_monitor_diagnostic_setting.this : key => d.id }
}

output "group_object_ids" {
  description = "Map of Entra group display name to object ID, for every group a role assignment named."
  value       = { for name, g in data.azuread_group.by_display_name : name => g.object_id }
}
