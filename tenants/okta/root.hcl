# Terragrunt root for every Okta tenant cell.
#
# Each child directory (dev/, prod/) is one tenant. The child includes this file,
# points at the shared stack, and supplies values. Everything that is the same for
# every tenant lives here: where state goes, how the provider is configured, and
# which Terraform version is allowed.
#
# Nothing in this file is tenant-specific and nothing in this file is a secret.

# ---------------------------------------------------------------------------
# Remote state. Bucket, region, and lock table come from the environment so the
# same repo can be planned from a laptop, a CI runner, or a different AWS account
# without editing HCL. TG_STATE_BUCKET and TG_LOCK_TABLE have no default on
# purpose: a missing value fails fast instead of silently using local state.
#
# The state key is derived from the tenant's path relative to this file, so
# tenants/okta/dev -> okta/dev/terraform.tfstate. Adding a tenant is a new
# directory, not a new backend configuration.
# ---------------------------------------------------------------------------

locals {
  state_bucket = get_env("TG_STATE_BUCKET")
  state_region = get_env("TG_STATE_REGION", "us-east-1")
  lock_table   = get_env("TG_LOCK_TABLE")
}

remote_state {
  backend = "s3"

  generate = {
    path      = "terragrunt_backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = local.state_bucket
    key            = "okta/${path_relative_to_include()}/terraform.tfstate"
    region         = local.state_region
    encrypt        = true
    dynamodb_table = local.lock_table

    # The bucket and table are provisioned separately (out of scope for this repo).
    # Terragrunt should never try to reconfigure them from a plan run.
    disable_bucket_update = true
  }
}

# ---------------------------------------------------------------------------
# Provider block. org_name and base_url are Terraform variables declared by the
# stack and populated from the tenant's inputs. The API token is deliberately
# absent: the okta provider reads OKTA_API_TOKEN from the environment on its
# own, so the token never appears in a generated file, in the plan, or in state.
# ---------------------------------------------------------------------------

generate "provider" {
  path      = "terragrunt_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "okta" {
      org_name = var.okta_org_name
      base_url = var.okta_base_url

      # api_token intentionally not set. The provider reads OKTA_API_TOKEN from the
      # environment. See docs/adr/0003-no-long-lived-secrets-in-ci.md.

      # Be polite to the Okta rate limiter on large tenants.
      max_retries      = 5
      max_wait_seconds = 60
    }
  EOF
}

# ---------------------------------------------------------------------------
# Terraform core version. Only required_version is generated here. The stack
# already declares required_providers, and Terraform rejects a second
# required_providers entry for the same provider, so this file pins the CLI
# version and nothing else.
# ---------------------------------------------------------------------------

generate "versions" {
  path      = "terragrunt_versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.9.0, < 2.0.0"
    }
  EOF
}

# ---------------------------------------------------------------------------
# Adoption hook. If a tenant directory contains imports.tf (as produced by
# scripts/Import-OktaPolicies.ps1), its import blocks are copied into the
# working directory so `terragrunt plan` adopts the existing resources. Delete
# imports.tf after the first apply; import blocks are one-shot.
# ---------------------------------------------------------------------------

generate "imports" {
  path      = "terragrunt_imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = fileexists("${get_terragrunt_dir()}/imports.tf") ? file("${get_terragrunt_dir()}/imports.tf") : "# No imports.tf present in this tenant cell.\n"
}
