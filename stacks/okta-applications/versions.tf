# The stack pins provider requirements only. There is deliberately no provider
# block here: org name, base URL, and credentials are tenant concerns and are
# injected by Terragrunt (see tenants/okta/root.hcl). That keeps this stack
# reusable across dev, prod, and any future tenant without edits.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 4.20"
    }
  }
}
