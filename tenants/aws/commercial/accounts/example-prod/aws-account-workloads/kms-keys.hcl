# AWS commercial partition, account example-prod: the catalog cell's keys.
#
# A fragment of ./terragrunt.hcl, included there as "kms_keys": one inputs
# attribute holding kms_keys and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.
#
# Keys. Role names are names; both roles are at /, so no path in front.

inputs = {
  kms_keys = {
    app = {
      alias           = "example-app"
      description     = "Encrypts the example application's configuration and build artifacts."
      user_role_names = ["example-app-server", "example-ci-deployer"]
    }
  }
}
