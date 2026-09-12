# Terragrunt root for every Azure tenant cell.
#
# Each tenant directory (corp/, subsidiary/) holds one cell per stack, for example
# corp/azure-rbac-roles and corp/azure-pim-governance. A cell includes this file,
# points at the shared stack, and supplies values. Everything that is the same for
# every cell lives here: where state goes, how the providers are configured, and
# which Terraform version is allowed.
#
# Nothing in this file is tenant-specific and nothing in this file is a secret.
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
# same way the state backend does. See the inputs block at the bottom.
#
# Stacks own required_providers. This root generates required_version only.
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
# tenants/azure/corp/azure-rbac-roles -> azure/corp/azure-rbac-roles/terraform.tfstate.
# Adding a cell is a new directory, not a new backend configuration.
# ---------------------------------------------------------------------------

locals {
  state_resource_group  = get_env("TG_AZ_STATE_RG")
  state_storage_account = get_env("TG_AZ_STATE_SA")
  state_container       = get_env("TG_AZ_STATE_CONTAINER", "tfstate")

  # Provider identity. See the contract block above.
  tenant_id       = get_env("ARM_TENANT_ID")
  subscription_id = get_env("ARM_SUBSCRIPTION_ID", "")
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
# storage_use_azuread = true mirrors the backend: any storage data-plane call
# the provider makes uses the Entra token, not a listed account key.
#
# resource_provider_registrations = "none" because a governance identity that
# manages roles and PIM has no business registering resource providers on the
# subscription, and the default "core" set would fail on a least-privilege
# identity that cannot write to Microsoft.Resources.
# ---------------------------------------------------------------------------

generate "provider" {
  path      = "terragrunt_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "azurerm" {
      features {}

      use_oidc        = true
      subscription_id = var.subscription_id
      tenant_id       = var.tenant_id

      storage_use_azuread             = true
      resource_provider_registrations = "none"

      # client_id intentionally not set. The provider reads ARM_CLIENT_ID from
      # the environment. See docs/adr/0004-azure-storage-state-with-oidc.md.
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
# inputs (the cell wins on conflict, but no cell should set these). An empty
# ARM_SUBSCRIPTION_ID becomes null so Entra-only stacks keep their default.
# ---------------------------------------------------------------------------

inputs = {
  tenant_id       = local.tenant_id
  subscription_id = local.subscription_id != "" ? local.subscription_id : null
}
