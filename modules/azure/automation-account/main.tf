# An Azure Automation account with its user-assigned managed identities, the
# account-level variables the runbooks read, and optional module assets.
#
# The identities are created here rather than passed in because they exist for
# this account and nothing else: a client ID is what a runbook hands to the
# Automation identity endpoint, a principal ID is what the Graph app roles are
# granted to, and their lifetime is the account's. A system-assigned identity
# would do the same job but cannot be granted permissions before the account
# exists and disappears with it, which makes a rebuild a permissions outage.
# User-assigned means the identities, the grants, and the account can be
# planned in one graph and an identity survives the account being recreated.
#
# One identity or several. "identities" is a map keyed by privilege tier, and
# every identity in it is attached to the account. A caller that names none
# gets exactly one, keyed "default" and named identity_name, which is what
# this module did before tiers existed; the moved block below keeps that one
# in state. Attaching several to one account separates what a runbook defect
# or a bad parameter can reach, not what someone who can start a job in the
# account can reach: any runbook in the account can ask the identity endpoint
# for a token for any identity attached to it (docs/adr/0016).
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

  # Tiers when the caller declares them, otherwise the single "default"
  # identity this module has always created.
  identities = length(var.identities) > 0 ? var.identities : { default = { name = var.identity_name } }
}

# ---------------------------------------------------------------------------
# Identities first. Their principal IDs and client IDs are the outputs
# everything else in the stack keys off.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "this" {
  for_each = local.identities

  name                = each.value.name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = var.tags
}

# The single identity this module created before it took a map is the same
# object as the "default" entry, so an existing account keeps its identity,
# its principal ID, and every grant made to it. A caller that moves to tiers
# declares no "default" key, and the plan then shows that identity being
# destroyed with its grants, which is the point of the move.
moved {
  from = azurerm_user_assigned_identity.this
  to   = azurerm_user_assigned_identity.this["default"]
}

# ---------------------------------------------------------------------------
# The account.
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "this" {
  # checkov:skip=CKV2_AZURE_24:Public network access is on because Azure
  # Automation cloud jobs and the deployment pipeline reach the account over
  # the public endpoint; the account has no virtual network and no private
  # endpoint. Authentication is Entra only (local_authentication_enabled is
  # false) and what a job may do is the tier identity's grants. Set
  # public_network_access_enabled = false only together with a private
  # endpoint and Hybrid Runbook Workers inside that network.
  name                = var.name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  sku_name            = var.sku_name

  local_authentication_enabled  = var.local_authentication_enabled
  public_network_access_enabled = var.public_network_access_enabled

  identity {
    type         = "UserAssigned"
    identity_ids = [for key in sort(keys(local.identities)) : azurerm_user_assigned_identity.this[key].id]
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
  # checkov:skip=CKV_AZURE_73:These variables hold no secret by design (a
  # tenant label, a mailbox, a cloud name, desired-state JSON from the
  # repository, a PIM baseline). An encrypted variable cannot be read back by
  # Terraform, so it would sit in state as written and every plan would be
  # blind; the caller sets encrypted = true per variable when a value ever
  # needs it. Nothing here is a credential: the runbooks have none.
  for_each = local.string_variables

  name                    = each.key
  resource_group_name     = data.azurerm_resource_group.this.name
  automation_account_name = azurerm_automation_account.this.name
  description             = each.value.description
  encrypted               = each.value.encrypted
  value                   = each.value.value
}

resource "azurerm_automation_variable_bool" "this" {
  # checkov:skip=CKV_AZURE_73:Same reason as the string variables above: the
  # one bool variable is the account-wide dry-run default, which is meant to
  # be readable in a plan and in the portal.
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
