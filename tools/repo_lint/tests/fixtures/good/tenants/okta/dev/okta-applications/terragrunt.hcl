# fixture cell: okta dev application catalog, in fragments.
#
# Values only. No resources, no provider configuration, no logic. A cell of
# the application catalog stack beside the okta-config cell of the same org.
# signon-policies.hcl, saml-apps.hcl, and oauth-apps.hcl each hold one inputs
# attribute; Terragrunt merges them with the inputs below.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "signon_policies" {
  path = "signon-policies.hcl"
}

include "saml_apps" {
  path = "saml-apps.hcl"
}

include "oauth_apps" {
  path = "oauth-apps.hcl"
}

terraform {
  source = "../../../../stacks/okta-applications"
}

# Ordering only. The policies name network zones the okta-config cell creates.
dependencies {
  paths = ["../okta-config"]
}

inputs = {
  name          = "okta-applications-dev"
  okta_org_name = "example-org-dev"
  okta_base_url = "oktapreview.com"
}
