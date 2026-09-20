# ---------------------------------------------------------------------------
# The log group. Encrypted with the key, which works only because the key
# policy names the CloudWatch Logs service principal for log groups in this
# account and region (service_users = ["logs"] above); a key without that
# statement is refused by the API when the log group is created. The module
# takes the key's ARN from the key module's output, which is also what
# orders the key before the group.
# ---------------------------------------------------------------------------

module "log_group" {
  source = "../../../../modules/aws/log-group"

  log_groups = {
    app = {
      name              = local.log_group_name
      retention_in_days = var.log_retention_days
      kms_key_arn       = module.key.keys["app"].arn
      tags              = local.tags
    }
  }
}
