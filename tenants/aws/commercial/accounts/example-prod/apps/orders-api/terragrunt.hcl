# AWS commercial partition, account example-prod: orders-api app stack cell.
#
# Values only, and few of them: the stack derives every name from app_name
# (its default, orders-api) and environment, so this cell says which
# deployment this is, which GitHub repository's pipeline may publish the
# image, how much the registry and the log group keep, and how it is
# tagged. No region (partition.hcl supplies us-east-1), no account id
# (../account.hcl addresses the cell and the stack discovers it), no ARN,
# no name that any other resource repeats. See docs/adr/0017 for why this
# is an app stack rather than five catalog entries, and
# stacks/apps/aws/orders-api for what it creates: the two ECS task roles
# and the image publisher role, a key, the image repository, an encrypted
# log group, and the parameter namespace /orders-api/prod/. There is no
# bucket; the application's artifact is its image.
#
# The one resource this cell names that it does not own is the reference
# data bucket, and the direction of that reference is the rule: an app cell
# may name a catalog resource, because the catalog
# (../../aws-account-workloads) is applied in the wave before the app
# stacks, but a catalog entry never names a role an app stack creates,
# because on the first release the catalog is applied before that role
# exists and the allow list would refuse. Dev reads no reference data, so
# the dev cell does not set the knob and the stack grants nothing.
#
# The publisher role trusts one GitHub environment of one repository,
# example-org/orders-api's production environment, so a prod image can only
# be pushed by a job that passed that environment's protection rules
# (required reviewers, and the deployment-branch rule that limits it to
# main). No branch is trusted on its own: a token carries the ref or the
# environment, never both, so a branch subject would bypass the environment
# rather than add to it. The environment is named here because GitHub calls
# it production and the deployment is called prod. The repository is named
# as two values, not one "org/repo" string, because the stack checks each
# half against GitHub's own naming rules before the trust is built.
#
# Application and Environment tags are set by the stack from the names and
# are refused here, so the tags cannot disagree with the names.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/apps/orders-api/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/aws/orders-api"
}

inputs = {
  environment                  = "prod"
  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "production"
  image_retention_count        = 30
  untagged_image_expiry_days   = 7
  log_retention_days           = 365

  # A name, not an ARN: the stack builds the bucket ARN from the partition
  # it discovers, so nothing is looked up and no dependency is declared. The
  # bucket is the catalog's (../../aws-account-workloads, entry
  # reference-data, owned by data-platform), applied in the wave before this
  # cell. The task role gains ListBucket on it and GetObject and
  # GetObjectVersion on its objects; nothing else here changes.
  reference_bucket_names = ["example-prod-reference-data"]

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
