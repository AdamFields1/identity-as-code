# fixture root for the okta family: state backend and provider generation.
#
# Nothing in this file is tenant-specific and nothing in this file is a secret.

locals {
  state_bucket = get_env("TG_STATE_BUCKET", "CHANGEME")
}
