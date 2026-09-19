# fixture module: rbac-role-definition. In the real tree this is the only layer that holds
# a resource block (azurerm_role_definition); the fixture holds none, so the repository's
# own tflint and checkov runs have nothing to score here.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Display name of the rbac-role-definition."
}

output "name" {
  description = "The name, echoed so a stack can wire it."
  value       = var.name
}
