# fixture fragment of ./terragrunt.hcl, included there as "iam_roles": one
# inputs attribute holding service_roles and nothing else.

inputs = {
  service_roles = {
    loadtest-runner = {
      name  = "payments-api-loadtest-runner"
      trust = { services = ["ec2"] }
    }
  }
}
