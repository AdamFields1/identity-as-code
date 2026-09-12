# The stack pins provider requirements only. There is deliberately no provider
# block here: region and credentials are tenant concerns and are injected by
# Terragrunt (see tenants/aws/root.hcl). That keeps this stack reusable across
# the commercial and GovCloud cells and any future partition without edits.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }
}
