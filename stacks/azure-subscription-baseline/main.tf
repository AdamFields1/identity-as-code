# azure-subscription-baseline stack
#
# One deployable unit that hardens one subscription. Order of dependency:
#
#   baseline resource group (+ lock)  -->  workspace, when created here
#                                      -->  activity log export to it
#   Defender plans                     (independent)
#   initiative assignments             (independent)
#
# The group comes first only when the stack creates the workspace: the
# workspace is created in it, in its region, and the module is given the
# group's name and location from the resource-group module's outputs, so the
# dependency is an ordinary one through the inputs and no data source has to
# be deferred to apply. When the workspace already exists, the stack creates
# no group, refuses one, and looks the workspace up by name.
#
# This is a catalog stack (docs/adr/0017): planned once per subscription that
# has a cell for it, into that cell's own state file, at
# tenants/azure/<tenant>/subscriptions/<sub-name>/azure-subscription-baseline/.
# The subscription is addressed by the locator above the cell and discovered
# inside the module from the provider; the cell holds values and no GUID.
#
# What a cell decides: which Defender plans are on (and which are declared
# off), where the activity log goes and which categories, which initiatives
# the subscription is held to and how hard, and whether the baseline group
# is locked. What it cannot decide: a scope ID, a definition ID, a workspace
# ID, a shared key, or a remediation identity, because none is an input.
#
# Deliberately NOT managed here: the subscription itself and its management
# group placement (README, "Deliberately out of scope"), custom policy
# definitions and initiatives (assignable once they exist, by display name),
# remediation identities and the role assignments they need, Defender
# settings that are not a plan (contacts, integrations, auto-provisioning),
# and diagnostic settings of individual resources, which belong with the
# resource (modules/azure/key-vault and storage-account each send their own
# audit log to a workspace named by the entry).

locals {
  # The one group the stack may create, keyed "baseline" so the address is
  # stable whatever the group is called. Empty when no group is wanted. The
  # variable already has the module's shape (name, location, delete_lock,
  # tags), so the entry is passed through as it is.
  baseline_resource_groups = { for key, rg in { baseline = var.baseline_resource_group } : key => rg if rg != null }

  # Name and location of that group, or null when there is none. Read from
  # the module's outputs rather than from the variable so the workspace
  # depends on the group's existence, not just on its name.
  baseline_resource_group_name     = one(values(module.resource_groups.resource_group_names))
  baseline_resource_group_location = one([for rg in values(module.resource_groups.resource_groups) : rg.location])
}

# ---------------------------------------------------------------------------
# The baseline resource group, with its optional CanNotDelete lock.
# ---------------------------------------------------------------------------

module "resource_groups" {
  source = "../../modules/azure/resource-group"

  resource_groups = local.baseline_resource_groups
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Defender plans, the activity log export (and its workspace), initiatives.
# ---------------------------------------------------------------------------

module "baseline" {
  source = "../../modules/azure/subscription-baseline"

  defender_plans          = var.defender_plans
  activity_log_categories = var.activity_log_categories
  policy_assignments      = var.policy_assignments
  tags                    = var.tags

  log_analytics_workspace = {
    name                       = var.log_analytics_workspace.name
    create                     = var.create_workspace
    resource_group_name        = var.create_workspace ? local.baseline_resource_group_name : var.log_analytics_workspace.resource_group_name
    location                   = var.create_workspace ? local.baseline_resource_group_location : null
    retention_in_days          = var.log_analytics_workspace.retention_in_days
    daily_quota_gb             = var.log_analytics_workspace.daily_quota_gb
    internet_ingestion_enabled = var.log_analytics_workspace.internet_ingestion_enabled
    internet_query_enabled     = var.log_analytics_workspace.internet_query_enabled
    tags                       = var.log_analytics_workspace.tags
  }
}
