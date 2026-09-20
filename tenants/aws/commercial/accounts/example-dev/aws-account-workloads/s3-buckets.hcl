# AWS commercial partition, account example-dev: the catalog cell's buckets.
#
# A fragment of ./terragrunt.hcl, included there as "s3_buckets": one inputs
# attribute holding buckets and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.

inputs = {
  buckets = {
    artifacts = {
      name            = "example-dev-artifacts"
      expiration_days = 90
    }
  }
}
