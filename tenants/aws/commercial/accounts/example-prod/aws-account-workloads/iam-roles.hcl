# AWS commercial partition, account example-prod: the catalog cell's roles.
#
# A fragment of ./terragrunt.hcl, included there as "iam_roles": one inputs
# attribute holding service_roles and nothing else. Values only, as the cell
# is; the header comment in terragrunt.hcl describes the whole cell.
#
# Service roles. Trust is a service or a repository, policies are names,
# and bucket_access is rendered into the role's inline policy by the stack:
# read is list and get, read_write adds put and delete (never
# DeleteObjectVersion; the buckets are versioned). An entry's tags are
# merged over the cell's, so the team-owned role carries its own owner and
# keeps the cell's cost centre.

inputs = {
  service_roles = {
    app-server = {
      name                 = "example-app-server"
      description          = "EC2 instances of the example application: Systems Manager, and read access to the application's configuration and artifacts."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      bucket_access = {
        read = ["example-prod-config", "example-prod-artifacts"]
      }
    }

    ci-deployer = {
      name        = "example-ci-deployer"
      description = "GitHub Actions in example-org/example-app publishes the application's configuration and build artifacts. Trusted from main and the production environment only."
      trust = {
        oidc_github = {
          repository   = "example-org/example-app"
          branches     = ["main"]
          environments = ["production"]
        }
      }
      max_session_duration = 3600
      bucket_access = {
        read_write = ["example-prod-config", "example-prod-artifacts"]
      }
    }

    # The data platform publishes reference data from its own repository's
    # production environment; no branch is named because the environment's
    # protection rules are the gate. The readers are not roles of this cell:
    # they are named in the app stacks that consume the bucket.
    reference-data-publisher = {
      name        = "example-reference-data-publisher"
      description = "GitHub Actions in example-org/reference-data publishes the data platform's reference data. Trusted from the production environment only."
      trust = {
        oidc_github = {
          repository   = "example-org/reference-data"
          environments = ["production"]
        }
      }
      max_session_duration = 3600
      bucket_access = {
        read_write = ["example-prod-reference-data"]
      }
      tags = { owner = "data-platform" }
    }
  }
}
