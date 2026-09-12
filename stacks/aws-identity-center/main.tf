# aws-identity-center stack
#
# One deployable unit for one IAM Identity Center instance. Order of dependency:
#
#   permission sets  -->  account assignments
#   (what a role is)      (one per convention-named group)
#
# The two must land together. An assignment references a permission set ARN, so
# the set exists before the assignment is written, and removing a set removes
# its assignments in the same plan rather than leaving Identity Center with a
# provisioned role nobody can see in code. One state file means one plan shows
# the whole access posture of the instance: every set, every policy on it, every
# group that can use it, in every account.
#
# Groups are named AWS-<PARTITION>-<accountId>-<PermissionSetName>. The name is
# the assignment: the account-assignment module parses it, checks the partition
# against the one the provider is talking to, checks the permission set against
# the ones defined here, and resolves the group in the identity store. A cell
# therefore holds permission set definitions and a list of group names, and
# nothing else. See docs/adr/0008.
#
# Tenant cells (tenants/aws/<partition>/aws-identity-center/terragrunt.hcl)
# supply values only. The instance, the identity store, the partition, and the
# groups are all discovered or resolved by name inside the modules and never
# typed into a cell. The same cell shape deploys to the commercial partition
# and to GovCloud; only the region and the values differ.
#
# Deliberately NOT managed here: users and groups in the identity store (SCIM
# from Entra ID owns them, see stacks/entra-aws-federation), the identity
# source configuration itself (a console step, see docs/adr/0008), the
# organization and its accounts, and the customer managed policies that
# permission sets reference by name (account baseline code owns those).

module "permission_sets" {
  source = "../../modules/aws/permission-set"

  permission_sets = var.permission_sets
}

module "account_assignments" {
  source = "../../modules/aws/account-assignment"

  permission_set_arns_by_name = module.permission_sets.permission_set_arns_by_name
  group_display_names         = var.group_display_names

  depends_on = [module.permission_sets]
}
