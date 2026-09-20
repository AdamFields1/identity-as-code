# fixture module: app-signon-policy. In the real tree this is the only layer that holds
# a resource block (okta_app_signon_policy); the fixture holds none, so the repository's
# own tflint and checkov runs have nothing to score here.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}

variable "name" {
  type        = string
  description = "Display name of the app-signon-policy."
}

output "name" {
  description = "The name, echoed so a stack can wire it."
  value       = var.name
}
