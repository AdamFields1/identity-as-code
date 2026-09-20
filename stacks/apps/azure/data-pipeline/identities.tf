# ---------------------------------------------------------------------------
# The identity and the one GitHub context that may obtain a token for it.
# The resource group is passed by the same name the group was created from:
# the name is known at plan time, so the module can key its lookup on it,
# while depends_on defers the read itself until the group exists.
# ---------------------------------------------------------------------------

module "identities" {
  source = "../../../../modules/azure/managed-identity"

  tags = local.tags

  identities = {
    pipeline = {
      name                = local.identity_name
      resource_group_name = local.resource_group_name

      federated_credentials = {
        github = {
          organization = var.github_organization
          repository   = var.github_repository
          environment  = local.github_environment
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}
