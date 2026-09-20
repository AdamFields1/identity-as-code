# Fragment of the orders-api app's catalog cell (./terragrunt.hcl): the
# service_roles map. One inputs attribute and nothing else; the cell's
# include "iam_roles" merges it with the other fragments' inputs.
#
# Trust is a service or a repository, policies are names, and bucket_access
# is rendered into the role's inline policy by the stack: read is list and
# get, read_write adds put and delete (never DeleteObjectVersion; the
# buckets are versioned). No owner tag on the entry: the cell's tags already
# say orders.

inputs = {
  service_roles = {
    # The orders team's load-test harness runs on EC2 outside the orders-api
    # stack and is the only identity that touches its results. Nothing of
    # the app reads or writes them, so the role is a catalog entry of the
    # team's own cell, not an app-stack resource.
    loadtest-runner = {
      name                 = "orders-api-loadtest-runner"
      description          = "EC2 instances of the orders team's load-test harness: Systems Manager, and read and write access to the harness's results bucket."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      bucket_access = {
        read_write = ["orders-api-prod-loadtest-results"]
      }
    }
  }
}
