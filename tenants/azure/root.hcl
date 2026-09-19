# Terragrunt root for every Azure tenant cell.
#
# Each tenant directory (corp/, subsidiary/) holds cells at two depths:
#
#   <tenant>/<stack>/                              tenant-wide cells, for example
#                                                  corp/azure-rbac-roles
#   <tenant>/subscriptions/<sub-name>/<stack>/     subscription-scoped cells (docs/adr/0017)
#
# A cell includes this file, points at the shared stack, and supplies values.
# Everything that is the same for every cell lives here: where state goes, how
# the providers are configured, which subscription the azurerm provider is
# pointed at, and which Terraform version is allowed.
#
# Nothing in this file is tenant-specific or subscription-specific, and
# nothing in this file is a secret. Subscription facts come from a locator
# file in the tree (see ADDRESSING below), never from a cell.
#
# ---------------------------------------------------------------------------
# CONTRACT WITH STACKS
#
# The generated provider blocks below reference two Terraform variables. Every
# stack that is deployed through this root MUST declare both:
#
#   variable "tenant_id"       { type = string }
#   variable "subscription_id" { type = string, default = null }
#
# tenant_id is the Entra tenant the providers authenticate to. subscription_id
# is the subscription the azurerm provider defaults to for subscription-scoped
# lookups. Entra-only stacks (app registrations, Conditional Access, PIM for
# groups) may leave subscription_id at null; the azurerm provider then falls
# back to ARM_SUBSCRIPTION_ID, which CI always exports.
#
# Neither value is typed into a cell. Both are identifiers, not secrets, but
# they are also not something a reviewer should be diffing between cells, so
# they arrive through the environment (ARM_TENANT_ID, ARM_SUBSCRIPTION_ID) the
# same way the state backend does, or, for subscription_id under
# subscriptions/<sub-name>/, from that directory's locator. See the inputs
# block at the bottom. A stack that needs the subscription it is running in
# discovers it with data.azurerm_client_config or data.azurerm_subscription.
#
# Stacks own required_providers. This root generates required_version only.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ADDRESSING: which subscription.
#
# One locator file answers that, and a cell never does:
#
#   tenants/azure/<tenant>/subscriptions/<sub-name>/subscription.hcl
#     locals { subscription_id = "11111111-1111-1111-1111-111111111111", subscription_name = "sub-example-prod" }
#
# A locator is not a cell: no include, no source, no inputs, and Terragrunt
# never runs it. It is read here and nowhere else. The tenant is not a
# locator: it is the tree (corp/, subsidiary/) and it still arrives as
# ARM_TENANT_ID, because switching tenants is a different login, not a
# different file.
#
# Evaluation order, because it matters. Terragrunt parses this file as an
# include of the cell, with the cell's own path as the starting point, so
# find_in_parent_folders walks up from the cell directory (its parent first)
# and returns the first subscription.hcl it meets. A cell under
# subscriptions/<sub-name>/ meets it one level up. A tenant-wide cell such as
# corp/azure-rbac-roles meets none: the fallback argument then returns the
# bare file name, read_terragrunt_config's default stands in for the missing
# file with an empty locals object, and every subscription-dependent local
# below collapses to "not a subscription cell", which is the behaviour every
# existing cell had before locators existed.
#
# Layering, from the outside in:
#
#   1. environment        state account and container; ARM_TENANT_ID;
#                         ARM_SUBSCRIPTION_ID. What the runner knows.
#   2. subscription.hcl   subscription id and name. What the tree knows.
#   3. cell inputs        values. What the reviewer diffs.
#
# A subscription cell's azurerm provider is assembled from 1 and 2 and never
# from 3; 2 wins over 1 for the subscription.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Remote state. Azure Storage rather than S3 because the identity that plans
# and applies this tree already lives in Entra, and one identity for both the
# backend and the providers means one federated credential to bootstrap, one
# RBAC assignment to audit, and no cross-cloud trust to explain.
#
# use_azuread_auth = true means the backend authenticates to the blob with
# the same Entra token as everything else. No storage account key is fetched,
# stored, or rotated. The identity needs Storage Blob Data Contributor on the
# container and nothing on the account keys. use_oidc = true is what lets that
# identity be a GitHub federated credential (see docs/adr/0004).
#
# Resource group, storage account, and container come from the environment so
# the same repo can be planned from a laptop, a CI runner, or a different
# subscription without editing HCL. TG_AZ_STATE_RG and TG_AZ_STATE_SA have no
# default on purpose: a missing value fails fast instead of silently using
# local state.
#
# The state key is derived from the cell's path relative to this file, so
# tenants/azure/corp/azure-rbac-roles -> azure/corp/azure-rbac-roles/terraform.tfstate
# and tenants/azure/corp/subscriptions/sub-example-prod/key-vaults ->
# azure/corp/subscriptions/sub-example-prod/key-vaults/terraform.tfstate.
# Adding a cell is a new directory, not a new backend configuration, and the
# subscription locator plays no part in the key.
# ---------------------------------------------------------------------------

locals {
  state_resource_group  = get_env("TG_AZ_STATE_RG")
  state_storage_account = get_env("TG_AZ_STATE_SA")
  state_container       = get_env("TG_AZ_STATE_CONTAINER", "tfstate")

  # Provider identity. See the contract block above.
  tenant_id           = get_env("ARM_TENANT_ID")
  env_subscription_id = get_env("ARM_SUBSCRIPTION_ID", "")

  # Locator. The read returns { locals = {} } when the file is absent, so
  # the try() calls yield "" and nothing below has to know whether the file
  # existed. The fallback name is relative to the cell, where no locator
  # ever sits, which is what makes it a reliable "absent".
  subscription_locator      = find_in_parent_folders("subscription.hcl", "subscription.hcl")
  subscription_locals       = read_terragrunt_config(local.subscription_locator, { locals = {} }).locals
  locator_subscription_id   = try(local.subscription_locals.subscription_id, "")
  locator_subscription_name = try(local.subscription_locals.subscription_name, "")
  subscription_dir          = basename(dirname(local.subscription_locator))

  is_subscription_cell = local.locator_subscription_id != ""

  # Guards. Terragrunt HCL has no precondition block, so each check is a
  # conditional whose failing branch reads an attribute that does not exist
  # on an empty object: the attribute name is the error message, and
  # Terragrunt prints it with this file and line. The passing branch is the
  # value itself. HCL reports only the diagnostics of the branch it takes,
  # so a passing check costs nothing, and Terragrunt evaluates every local
  # whether or not something reads it, so a failing check always fires.
  guard = {}

  checked_subscription_id = !local.is_subscription_cell || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", local.locator_subscription_id)) ? local.locator_subscription_id : local.guard.ERROR_subscription_hcl_subscription_id_must_be_a_lowercase_guid

  checked_subscription_name = !local.is_subscription_cell || local.locator_subscription_name == local.subscription_dir ? local.locator_subscription_name : local.guard.ERROR_subscription_hcl_subscription_name_must_equal_the_name_of_its_directory

  # The subscription the azurerm provider is pointed at. A subscription cell
  # is addressed by its locator and by nothing else; any other cell keeps the
  # environment-driven value, if one is set.
  subscription_id = local.is_subscription_cell ? local.checked_subscription_id : local.env_subscription_id
}

remote_state {
  backend = "azurerm"

  generate = {
    path      = "terragrunt_backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    resource_group_name  = local.state_resource_group
    storage_account_name = local.state_storage_account
    container_name       = local.state_container
    key                  = "azure/${path_relative_to_include()}/terraform.tfstate"

    # Entra token for the blob, federated from GitHub in CI. No account keys.
    use_oidc         = true
    use_azuread_auth = true
  }
}

# ---------------------------------------------------------------------------
# Provider blocks. Both providers authenticate with OIDC. In CI the identity is
# a GitHub OIDC federated credential on a user-assigned managed identity or an
# app registration, never a client secret. The provider reads ARM_CLIENT_ID and
# the GitHub token request variables from the environment on its own, so no
# credential is interpolated into this file, the plan, or state.
#
# Locally, `az login` with ARM_USE_OIDC unset falls back to the Azure CLI
# token, which is the same identity model with a person instead of a workflow.
#
# subscription_id is var.subscription_id in every cell. What changes under
# subscriptions/<sub-name>/ is where the root gets the value: the locator
# rather than ARM_SUBSCRIPTION_ID (see the inputs block). The generated file
# says which, so a reviewer of a plan artifact can tell an addressed cell
# from an environment-driven one.
#
# storage_use_azuread = true mirrors the backend: any storage data-plane call
# the provider makes uses the Entra token, not a listed account key.
#
# resource_provider_registrations = "none" because a governance identity that
# manages roles and PIM has no business registering resource providers on the
# subscription, and the default "core" set would fail on a least-privilege
# identity that cannot write to Microsoft.Resources.
#
# features.storage.data_plane_available = false because every storage
# account this tree manages (modules/azure/storage-account,
# modules/azure/backup-storage) has public network access off or a Deny
# firewall, and the release train applies them from GitHub-hosted runners
# outside every network. In azurerm 4.x the storage account resource still
# reads queue service properties and static website settings through the
# data plane unless this flag is set, and that read fails from such a
# runner with an authorization error right after the create. No module in
# this repository manages queue_properties or static_website, so nothing
# depends on the data plane being reachable, and the flag turns those two
# reads off for every cell at once rather than in each module's README.
# ---------------------------------------------------------------------------

generate "provider" {
  path      = "terragrunt_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "azurerm" {
      features {
        storage {
          # Closed storage accounts are read through the management plane
          # only; the two data-plane blocks this disables (queue properties,
          # static website) are managed by no module here. See the comment
          # above the generate block in tenants/azure/root.hcl.
          data_plane_available = false
        }
      }

      use_oidc        = true
      subscription_id = var.subscription_id
      tenant_id       = var.tenant_id

      storage_use_azuread             = true
      resource_provider_registrations = "none"

      # client_id intentionally not set. The provider reads ARM_CLIENT_ID from
      # the environment. See docs/adr/0004-azure-storage-state-with-oidc.md.
    %{if local.is_subscription_cell}

      # Subscription cell. subscription_id comes from
      # subscriptions/${local.checked_subscription_name}/subscription.hcl,
      # not from ARM_SUBSCRIPTION_ID. See docs/adr/0017.
    %{else}

      # subscription_id comes from ARM_SUBSCRIPTION_ID: no subscription
      # locator above this cell.
    %{endif}
    }

    provider "azuread" {
      use_oidc  = true
      tenant_id = var.tenant_id
    }
  EOF
}

# ---------------------------------------------------------------------------
# Terraform core version. Only required_version is generated here. The stack
# already declares required_providers, and Terraform rejects a second
# required_providers entry for the same provider, so this file pins the CLI
# version and nothing else.
# ---------------------------------------------------------------------------

generate "versions" {
  path      = "terragrunt_versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.9.0"
    }
  EOF
}

# ---------------------------------------------------------------------------
# Adoption hook. If a cell directory contains imports.tf (as produced by the
# export helpers under scripts/), its import blocks are copied into the working
# directory so `terragrunt plan` adopts the existing resources. Delete
# imports.tf after the first apply; import blocks are one-shot.
# ---------------------------------------------------------------------------

generate "imports" {
  path      = "terragrunt_imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = fileexists("${get_terragrunt_dir()}/imports.tf") ? file("${get_terragrunt_dir()}/imports.tf") : "# No imports.tf present in this tenant cell.\n"
}

# ---------------------------------------------------------------------------
# Inputs shared by every cell. Terragrunt merges these with the cell's own
# inputs (the cell wins on conflict, but no cell should set these).
# subscription_id is the locator's value under subscriptions/<sub-name>/ and
# ARM_SUBSCRIPTION_ID everywhere else; an empty value becomes null so
# Entra-only stacks keep their default.
# ---------------------------------------------------------------------------

inputs = {
  tenant_id       = local.tenant_id
  subscription_id = local.subscription_id != "" ? local.subscription_id : null
}
