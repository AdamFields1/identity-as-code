# The stack pins provider requirements only. There is deliberately no provider
# block here: tenant, subscription, and credentials are tenant concerns and are
# injected by Terragrunt (see tenants/azure/root.hcl).
#
# azuread is pinned beside azurerm because the key-vault and storage-account
# modules resolve Entra groups by display name and declare the provider; a
# stack that composes either pins both, as stacks/azure-automation does. This
# stack names no group, so the provider is configured and never called.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}
