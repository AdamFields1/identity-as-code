# The stack pins provider requirements only. There is deliberately no provider
# block here: tenant, subscription, and credentials are tenant concerns and are
# injected by Terragrunt (see tenants/azure/root.hcl).

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
