# ---------------------------------------------------------------------------
# The key. The task and execution roles are users; CloudWatch Logs is a
# service user so the log group below can be encrypted with it. The
# publisher is not a user: ECR encrypts and decrypts layers under the grant
# it creates for the repository's creator, so a role that pushes needs
# nothing on the key. The role ARNs are constructed by the module, not
# looked up, so naming roles created in the same plan is allowed, but KMS
# checks they exist when the policy is written. The names are therefore
# taken from the roles module's output rather than from the locals that fed
# it: the values are the same, and the reference is what makes Terraform
# create the roles before the key. It is a reference and not a depends_on
# on purpose: a reference through a module output orders the resources
# without deferring the key policy's document to apply, so a plan shows the
# full policy.
# ---------------------------------------------------------------------------

module "key" {
  source = "../../../../modules/aws/kms-key"

  keys = {
    app = {
      alias           = local.key_alias
      description     = "Encrypts the ${local.name_prefix} image repository, log group, and parameters."
      user_role_names = [module.roles.roles["task"].name, module.roles.roles["execution"].name]
      service_users   = ["logs"]
      tags            = local.tags
    }
  }
}
