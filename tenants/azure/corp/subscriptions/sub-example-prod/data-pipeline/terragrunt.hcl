# Azure corp tenant, subscription sub-example-prod: data-pipeline app stack cell.
#
# Values only. The stack derives every name from app_name and environment
# (rg-sales-etl-prod, id-sales-etl-prod, kv-sales-etl-prod, stsalesetlprod
# with the containers raw and curated) and wires the identity to the vault,
# to each container, and to the group itself, so this cell says which
# pipeline, where, from which repository, and where the audit logs go. No
# subscription id (../subscription.hcl addresses the cell), no tenant id
# (ARM_TENANT_ID), no principal id, no resource id. See docs/adr/0017 for
# why this is an app stack and stacks/apps/azure/data-pipeline for what it
# creates and what the identity may do.
#
# allowed_ip_ranges opens the vault and the lake to exactly that block, the
# NAT address of the self-hosted runners the pipeline's jobs run on, behind
# a Deny default. GitHub-hosted runners have no fixed address and would
# reach neither, which is the intended outcome, not a reason to open either.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-prod/data-pipeline/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/apps/azure/data-pipeline"
}

# Ordering only. The vault and the lake audit to the Log Analytics workspace
# the baseline cell creates, named below and resolved by name; no outputs
# are read from that cell. See docs/adr/0005.
dependencies {
  paths = ["../azure-subscription-baseline"]
}

inputs = {
  app_name    = "sales-etl"
  environment = "prod"
  location    = "eastus"

  github_organization = "example-org"
  github_repository   = "sales-etl"

  log_analytics_workspace = {
    name                = "law-example-prod-activity"
    resource_group_name = "rg-example-baseline"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  tags = {
    owner = "data-platform"
  }
}
