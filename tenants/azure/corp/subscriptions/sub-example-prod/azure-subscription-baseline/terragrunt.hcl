# Azure corp tenant, subscription sub-example-prod: subscription baseline cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Which subscription this is is not in this file. The locator beside this
# cell (../subscription.hcl) addresses it: tenants/azure/root.hcl reads the
# subscription id from it and points the azurerm provider there in place of
# ARM_SUBSCRIPTION_ID. The tenant still comes from ARM_TENANT_ID, because the
# tenant is the tree (corp/), not a locator. No GUID anywhere in this file.
# See docs/adr/0017.
#
# This is the "no workspace yet" shape: the stack creates the baseline
# resource group and locks it, creates the Log Analytics workspace in it,
# sends the subscription's activity log there (all eight categories, the
# stack default), turns on the Defender plans listed, and assigns the
# Microsoft cloud security benchmark with a non-compliance message. The
# workloads and data-pipeline cells beside this one name the workspace
# created here, by name, which is why the release train applies this cell
# first.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-prod/azure-subscription-baseline/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../stacks/azure-subscription-baseline"
}

inputs = {
  # -------------------------------------------------------------------------
  # The group and the workspace. Both are prevent_destroy in their modules;
  # the lock additionally stops anyone deleting either from the portal.
  # Retention is a year so the activity log outlives an annual review.
  # -------------------------------------------------------------------------
  create_workspace = true

  baseline_resource_group = {
    name        = "rg-example-baseline"
    location    = "eastus"
    delete_lock = true
  }

  log_analytics_workspace = {
    name              = "law-example-prod-activity"
    retention_in_days = 365
  }

  # -------------------------------------------------------------------------
  # Defender plans, keyed by resource type. An empty entry is Standard with
  # the full plan and no extensions; a type absent here is left as the
  # portal has it. The key is the import id suffix.
  # -------------------------------------------------------------------------
  defender_plans = {
    CloudPosture    = {}
    Arm             = {}
    KeyVaults       = {}
    VirtualMachines = { subplan = "P2", extensions = { AgentlessVmScanning = {}, MdeDesignatedSubscription = {} } }
    StorageAccounts = { subplan = "DefenderForStorageV2", extensions = { OnUploadMalwareScanning = { CapGBPerMonthPerStorageAccount = "5000" }, SensitiveDataDiscovery = {} } }
  }

  # -------------------------------------------------------------------------
  # Initiatives, by display name. Setting this map replaces the stack default
  # (the same benchmark, enforced, without a message). No remediation
  # identity is offered: the benchmark audits, it does not deploy.
  # -------------------------------------------------------------------------
  policy_assignments = {
    microsoft-cloud-security-benchmark = {
      policy_set_display_name = "Microsoft cloud security benchmark"
      non_compliance_message  = "This resource does not meet the Microsoft cloud security benchmark. The platform security team owns exceptions."
    }
  }

  tags = {
    owner = "platform-security"
  }
}
