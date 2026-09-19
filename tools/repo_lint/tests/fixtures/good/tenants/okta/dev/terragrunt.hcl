# fixture cell: okta dev.
#
# Values only. No resources, no provider configuration, no logic.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../stacks/okta-config"
}

inputs = {
  okta_org_name = "example-org-dev"
  okta_base_url = "oktapreview.com"
}
