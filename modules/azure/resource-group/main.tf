# Resource groups, one per map entry, each with an optional CanNotDelete lock.
#
# A resource group is the container every other catalog shape sits in, and
# the one Azure object whose deletion takes everything inside it along. This
# module therefore does two things and nothing else: it creates the groups a
# cell names, and it refuses to let them go quietly.
#
#   - prevent_destroy on every group. Removing an entry from a cell, or
#     changing an immutable attribute (name, location), would otherwise plan
#     the group's deletion together with every resource in it, managed here
#     or not. Retiring a group is a deliberate change that lifts the flag in
#     this module first, in its own pull request, so the plan that deletes it
#     is obviously about deleting it.
#   - An optional CanNotDelete management lock, behind a bool. The flag
#     protects against Terraform; the lock protects against everyone else:
#     while it exists, the portal, the CLI, and any Terraform plan (this
#     cell's or another's) are refused when they try to delete the group or
#     anything in it. Reads and writes are unaffected, which is why the lock
#     level is CanNotDelete and never ReadOnly (a ReadOnly lock breaks
#     ordinary operations such as listing storage keys and reading role
#     assignments, and would stop the other catalog stacks from planning).
#
# Turning delete_lock off removes the lock, and only the lock, in the plan
# that does it. Do that in one change and delete what the lock protected in
# the next: Terraform orders the lock's removal after the group's creation,
# not before another module's deletions, so a lock removed and a resource
# deleted in the same plan can still fail on the delete.
#
# Nothing here is looked up. A resource group has no dependency on any
# other resource, so this is the one module under modules/azure that reads
# no data source.

resource "azurerm_resource_group" "this" {
  for_each = var.resource_groups

  name     = each.value.name
  location = each.value.location
  tags     = merge(var.tags, each.value.tags)

  lifecycle {
    # Deleting a resource group deletes every resource in it, including
    # ones managed by other cells or by nobody. Removing an entry from a
    # cell must never be able to do that as a side effect; retiring a group
    # is a change that lifts this flag first.
    prevent_destroy = true
  }
}

resource "azurerm_management_lock" "delete" {
  for_each = { for key, rg in var.resource_groups : key => rg if rg.delete_lock }

  name       = "do-not-delete"
  scope      = azurerm_resource_group.this[each.key].id
  lock_level = "CanNotDelete"
  notes      = each.value.lock_notes
}
