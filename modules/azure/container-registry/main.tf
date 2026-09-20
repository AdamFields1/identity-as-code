# Container registries, one per map entry, hardened the same way whatever
# the values, with data-plane access granted by role name to identities and
# groups.
#
# A registry in this module has one shape and a few knobs. What is fixed:
#
#   - No admin user (admin_enabled = false). The admin user is a username
#     and two passwords that any holder can use from anywhere, that no
#     Entra sign-in log records, and that a role assignment review cannot
#     see. Every pull and push here is an Entra identity holding AcrPull or
#     AcrPush, and the entry below is the only way this module grants one.
#   - No anonymous pull (anonymous_pull_enabled = false). A registry that
#     serves images to the world is a different product; this one serves
#     its own workloads.
#   - The export policy is left at the platform default. Turning it off is
#     only accepted with public network access off, which is a Premium
#     private-endpoint posture this module does not build.
#   - No customer-managed key. The registry encrypts at rest with platform
#     keys; a CMK needs a key vault key, an identity with wrap and unwrap,
#     and a rotation story, and is a later change (README, "Design notes").
#   - prevent_destroy. A registry holds every image ever published to it,
#     and the pipelines and running workloads that pull from it do not
#     notice it is gone until they restart. Removing an entry from a cell
#     must never be able to do that as a side effect.
#
# What is offered as values: the SKU, public network access (a bool that
# defaults to true; every request still carries an Entra token, so a
# registry with no network rules is reachable by identity only, and false
# is a Premium-only value that leaves only private endpoints, which this
# module does not create), the Premium-only knobs (an IP allow list behind
# a Deny default, an untagged-manifest retention period, zone redundancy),
# a Log Analytics workspace for the audit log, and the role assignments.
# The Premium-only knobs are refused on the other SKUs by validation so a
# cell that sets one on a Standard registry fails the plan with a message
# instead of an API error at apply.
#
# Role assignments name a role and a principal. The role is one of the
# registry data-plane roles and nothing else: AcrPull, AcrPush, AcrDelete,
# AcrImageSigner. A cell cannot make anyone Owner or Contributor of a
# registry through this module, and cannot assign a role that assigns
# roles. The principal is either an identity by its key in
# identity_principal_ids (the managed-identity module's principal_ids
# output, so the stack wires the two without a GUID) or an Entra security
# group by display name, resolved with azuread_group. A group assignment is
# standing access for the group's members; where that access should be
# just in time, name a PIM-governed group (stacks/entra-pim-governance) and
# let PIM for Groups gate the membership. The assignment stays standing
# either way, which is the point: what the group may do is fixed here and
# reviewed here, and who is in it is the directory's business.
#
# The Log Analytics workspace is resolved by name in its resource group, so
# a cell names it and holds no workspace ID. The diagnostic setting sends
# ContainerRegistryRepositoryEvents (every push, pull, and delete with the
# identity that did it and the repository and tag it touched),
# ContainerRegistryLoginEvents (every login with its identity and result),
# and all metrics. Nothing is sent when no workspace is named.
#
# The resource group is looked up by name and never created here. A stack
# that creates the group in the same plan (modules/azure/resource-group)
# gives this module depends_on on that module.

# ---------------------------------------------------------------------------
# Lookups. One per distinct resource group, workspace, and group name.
# ---------------------------------------------------------------------------

locals {
  resource_group_names = toset([for cr in var.container_registries : cr.resource_group_name])

  workspaces = {
    for key, cr in var.container_registries :
    "${cr.log_analytics_workspace.resource_group_name}/${cr.log_analytics_workspace.name}" => cr.log_analytics_workspace
    if cr.log_analytics_workspace != null
  }

  group_display_names = toset(flatten([
    for cr in var.container_registries : [for a in cr.role_assignments : a.principal.name if a.principal.type == "group"]
  ]))
}

data "azurerm_resource_group" "this" {
  for_each = local.resource_group_names

  name = each.value
}

data "azurerm_log_analytics_workspace" "this" {
  for_each = local.workspaces

  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}

# security_enabled narrows the match so a Microsoft 365 group with the same
# display name as a security group does not make the lookup ambiguous.
data "azuread_group" "by_display_name" {
  for_each = local.group_display_names

  display_name     = each.value
  security_enabled = true
}

locals {
  locations = {
    for key, cr in var.container_registries : key => coalesce(cr.location, data.azurerm_resource_group.this[cr.resource_group_name].location)
  }

  workspace_ids = {
    for key, cr in var.container_registries :
    key => data.azurerm_log_analytics_workspace.this["${cr.log_analytics_workspace.resource_group_name}/${cr.log_analytics_workspace.name}"].id
    if cr.log_analytics_workspace != null
  }

  # Flattened "registry/assignment" map so each assignment is one
  # addressable resource. The principal ID is resolved here; a missing
  # identity key is caught by the precondition on the assignment so the
  # message names it.
  role_assignments = merge(concat([{}], [
    for registry_key, cr in var.container_registries : {
      for assignment_key, a in cr.role_assignments : "${registry_key}/${assignment_key}" => {
        registry_key   = registry_key
        assignment_key = assignment_key
        role_name      = a.role_name
        principal_type = a.principal.type
        principal_name = a.principal.name
        description    = a.description
        principal_id = (
          a.principal.type == "group"
          ? data.azuread_group.by_display_name[a.principal.name].object_id
          : lookup(var.identity_principal_ids, a.principal.name, null)
        )
      }
    }
  ])...)
}

# ---------------------------------------------------------------------------
# Registries.
# ---------------------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  # checkov:skip=CKV_AZURE_139:public_network_access_enabled is a per-entry
  # input that defaults to true because Azure keeps the public login server
  # on for Basic and Standard; every request still carries an Entra token.
  # A Premium cell that turns it off does so in its diff and reaches the
  # registry through a private endpoint this module does not create.
  # checkov:skip=CKV_AZURE_163:The check wants a literal sku of Standard or
  # Premium (the Defender for Containers tiers); sku is a per-entry input
  # that defaults to Standard, which checkov cannot resolve through a
  # for_each. A cell that picks Basic does so in its diff.
  # checkov:skip=CKV_AZURE_164:Content trust (trust_policy_enabled) is the
  # Notary v1 signing model, which Azure has retired and which is Premium
  # only. Image signing belongs to the publisher pipeline, and a signer's
  # standing here is an AcrImageSigner assignment, not a registry flag.
  # checkov:skip=CKV_AZURE_165:Geo-replication is a Premium-only, per-region
  # cost that follows a multi-region deployment decision this catalog does
  # not make for an app; a registry serves the region it is in.
  # checkov:skip=CKV_AZURE_166:The quarantine policy holds every pushed image
  # until a scanner marks it, which needs the Defender quarantine workflow
  # wired to the registry; the feature is in preview and not offered here.
  # checkov:skip=CKV_AZURE_233:zone_redundancy_enabled is a per-entry input
  # that defaults to false because Azure offers it on Premium only; a
  # Premium cell that turns it on does so in its diff.
  # checkov:skip=CKV_AZURE_237:Dedicated data endpoints are Premium only and
  # change the host names every client firewall must allow; a cell that
  # needs them raises the SKU and asks for the knob.
  for_each = var.container_registries

  name                = each.value.name
  resource_group_name = data.azurerm_resource_group.this[each.value.resource_group_name].name
  location            = local.locations[each.key]
  sku                 = each.value.sku

  # Fixed. See the header comment.
  admin_enabled          = false
  anonymous_pull_enabled = false

  public_network_access_enabled = each.value.public_network_access_enabled
  retention_policy_in_days      = each.value.retention_policy_in_days
  zone_redundancy_enabled       = each.value.zone_redundancy_enabled

  # Deny is the default action whenever a rule set is written at all. The
  # attribute is optional and computed on the provider side, and the API
  # refuses it below Premium, so an entry with no addresses writes nothing
  # and the registry keeps the platform default (Allow, which with public
  # access on means reachable by identity from anywhere). Validation has
  # already refused a list on a non-Premium SKU.
  network_rule_set = length(each.value.allowed_ip_ranges) > 0 ? [{
    default_action = "Deny"
    ip_rule = [
      for ip in each.value.allowed_ip_ranges : {
        action   = "Allow"
        ip_range = ip
      }
    ]
  }] : null

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    # The registry holds every image ever published to it, and the
    # workloads that pull from it do not notice it is gone until they
    # restart. Removing it is a deliberate change that flips this flag
    # first, never a side effect of dropping an entry from a cell.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Audit log to Log Analytics, for the registries that name a workspace.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = local.workspace_ids

  name                       = "log-analytics"
  target_resource_id         = azurerm_container_registry.this[each.key].id
  log_analytics_workspace_id = each.value

  # Every push, pull, and delete with the identity that did it and the
  # repository and tag it touched.
  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  # Every login with its identity and result, including the failures.
  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Role assignments. Data-plane roles only, on the registry, by name.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                = azurerm_container_registry.this[each.value.registry_key].id
  role_definition_name = each.value.role_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type == "group" ? "Group" : "ServicePrincipal"
  description          = each.value.description

  # An identity created in the same plan may not have reached every Entra
  # replica when ARM checks it. The principal ID comes from the identity
  # resource, so skipping the lookup weakens nothing. Groups are looked up
  # by display name above, so they exist by definition.
  skip_service_principal_aad_check = each.value.principal_type == "identity"

  lifecycle {
    precondition {
      condition     = each.value.principal_id != null
      error_message = "Role assignment \"${each.value.assignment_key}\" on registry \"${each.value.registry_key}\": \"${each.value.principal_name}\" is not a key of identity_principal_ids. Pass the principal_ids output of modules/azure/managed-identity and name one of its keys, or use principal.type = \"group\" for an Entra group."
    }
  }
}
