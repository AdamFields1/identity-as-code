# azure-automation stack
#
# One deployable unit for the identity hygiene and governance runbooks in a
# tenant. Order of dependency:
#
#   automation account + identity  -->  optional backup storage
#                                  -->  runbooks, schedules, job schedules
#                                  -->  Graph app roles for the identity
#                                  -->  Azure role assignments for the identity
#
# The account comes first because everything else keys off it: the runbooks
# module needs the account name and location, the Graph grants and the Azure
# role assignments need each identity's principal ID, and the backup storage
# grants a data role on its container to the identity of the runbook that
# writes backups. The leaves are independent of each other and Terraform
# applies them side by side.
#
# Identity tiers. A cell declares a map of identities, one per privilege tier,
# each with its own Graph application permissions and Azure role assignments,
# and every runbook names the tier it runs as (identity_key). All of them are
# attached to the one Automation account, so a tier bounds what a runbook
# defect or a bad parameter can reach, not what someone who can publish a
# runbook or start a job in the account can reach (docs/adr/0016). A cell that
# declares no identities gets the earlier single-identity form: one identity
# keyed "default", named identity_name, holding graph_app_roles and
# arm_role_assignments.
#
# What this stack owns that a tenant cell never sees: the client ID of the
# identity each runbook runs as, which the runbook needs to ask the Automation
# identity endpoint for a token, is read from the account module and injected
# into that runbook's job schedule parameters here. So is the cloud, the
# sender mailbox, and the dry-run flag, so a cell states each of those once and
# cannot give two runbooks different answers. A runbook entry can also ask for
# a small, fixed set of other values only the stack knows (the account's own
# name, its resource group and subscription, its own identity's principal ID,
# the backup storage names) through stack_parameters, by naming the value
# rather than typing it. Job schedule parameter keys are lowercase because
# Azure Automation normalises them (see the runbooks module).
#
# Lists in a job schedule are semicolon-joined strings, never jsonencode of a
# list, and structured configuration (the PIM baselines) is not a parameter at
# all: it is published as an Automation string variable through
# desired_state_files and the runbook is given the variable's name. The
# Automation service may parse a JSON-looking parameter value before it binds
# it, and what then reaches a [string] parameter is "@{...}" or a
# space-joined array (see automation/lib/Runbook.Common.ps1).
#
# The runbook files come from automation/runbooks in this repository,
# resolved relative to this stack the same way modules are. A runbook that
# names a library gets automation/lib/<library> inlined between its marker
# lines by the runbooks module (see that module's README and docs/adr/0013).
#
# Desired-state files are the third kind of input. The authentication methods
# policy has no Terraform resource (docs/adr/0012), so its desired state is a
# folder of JSON under policies/entra/authentication-methods; this stack
# publishes each file as an Automation string variable so the drift runbook
# compares the tenant against exactly what the repository says, and a file
# edit is a plan diff on the variable like any other change. The two PIM
# baselines under policies/azure/pim-governance and
# policies/entra/pim-governance reach their runbooks the same way.
#
# Azure permissions are a fourth. A managed identity cannot activate a PIM
# role, so what a runbook may do in Azure Resource Manager is a set of
# standing assignments for its tier's identity, declared in the cell by scope
# name and role name (arm_role_assignments inside each identity), with an
# optional ABAC condition whose GUIDs are resolved from name tokens
# (docs/adr/0014).
#
# Deliberately NOT managed here: the resource group (platform bootstrap), the
# three lifecycle stage groups and the exclusion group the guest runbook
# resolves by name (ordinary security groups, created with the tenant's other
# groups), the shared sender mailbox, the Exchange application access policy
# that restricts Mail.Send to it (no Terraform resource exists), the
# diagnostic settings that stream job output to the SIEM (they belong with
# the workspace), the custom role definitions arm_role_assignments may name
# (stacks/azure-rbac-roles, docs/adr/0005), and the job watcher's state
# variable, which the watcher creates and rewrites itself.

data "azurerm_client_config" "current" {}

locals {
  repository_root    = "${path.module}/../.."
  runbooks_directory = "${local.repository_root}/automation/runbooks"
  library_directory  = "${local.repository_root}/automation/lib"

  # The union the shipped runbooks need for live runs, used only by the
  # single-identity form. A cell with identity tiers lists each tier's
  # permissions in its own entry, which is the point of the tiers.
  default_graph_app_roles = [
    # Invoke-AppCredentialHygiene, Invoke-GuestLifecycle, Invoke-AuthenticationMethodsDrift
    "Application.ReadWrite.All",
    "User.ReadWrite.All",
    "Group.ReadWrite.All",
    "Mail.Send",
    "Directory.Read.All",
    "AuditLog.Read.All",
    "Policy.ReadWrite.AuthenticationMethod",
    # Invoke-AzurePimPolicyGovernance, Invoke-EntraPimPolicyDrift,
    # Invoke-PimEligibilityRenewal, Disable-UnauthorizedSubscriptions
    "Group.Read.All",
    "GroupMember.Read.All",
    "User.Read.All",
    "RoleManagement.Read.Directory",
    "RoleManagementPolicy.Read.Directory",
    "RoleManagementPolicy.ReadWrite.Directory",
    "RoleManagementPolicy.Read.AzureADGroup",
    "RoleManagementPolicy.ReadWrite.AzureADGroup",
    "RoleEligibilitySchedule.ReadWrite.Directory",
    "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup",
  ]

  # One shape for both forms: tiers as declared, or the single "default"
  # identity carrying the flat inputs.
  identity_tiers = length(var.identities) > 0 ? {
    for key, identity in var.identities : key => {
      name                 = identity.name
      graph_app_roles      = identity.graph_app_roles
      arm_role_assignments = identity.arm_role_assignments
    }
    } : {
    default = {
      name                 = var.identity_name
      graph_app_roles      = var.graph_app_roles == null ? local.default_graph_app_roles : var.graph_app_roles
      arm_role_assignments = var.arm_role_assignments
    }
  }

  # Which identity each runbook runs as.
  runbook_identity_keys = { for key, r in var.runbooks : key => coalesce(r.identity_key, "default") }

  runbook_definitions = {
    for key, r in var.runbooks : key => {
      name         = r.name
      content_path = "${local.runbooks_directory}/${r.file}"
      library_path = r.library == null ? null : "${local.library_directory}/${r.library}"
      description  = r.description
    }
  }

  # One Automation string variable per desired-state file, holding the file's
  # text: the authentication methods desired state the drift runbook compares
  # against, and the two PIM baselines the sweeps are held to. Each runbook
  # reads its own with Get-AutomationVariable, because a job schedule cannot
  # carry JSON safely.
  desired_state_variables = {
    for name, relative_path in var.desired_state_files : name => {
      type        = "string"
      value       = file("${local.repository_root}/${relative_path}")
      description = "Desired state published from ${relative_path} by stacks/azure-automation. Edit the file in the repository, never this variable."
    }
  }

  # Parameters every runbook receives from this stack, per runbook because
  # clientid is the client ID of that runbook's own tier identity. Keys
  # lowercase.
  common_parameters = {
    for key, r in var.runbooks : key => {
      clientid      = module.automation_account.identities[local.runbook_identity_keys[key]].client_id
      environment   = var.graph_environment
      sendermailbox = var.sender_mailbox
      dryrun        = var.dry_run ? "true" : "false"
    }
  }

  # Values a runbook entry may ask for by name in stack_parameters. A list is
  # a semicolon-joined string, the only form a job schedule carries safely.
  # The subscription is passed as an ID: the runbooks that take a subscription
  # name accept an ID and skip the lookup, which also spares the identity a
  # subscription-level read. The backup values are null when backup_storage
  # is null; validation stops a runbook from asking for them then.
  stack_values = {
    automation_account_name     = module.automation_account.automation_account_name
    automation_account_names    = join(";", [module.automation_account.automation_account_name])
    resource_group_name         = module.automation_account.resource_group_name
    subscription_id             = data.azurerm_client_config.current.subscription_id
    backup_storage_account_name = one(module.backup_storage[*].storage_account_name)
    backup_container_name       = one(module.backup_storage[*].container_name)
  }

  # identity_principal_id is per runbook: the principal of its own tier.
  runbook_stack_values = {
    for key, r in var.runbooks : key => merge(local.stack_values, {
      identity_principal_id = module.automation_account.identities[local.runbook_identity_keys[key]].principal_id
    })
  }

  job_schedules = {
    for key, r in var.runbooks : key => {
      runbook_key  = key
      schedule_key = r.schedule_key
      parameters = merge(
        r.parameters,
        { for name, value_name in r.stack_parameters : name => local.runbook_stack_values[key][value_name] },
        local.common_parameters[key],
      )
    }
  }

  # A scope of type automation_account is this stack's own account.
  arm_role_assignments = {
    for tier, identity in local.identity_tiers : tier => {
      for key, a in identity.arm_role_assignments : key => {
        role_name         = a.role_name
        description       = a.description
        condition         = a.condition
        condition_version = a.condition_version
        scope = a.scope.type == "automation_account" ? {
          type = "resource_id"
          name = module.automation_account.automation_account_id
          } : {
          type = a.scope.type
          name = a.scope.name
        }
      }
    }
  }

  # The container role follows the runbook that writes backups: the tier of
  # every runbook that asks the stack for a backup value, and nobody else.
  backup_writer_tiers = toset([
    for key, r in var.runbooks : local.runbook_identity_keys[key]
    if length([for v in values(r.stack_parameters) : v if startswith(v, "backup_")]) > 0
  ])
}

# ---------------------------------------------------------------------------
# Account and identity.
# ---------------------------------------------------------------------------

module "automation_account" {
  source = "../../modules/azure/automation-account"

  name                = var.automation_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  identities          = { for tier, identity in local.identity_tiers : tier => { name = identity.name } }
  tags                = var.tags

  variables = merge(
    {
      TenantLabel      = { type = "string", value = var.tenant_label, description = "Tenant this account serves. Read by runbooks for log context." }
      SenderMailbox    = { type = "string", value = var.sender_mailbox, description = "Shared mailbox the runbooks send from." }
      GraphEnvironment = { type = "string", value = var.graph_environment, description = "National cloud: Global or USGov." }
      DryRun           = { type = "bool", value = var.dry_run ? "true" : "false", description = "Account-wide dry-run default. Job schedules pass the same value explicitly." }
    },
    local.desired_state_variables,
  )
}

# ---------------------------------------------------------------------------
# Optional backup storage for Backup-AutomationRunbooks.
# ---------------------------------------------------------------------------

module "backup_storage" {
  source = "../../modules/azure/backup-storage"
  count  = var.backup_storage == null ? 0 : 1

  name                     = var.backup_storage.storage_account_name
  resource_group_name      = coalesce(var.backup_storage.resource_group_name, module.automation_account.resource_group_name)
  location                 = module.automation_account.location
  container_name           = var.backup_storage.container_name
  account_replication_type = var.backup_storage.account_replication_type
  retention_days           = var.backup_storage.retention_days
  version_retention_days   = var.backup_storage.version_retention_days
  tags                     = var.tags

  writer_principal_ids = {
    for tier in local.backup_writer_tiers : tier => module.automation_account.identities[tier].principal_id
  }
}

# ---------------------------------------------------------------------------
# Runbooks, schedules, and their links.
# ---------------------------------------------------------------------------

module "runbooks" {
  source = "../../modules/azure/automation-runbooks"

  automation_account_name = module.automation_account.automation_account_name
  resource_group_name     = module.automation_account.resource_group_name
  location                = module.automation_account.location
  tags                    = var.tags

  runbooks      = local.runbook_definitions
  schedules     = var.schedules
  job_schedules = local.job_schedules
}

# ---------------------------------------------------------------------------
# What each identity may do in Graph. One module instance per tier that names
# any permission; a tier whose runbooks call no Graph API gets none.
# ---------------------------------------------------------------------------

module "graph_grants" {
  source   = "../../modules/entra/graph-app-role-grant"
  for_each = { for tier, identity in local.identity_tiers : tier => identity if length(identity.graph_app_roles) > 0 }

  principal_object_id = module.automation_account.identities[each.key].principal_id
  app_role_names      = each.value.graph_app_roles
}

# The single-identity form's grants are the "default" tier's, so an account
# that had one identity keeps its Graph assignments. Moving to tiers plans
# them away with that identity, which is the point of the move.
moved {
  from = module.graph_grants
  to   = module.graph_grants["default"]
}

# ---------------------------------------------------------------------------
# What each identity may do in Azure Resource Manager.
# ---------------------------------------------------------------------------

module "arm_role_assignments" {
  source   = "../../modules/azure/workload-role-assignment"
  for_each = { for tier, assignments in local.arm_role_assignments : tier => assignments if length(assignments) > 0 }

  principal_id = module.automation_account.identities[each.key].principal_id
  assignments  = each.value
}
