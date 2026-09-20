# Azure corp tenant, subscription sub-example-prod: orders-api app stack cell.
#
# Values only. The stack derives every name from app_name (its default,
# orders-api) and environment (rg-orders-api-prod, id-orders-api-prod,
# id-orders-api-prod-publisher, crordersapiprod, kv-orders-api-prod) and
# wires the runtime identity to the registry (AcrPull) and to the vault (Key
# Vault Secrets User), and the publisher identity to the registry (AcrPush),
# nothing to the group, so this cell says which deployment
# this is, where, which GitHub repository's pipeline may publish the image,
# what the registry keeps, who may reach the two data planes, and where the
# audit logs go. No subscription id (../subscription.hcl addresses the
# cell), no tenant id (ARM_TENANT_ID), no principal id, no resource id, no
# client id. See docs/adr/0017 for why this is an app stack and
# stacks/apps/azure/orders-api for what it creates and what each identity
# may do. There is no storage account; the application's artifact is its
# image, which is what distinguishes this cell from the data-pipeline cell
# beside it.
#
# The publisher identity trusts one GitHub environment of one repository,
# example-org/orders-api's production environment, so a prod image can only
# be pushed by a job that passed that environment's protection rules. The
# repository is named as two values, not one "org/repo" string, because the
# stack checks each half against GitHub's own naming rules before the
# federated credential's subject is built.
#
# Premium is the SKU because it is the only one Azure sells the registry
# firewall and the untagged-manifest retention policy on: the release
# workflow pushes the same tag again on every hotfix, and seven days is long
# enough to roll back to the manifest it replaced. allowed_ip_ranges opens
# the vault and the registry to exactly that block, the NAT address of the
# self-hosted runners the release jobs run on, behind a Deny default.
# GitHub-hosted runners have no fixed address and would reach neither, which
# is the intended outcome, not a reason to open either.
#
# application and environment tags are set by the stack from the names and
# a cell's own tags are merged over them, so this cell adds owner and cost
# centre only.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-prod/apps/orders-api/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../../stacks/apps/azure/orders-api"
}

# Ordering only. The registry and the vault audit to the Log Analytics
# workspace the baseline cell creates, named below and resolved by name; no
# outputs are read from that cell. See docs/adr/0005.
dependencies {
  paths = ["../../azure-subscription-baseline"]
}

inputs = {
  environment = "prod"
  location    = "eastus"

  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "production"

  registry_sku            = "Premium"
  registry_retention_days = 7

  log_analytics_workspace = {
    name                = "law-example-prod-activity"
    resource_group_name = "rg-example-baseline"
  }

  allowed_ip_ranges = ["203.0.113.0/24"]

  delete_lock = true

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
