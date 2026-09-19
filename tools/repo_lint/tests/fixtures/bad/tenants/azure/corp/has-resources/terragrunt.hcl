# A cell that breaks the values-only rule in every way at once.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/unlisted-stack"
}

inputs = {
  name = "example"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-example"
  location = "eastus"
}

data "azurerm_client_config" "current" {}

module "direct" {
  source = "../../../../modules/azure/unlisted-module"
}

locals {
  computed = "${data.azurerm_client_config.current.tenant_id}-suffix"
}

variable "name" {
  type = string
}

output "rg_id" {
  value = azurerm_resource_group.rg.id
}

provider "azurerm" {
  features {}
}

generate "extra" {
  path      = "extra.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    # a heredoc with { braces } and "quotes" that must not confuse the reader
    locals { inside = "heredoc" }
  EOF
}
