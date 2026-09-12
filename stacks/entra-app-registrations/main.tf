# entra-app-registrations stack
#
# One deployable unit for application onboarding in a tenant. Order of dependency:
#
#   security groups  -->  application registrations
#                         (+ service principals, federated credentials,
#                            enforced Graph grants)
#
# An application lands with the group that will govern access to it, in one plan
# and one state file, so the registration is never assignable to nobody and the
# group is never created for an application that does not exist. Assigning the
# group to the enterprise application is left to the application owner in the
# portal, consistent with the inventory-and-guardrail contract (ADR 0006).
#
# Tenant cells (tenants/azure/<tenant>/entra-app-registrations/terragrunt.hcl)
# supply values only. Users, groups outside this stack, and Microsoft APIs are
# looked up by name inside the modules and never created here.
#
# Deliberately NOT managed here: client secrets (no such resource exists in the
# module), app role assignments of users or groups to applications, and Azure
# RBAC for the service principals (that belongs with the subscription code).

module "security_groups" {
  source = "../../modules/entra/security-group"

  groups = var.security_groups
}

module "app_registrations" {
  source = "../../modules/entra/app-registration"

  applications = var.applications

  depends_on = [module.security_groups]
}
