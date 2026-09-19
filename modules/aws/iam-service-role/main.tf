# IAM roles for workloads, keyed by the caller's logical name.
#
# A service role is a trust policy plus permissions. This module offers both
# as shapes rather than as documents: trust is chosen from an allowlist of
# services, a list of account ids, or a GitHub repository with the branches
# and environments that may deploy, and permissions are policy names. The
# only free-form document is the optional inline policy, and even that is
# read before it is accepted (see the allow_admin validations).
#
# What the module refuses, and why:
#
#   - A wildcard principal. There is no input that takes one; account trust
#     is a 12-digit id, service trust is an allowlist entry, GitHub trust is
#     a repository with named branches or environments. A precondition below
#     also checks the rendered trust document, so a future edit to this file
#     cannot quietly widen it.
#   - AdministratorAccess or IAMFullAccess, or an inline statement that
#     allows every action, iam:*, or one of the IAM actions that are
#     administrator by privilege escalation (PassRole, AttachRolePolicy,
#     PutRolePolicy, CreatePolicyVersion, SetDefaultPolicyVersion,
#     UpdateAssumeRolePolicy) on every resource, unless the role says
#     allow_admin = true. The flag exists so the word admin appears in the
#     diff next to the trust that grants it.
#   - An ECS task trust without an account condition. The ecs-tasks
#     statement carries aws:SourceAccount = this account, as the ECS
#     documentation recommends against the cross-service confused deputy,
#     so a task in another account that can name this role's ARN is not
#     vended its credentials. The other services on the allowlist do not
#     document the key and are left unconditioned: a condition a service
#     does not send is a role nothing can assume.
#
# Everything partition-specific is discovered. Service principals are built
# from the partition's DNS suffix (ec2.amazonaws.com in both commercial and
# GovCloud), managed policy ARNs from the partition, the account for the
# ECS condition from the caller, and the GitHub OIDC provider is looked up
# by URL in the account the provider is pointed at. The same cell values
# therefore deploy to any account in either partition.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  account_id = data.aws_caller_identity.current.account_id

  managed_policy_arn_prefix = "arn:${local.partition}:iam::aws:policy/"

  # The allowlist, as service principal names for this partition. Every
  # entry the variable validation accepts has a row here.
  service_principal_names = {
    ec2       = "ec2.${local.dns_suffix}"
    lambda    = "lambda.${local.dns_suffix}"
    ecs-tasks = "ecs-tasks.${local.dns_suffix}"
    eks-pods  = "pods.eks.${local.dns_suffix}"
  }

  github_oidc_url      = "https://token.actions.githubusercontent.com"
  github_oidc_audience = "sts.amazonaws.com"
  github_oidc_needed   = anytrue([for r in var.roles : r.trust.oidc_github != null])
}

# ---------------------------------------------------------------------------
# GitHub OIDC provider. One per account, created by the account baseline
# (platform bootstrap, out of scope here). Looked up only when a role needs
# it, so an account without one still deploys roles that do not use it.
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  for_each = local.github_oidc_needed ? toset(["github"]) : toset([])

  url = local.github_oidc_url
}

# ---------------------------------------------------------------------------
# Customer managed policies, resolved by name and path. Attachments and
# boundaries share one lookup per distinct policy so a policy used by five
# roles costs one API call. A policy that does not exist fails the plan with
# its name in the error.
# ---------------------------------------------------------------------------

locals {
  customer_managed_policy_refs = merge(concat([{}], [
    for key, r in var.roles : {
      for p in r.customer_managed_policies : "${p.path}${p.name}" => { name = p.name, path = p.path }
    }
  ])...)

  boundary_customer_managed_refs = {
    for key, r in var.roles :
    "${r.permissions_boundary.customer_managed_policy.path}${r.permissions_boundary.customer_managed_policy.name}" => {
      name = r.permissions_boundary.customer_managed_policy.name
      path = r.permissions_boundary.customer_managed_policy.path
    }
    if try(r.permissions_boundary.customer_managed_policy, null) != null
  }

  customer_managed_policy_lookups = merge(local.customer_managed_policy_refs, local.boundary_customer_managed_refs)
}

data "aws_iam_policy" "customer_managed" {
  for_each = local.customer_managed_policy_lookups

  name        = each.value.name
  path_prefix = each.value.path
}

# ---------------------------------------------------------------------------
# Trust policies. One document per role, one statement per trust form, so a
# reviewer reading the plan sees "TrustedServices", "TrustedEcsTasks",
# "TrustedEksPodIdentity", "TrustedAccounts", or "TrustedGitHubActions" and
# nothing else. ECS tasks are their own statement because their trust
# carries an account condition, and EKS Pod Identity because it needs
# sts:TagSession as well as sts:AssumeRole.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  for_each = var.roles

  dynamic "statement" {
    for_each = length([for s in each.value.trust.services : s if s != "eks-pods" && s != "ecs-tasks"]) > 0 ? [1] : []

    content {
      sid     = "TrustedServices"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "Service"
        identifiers = [for s in each.value.trust.services : local.service_principal_names[s] if s != "eks-pods" && s != "ecs-tasks"]
      }
    }
  }

  # The ECS documentation (task-iam-roles) recommends aws:SourceAccount or
  # aws:SourceArn on a task role's trust so a task in another account that
  # can name this role's ARN is not vended its credentials. SourceAccount
  # rather than the documented ArnLike on arn:<partition>:ecs:<region>:
  # <account>:*, because that pattern carries a wildcard and the
  # precondition on the role refuses one in the rendered trust; the
  # account is exact, discovered from the caller, and never typed.
  dynamic "statement" {
    for_each = contains(each.value.trust.services, "ecs-tasks") ? [1] : []

    content {
      sid     = "TrustedEcsTasks"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "Service"
        identifiers = [local.service_principal_names["ecs-tasks"]]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(each.value.trust.services, "eks-pods") ? [1] : []

    content {
      sid     = "TrustedEksPodIdentity"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:TagSession"]

      principals {
        type        = "Service"
        identifiers = [local.service_principal_names["eks-pods"]]
      }
    }
  }

  dynamic "statement" {
    for_each = length(each.value.trust.account_principals) > 0 ? [1] : []

    content {
      sid     = "TrustedAccounts"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = [for id in each.value.trust.account_principals : "arn:${local.partition}:iam::${id}:root"]
      }

      dynamic "condition" {
        for_each = each.value.trust.external_id != null ? [each.value.trust.external_id] : []

        content {
          test     = "StringEquals"
          variable = "sts:ExternalId"
          values   = [condition.value]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.trust.oidc_github != null ? [each.value.trust.oidc_github] : []

    content {
      sid     = "TrustedGitHubActions"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [data.aws_iam_openid_connect_provider.github["github"].arn]
      }

      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:aud"
        values   = [local.github_oidc_audience]
      }

      # StringEquals with several values is an OR: any listed branch or
      # environment of this one repository, and nothing else.
      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:sub"
        values = concat(
          [for b in statement.value.branches : "repo:${statement.value.repository}:ref:refs/heads/${b}"],
          [for e in statement.value.environments : "repo:${statement.value.repository}:environment:${e}"],
        )
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Roles.
# ---------------------------------------------------------------------------

locals {
  boundary_arns = {
    for key, r in var.roles : key => (
      r.permissions_boundary == null ? null : (
        try(r.permissions_boundary.aws_managed_policy, null) != null
        ? "${local.managed_policy_arn_prefix}${r.permissions_boundary.aws_managed_policy}"
        : data.aws_iam_policy.customer_managed["${r.permissions_boundary.customer_managed_policy.path}${r.permissions_boundary.customer_managed_policy.name}"].arn
      )
    )
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name                 = each.value.name
  path                 = each.value.path
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = each.value.max_session_duration
  permissions_boundary = local.boundary_arns[each.key]
  tags                 = each.value.tags

  # A policy attached outside this module is drift, and drift should stop a
  # destroy rather than be detached silently on the way out.
  force_detach_policies = false

  lifecycle {
    precondition {
      # Nothing that reaches the trust document may contain a wildcard: the
      # validations keep one out of every input, and this check keeps one
      # out of the rendered result whatever this file is edited into later.
      condition     = !strcontains(data.aws_iam_policy_document.trust[each.key].json, "*")
      error_message = "Role \"${each.key}\": the rendered trust policy contains a wildcard. A role that any principal, branch, or account can assume is refused; name the accounts, services, branches, or environments that may assume it."
    }

    precondition {
      condition     = each.value.trust.oidc_github == null || contains(try(data.aws_iam_openid_connect_provider.github["github"].client_id_list, []), local.github_oidc_audience)
      error_message = "Role \"${each.key}\" trusts GitHub Actions, but the ${local.github_oidc_url} provider in this account does not list ${local.github_oidc_audience} as an audience. The trust condition requires it; add the audience to the provider in the account baseline."
    }
  }
}

# ---------------------------------------------------------------------------
# Permissions. One attachment resource per (role, policy) so adding or
# removing a policy is a one-line diff that never replaces the role.
# ---------------------------------------------------------------------------

locals {
  aws_managed_attachments = merge(concat([{}], [
    for key, r in var.roles : {
      for p in r.aws_managed_policies :
      "${key}/${p}" => { role_key = key, policy_arn = "${local.managed_policy_arn_prefix}${p}" }
    }
  ])...)

  customer_managed_attachments = merge(concat([{}], [
    for key, r in var.roles : {
      for p in r.customer_managed_policies :
      "${key}/${p.path}${p.name}" => { role_key = key, policy_arn = data.aws_iam_policy.customer_managed["${p.path}${p.name}"].arn }
    }
  ])...)

  inline_policies = { for key, r in var.roles : key => r.inline_policy if r.inline_policy != null }

  ec2_roles = { for key, r in var.roles : key => r if contains(r.trust.services, "ec2") }
}

resource "aws_iam_role_policy_attachment" "aws_managed" {
  for_each = local.aws_managed_attachments

  role       = aws_iam_role.this[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy_attachment" "customer_managed" {
  for_each = local.customer_managed_attachments

  role       = aws_iam_role.this[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "inline" {
  for_each = local.inline_policies

  name   = "inline"
  role   = aws_iam_role.this[each.key].name
  policy = each.value
}

# ---------------------------------------------------------------------------
# Instance profiles. EC2 cannot use a role directly; it needs a profile that
# wraps it. One is created for every role that trusts ec2, under the role's
# own name and path, so the cell never has to know profiles exist.
# ---------------------------------------------------------------------------

resource "aws_iam_instance_profile" "this" {
  for_each = local.ec2_roles

  name = each.value.name
  path = each.value.path
  role = aws_iam_role.this[each.key].name
  tags = each.value.tags
}
