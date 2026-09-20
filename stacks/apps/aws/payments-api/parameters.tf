# ---------------------------------------------------------------------------
# The parameter namespace. One SecureString placeholder under the prefix,
# encrypted with the key, whose value the module writes once and never
# manages again. The placeholder must never hold a real value: the
# application's real secrets are siblings under the same prefix, written by
# the secrets process, and this stack neither declares nor reads them, so
# no secret passes through a plan, a cell, or a commit (the module README
# says what a refresh would otherwise put in state). The prefix is the same
# local the task role's policy was rendered from; the parameter_prefix
# output (outputs.tf) carries the check that the two still agree.
# ---------------------------------------------------------------------------

module "parameters" {
  source = "../../../../modules/aws/ssm-parameter-namespace"

  namespaces = {
    app = {
      prefix      = local.parameter_prefix
      description = "Reserves ${local.parameter_prefix}/ for ${local.name_prefix} and proves the key and the roles' grants end to end. Real secrets are siblings of this parameter, written outside Terraform; this value is never a secret."
      kms_key_id  = module.key.keys["app"].key_id
      tags        = local.tags
    }
  }
}
