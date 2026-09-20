# fixture stack: okta-applications. Composes modules, resolves names to IDs.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Name passed to every module the stack composes."
}

module "m0" {
  source = "../../modules/okta/app-signon-policy"
  name   = var.name
}

module "m1" {
  source = "../../modules/okta/app-saml"
  name   = var.name
}

module "m2" {
  source = "../../modules/okta/app-oauth"
  name   = var.name
}
