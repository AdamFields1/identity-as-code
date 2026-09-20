# AWS commercial partition, account example-prod: the catalog cell's buckets.
#
# A fragment of ./terragrunt.hcl, included there as "s3_buckets": one inputs
# attribute holding buckets and nothing else. Values only, as the cell is;
# the header comment in terragrunt.hcl describes the whole cell.
#
# Buckets. Versioned, TLS-only, nothing public, ACLs off: the module fixes
# that. access-logs receives the other three buckets' server access logs,
# so it is SSE-S3 and logs nowhere itself; it has no allow list because S3
# writes into it and nobody reads it except during an investigation.

inputs = {
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
