# A fragment holding a resource block beside its inputs.

inputs = {
  extra = "value"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-example"
  location = "eastus"
}
