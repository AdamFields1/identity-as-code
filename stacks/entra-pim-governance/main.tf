# entra-pim-governance stack
#
# One deployable unit for privileged access in a tenant. Order of dependency:
#
#   role-assignable groups  -->  role management policies (activation rules)
#                           -->  eligibilities (group -> directory role,
#                                               person -> group)
#
# The three layers must land together. A policy cannot exist before its group,
# and an eligibility granted before the policy is in place would activate under
# Entra's permissive defaults (eight hours, no MFA, no approval) until the next
# apply. depends_on between the modules makes Terraform sequence them, and one
# state file means one plan shows the whole privileged-access posture.
#
# Every group here is role-assignable, and membership is never listed in values:
# PIM activation writes it, and Terraform leaves it alone (the security-group
# module sends null members when nothing is listed).
#
# Tenant cells (tenants/azure/<tenant>/entra-pim-governance/terragrunt.hcl)
# supply values only. Approver groups and eligible principals are looked up by
# name and never created here.
#
# Deliberately NOT managed here: the directory role activation policies for
# roles assigned directly to users (there should be none), and the break-glass
# accounts, which hold Global Administrator permanently and outside PIM by
# design.

module "privileged_groups" {
  source = "../../modules/entra/security-group"

  groups = {
    for k, g in var.privileged_groups : k => {
      display_name       = g.display_name
      description        = g.description
      assignable_to_role = true
      owners             = g.owners
    }
  }
}

module "role_policies" {
  source = "../../modules/entra/pim-role-policy"

  policies = var.role_policies

  depends_on = [module.privileged_groups]
}

module "eligibility" {
  source = "../../modules/entra/pim-eligibility"

  directory_role_eligibilities = var.directory_role_eligibilities
  group_eligibilities          = var.group_eligibilities

  depends_on = [module.role_policies]
}
