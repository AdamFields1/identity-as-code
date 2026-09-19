# AWS commercial partition, account example-dev: workloads catalog cell.
#
# Values only. Same stack as ../../example-prod/aws-account-workloads, with
# the smallest menu a workload account can have: one role for the example
# application's EC2 instances and one bucket they read and write. What prod
# has that dev does not, and why:
#   - no CI deployer role: developers publish to the bucket with their own
#     Identity Center access (AWS-COM-222222222222-PowerUser)
#   - no customer managed key: the bucket is SSE-S3
#   - no allow list on the bucket, for the same reason as the first point;
#     the TLS-only statement, versioning, and the public access blocks are
#     the module's and still apply
#   - no access logging, and objects expire after 90 days
#
# The account and the partition are the tree, not values: ../account.hcl and
# ../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). See docs/adr/0017.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-dev/aws-account-workloads/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/aws-account-workloads"
}

inputs = {
  tags = {
    owner       = "example-app"
    cost_centre = "cc-2222"
  }

  service_roles = {
    app-server = {
      name                 = "example-app-server"
      description          = "EC2 instances of the example application in dev: Systems Manager, and read and write access to the artifacts bucket."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      bucket_access = {
        read_write = ["example-dev-artifacts"]
      }
    }
  }

  buckets = {
    artifacts = {
      name            = "example-dev-artifacts"
      expiration_days = 90
    }
  }
}
