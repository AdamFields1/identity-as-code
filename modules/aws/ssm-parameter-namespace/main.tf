# SSM Parameter Store namespaces, keyed by the caller's logical name.
#
# A namespace is a prefix under which a workload reads its parameters and
# nothing outside it, and the shape this module offers is the namespace, not
# the secrets: one SecureString parameter, <prefix>/placeholder, encrypted
# with the key the caller names, whose value Terraform writes once as
# "placeholder" and never manages again. The placeholder reserves the prefix
# so nothing else claims it, and proves the prefix, the key, and the grants
# the composing stack writes for it work end to end before a real secret
# exists.
#
# The rule that keeps secrets out of this repository is written here so it
# is a rule and not a hope: the placeholder must never hold a real value.
# The provider reads a parameter back decrypted on every refresh, so
# whatever the placeholder holds at refresh time lands in state and in the
# prior state of every plan file. A real value written into it would be
# readable by everyone who can read state or a plan artifact, including the
# read-only identity that plans pull requests. Real secrets are sibling
# parameters under the same prefix, written by the secrets process; this
# module neither declares nor reads them, so no secret passes through a
# plan, a cell, or a commit. ignore_changes on value exists so an
# accidental overwrite of the placeholder is not reverted by the next plan,
# and for no other reason.
#
# prevent_destroy, because the parameter anchors a namespace an application
# reads at start-up, and a map edit must not be able to remove it. A prefix
# change is a replacement and is refused for the same reason.
#
# The key is the key id (or key ARN) the composing stack takes from the key
# module's output; SSM stores what it was given, so the same form must be
# handed to it on every plan. Standard tier: the deploying identity needs
# kms:Encrypt on the key to create the parameter, which the key's root
# statement lets its IAM policy grant. Nothing is looked up.

resource "aws_ssm_parameter" "placeholder" {
  for_each = var.namespaces

  name        = "${each.value.prefix}/placeholder"
  description = each.value.description
  type        = "SecureString"
  tier        = "Standard"
  key_id      = each.value.kms_key_id
  value       = "placeholder"
  tags        = each.value.tags

  lifecycle {
    # The placeholder anchors the namespace; removing an entry from a map
    # must not be able to delete it under a running application.
    prevent_destroy = true

    # The placeholder must never hold a real value (see the header). This
    # exists so an accidental overwrite is not reverted by the next plan,
    # which would put the overwritten value in front of every reviewer of
    # that plan; it is not permission to write a value here.
    ignore_changes = [value]
  }
}
