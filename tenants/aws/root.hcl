# Terragrunt root for every AWS cell.
#
# Each partition directory (commercial/, govcloud/) holds one cell per stack,
# for example commercial/aws-identity-center. A cell includes this file, points
# at the shared stack, and supplies values. Everything that is the same for
# every cell lives here: where state goes, how the provider is configured, and
# which Terraform version is allowed.
#
# Nothing in this file is partition-specific and nothing in this file is a
# secret.
#
# ---------------------------------------------------------------------------
# CONTRACT WITH STACKS
#
# The generated provider block below references one Terraform variable. Every
# stack that is deployed through this root MUST declare it:
#
#   variable "region" { type = string }
#
# region is the region the provider talks to. For Identity Center it is the
# region the instance lives in, and it also selects the partition: a us-gov-*
# region is arn:aws-us-gov, everything else here is arn:aws. The cell sets it
# as an ordinary value because it is one; there is no partition variable
# anywhere, the modules read the partition from data.aws_partition.
#
# Stacks own required_providers. This root generates required_version only.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Remote state. Bucket, region, and lock table come from the environment so the
# same repo can be planned from a laptop, a CI runner, or a different AWS
# account without editing HCL. TG_AWS_STATE_BUCKET and TG_AWS_LOCK_TABLE have no
# default on purpose: a missing value fails fast instead of silently using
# local state.
#
# The variables are deliberately not the Okta tree's TG_STATE_* names. The Okta
# tree keeps state in one commercial bucket. This tree has a bucket per
# partition, because a GovCloud identity cannot write to a commercial bucket
# and the reverse: the govcloud cell is planned with TG_AWS_STATE_BUCKET
# pointing at a bucket in us-gov-west-1, the commercial cell with one in
# us-east-1. CI sets them per GitHub environment (docs/adr/0009).
#
# DynamoDB locking rather than the newer S3 lock file because this repository
# allows Terraform 1.9, which predates use_lockfile.
#
# The state key is derived from the cell's path relative to this file, so
# tenants/aws/commercial/aws-identity-center ->
# aws/commercial/aws-identity-center/terraform.tfstate. Adding a cell is a new
# directory, not a new backend configuration.
# ---------------------------------------------------------------------------

locals {
  state_bucket = get_env("TG_AWS_STATE_BUCKET")
  state_region = get_env("TG_AWS_STATE_REGION", "us-east-1")
  lock_table   = get_env("TG_AWS_LOCK_TABLE")

  # Optional role to assume for the provider. Empty means "use the ambient
  # credentials as they are". See the provider block for when it is set.
  role_arn = get_env("TG_AWS_ROLE_ARN", "")
}

remote_state {
  backend = "s3"

  generate = {
    path      = "terragrunt_backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = local.state_bucket
    key            = "aws/${path_relative_to_include()}/terraform.tfstate"
    region         = local.state_region
    encrypt        = true
    dynamodb_table = local.lock_table

    # The bucket and table are provisioned separately (out of scope for this repo).
    # Terragrunt should never try to reconfigure them from a plan run.
    disable_bucket_update = true
  }
}

# ---------------------------------------------------------------------------
# Provider block. region is a Terraform variable declared by the stack and
# populated from the cell's inputs. Credentials are deliberately absent: the
# provider reads them from the environment on its own. In CI that environment
# is populated by aws-actions/configure-aws-credentials, which exchanges the
# job's GitHub OIDC token for short-lived credentials on a role whose ARN is a
# repository variable. There are no static access keys anywhere in the flow.
# See docs/adr/0003-no-long-lived-secrets-in-ci.md.
#
# assume_role is generated only when TG_AWS_ROLE_ARN is set. It is for the
# case where the ambient credentials land in one account (an engineer's SSO
# session, or a CI role that can only assume) and the Identity Center delegated
# administrator lives in another. CI normally leaves it unset because the OIDC
# role is already in the right account.
# ---------------------------------------------------------------------------

generate "provider" {
  path      = "terragrunt_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = var.region

      # Access keys intentionally not set. The provider reads the environment
      # populated by GitHub OIDC (CI) or an SSO session (local).
      # See docs/adr/0003-no-long-lived-secrets-in-ci.md.

      # Identity Center provisions a role into every assigned account on each
      # change and the API is eventually consistent; be patient with it.
      max_retries = 10
    %{if local.role_arn != ""}
      assume_role {
        role_arn     = "${local.role_arn}"
        session_name = "identity-as-code"
      }
    %{else}
      # assume_role not generated: TG_AWS_ROLE_ARN is unset.
    %{endif}
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
      required_version = ">= 1.9.0"
    }
  EOF
}

# ---------------------------------------------------------------------------
# Adoption hook. If a cell directory contains imports.tf (hand-written from the
# import IDs documented in each module README), its import blocks are copied
# into the working directory so `terragrunt plan` adopts the existing
# resources. Delete imports.tf after the first apply; import blocks are one-shot.
# ---------------------------------------------------------------------------

generate "imports" {
  path      = "terragrunt_imports.tf"
  if_exists = "overwrite_terragrunt"
  contents  = fileexists("${get_terragrunt_dir()}/imports.tf") ? file("${get_terragrunt_dir()}/imports.tf") : "# No imports.tf present in this tenant cell.\n"
}
