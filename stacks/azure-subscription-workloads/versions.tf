# The stack pins provider requirements only. There is deliberately no provider
# block here: tenant, subscription, and credentials are tenant concerns and are
# injected by Terragrunt (see tenants/azure/root.hcl). A cell under
# tenants/azure/<tenant>/subscriptions/<sub-name>/ is addressed by that
# directory's subscription locator, so the same stack deploys to any
# subscription of any tenant without edits (docs/adr/0017).
#
# azuread is required because the key-vault and storage-account modules
# resolve Entra security groups by display name, and because the generated
# provider block configures both providers for every stack under
# tenants/azure.

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
