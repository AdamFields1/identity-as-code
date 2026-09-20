# Azure corp tenant, subscription sub-example-dev: orders-api app stack cell.
#
# Values only. Same stack as ../../../sub-example-prod/apps/orders-api, and
# the first app cell in the dev subscription: this subscription holds the
# baseline and nothing else, so the registry, the vault, and the two
# identities this cell creates are its first workload. Every name is
# derived the same way as in prod, with dev as the segment, so the group is
# rg-orders-api-dev, the identities id-orders-api-dev and
# id-orders-api-dev-publisher, the registry crordersapidev, and the vault
# kv-orders-api-dev, and the runtime identity holds the same two roles
# (AcrPull, Key Vault Secrets User; nothing on the group) that it holds in
# prod. What prod has that dev does not, and why:
#   - the publisher trusts the repository's development environment, not
#     production: the same repository, a different set of protection rules,
#     so a dev image never needs the prod reviewers and a prod image can
#     never come from the dev environment's token
#   - the registry is Standard, not Premium, so it has no retention policy
#     (registry_retention_days is not set; the stack would refuse it on
#     this SKU) and no firewall. Dev builds are frequent and nothing is
#     rolled back to, and the registry's login server is reachable by
#     identity from anywhere on every SKU, so nothing is lost.
#   - no allowed_ip_ranges, so the vault is closed to the public network:
#     with no addresses listed the stack leaves public access off, and only
#     Azure trusted services can reach the vault. The Container Apps
#     environment that will run the application has no fixed egress
#     address in dev; when it does, listing it here is the whole change.
#   - no CanNotDelete lock on the group. A dev registry holds no image
#     anyone ships, and a dev vault holds no secret anyone cannot re-issue;
#     the lock would only make tearing the group down a two-step change.
#     The registry and the vault are still prevent_destroy in their modules.
# Everything else is the stack's and still applies: no admin user and no
# anonymous pull on the registry, RBAC authorization and purge protection
# on the vault, and both audit logs to the workspace the dev baseline cell
# creates, resolved by name.
#
# No subscription id (../../subscription.hcl addresses the cell), no tenant
# id (ARM_TENANT_ID), no principal id, no resource id, no client id. See
# docs/adr/0017 for why this is an app stack and
# stacks/apps/azure/orders-api for what it creates.
#
# application and environment tags are set by the stack from the names and
# a cell's own tags are merged over them, so this cell adds owner and cost
# centre only.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-dev/apps/orders-api/terraform.tfstate

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
  environment = "dev"
  location    = "eastus"

  github_organization          = "example-org"
  github_repository            = "orders-api"
  publisher_github_environment = "development"

  registry_sku = "Standard"

  log_analytics_workspace = {
    name                = "law-example-dev-activity"
    resource_group_name = "rg-example-dev-baseline"
  }

  allowed_ip_ranges = []

  delete_lock = false

  tags = {
    owner       = "orders"
    cost_centre = "cc-4444"
  }
}
