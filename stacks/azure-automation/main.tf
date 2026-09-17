# azure-automation stack
#
# One deployable unit for the identity hygiene runbooks in a tenant. Order of
# dependency:
#
#   automation account + identity  -->  runbooks, schedules, job schedules
#                                  -->  Graph app roles for the identity
#
# The account comes first because both other modules key off it: the
# runbooks module needs the account name and location, and the Graph grants
# need the identity's principal ID. The two leaves are independent of each
# other and Terraform applies them side by side.
#
# What this stack owns that a tenant cell never sees: the identity's client
# ID, which every runbook needs to ask the Automation identity endpoint for a
# token, is read from the account module and injected into every job
# schedule's parameters here. So is the cloud, the sender mailbox, and the
# dry-run flag, so a cell states each of those once and cannot give two
# runbooks different answers. Job schedule parameter keys are lowercase
# because Azure Automation normalises them (see the runbooks module).
#
# The runbook files come from automation/runbooks in this repository,
# resolved relative to this stack the same way modules are. A runbook that
# names a library gets automation/lib/<library> inlined between its marker
# lines by the runbooks module (see that module's README for why).
#
# Desired-state files are the third kind of input. The authentication methods
# policy has no Terraform resource (docs/adr/0012), so its desired state is a
# folder of JSON under policies/entra/authentication-methods; this stack
# publishes each file as an Automation string variable so the drift runbook
# compares the tenant against exactly what the repository says, and a file
# edit is a plan diff on the variable like any other change.
#
# Deliberately NOT managed here: the resource group (platform bootstrap), the
# three lifecycle stage groups and the exclusion group the guest runbook
# resolves by name (ordinary security groups, created with the tenant's other
# groups), the shared sender mailbox, the Exchange application access policy
# that restricts Mail.Send to it (no Terraform resource exists), and the
# diagnostic settings that stream job output to the SIEM (they belong with
# the workspace).

locals {
  repository_root    = "${path.module}/../.."
  runbooks_directory = "${local.repository_root}/automation/runbooks"
  library_directory  = "${local.repository_root}/automation/lib"

  runbook_definitions = {
    for key, r in var.runbooks : key => {
      name         = r.name
      content_path = "${local.runbooks_directory}/${r.file}"
      library_path = r.library == null ? null : "${local.library_directory}/${r.library}"
      description  = r.description
    }
  }

  # One Automation string variable per desired-state file, holding the file's
  # text. Read by Invoke-AuthenticationMethodsDrift with Get-AutomationVariable.
  desired_state_variables = {
    for name, relative_path in var.desired_state_files : name => {
      type        = "string"
      value       = file("${local.repository_root}/${relative_path}")
      description = "Desired state published from ${relative_path} by stacks/azure-automation. Edit the file in the repository, never this variable."
    }
  }

  # Parameters every runbook receives from this stack. Keys lowercase.
  common_parameters = {
    clientid      = module.automation_account.identity_client_id
    environment   = var.graph_environment
    sendermailbox = var.sender_mailbox
    dryrun        = var.dry_run ? "true" : "false"
  }

  job_schedules = {
    for key, r in var.runbooks : key => {
      runbook_key  = key
      schedule_key = r.schedule_key
      parameters   = merge(r.parameters, local.common_parameters)
    }
  }
}

# ---------------------------------------------------------------------------
# Account and identity.
# ---------------------------------------------------------------------------

module "automation_account" {
  source = "../../modules/azure/automation-account"

  name                = var.automation_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  identity_name       = var.identity_name
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
# What the identity may do in Graph.
# ---------------------------------------------------------------------------

module "graph_grants" {
  source = "../../modules/entra/graph-app-role-grant"

  principal_object_id = module.automation_account.identity_principal_id
  app_role_names      = var.graph_app_roles
}
