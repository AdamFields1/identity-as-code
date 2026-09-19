# CloudTrail trails, keyed by the caller's logical name.
#
# A trail is the account's audit log, and everything that would make it less
# than that is fixed: every region (a single-region trail misses the API
# calls an attacker makes elsewhere), global service events (IAM, STS, and
# CloudFront, logged once through the trail's home region), log file
# validation (a signed digest chain that shows whether a log file was changed
# after delivery), and logging started. Organization trails are a different
# shape (management account, an AWSLogs/<org id>/ path in the bucket) and
# are not offered.
#
# What varies is where the trail writes and under which key, and both come
# from the stack that composes this module as a bucket name and a key ARN.
# The bucket's policy and the key's policy must already name the trail when
# it is created: CloudTrail checks both at CreateTrail and refuses
# (InsufficientS3BucketPolicyException, InsufficientEncryptionPolicyException)
# rather than delivering nothing later. That ordering is the composing
# stack's job, with depends_on on the bucket and key modules; this module
# has no data sources, so being depended on costs it nothing.
#
# Deliberately not here: CloudWatch Logs delivery (a log group and a role
# CloudTrail can assume, a composition of its own), SNS notification (names
# a topic), data events and Insights (application choices with their own
# cost). Each is a checkov skip on the resource with the same reason.
#
# No prevent_destroy: the trail itself holds nothing. Its log files live in
# the bucket, which does, and the bucket module refuses to destroy it.

locals {
  # The two event sources CloudTrail allows a trail to exclude, as the API
  # names them; the strings are the same in every partition. Null rather
  # than an empty set when nothing is excluded, so the plan matches what
  # CloudTrail reports back.
  excluded_sources = {
    for key, t in var.trails : key => concat(
      t.management_events.exclude_kms_events ? ["kms.amazonaws.com"] : [],
      t.management_events.exclude_rds_data_api_events ? ["rdsdata.amazonaws.com"] : [],
    )
  }
}

resource "aws_cloudtrail" "this" {
  # checkov:skip=CKV2_AWS_10:CloudWatch Logs delivery needs a log group and a
  # role CloudTrail can assume with logs:PutLogEvents on it. That is a
  # composition of its own, not a knob on the trail (docs/adr/0017).
  # checkov:skip=CKV_AWS_252:SNS notification of log file delivery names a
  # topic, which is cross-resource wiring this module does not express.
  for_each = var.trails

  name           = each.value.name
  s3_bucket_name = each.value.s3_bucket_name
  s3_key_prefix  = each.value.s3_key_prefix
  kms_key_id     = each.value.kms_key_arn
  tags           = each.value.tags

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true
  is_organization_trail         = false

  event_selector {
    read_write_type           = each.value.management_events.read_write_type
    include_management_events = true

    exclude_management_event_sources = length(local.excluded_sources[each.key]) > 0 ? local.excluded_sources[each.key] : null
  }
}
