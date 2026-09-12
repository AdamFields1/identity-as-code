# azure-rbac-roles stack
#
# One deployable unit that owns the custom role definitions for a tenant. It
# composes a single module on purpose: role definitions are the slow-moving
# vocabulary that PIM policies and eligibilities in the azure-pim-governance
# stack refer to by name, and they belong in their own state file with their
# own blast radius. See docs/adr/0005 for the reasoning behind the split.
#
# Tenant cells (tenants/azure/<tenant>/azure-rbac-roles/terragrunt.hcl) supply
# values only. The module resolves every scope by name, so no cell ever holds a
# management group ID or a subscription GUID.
#
# Deliberately NOT managed here: role assignments of any kind, PIM policies,
# built-in role definitions (read-only by nature), and the management group
# hierarchy itself.

module "custom_roles" {
  source = "../../modules/azure/rbac-role-definition"

  roles = var.custom_roles
}
