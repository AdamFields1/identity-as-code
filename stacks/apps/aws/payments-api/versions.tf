# The stack pins provider requirements only. There is deliberately no provider
# block here: region and credentials are tenant concerns and are injected by
# Terragrunt (see tenants/aws/root.hcl), which for an account cell also pins
# the provider to the account named by the cell's locator. That keeps this
# stack deployable to any account in either partition without edits.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }
}
