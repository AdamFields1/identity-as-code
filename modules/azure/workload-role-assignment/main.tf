# Standing Azure role assignments for one workload identity (a managed
# identity or another service principal), keyed by the caller's logical names.
#
# People never get standing access from this repository: their access is a
# PIM eligibility (modules/azure/pim-eligible-assignment). A managed identity
# cannot activate a PIM role, so what an automation identity may do in Azure
# Resource Manager is a standing assignment, and this module is where those
# assignments are declared and reviewed. principal_type is fixed to
# ServicePrincipal for that reason.
#
# Scopes and roles are given by name, never by ID, and resolved the same way
# as the other modules under modules/azure. A fourth scope type, resource_id,
# takes a full ARM ID; it exists for a stack that created the resource in the
# same plan (the automation stack passes its own Automation account) and is
# not meant for tenant cells.
#
# ABAC conditions. An entry may carry an Azure ABAC condition (conditionVersion
# 2.0), for example a delegation condition that limits which roles and which
# principals a Role Based Access Control Administrator assignment may assign.
# Such a condition needs GUIDs, and a cell never holds one, so the condition
# text may use two tokens that are resolved here:
#
#   <principal_id>    the object ID of the principal this module assigns to
#   <role_id:NAME>    the GUID of the role definition named NAME, resolved at
#                     the entry's scope
#
# Terraform has no fold, so the tokens are replaced without a loop: every
# role token is first replaced with one separator, the text is split on it,
# and the parts are joined back with the GUIDs regexall() found, in the same
# order. The separator is "<role_id>", a role token without a name: ABAC
# condition text never contains "<", the token pattern never matches it, and
# validation keeps it out of the condition text.

# ---------------------------------------------------------------------------
# Scope resolution. One lookup per distinct scope name.
# ---------------------------------------------------------------------------

locals {
  all_scopes = [for a in var.assignments : a.scope]

  management_group_names = toset([for s in local.all_scopes : s.name if s.type == "management_group"])
  subscription_names     = toset([for s in local.all_scopes : s.name if s.type == "subscription"])
  resource_group_names   = toset([for s in local.all_scopes : s.name if s.type == "resource_group"])
}

data "azurerm_management_group" "by_display_name" {
  for_each = local.management_group_names

  display_name = each.value
}

# Prefix match only; the exact match is applied below and one() fails the
# plan when a prefix is ambiguous.
data "azurerm_subscriptions" "by_display_name" {
  for_each = local.subscription_names

  display_name_prefix = each.value
}

data "azurerm_resource_group" "by_name" {
  for_each = local.resource_group_names

  name = each.value
}

locals {
  subscription_ids = {
    for name, result in data.azurerm_subscriptions.by_display_name :
    name => one([for s in result.subscriptions : s.id if s.display_name == name])
  }

  named_scope_ids = merge(
    { for name, mg in data.azurerm_management_group.by_display_name : "management_group/${name}" => mg.id },
    { for name, id in local.subscription_ids : "subscription/${name}" => id },
    { for name, rg in data.azurerm_resource_group.by_name : "resource_group/${name}" => rg.id },
  )

  # A resource_id scope is its own ID and needs no lookup.
  scope_ids = {
    for key, a in var.assignments : key => (
      a.scope.type == "resource_id" ? a.scope.name : lookup(local.named_scope_ids, "${a.scope.type}/${a.scope.name}", null)
    )
  }
}

# ---------------------------------------------------------------------------
# Role resolution at each entry's own scope, so the assignment receives the
# fully qualified role definition ID it expects and a misspelt role fails
# the plan.
# ---------------------------------------------------------------------------

data "azurerm_role_definition" "this" {
  for_each = var.assignments

  name  = each.value.role_name
  scope = local.scope_ids[each.key]
}

# ---------------------------------------------------------------------------
# Condition tokens.
# ---------------------------------------------------------------------------

locals {
  principal_token    = "<principal_id>"
  role_token_pattern = "<role_id:([^<>]+)>"
  token_separator    = "<role_id>"

  # Role names in the order their tokens appear, per entry.
  condition_role_names = {
    for key, a in var.assignments : key => (
      a.condition == null ? [] : [for m in regexall(local.role_token_pattern, a.condition) : trimspace(m[0])]
    )
  }

  condition_role_lookups = merge(concat([{}], [
    for key, names in local.condition_role_names : {
      for name in distinct(names) : "${key}|${name}" => { assignment_key = key, role_name = name }
    }
  ])...)
}

data "azurerm_role_definition" "condition" {
  for_each = local.condition_role_lookups

  name  = each.value.role_name
  scope = local.scope_ids[each.value.assignment_key]
}

locals {
  # The last segment of a role definition ID is the role's GUID.
  condition_role_guids = {
    for key, d in data.azurerm_role_definition.condition : key => element(reverse(split("/", d.id)), 0)
  }

  # Surrounding whitespace is trimmed so a heredoc's final newline is not sent.
  conditions = {
    for key, a in var.assignments : key => a.condition == null ? null : trimspace(join("", flatten([
      for i, part in split(local.token_separator, replace(
        replace(a.condition, local.principal_token, var.principal_id),
        "/${local.role_token_pattern}/",
        local.token_separator,
      )) :
      [
        part,
        i < length(local.condition_role_names[key]) ? local.condition_role_guids["${key}|${local.condition_role_names[key][i]}"] : "",
      ]
    ])))
  }
}

# ---------------------------------------------------------------------------
# Assignments.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "this" {
  for_each = var.assignments

  scope              = local.scope_ids[each.key]
  role_definition_id = data.azurerm_role_definition.this[each.key].id
  principal_id       = var.principal_id
  principal_type     = "ServicePrincipal"
  description        = each.value.description

  condition         = local.conditions[each.key]
  condition_version = each.value.condition == null ? null : coalesce(each.value.condition_version, "2.0")

  # A managed identity created in the same plan may not have replicated to
  # every Entra read replica yet; ARM would otherwise refuse the assignment
  # with PrincipalNotFound. The principal ID comes from the identity resource,
  # so skipping the lookup does not weaken anything.
  skip_service_principal_aad_check = true

  lifecycle {
    precondition {
      condition     = local.scope_ids[each.key] != null
      error_message = "Assignment \"${each.key}\": subscription \"${each.value.scope.name}\" was not found by display name in this tenant."
    }
  }
}
