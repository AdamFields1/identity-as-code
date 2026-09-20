# Fragment of the orders-api app's catalog cell (./terragrunt.hcl): the
# buckets map. One inputs attribute and nothing else; the cell's include
# "s3_buckets" merges it with the other fragments' inputs.
#
# Versioned, TLS-only, nothing public, ACLs off: the module fixes that. Both
# buckets are SSE-S3; no key of this cell or of the account's is named. No
# owner tag on the entries: the cell's tags already say orders.

inputs = {
  buckets = {
    # Receives the results bucket's server access logs, so it is SSE-S3 and
    # logs nowhere itself; it has no allow list because S3 writes into it
    # and nobody reads it except during an investigation. It is a bucket of
    # this cell because the stack refuses a logging target outside the cell,
    # and the account catalog's access-logs bucket is outside it.
    access-logs = {
      name            = "orders-api-prod-access-logs"
      expiration_days = 365
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
    }
  }
}
