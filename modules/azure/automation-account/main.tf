# An Azure Automation account with its own user-assigned managed identity, the
# account-level variables the runbooks read, and optional module assets.
#
# The identity is created here rather than passed in because it exists for
# this account and nothing else: its client ID is what the runbooks hand to
# the Automation identity endpoint, its principal ID is what the Graph app
# roles are granted to, and its lifetime is the account's. A system-assigned
# identity would do the same job but cannot be granted permissions before the
# account exists and disappears with it, which makes a rebuild a permissions
# outage. User-assigned means the identity, the grants, and the account can be
# planned in one graph and the identity survives the account being recreated.
#
# local_authentication_enabled is false by default: the only thing that should
# talk to this account is Terraform and the portal, both with Entra tokens,
# and the runbooks talk to Graph, not to the account. The agent registration
# keys that local authentication unlocks are for hybrid workers, which this
# repository does not use.
#
# The resource group is looked up by name and never created. Where it is and
# who may write to it belongs to the platform bootstrap, like the state
# storage account.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  location = coalesce(var.location, data.azurerm_resource_group.this.location)

  string_variables = { for k, v in var.variables : k => v if v.type == "string" }
  bool_variables   = { for k, v in var.variables : k => v if v.type == "bool" }
}

# ---------------------------------------------------------------------------
# Identity first. Its principal ID and client ID are the outputs everything
# else in the stack keys off.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "this" {
  name                = var.identity_name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# The account.
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "this" {
  name                = var.name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  sku_name            = var.sku_name

  local_authentication_enabled  = var.local_authentication_enabled
  public_network_access_enabled = var.public_network_access_enabled

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Account variables. Runbooks read these with Get-AutomationVariable when a
# value is account-wide rather than per job; the stack passes the same values
# as job parameters so a runbook can also be run by hand with explicit
# arguments. Two resource types because the provider types the value.
# ---------------------------------------------------------------------------

resource "azurerm_automation_variable_string" "this" {
  for_each = local.string_variables

  name                    = each.key
  resource_group_name     = data.azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  description             = each.value.description
  encrypted               = each.value.encrypted
  value                   = each.value.value
}

resource "azurerm_automation_variable_bool" "this" {
  for_each = local.bool_variables

  name                    = each.key
  resource_group_name     = data.azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  description             = each.value.description
  encrypted               = each.value.encrypted
  value                   = tobool(each.value.value)
}

# ---------------------------------------------------------------------------
# Module assets. Empty by default: the runbooks in this repository call REST
# endpoints with Invoke-WebRequest and need nothing beyond what the sandbox
# ships. A module is declared here only when a runbook genuinely imports it.
# ---------------------------------------------------------------------------

resource "azurerm_automation_module" "this" {
  for_each = var.modules

  name                    = each.key
  resource_group_name     = data.azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name

  module_link {
    uri = each.value.uri

    dynamic "hash" {
      for_each = each.value.hash == null ? [] : [each.value.hash]
      content {
        algorithm = hash.value.algorithm
        value     = hash.value.value
      }
    }
  }
}
