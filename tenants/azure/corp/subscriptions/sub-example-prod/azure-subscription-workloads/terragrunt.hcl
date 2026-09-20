# Azure corp tenant, subscription sub-example-prod: workloads catalog cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module or an app stack
# (docs/adr/0017), never in a looser entry here.
#
# The subscription is the tree, not a value: ../subscription.hcl addresses
# this cell through tenants/azure/root.hcl, and the tenant comes from
# ARM_TENANT_ID. Nothing below is a GUID or a resource ID: a resource group
# is named by its key, an identity by its key, an Entra group by display
# name, and the workspace by its name in its group.
#
# What this cell holds: one resource group; one identity the example
# application's GitHub workflow runs as, trusted from that repository's prod
# environment and nothing else; one vault the identity reads secrets from;
# one storage account with one container the identity publishes releases
# into and the engineers read. The vault and the account audit to the
# workspace ../azure-subscription-baseline creates, named here and resolved
# by name.
#
# The cell is written as fragments so it reads like the portal: one file
# per map, each holding an inputs attribute with that map and nothing else,
# and each brought in by a labeled include below whose path is the bare
# file name. Terragrunt merges every include's inputs with the ones here
# into one map, so the stack sees exactly what a single inputs block would
# have given it. This file keeps what is cell-wide (the location, the tags)
# and the wiring; an entry is added or changed in the fragment that holds
# its map. A fragment is not a cell: it has no include of its own, no
# source, and Terragrunt never runs it.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-prod/azure-subscription-workloads/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Fragments. One per map the cell sets, in the order the stack composes
# them: groups first, then the identities that live in them, then the
# vaults and the accounts that grant roles to those identities.
include "resource_groups" {
  path = "resource-groups.hcl"
}

include "managed_identities" {
  path = "managed-identities.hcl"
}

include "key_vaults" {
  path = "key-vaults.hcl"
}

include "storage_accounts" {
  path = "storage-accounts.hcl"
}

terraform {
  source = "../../../../../../stacks/azure-subscription-workloads"
}

# Ordering only. The vault and the storage account name the Log Analytics
# workspace the baseline cell creates, resolved by name (at plan time once
# the resource group exists; on the first plan the lookup is deferred to
# apply with the group's). No outputs are read from that cell. This block
# makes `terragrunt run --all` apply the baseline first, and the release
# workflow orders the jobs the same way. See docs/adr/0005.
dependencies {
  paths = ["../azure-subscription-baseline"]
}

# Cell-wide values. Every map lives in its fragment.
inputs = {
  location = "eastus"

  tags = {
    owner = "example-app"
  }
}
