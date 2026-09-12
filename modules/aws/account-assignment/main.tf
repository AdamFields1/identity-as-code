# IAM Identity Center account assignments, one per group.
#
# The group name is the assignment. A group named
#
#   AWS-<PARTITION>-<accountId>-<PermissionSetName>
#
# is assigned <PermissionSetName> in <accountId>, and nowhere else. The module
# parses the three fields from the display name, checks that PARTITION matches
# the partition the provider is actually talking to, checks that the permission
# set is one this stack manages, resolves the group to its identity store ID,
# and writes the assignment. There is no separate list of accounts, permission
# sets, and groups to keep consistent, because there is only one artifact: the
# group, which Entra ID owns and SCIM provisions.
#
# Why a name-carried model. The group is self-describing: an access reviewer
# reading "AWS-COM-111111111111-ReadOnly" in an Entra access review knows what
# membership grants without opening the AWS console. Provisioning (the group
# exists in the identity store because it is assigned to the Entra gallery
# application) and assignment (this module) derive from the same artifact, so
# they cannot disagree. And the permission set name in the group name is a
# reference the plan checks: a group for a set that does not exist fails here,
# with the group name in the error, not in a portal three weeks later. See
# docs/adr/0008.
#
# Principals are groups only. Users are never assigned directly, for the same
# reason the Azure PIM modules refuse a user principal: a person-to-permission
# edge lives in the directory of record, is reviewed there, and disappears
# there when the person leaves. Identity Center's identity source is Entra ID
# (see stacks/entra-aws-federation), so the group a user needs to be in is an
# Entra group, its membership is governed by Entra (including PIM for groups
# where just-in-time access is wanted), and SCIM carries the membership here.

# ---------------------------------------------------------------------------
# Instance and partition discovery. Same pattern as the permission-set module;
# repeated so each module stays self-contained.
# ---------------------------------------------------------------------------

data "aws_ssoadmin_instances" "this" {}

data "aws_partition" "current" {}

locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  # The partition the provider is configured for, expressed as the token the
  # naming convention uses. Anything else (aws-cn, aws-iso-*) is unsupported
  # and fails the precondition below rather than being guessed.
  partition_tokens = {
    "aws"        = "COM"
    "aws-us-gov" = "GOV"
  }
  expected_partition_token = lookup(local.partition_tokens, data.aws_partition.current.partition, null)
}

# ---------------------------------------------------------------------------
# Name parsing. One entry per group, keyed by the group's display name so the
# Terraform address reads the same as the access review.
# ---------------------------------------------------------------------------

locals {
  parsed = {
    for g in var.group_display_names : g => {
      partition_token     = regex("^AWS-(GOV|COM)-([0-9]{12})-([A-Za-z0-9]+)$", g)[0]
      account_id          = regex("^AWS-(GOV|COM)-([0-9]{12})-([A-Za-z0-9]+)$", g)[1]
      permission_set_name = regex("^AWS-(GOV|COM)-([0-9]{12})-([A-Za-z0-9]+)$", g)[2]
    }
  }
}

# ---------------------------------------------------------------------------
# Group resolution. The alternate identifier form is a server-side filter on
# DisplayName, so a group that does not exist (for example one SCIM has not
# provisioned yet) fails the plan with the group name in the error rather
# than creating an assignment for nobody.
# ---------------------------------------------------------------------------

data "aws_identitystore_group" "by_display_name" {
  for_each = local.parsed

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.key
    }
  }
}

# ---------------------------------------------------------------------------
# Assignments.
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.parsed

  instance_arn       = local.instance_arn
  permission_set_arn = lookup(var.permission_set_arns_by_name, each.value.permission_set_name, null)

  principal_type = "GROUP"
  principal_id   = data.aws_identitystore_group.by_display_name[each.key].group_id

  target_type = "AWS_ACCOUNT"
  target_id   = each.value.account_id

  lifecycle {
    precondition {
      condition     = local.expected_partition_token != null
      error_message = "Partition \"${data.aws_partition.current.partition}\" has no token in the AWS-<PARTITION>-... naming convention. Only aws (COM) and aws-us-gov (GOV) are supported."
    }

    precondition {
      condition     = each.value.partition_token == local.expected_partition_token
      error_message = "Group \"${each.key}\" is an ${each.value.partition_token} group but this cell is planning against the ${coalesce(local.expected_partition_token, "unknown")} partition (${data.aws_partition.current.partition}). A GovCloud cell assigns AWS-GOV-* groups only, a commercial cell AWS-COM-* only."
    }

    precondition {
      condition     = contains(keys(var.permission_set_arns_by_name), each.value.permission_set_name)
      error_message = "Group \"${each.key}\" names permission set \"${each.value.permission_set_name}\", which is not defined in this stack. Managed permission sets: ${join(", ", sort(keys(var.permission_set_arns_by_name)))}. Add the permission set to the cell or rename the group."
    }
  }
}
