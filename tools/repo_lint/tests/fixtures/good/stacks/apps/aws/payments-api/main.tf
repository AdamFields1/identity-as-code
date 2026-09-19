# fixture stack: payments-api. Composes modules, resolves names to IDs.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Name passed to every module the stack composes."
}

module "m0" {
  source = "../../../../modules/aws/kms-key"
  name   = var.name
}

module "m1" {
  source = "../../../../modules/aws/s3-bucket"
  name   = var.name
}
