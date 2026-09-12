# IAM Identity Center permission sets and the policies attached to them, keyed
# by the caller's logical name.
#
# A permission set is a template for the IAM role Identity Center provisions
# into every account it is assigned to. Everything that shapes that role lives
# here: the managed policies, the customer managed policy references, the one
# inline policy, the optional permissions boundary, and the session duration.
# Who may use it, and where, is the account-assignment module's business.
#
# session_duration is treated as a security control, not a convenience setting.
# It bounds how long a console or CLI session obtained through this permission
# set stays valid after the SAML assertion that created it. A shorter window
# means a stolen session token, an unlocked laptop, or a forgotten browser tab
# is useful to an attacker for less time. The module default is PT1H (the AWS
# minimum and default); a tenant cell raises it per permission set and the
# reviewer sees the raise in the diff.
#
# The Identity Center instance and its identity store are discovered, never
# typed. Managed policy ARNs are built from the current partition so the same
# values work in commercial (arn:aws) and GovCloud (arn:aws-us-gov).

data "aws_ssoadmin_instances" "this" {}

data "aws_partition" "current" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  managed_policy_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy/"

  # Flattened "set/policy" maps so each attachment is one addressable resource.
  aws_managed_attachments = merge([
    for key, ps in var.permission_sets : {
      for policy in ps.aws_managed_policies :
      "${key}/${policy}" => { set_key = key, policy_arn = "${local.managed_policy_arn_prefix}${policy}" }
    }
  ]...)

  customer_managed_attachments = merge([
    for key, ps in var.permission_sets : {
      for policy in ps.customer_managed_policies :
      "${key}/${policy.path}${policy.name}" => { set_key = key, name = policy.name, path = policy.path }
    }
  ]...)

  inline_policies = { for key, ps in var.permission_sets : key => ps.inline_policy if ps.inline_policy != null }

  permissions_boundaries = { for key, ps in var.permission_sets : key => ps.permissions_boundary if ps.permissions_boundary != null }
}

# ---------------------------------------------------------------------------
# Permission sets.
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "this" {
  for_each = var.permission_sets

  instance_arn     = local.instance_arn
  name             = each.value.name
  description      = each.value.description
  session_duration = each.value.session_duration
  relay_state      = each.value.relay_state
  tags             = each.value.tags
}

# ---------------------------------------------------------------------------
# Policy attachments. One resource per (set, policy) so adding or removing a
# policy is a one-line diff and never replaces the permission set.
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.aws_managed_attachments

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.set_key].arn
  managed_policy_arn = each.value.policy_arn
}

resource "aws_ssoadmin_customer_managed_policy_attachment" "this" {
  for_each = local.customer_managed_attachments

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.set_key].arn

  customer_managed_policy_reference {
    name = each.value.name
    path = each.value.path
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "this" {
  for_each = local.inline_policies

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  inline_policy      = each.value
}

resource "aws_ssoadmin_permissions_boundary_attachment" "this" {
  for_each = local.permissions_boundaries

  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn

  permissions_boundary {
    managed_policy_arn = each.value.aws_managed_policy != null ? "${local.managed_policy_arn_prefix}${each.value.aws_managed_policy}" : null

    dynamic "customer_managed_policy_reference" {
      for_each = each.value.customer_managed_policy != null ? [each.value.customer_managed_policy] : []
      content {
        name = customer_managed_policy_reference.value.name
        path = customer_managed_policy_reference.value.path
      }
    }
  }
}
