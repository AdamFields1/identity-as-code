# tflint configuration shared by pre-commit and the PR workflow.
# There is no Okta ruleset for tflint, so this runs the core Terraform rules only:
# unused declarations, deprecated syntax, naming, and required-version presence.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}
