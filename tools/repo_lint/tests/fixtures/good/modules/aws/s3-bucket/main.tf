# fixture module: s3-bucket. In the real tree this is the only layer that holds
# a resource block (aws_s3_bucket); the fixture holds none, so the repository's
# own tflint and checkov runs have nothing to score here.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Display name of the s3-bucket."
}

output "name" {
  description = "The name, echoed so a stack can wire it."
  value       = var.name
}

# The bucket module composes the key module for its default key.
module "key" {
  source = "../kms-key"
  name   = var.name
}
