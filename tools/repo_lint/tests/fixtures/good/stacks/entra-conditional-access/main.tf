# fixture stack: entra-conditional-access. Composes modules, resolves names to IDs.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Name passed to every module the stack composes."
}

module "m0" {
  source = "../../modules/entra/conditional-access"
  name   = var.name
}
