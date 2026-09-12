# entra-aws-federation stack
#
# One deployable unit that makes an Entra tenant the identity source for every
# AWS IAM Identity Center instance the organisation runs. One Entra tenant, two
# Identity Center instances (commercial and GovCloud are separate partitions
# and cannot share one), so the stack instantiates the module once per target
# from a map. Each target is a separate gallery application with its own SAML
# endpoints, its own signing certificate, its own group assignments, and its
# own SCIM job. Nothing is shared between targets except the tenant and the
# group list.
#
# Groups are listed once, in aws_groups, and named
# AWS-<PARTITION>-<accountId>-<PermissionSetName>. The stack hands each target
# the groups whose PARTITION matches its partition_token, so the cell never
# says which application a group belongs to: the name does. The AWS cell for
# the same instance lists the same names and turns them into account
# assignments. See docs/adr/0008.
#
# Order of dependency, per target:
#
#   gallery application + service principal
#     --> signing certificate
#     --> group assignments (the provisioning scope)
#     --> SCIM secret --> SCIM job
#
# Tenant cells (tenants/azure/<tenant>/entra-aws-federation/terragrunt.hcl)
# supply values only. Groups are looked up by display name and never created
# here; they belong to the directory of record, or to entra-pim-governance when
# they are PIM-managed. SCIM credentials arrive through TF_VAR_scim_credentials
# and appear in no file.
#
# Deliberately NOT managed here: the Identity Center instances themselves and
# their identity source setting (a console wizard, see the module README),
# permission sets and account assignments (stacks/aws-identity-center, which
# parses the same group names), and SAML claim mappings for ABAC.

locals {
  groups_by_partition = {
    for k, t in var.targets :
    k => [for g in var.aws_groups : g if startswith(g, "AWS-${t.partition_token}-")]
  }
}

module "identity_center" {
  for_each = var.targets
  source   = "../../modules/entra/aws-identity-center-app"

  display_name                 = each.value.display_name
  partition_token              = each.value.partition_token
  identifier_uris              = each.value.identifier_uris
  reply_urls                   = each.value.reply_urls
  sign_on_url                  = each.value.sign_on_url
  relay_state                  = each.value.relay_state
  notification_email_addresses = each.value.notification_email_addresses
  assigned_groups              = local.groups_by_partition[each.key]
  app_role_display_name        = each.value.app_role_display_name
  account_enabled              = each.value.account_enabled
  signing_certificate          = each.value.signing_certificate

  scim_enabled      = each.value.scim.enabled
  scim_template_id  = each.value.scim.template_id
  scim_base_address = try(var.scim_credentials[each.key].base_address, "")
  scim_secret_token = try(var.scim_credentials[each.key].secret_token, "")
}
