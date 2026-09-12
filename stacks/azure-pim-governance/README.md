# stacks/azure-pim-governance

The deployable unit for a tenant's Azure resource PIM baseline. It composes two
modules into one plan and one state file, in a fixed order:

1. `pim-role-policy` sets the activation rules for each (scope, role) pair:
   activation window, MFA, justification, approval, eligibility expiration.
2. `pim-eligible-assignment` makes Entra groups eligible for those roles at those
   scopes, with an end date or, where the policy allows it, permanently.

Tenant cells under `tenants/azure/<tenant>/azure-pim-governance/` point at this
stack and provide values only.

## Why policies apply before eligibilities

Azure validates an eligibility against the policy for its (scope, role) at write
time. A 365-day eligibility is rejected if the policy still allows 180, and a
permanent one is rejected unless the policy says expiration is not required.
Nothing in the eligibility resource references the policy resource, so Terraform
sees no edge between them and would happily write them in parallel. The stack adds
`depends_on = [module.pim_role_policy]` to the eligibility module so every policy
lands first. A validation block in `variables.tf` goes one step further and refuses
an eligibility that has no matching policy entry at all, so activation rules are
always stated rather than inherited from an Azure default nobody reviewed.

## Definitions in one cell, assignments in another

This stack refers to custom roles by display name and never defines one. The
definitions live in `stacks/azure-rbac-roles`, applied from its own cell into its
own state file. The reasons, in plain terms:

- **Different owners, different cadence.** Who may hold a role changes often and is
  reviewed by the scope owner. What a role permits changes rarely and is reviewed
  by whoever owns the permission model. One plan per concern keeps each review
  about one thing.
- **Blast radius.** A definition with `prevent_destroy` in its own state cannot be
  taken out by a mistaken edit to an assignments map, and an assignments cell
  applied with the wrong values cannot rewrite a role's actions.
- **Tenants without custom roles.** The subsidiary tenant assigns built-in roles
  only. It has a governance cell and no roles cell, and nothing is stubbed.

The cost is ordering: the roles cell must be applied before this cell can plan,
because the role name is resolved at plan time. Introducing a new custom role and
its first eligibility in one pull request therefore takes two release runs, or a
release that applies the roles cell before planning this one, which is what
`.github/workflows/azure-release.yml` does. See
`docs/adr/0005-definitions-and-assignments-in-separate-cells.md`.

## What this stack does not manage

Groups and their membership belong to the directory of record. Custom role
definitions belong to `azure-rbac-roles`. Entra directory roles and PIM for groups
belong to `entra-pim-governance`. Standing (active) role assignments are not
managed anywhere in this repository on purpose: if a principal needs standing
access, that is a design conversation, not a map entry.

## Provider configuration

`versions.tf` declares `required_providers` only. The provider blocks are generated
by Terragrunt from `tenant_id` and `subscription_id`, which `tenants/azure/root.hcl`
reads from the environment. The identity is a GitHub OIDC federated credential in CI
and the Azure CLI login on a laptop.

## Standalone use without Terragrunt

```hcl
provider "azurerm" {
  features {}
  # tenant_id, subscription_id, client_id read from ARM_* environment variables
}

provider "azuread" {}

module "azure_pim_governance" {
  source = "./stacks/azure-pim-governance"

  tenant_id       = "00000000-0000-0000-0000-000000000000"
  subscription_id = "00000000-0000-0000-0000-000000000000"

  activation_maximum_duration = "PT4H"
  require_approval            = false

  policies = {
    contributor-prod = {
      role_name = "Contributor"
      scope     = { type = "subscription", name = "sub-example-prod" }
    }

    owner-at-root = {
      role_name = "Owner"
      scope     = { type = "management_group", name = "mg-example-root" }
      activation = {
        maximum_duration = "PT1H"
        require_approval = true
        approver_groups  = ["PIM Approvers"]
      }
    }
  }

  eligibilities = {
    cloud-engineers-contributor-prod = {
      group_display_name = "Cloud Engineers"
      role_name          = "Contributor"
      scope              = { type = "subscription", name = "sub-example-prod" }
      justification      = "Change delivery into production through PIM only."
      expiration         = { duration_days = 180 }
    }

    break-glass-owner-at-root = {
      group_display_name = "Break Glass Owners"
      role_name          = "Owner"
      scope              = { type = "management_group", name = "mg-example-root" }
      justification      = "Emergency access. Every activation is approved and reviewed."
      expiration         = { duration_days = 365 }
    }
  }
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `tenant_id` | `string` | Entra tenant ID, from the environment via root.hcl. |
| `subscription_id` | `string` | Default subscription, from the environment via root.hcl. |
| `activation_maximum_duration` | `string` | Tenant baseline activation window. Default `PT4H`. |
| `require_multifactor_authentication` | `bool` | Default `true`. |
| `require_justification` | `bool` | Default `true`. |
| `require_ticket_info` | `bool` | Default `false`. |
| `require_approval` | `bool` | Default `false`. |
| `approver_groups` | `list(string)` | Approver group display names for the baseline. |
| `eligible_assignment_rules` | `object` | Eligibility expiration baseline. |
| `active_assignment_rules` | `object` | Standing assignment baseline. |
| `notification_rules` | `object` | Optional admin notifications. |
| `policies` | `map(object)` | One entry per (scope, role); per-entry overrides optional. |
| `eligibilities` | `map(object)` | Group, role, scope, justification, expiration. |

## Outputs

| Name | Description |
|------|-------------|
| `policy_ids` | Logical key to policy resource ID. |
| `policies` | Logical key to `{ name, scope, role_definition_id, activation_maximum_duration, require_approval }`. |
| `eligibility_ids` | Logical key to eligible assignment resource ID. |
| `eligibilities` | Logical key to `{ scope, role_definition_id, principal_id, group_display_name, permanent }`. |
| `approver_group_object_ids` | Approver display name to object ID. |
| `group_object_ids` | Eligible group display name to object ID. |
