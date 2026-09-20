# fixture fragment of ./terragrunt.hcl, included there as "s3_buckets": one
# inputs attribute holding buckets and nothing else.

inputs = {
  buckets = {
    loadtest-results = {
      name               = "payments-api-prod-loadtest-results"
      allowed_role_names = ["payments-api-loadtest-runner"]
    }
  }
}
