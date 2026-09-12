# entra-conditional-access stack
#
# One deployable unit for a tenant's Conditional Access baseline. Order of
# dependency inside the module:
#
#   named locations           -->  policies (location conditions)
#   authentication strengths  -->  policies (grant controls)
#
# Tenant cells (tenants/azure/<tenant>/entra-conditional-access/terragrunt.hcl)
# supply values only. Groups, directory roles, and enterprise applications are
# looked up by name and never created here.
#
# Cross-stack references are by name. A policy that scopes to "PIM Global
# Administrators" depends on stacks/entra-pim-governance having created that
# group. Apply pim-governance first; the data source fails clearly otherwise.
#
# Deliberately NOT managed here: the break-glass accounts and their group (the
# group is looked up, never created, so this stack can never destroy it), and
# authentication method policies (a natural next stack).

module "conditional_access" {
  source = "../../modules/entra/conditional-access"

  break_glass_exclusion_group = var.break_glass_exclusion_group
  named_locations             = var.named_locations
  authentication_strengths    = var.authentication_strengths
  policies                    = var.policies
}
