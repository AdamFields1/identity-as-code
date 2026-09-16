# modules/azure/automation-account

Manages an Azure Automation account, the user-assigned managed identity it runs
as, the account variables runbooks read, and (optionally) module assets. It
creates no runbooks; `modules/azure/automation-runbooks` does that against the
account name this module outputs.

## Design notes

- **The identity is created here, user-assigned.** Its principal ID is what
  `modules/entra/graph-app-role-grant` grants Graph permissions to, and its client
  ID is what the runbooks pass to the Automation identity endpoint. A
  system-assigned identity cannot be granted anything until the account exists and
  is destroyed with it, so a rebuilt account would come back with no permissions.
  User-assigned lets the identity, its grants, and the account share one plan and
  lets the identity outlive the account.
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
  identity_name       = "id-example-identity-automation"

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
| `identity_name` | `string` | n/a | User-assigned identity name. |
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
| `identity_id` | Identity resource ID. |
| `identity_name` | Identity name (its Entra display name). |
| `identity_principal_id` | Identity service principal object ID, for Graph grants. |
| `identity_client_id` | Identity client ID, for the identity endpoint. |
| `variable_names` | Names created, by type. |

## Import

```hcl
import {
  to = module.automation_account.azurerm_user_assigned_identity.this
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-example-identity-automation"
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
