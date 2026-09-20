# ---------------------------------------------------------------------------
# The bucket. Encrypted with the key by alias and restricted to the task
# role by name, both of which the bucket module resolves with data sources
# at plan time. In this stack both are created in the same plan, so the
# module must wait for them: depends_on defers every lookup in the module
# to apply whenever the key or the roles have pending changes. The cost is
# stated in the README: on the first plan, and on any plan that changes
# the key or a role, the bucket's encryption and policy show as known
# after apply rather than as the values they will have.
# ---------------------------------------------------------------------------

module "artifacts" {
  source = "../../../../modules/aws/s3-bucket"

  buckets = {
    artifacts = {
      name               = local.bucket_name
      kms_key_alias      = local.key_alias
      allowed_role_names = [local.task_role_name]
      tags               = local.tags
    }
  }

  depends_on = [module.key, module.roles]
}
