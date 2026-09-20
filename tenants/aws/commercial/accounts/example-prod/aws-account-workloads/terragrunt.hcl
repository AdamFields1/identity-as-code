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
#   - four roles: the example application's EC2 instances (an instance
#     profile is created because the trust is ec2), and its CI deployer,
#     trusted from one GitHub repository's main branch and production
#     environment through the account's OIDC provider; the orders team's
#     load-test runner, another EC2 role; and the data platform's reference
#     data publisher, trusted from a second repository's production
#     environment through the same provider
#   - one key, whose users are the example application's two roles
#   - five buckets: the artifacts and the configuration the deployer
#     publishes and the instances read, both encrypted with the key and
#     closed to every other role; the load-test results the runner writes,
#     closed to every role but it; the reference data the publisher writes
#     and app stacks read; and the bucket the other four log access to
# The stack checks the wiring at plan: a role granted a bucket is on that
# bucket's allow list and, where the bucket is under a key of this cell, on
# that key's user list. A role or bucket that is not is a refused plan, not
# an AccessDenied at the first request.
#
# Two pairs of entries belong to application teams rather than to the
# example application, and each pair is one of the two doors a resource an
# app needs comes through when it does not live in the app's own stack. The
# load-test runner and its results bucket are app-owned and live here
# because no identity of the orders-api stack touches them: the runner is
# the only reader and writer, so the catalog holds the pair under the
# orders team's owner tag and nothing orders it against the app. The
# reference data bucket is shared and consumed: its publisher is a role of
# this cell, and its readers are named in their own stacks (the orders-api
# task role, through that stack's reference_bucket_names knob), each of
# which builds the bucket ARN from the name and grants itself the read. The
# direction rule in one sentence: within an account the baseline is applied
# first, then this cell, then the app stacks, so an app stack may name a
# bucket of this cell by name, and an entry here never names a role an app
# stack creates.
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
  # DeleteObjectVersion; the buckets are versioned). An entry's tags are
  # merged over the cell's, so the two team-owned roles carry their own
  # owner and keep the cell's cost centre.
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

    # The orders team's load-test harness runs on EC2 outside the orders-api
    # stack and is the only identity that touches its results. Nothing of
    # the app reads or writes them, so the role is a catalog entry with the
    # team's owner tag, not an app-stack resource.
    loadtest-runner = {
      name                 = "orders-api-loadtest-runner"
      description          = "EC2 instances of the orders team's load-test harness: Systems Manager, and read and write access to the harness's results bucket."
      trust                = { services = ["ec2"] }
      aws_managed_policies = ["AmazonSSMManagedInstanceCore"]
      bucket_access = {
        read_write = ["orders-api-prod-loadtest-results"]
      }
      tags = { owner = "orders" }
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
  # that. access-logs receives the other four buckets' server access logs, so
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

    # Load-test results: SSE-S3, closed to every role but the runner, and
    # the runs are disposable, so objects expire after 30 days. The allow
    # list can name the runner because the runner is a role of this cell,
    # created in the same plan.
    loadtest-results = {
      name               = "orders-api-prod-loadtest-results"
      expiration_days    = 30
      allowed_role_names = ["orders-api-loadtest-runner"]
      access_logging     = { target_bucket = "access-logs" }
      tags               = { owner = "orders" }
    }

    # Reference data: SSE-S3 and deliberately without an allow list. Its
    # readers are named in their own stacks, the orders-api task role among
    # them through that stack's reference_bucket_names, and their identity
    # policies decide who reads. The allow list is a deny fence, and naming
    # a reader here would name a role that a later wave creates, which
    # fails the first release because this cell is applied before the app
    # stack exists. Versioning, TLS-only, and nothing public are the
    # module's and still apply.
    reference-data = {
      name           = "example-prod-reference-data"
      access_logging = { target_bucket = "access-logs" }
      tags           = { owner = "data-platform" }
    }
  }
}
