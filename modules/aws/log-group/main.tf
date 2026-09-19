# CloudWatch Logs log groups, keyed by the caller's logical name.
#
# A log group is a workload's record of what it did, and the two things that
# decide how long that record lasts are bounded here rather than left to the
# API's defaults: retention is one of the values CloudWatch Logs accepts and
# never "never expire" (a group that keeps everything forever is a cost and a
# records-retention decision, and the longest value the API offers, ten
# years, is available), and every group is prevent_destroy, because deleting
# a group deletes every event in it before its retention would have.
#
# Encryption is a customer managed key, named by ARN, and it is required:
# a group under the service's own key has no key policy anyone reviews. The
# key's policy must let the CloudWatch Logs service principal use it for log
# groups in this account and region (modules/aws/kms-key, service_users =
# ["logs"]); CloudWatch Logs checks that when the key is associated and
# refuses otherwise, which is the honest failure and why a stack that
# composes the two hands this module the key module's output. It is an ARN
# and not an alias for the same reason modules/aws/cloudtrail takes one:
# the API stores and reports the key ARN, and an alias here would plan a
# change on every run.
#
# Nothing is looked up. A log group depends on nothing but the key it
# names, so this module reads no data source.

resource "aws_cloudwatch_log_group" "this" {
  # checkov:skip=CKV_AWS_338:Retention is a value the cell sets from its own
  # records-retention decision. The module refuses "never expire" and offers
  # every value CloudWatch Logs accepts up to ten years; a year is one of
  # them, not the floor.
  for_each = var.log_groups

  name              = each.value.name
  retention_in_days = each.value.retention_in_days
  kms_key_id        = each.value.kms_key_arn
  tags              = each.value.tags

  lifecycle {
    # The events are the workload's record of what it did; retention bounds
    # how long they are kept, and deleting the group deletes them early.
    # Retiring a workload is a deliberate change that flips this flag first,
    # never a side effect of removing an entry from a map. A name change is
    # a replacement and is refused for the same reason.
    prevent_destroy = true
  }
}
