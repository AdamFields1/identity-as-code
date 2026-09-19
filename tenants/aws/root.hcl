# Terragrunt root for every AWS cell.
#
# Each partition directory (commercial/, govcloud/) holds cells at two depths:
#
#   <partition>/<stack>/                           partition-wide cells, for
#                                                  example commercial/aws-identity-center
#   <partition>/accounts/<account-name>/<stack>/   account-scoped cells (docs/adr/0017)
#
# A cell includes this file, points at the shared stack, and supplies values.
# Everything that is the same for every cell lives here: where state goes, how
# the provider is configured, which account it is pointed at, and which
# Terraform version is allowed.
#
# Nothing in this file is partition-specific or account-specific, and nothing
# in this file is a secret. Partition and account facts come from locator
# files in the tree (see ADDRESSING below), never from a cell.
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
# For a cell under accounts/, the partition locator supplies region as an
# input (see the inputs block at the bottom), so the cell does not have to
# say it. A cell that sets region itself wins. A stack that needs the account
# it is running in discovers it with data.aws_caller_identity; the root never
# passes an account id as an input, because a cell holds no IDs.
#
# Stacks own required_providers. This root generates required_version only.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ADDRESSING: which partition, which account.
#
# Two locator files answer that, and a cell never does:
#
#   tenants/aws/<partition>/partition.hcl
#     locals { partition = "aws" | "aws-us-gov", region = "us-east-1" }
#   tenants/aws/<partition>/accounts/<account-name>/account.hcl
#     locals { account_id = "111111111111", account_name = "example-prod" }
#
# A locator is not a cell: no include, no source, no inputs, and Terragrunt
# never runs it. It is read here and nowhere else.
#
# Evaluation order, because it matters. Terragrunt parses this file as an
# include of the cell, with the cell's own path as the starting point, so
# find_in_parent_folders walks up from the cell directory (its parent first)
# and returns the first partition.hcl or account.hcl it meets. A cell under
# accounts/<account-name>/ meets account.hcl one level up and partition.hcl
# three levels up. A partition-wide cell such as commercial/aws-identity-center
# meets partition.hcl one level up and no account.hcl at all: the fallback
# argument then returns the bare file name, read_terragrunt_config's default
# stands in for the missing file with an empty locals object, and every
# account-dependent local below collapses to "not an account cell". The
# search does not stop at the repository root, so an account.hcl above the
# checkout would be found; the directory-name check below is what makes that
# visible.
#
# Layering, from the outside in:
#
#   1. environment     state bucket, region, and lock table; the ambient
#                      credentials; TG_AWS_ROLE_ARN for a cell with no
#                      account locator; for an account cell, the shared
#                      config profile that names its deployment role (see
#                      the provider block). What the runner knows.
#   2. partition.hcl   ARN partition and default region. What the tree knows.
#   3. account.hcl     account id and name. What the tree knows.
#   4. cell inputs     values. What the reviewer diffs.
#
# An account cell's provider is assembled from 2 and 3, its credentials come
# from 1, and nothing comes from 4.
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
# aws/commercial/aws-identity-center/terraform.tfstate, and
# tenants/aws/commercial/accounts/example-prod/aws-account-baseline ->
# aws/commercial/accounts/example-prod/aws-account-baseline/terraform.tfstate.
# Adding a cell is a new directory, not a new backend configuration, and the
# account locator plays no part in the key.
#
# The backend always uses the ambient credentials. An account cell's
# provider uses a profile (below); the backend does not, so the account's
# deployment role never needs to reach the state bucket.
# ---------------------------------------------------------------------------

locals {
  state_bucket = get_env("TG_AWS_STATE_BUCKET")
  state_region = get_env("TG_AWS_STATE_REGION", "us-east-1")
  lock_table   = get_env("TG_AWS_LOCK_TABLE")

  # Optional role to assume for cells that have no account locator. Empty
  # means "use the ambient credentials as they are". See the provider block
  # for when it is set. An account cell ignores it: its address is the tree.
  env_role_arn = get_env("TG_AWS_ROLE_ARN", "")

  # Locators. Each read returns { locals = {} } when the file is absent, so
  # the try() calls yield "" and nothing below has to know whether the file
  # existed. The fallback name is relative to the cell, where no locator
  # ever sits, which is what makes it a reliable "absent".
  partition_locator = find_in_parent_folders("partition.hcl", "partition.hcl")
  partition_locals  = read_terragrunt_config(local.partition_locator, { locals = {} }).locals
  partition         = try(local.partition_locals.partition, "")
  partition_region  = try(local.partition_locals.region, "")

  account_locator = find_in_parent_folders("account.hcl", "account.hcl")
  account_locals  = read_terragrunt_config(local.account_locator, { locals = {} }).locals
  account_id      = try(local.account_locals.account_id, "")
  account_name    = try(local.account_locals.account_name, "")
  account_dir     = basename(dirname(local.account_locator))

  is_account_cell = local.account_id != ""

  # Guards. Terragrunt HCL has no precondition block, so each check is a
  # conditional whose failing branch reads an attribute that does not exist
  # on an empty object: the attribute name is the error message, and
  # Terragrunt prints it with this file and line. The passing branch is the
  # value itself. HCL reports only the diagnostics of the branch it takes,
  # so a passing check costs nothing, and Terragrunt evaluates every local
  # whether or not something reads it, so a failing check always fires.
  guard = {}

  checked_account_id = !local.is_account_cell || can(regex("^[0-9]{12}$", local.account_id)) ? local.account_id : local.guard.ERROR_account_hcl_account_id_must_be_exactly_12_digits

  checked_account_name = !local.is_account_cell || local.account_name == local.account_dir ? local.account_name : local.guard.ERROR_account_hcl_account_name_must_equal_the_name_of_its_directory

  checked_partition = !local.is_account_cell || contains(["aws", "aws-us-gov"], local.partition) ? local.partition : local.guard.ERROR_account_cell_needs_a_partition_hcl_above_it_with_partition_aws_or_aws_us_gov

  # The provider profile of an account cell: the credential slot the
  # account's deployment role is named in (the provider block says why it
  # is a profile and not an assume_role). The name is derived from the
  # locator, so it is the same in every environment and safe to record in a
  # plan file; what fills it is the runner's or the engineer's shared
  # config, never a cell. The partition guard above still fires for an
  # account cell even though nothing here reads its value any more: the
  # role ARN behind the profile is built from the partition outside this
  # file, and a locator that cannot name one is still a broken address.
  account_profile = local.is_account_cell ? "identity-as-code-${local.checked_account_name}" : ""

  # The environment-driven assume_role target of a cell with no account
  # locator, if one is set. An account cell ignores it: its address is the
  # tree, and its credentials are the profile above.
  provider_role_arn = local.is_account_cell ? "" : local.env_role_arn
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
# populated from the cell's inputs (or from the partition locator, see the
# inputs block). Credentials are deliberately absent: the provider reads them
# from the environment on its own. In CI that environment is populated by
# aws-actions/configure-aws-credentials, which exchanges the job's GitHub
# OIDC token for short-lived credentials on a role whose ARN is a repository
# variable. There are no static access keys anywhere in the flow.
# See docs/adr/0003-no-long-lived-secrets-in-ci.md.
#
# An account cell (an account.hcl above it) gets two things, and no
# assume_role:
#
#   - allowed_account_ids from the locator. The provider checks the account
#     its credentials actually landed in against it when it is configured,
#     so a mis-addressed plan stops before its first resource API call
#     rather than after a plan against the wrong estate. (The backend has
#     read the state file by then: it runs before the provider is
#     configured, so the check stops the plan before it refreshes anything,
#     not before it reads state.)
#   - profile = "identity-as-code-<account_name>", derived from the locator.
#     That profile is where the account's deployment role is named, and it
#     is named there rather than here because a saved plan carries this
#     generated file with it: `terraform apply <planfile>` applies the
#     configuration recorded in the plan, not the working directory, so an
#     assume_role rendered here at plan time would be the role the apply job
#     assumes too. The release train plans account cells as a read-only
#     deployment role and applies them as a writer (docs/adr/0003), and that
#     split can only live where the plan file cannot capture it: the
#     runner's shared config file, which the workflow writes from the cell's
#     locators and the environment's TG_AWS_DEPLOY_ROLE_NAME just before
#     Terragrunt runs (.github/workflows/aws-*.yml), with credential_source
#     = Environment so the role is assumed from the OIDC session. Locally
#     it is a profile an engineer defines once per account (README, "How to
#     use it"). Only the provider uses the profile; the backend keeps the
#     ambient credentials, so the deployment role never touches state. A
#     missing profile fails when the provider is configured, with the
#     profile's name in the error, which is the honest failure for an
#     account nobody has set up.
#
# Any other cell keeps the environment-driven assume_role when
# TG_AWS_ROLE_ARN is set. It is for the case where the ambient credentials
# land in one account (an engineer's SSO session, or a CI role that can only
# assume) and the Identity Center delegated administrator lives in another.
# CI leaves it unset because the OIDC role is already in the right account,
# and it must stay unset in CI for the reason above: a value rendered at
# plan time is the value the apply runs with.
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
    %{if local.is_account_cell}
      # Account cell. Addressed by accounts/${local.checked_account_name}/account.hcl:
      # account ${local.checked_account_id}, partition ${local.checked_partition}.
      # The provider refuses to run in any other account.
      allowed_account_ids = ["${local.checked_account_id}"]

      # The account's deployment role is named in this profile on the
      # runner or the workstation, never here: a saved plan carries this
      # file, and the plan and apply environments name different roles.
      # See the comment above the generate block in tenants/aws/root.hcl.
      profile = "${local.account_profile}"
    %{else}
    %{if local.provider_role_arn != ""}
      assume_role {
        role_arn     = "${local.provider_role_arn}"
        session_name = "identity-as-code"
      }
    %{else}
      # assume_role not generated: no account locator above this cell and
      # TG_AWS_ROLE_ARN is unset.
    %{endif}
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

# ---------------------------------------------------------------------------
# Inputs shared by every cell. Terragrunt merges these with the cell's own
# inputs and the cell wins on conflict. region comes from the partition
# locator so an account cell does not have to say it; the Identity Center
# cells set region themselves, because the instance's region is the address
# of the instance, and that value wins. Without a partition locator nothing
# is set here, as before.
# ---------------------------------------------------------------------------

inputs = local.partition_region != "" ? { region = local.partition_region } : {}
