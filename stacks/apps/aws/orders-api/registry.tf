# ---------------------------------------------------------------------------
# The registry. One repository, encrypted with the key by ARN, with the
# execution role allowed to pull and the publisher allowed to push (push
# includes pull; nobody may delete). The module builds the principal ARNs
# from names and looks nothing up, but ECR validates every principal when
# the repository policy is written, so the names are taken from the roles
# module's output for the same reason the key does it: the reference makes
# Terraform create the roles first, and the policy document is still shown
# in full at plan. The key's ARN comes from the key module's output, which
# is also what orders the key before the repository. The check that the
# registry and the log group are under the same key is on the
# log_group_name output (outputs.tf).
# ---------------------------------------------------------------------------

module "registry" {
  source = "../../../../modules/aws/ecr-repository"

  repositories = {
    app = {
      name                 = local.repository_name
      kms_key_arn          = module.key.keys["app"].arn
      keep_tagged_count    = var.image_retention_count
      untagged_expiry_days = var.untagged_image_expiry_days
      pull_role_names      = [module.roles.roles["execution"].name]
      push_role_names      = [module.roles.roles["publisher"].name]
      tags                 = local.tags
    }
  }
}
