# The stack pins provider requirements only. There is deliberately no provider
# block here: tenant ID, subscription ID, and credentials are tenant concerns and
# are injected by Terragrunt (see tenants/azure/root.hcl). azurerm is declared
# because the generated provider block configures it, even though an Entra-only
# stack creates no azurerm resources.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }
}
