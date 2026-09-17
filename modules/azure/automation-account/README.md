# modules/azure/automation-account

Manages an Azure Automation account, the user-assigned managed identities it
runs as, the account variables runbooks read, and (optionally) module assets.
It creates no runbooks; `modules/azure/automation-runbooks` does that against
the account name this module outputs.

## Design notes

- **The identities are created here, user-assigned.** A principal ID is what
  `modules/entra/graph-app-role-grant` grants Graph permissions to, and a client
  ID is what a runbook passes to the Automation identity endpoint. A
  system-assigned identity cannot be granted anything until the account exists and
  is destroyed with it, so a rebuilt account would come back with no permissions.
  User-assigned lets the identities, their grants, and the account share one plan
  and lets an identity outlive the account.
- **One identity, or one per privilege tier.** `identities` is a map keyed by
  tier name, and every identity in it is attached to the account. A caller that
  sets `identity_name` instead gets exactly one, under the key `default`, which
  is what this module did before tiers existed; a `moved` block keeps that one
  in state, so adopting the map changes nothing for a caller that keeps the
  single form. Setting both is refused. Attaching several identities separates
  what a runbook defect can reach, not what someone who can start a job in the
  account can reach: any runbook can ask the identity endpoint for a token for
  any identity attached to the account. See
  [ADR 0016](../../../docs/adr/0016-one-identity-per-privilege-tier-in-one-automation-account.md).
- **No local authentication.** `local_authentication_enabled` defaults to `false`.
  Terraform and the portal use Entra tokens; the runbooks talk to Graph, not to the
  account; nothing needs the agent registration keys.
- **Variables are typed by the caller.** `type = "string"` or `"bool"` chooses the
  provider resource. Values are strings in the map so a cell reads uniformly; a
  bool value is validated to be `"true"` or `"false"`. Nothing here is a secret,
  so `encrypted` defaults to `false`; an encrypted variable cannot be read back and
  would sit in state as written anyway.
- **Modules are empty by default.** The runbooks in `automation/runbooks` use
  `Invoke-WebRequest` against Graph and ARM and need nothing the sandbox lacks. A
  module asset is declared only when a runbook genuinely imports one.
- **The resource group is looked up by name.** Creating it belongs to the platform
  bootstrap, like the state storage account.

## Usage

```hcl
module "automation_account" {
  source = "../../modules/azure/automation-account"

  name                = "aa-example-identity"
  resource_group_name = "rg-example-identity-automation"

  # One identity per privilege tier. For the older single-identity form, set
  # identity_name = "id-example-identity-automation" and leave identities out.
  identities = {
    observer  = { name = "id-example-automation-observer" }
    lifecycle = { name = "id-example-automation-lifecycle" }
  }

  variables = {
    TenantLabel   = { type = "string", value = "corp" }
    SenderMailbox = { type = "string", value = "iam-noreply@corp.example.com" }
    DryRun        = { type = "bool", value = "true" }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name` | `string` | n/a | Automation account name. |
| `resource_group_name` | `string` | n/a | Existing resource group, by name. |
| `location` | `string` | `null` | Region; null uses the resource group's. |
| `identity_name` | `string` | `null` | Single-identity form: the name of the one identity, created under the key `default`. |
| `identities` | `map(object)` | `{}` | One entry per privilege tier, each with `name`. Empty uses `identity_name`. |
| `sku_name` | `string` | `"Basic"` | `Basic` or `Free`. |
| `local_authentication_enabled` | `bool` | `false` | Agent registration key auth. |
| `public_network_access_enabled` | `bool` | `true` | Public endpoint access. |
| `variables` | `map(object)` | `{}` | Account variables keyed by name; see `variables.tf`. |
| `modules` | `map(object)` | `{}` | Module assets keyed by name. |
| `tags` | `map(string)` | `{}` | Tags for the account and identity. |

## Outputs

| Name | Description |
|------|-------------|
| `automation_account_id` | Account resource ID. |
| `automation_account_name` | Account name, for the runbooks module. |
| `resource_group_name` | Resource group name. |
| `location` | Region used. |
| `identities` | Tier key to `{ id, name, principal_id, client_id }` for every identity. |
| `identity_id` | The `default` identity's resource ID, or null with tiers. |
| `identity_name` | The `default` identity's name (its Entra display name), or null. |
| `identity_principal_id` | The `default` identity's service principal object ID, or null. |
| `identity_client_id` | The `default` identity's client ID, or null. |
| `variable_names` | Names created, by type. |

## Import

```hcl
import {
  to = module.automation_account.azurerm_user_assigned_identity.this["observer"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-example-automation-observer"
}

import {
  to = module.automation_account.azurerm_automation_account.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity"
}

import {
  to = module.automation_account.azurerm_automation_variable_bool.this["DryRun"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity/variables/DryRun"
}
```
