# AWS commercial partition, account example-prod: payments-api app stack cell.
#
# Values only, and few of them: the stack derives every name from app_name
# (its default, payments-api) and environment, so this cell says which
# deployment this is, how long its logs are kept, and how it is tagged. No
# region (partition.hcl supplies us-east-1), no account id (../account.hcl
# addresses the cell and the stack discovers it), no ARN, no name that any
# other resource repeats. See docs/adr/0017 for why this is an app stack
# rather than three catalog entries, and stacks/apps/aws/payments-api for
# what it creates: the two ECS task roles, a key, the artifacts bucket, an
# encrypted log group, and the parameter namespace /payments-api/prod/.
#
# Application and Environment tags are set by the stack from the names and
# are refused here, so the tags cannot disagree with the names.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/payments-api/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/apps/aws/payments-api"
}

inputs = {
  environment        = "prod"
  log_retention_days = 365

  tags = {
    owner       = "payments"
    cost_centre = "cc-3333"
  }
}
