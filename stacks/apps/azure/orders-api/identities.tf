# ---------------------------------------------------------------------------
# The two identities. The runtime identity carries no credential: the
# Container App is assigned it by its own pipeline, and the platform mints
# its tokens. The publisher identity carries exactly one, for the one GitHub
# context that may push an image. The resource group is passed by the same
# name the group was created from: the name is known at plan time, so the
# module can key its lookup on it, while depends_on defers the read itself
# until the group exists.
# ---------------------------------------------------------------------------

module "identities" {
  source = "../../../../modules/azure/managed-identity"

  tags = local.tags

  identities = {
    runtime = {
      name                = local.runtime_identity_name
      resource_group_name = local.resource_group_name
    }

    publisher = {
      name                = local.publisher_identity_name
      resource_group_name = local.resource_group_name

      federated_credentials = {
        github = {
          organization = var.github_organization
          repository   = var.github_repository
          environment  = local.publisher_github_environment
        }
      }
    }
  }

  depends_on = [module.resource_groups]
}
