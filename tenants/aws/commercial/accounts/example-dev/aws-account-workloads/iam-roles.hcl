# AWS commercial partition, account example-dev: the catalog cell's roles.
#
# A fragment of ./terragrunt.hcl, included there as "iam_roles": one inputs
# attribute holding service_roles and nothing else. Values only, as the cell
# is; the header comment in terragrunt.hcl describes the whole cell.

inputs = {
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
}
