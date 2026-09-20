# fixture fragment of ./terragrunt.hcl, included there as "saml_apps": one
# inputs attribute holding saml_apps and nothing else.

inputs = {
  saml_apps = {
    payroll = {
      label         = "Example Payroll"
      sso_url       = "https://payroll.dev.example.com/saml/acs"
      audience      = "https://payroll.dev.example.com"
      group_names   = ["app-payroll-users"]
      signon_policy = "standard-workforce"
    }
  }
}
