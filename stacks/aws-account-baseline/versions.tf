# The stack pins provider requirements only. There is deliberately no provider
# block here: region, credentials, and the account to assume into are tenant
# concerns and are injected by Terragrunt (see tenants/aws/root.hcl, which
# builds them from the account and partition locators, docs/adr/0017). That
# keeps this stack reusable across every account in the commercial and
# GovCloud partitions without edits.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }
}
