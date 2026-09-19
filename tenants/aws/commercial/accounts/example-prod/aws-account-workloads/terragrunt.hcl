# AWS commercial partition, account example-prod: workloads catalog cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack; if the shape you
# need is not on the menu, it belongs in a module or an app stack
# (docs/adr/0017), never in a looser entry here.
#
# The account and the partition are the tree, not values: ../account.hcl and
# ../../../partition.hcl address this cell through tenants/aws/root.hcl,
# which also supplies region (us-east-1). Nothing below is an ID, an ARN, or
# a policy document: roles, keys, and buckets name each other by name or by
# map key, and the stack builds every ARN from the partition it discovers.
#
# What this cell holds, and how the entries refer to each other:
#   - two roles: the example application's EC2 instances (an instance
#     profile is created because the trust is ec2), and its CI deployer,
#     trusted from one GitHub repository's main branch and production
#     environment through the account's OIDC provider
#   - one key, whose users are the two roles
#   - three buckets: the artifacts and the configuration the deployer
#     publishes and the instances read, both encrypted with the key and
#     closed to every other role, and the bucket both of them log access to
# The stack checks the wiring at plan: a role granted a bucket is on that
# bucket's allow list and, where the bucket is under a key of this cell, on
# that key's user list. A role or bucket that is not is a refused plan, not
# an AccessDenied at the first request.
#
# State key (derived by root.hcl):
# aws/commercial/accounts/example-prod/aws-account-workloads/terraform.tfstate

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

  # -------------------------------------------------------------------------
  # Service roles. Trust is a service or a repository, policies are names,
  # and bucket_access is rendered into the role's inline policy by the stack:
  # read is list and get, read_write adds put and delete (never
  # DeleteObjectVersion; the buckets are versioned).
  # -------------------------------------------------------------------------
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
  }

  # -------------------------------------------------------------------------
  # Keys. Role names are names; both roles are at /, so no path in front.
  # -------------------------------------------------------------------------
  kms_keys = {
    app = {
      alias           = "example-app"
      description     = "Encrypts the example application's configuration and build artifacts."
      user_role_names = ["example-app-server", "example-ci-deployer"]
    }
  }

  # -------------------------------------------------------------------------
  # Buckets. Versioned, TLS-only, nothing public, ACLs off: the module fixes
  # that. access-logs receives the other two buckets' server access logs, so
  # it is SSE-S3 and logs nowhere itself; it has no allow list because S3
  # writes into it and nobody reads it except during an investigation.
  # -------------------------------------------------------------------------
  buckets = {
    access-logs = {
      name            = "example-prod-access-logs"
      expiration_days = 365
    }

    artifacts = {
      name               = "example-prod-artifacts"
      kms_key            = "app"
      allowed_role_names = ["example-app-server", "example-ci-deployer"]
      access_logging     = { target_bucket = "access-logs" }
    }

    config = {
      name               = "example-prod-config"
      kms_key            = "app"
      allowed_role_names = ["example-app-server", "example-ci-deployer"]
      access_logging     = { target_bucket = "access-logs" }
    }
  }
}
