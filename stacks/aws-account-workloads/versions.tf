# The stack pins provider requirements only. There is deliberately no provider
# block here: region, partition, account, and credentials are tenant concerns
# and are injected by Terragrunt (see tenants/aws/root.hcl), which reads the
# partition and account locators above the cell and generates
# allowed_account_ids and the account's profile for the account the cell
# sits in (docs/adr/0017). That keeps this stack reusable across every
# account in either partition without edits.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }
}
