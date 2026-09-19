output "resource_groups" {
  description = "Map of logical key to { id, name, location, locked }."
  value = {
    for key, rg in azurerm_resource_group.this : key => {
      id       = rg.id
      name     = rg.name
      location = rg.location
      locked   = contains(keys(azurerm_management_lock.delete), key)
    }
  }
}

output "resource_group_ids" {
  description = "Map of logical key to resource group ID, the scope of a role assignment or a lock."
  value       = { for key, rg in azurerm_resource_group.this : key => rg.id }
}

output "resource_group_names" {
  description = "Map of logical key to resource group name, for the modules that look a group up by name."
  value       = { for key, rg in azurerm_resource_group.this : key => rg.name }
}

output "lock_ids" {
  description = "Map of logical key to the CanNotDelete lock's resource ID, for the entries that have delete_lock set."
  value       = { for key, lock in azurerm_management_lock.delete : key => lock.id }
}
