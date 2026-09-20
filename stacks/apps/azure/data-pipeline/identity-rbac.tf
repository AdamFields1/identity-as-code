# ---------------------------------------------------------------------------
# Reader on the group, so the identity can resolve the vault and the account
# through the management plane before it talks to either data plane. The
# scope is the group's ID from the module above (the resource_id scope type
# exists for exactly this: a resource created in the same plan), so the cell
# holds no ID and the assignment cannot point anywhere else.
# ---------------------------------------------------------------------------

module "identity_rbac" {
  source = "../../../../modules/azure/workload-role-assignment"

  principal_id = module.identities.principal_ids["pipeline"]

  assignments = {
    reader-on-resource-group = {
      role_name   = "Reader"
      scope       = { type = "resource_id", name = module.resource_groups.resource_group_ids["app"] }
      description = "The ${var.app_name} pipeline resolves its vault and its lake through the management plane. Read only, no data action."
    }
  }
}
