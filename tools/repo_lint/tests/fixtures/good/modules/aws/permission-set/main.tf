# fixture module: permission-set. In the real tree this is the only layer that holds
# a resource block (aws_ssoadmin_permission_set); the fixture holds none, so the repository's
# own tflint and checkov runs have nothing to score here.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Display name of the permission-set."
}

output "name" {
  description = "The name, echoed so a stack can wire it."
  value       = var.name
}
