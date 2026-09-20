# AWS commercial partition, account example-dev: orders-api app stack cell.
#
# Values only. Same stack as ../../../example-prod/apps/orders-api, and the
# first app cell in the dev account: until now this account held only the
# baseline and the workloads catalog, and the example application's
# instances got their role from the catalog. This cell is the other kind of
# workload, a container, and it lands in the app wave after the catalog.
# Every name is derived the same way as in prod, with dev as the segment,
# so the roles are orders-api-dev-task, orders-api-dev-task-execution, and
# orders-api-dev-image-publisher, and the namespace is /orders-api/dev/.
# What prod has that dev does not, and why:
#   - the publisher trusts the repository's development environment, not
#     production: the same repository, a different set of protection rules,
#     so a dev image never needs the prod reviewers and a prod image can
#     never come from the dev environment's token. The trust is that one
#     environment's subject and nothing else; no branch is trusted, so a
#     job outside the environment cannot assume either publisher role
#   - the registry keeps 10 images and expires untagged layers after 3
#     days, not 30 and 7: dev builds are frequent and nothing is rolled
#     back to
#   - logs are kept 30 days, not 365
# Everything else is the stack's and still applies: immutable tags, scanning
# on push, the customer managed key on the repository, on the log group, and
# on the placeholder parameter, and the parameter namespace itself.
#
# The account and the partition are the tree, not values: ../../account.hcl
# and ../../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). See docs/adr/0017.
#
# Application and Environment tags are set by the stack from the names and
# are refused here, so the tags cannot disagree with the names.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-dev/apps/orders-api/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/aws/orders-api"
}

inputs = {
  environment                  = "dev"
  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "development"
  image_retention_count        = 10
  untagged_image_expiry_days   = 3
  log_retention_days           = 30

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
