# Azure subsidiary tenant, PIM governance cell.
#
# Values only. Same stack as corp; the differences below are the whole story of
# "what is stricter in the subsidiary":
#   - two-hour activation instead of four
#   - approval required on every activation, not only Owner
#   - eligibilities expire in 180 days instead of 365, none permanent
#   - fewer eligibilities: two groups, two roles, nothing at Owner
#
# There is no ../azure-rbac-roles cell for this tenant. The subsidiary assigns
# built-in roles only (Contributor, Reader) and has no custom role definitions,
# so there is nothing for that stack to manage and nothing is stubbed. The day
# the subsidiary needs a custom role, the cell is added and this one gains a
# dependencies block, exactly as corp has.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID, which the subsidiary-* GitHub
# environments override with this tenant's values.
#
# State key (derived by root.hcl): azure/subsidiary/azure-pim-governance/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-pim-governance"
}

inputs = {
  activation_maximum_duration        = "PT2H"
  require_multifactor_authentication = true
  require_justification              = true
  require_ticket_info                = true
  require_approval                   = true
  approver_groups                    = ["PIM Approvers"]

  eligible_assignment_rules = {
    expiration_required = true
    expire_after        = "P180D"
  }

  active_assignment_rules = {
    expiration_required = true
    expire_after        = "P90D"
  }

  policies = {
    contributor-prod = {
      role_name = "Contributor"
      scope     = { type = "subscription", name = "sub-example-subsidiary-prod" }
    }

    reader-at-root = {
      role_name = "Reader"
      scope     = { type = "management_group", name = "mg-example-subsidiary" }
    }
  }

  eligibilities = {
    cloud-engineers-contributor-prod = {
      group_display_name = "Cloud Engineers"
      role_name          = "Contributor"
      scope              = { type = "subscription", name = "sub-example-subsidiary-prod" }
      justification      = "Change delivery into the subsidiary production subscription. Approved per activation."
      expiration         = { duration_days = 180 }
    }

    security-readers-at-root = {
      group_display_name = "Security Operations"
      role_name          = "Reader"
      scope              = { type = "management_group", name = "mg-example-subsidiary" }
      justification      = "Read-only investigation access. Renewed every 180 days through access review."
      expiration         = { duration_days = 180 }
    }
  }
}
