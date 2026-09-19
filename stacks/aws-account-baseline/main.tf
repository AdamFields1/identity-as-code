# aws-account-baseline stack
#
# One deployable unit for the hardening every account gets, planned once per
# account into that account's own state file
# (tenants/aws/<partition>/accounts/<account-name>/aws-account-baseline,
# docs/adr/0017). Two halves:
#
#   account-hardening   the switches: password policy, EBS encryption by
#                       default, S3 Block Public Access, GuardDuty, Access
#                       Analyzer. Independent of each other and of the trail.
#
#   the trail           three modules in a fixed order, because CloudTrail
#                       checks the bucket policy and the key policy at
#                       CreateTrail and refuses if either is missing:
#
#                         kms-key  -->  s3-bucket  -->  cloudtrail
#
#                       The key policy names the trail (by name; the module
#                       builds the ARN). The bucket is encrypted with the key
#                       and its policy names the trail the same way. The trail
#                       then names the bucket and the key's ARN.
#
# The bucket module resolves kms_key_alias with a data source at plan time,
# and on the first plan of an account the key does not exist yet. The
# depends_on on that module call is what makes this work: Terraform defers
# every data read inside a module that depends on another module with
# pending changes until apply, so the alias is read after the key is
# created. The cost, stated because it is visible: whenever a plan changes
# the key (a tag, a role name, the rotation period), the bucket module's
# reads are deferred again and the bucket policy and encryption settings
# show as "known after apply" in that plan; the apply then writes them
# unchanged. A steady-state plan reads everything at plan time as usual.
#
# The trail module has no data sources, so its depends_on on the bucket and
# key modules costs nothing beyond ordering.
#
# Every entry is keyed "trail" in the key and bucket modules, "access-logs"
# for the optional access log bucket, and "account" in the trail module, so
# the addresses in a plan read as what they are:
# module.trail_key.aws_kms_key.this["trail"],
# module.trail_bucket.aws_s3_bucket.this["trail"],
# module.trail.aws_cloudtrail.this["account"]. When the cell turns the trail
# off, all three maps are empty and the modules manage nothing; turning it
# off after it has been on is refused by prevent_destroy on the bucket and
# the key (see the README).
#
# Tenant cells supply values only. The account, the partition, and the trail
# ARN are discovered inside the modules; the only names a cell types are
# bucket names, the trail name, the key alias, and role names.

locals {
  trail_entries = var.cloudtrail.enabled ? toset(["trail"]) : toset([])

  access_log_entries = var.cloudtrail.enabled && var.cloudtrail.access_log_bucket_name != null ? toset(["access-logs"]) : toset([])

  trail_keys = {
    for k in local.trail_entries : k => {
      alias                    = var.cloudtrail.kms_key_alias
      description              = "Encrypts the log and digest files of the ${var.cloudtrail.trail_name} CloudTrail trail (stacks/aws-account-baseline)."
      administrator_role_names = var.cloudtrail.kms_key_administrator_role_names
      user_role_names          = var.cloudtrail.kms_key_user_role_names
      cloudtrail_trail_names   = [var.cloudtrail.trail_name]
      tags                     = var.tags
    }
  }

  trail_buckets = merge(
    {
      for k in local.trail_entries : k => {
        name            = var.cloudtrail.bucket_name
        kms_key_alias   = var.cloudtrail.kms_key_alias
        expiration_days = var.cloudtrail.log_expiration_days
        cloudtrail_delivery = {
          trail_names = [var.cloudtrail.trail_name]
          prefix      = var.cloudtrail.s3_key_prefix
        }
        access_logging = var.cloudtrail.access_log_bucket_name == null ? null : { target_bucket = "access-logs" }
        tags           = var.tags
      }
    },
    {
      for k in local.access_log_entries : k => {
        name            = var.cloudtrail.access_log_bucket_name
        expiration_days = var.cloudtrail.access_log_expiration_days
        tags            = var.tags
      }
    },
  )

  trails = {
    for k in local.trail_entries : "account" => {
      name           = var.cloudtrail.trail_name
      s3_bucket_name = module.trail_bucket.buckets[k].name
      s3_key_prefix  = var.cloudtrail.s3_key_prefix
      kms_key_arn    = module.trail_key.keys[k].arn
      management_events = {
        read_write_type             = var.cloudtrail.management_events_read_write_type
        exclude_kms_events          = var.cloudtrail.exclude_kms_events
        exclude_rds_data_api_events = var.cloudtrail.exclude_rds_data_api_events
      }
      tags = var.tags
    }
  }
}

module "account_hardening" {
  source = "../../modules/aws/account-hardening"

  password_policy        = var.password_policy
  ebs_encryption         = var.ebs_encryption
  s3_public_access_block = var.s3_public_access_block
  guardduty              = var.guardduty
  access_analyzer        = var.access_analyzer
  tags                   = var.tags
}

module "trail_key" {
  source = "../../modules/aws/kms-key"

  keys = local.trail_keys
}

module "trail_bucket" {
  source = "../../modules/aws/s3-bucket"

  buckets = local.trail_buckets

  # The key must exist before the bucket module looks its alias up. See the
  # header for what this costs in a plan that changes the key.
  depends_on = [module.trail_key]
}

module "trail" {
  source = "../../modules/aws/cloudtrail"

  trails = local.trails

  # CloudTrail checks both policies at CreateTrail; nothing in the trail
  # references the bucket policy or the key policy, so the order is stated.
  depends_on = [module.trail_bucket, module.trail_key]
}
