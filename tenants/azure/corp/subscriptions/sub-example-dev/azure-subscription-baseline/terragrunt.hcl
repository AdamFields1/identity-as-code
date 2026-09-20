# Azure corp tenant, subscription sub-example-dev: subscription baseline cell.
#
# Values only. Same stack as ../../sub-example-prod/azure-subscription-baseline;
# the differences below are the whole story of "what is weaker in dev":
#   - the activity log is kept 90 days, not 365. Nothing in a developer
#     subscription is reviewed a year later; 90 days covers an incident
#     window and keeps the ingestion bill in proportion to the subscription.
#   - three Defender plans, CloudPosture, Arm, and KeyVaults, not five.
#     Posture and control-plane findings are the ones that matter in a
#     subscription where the workloads are short-lived, and the Key Vault
#     plan is on because the orders-api app cell under apps/ creates a
#     vault (kv-orders-api-dev). There is no VM plan and no storage plan
#     because the catalog that would put machines and accounts here (the
#     workloads cell) does not exist in dev. Add a plan in the same change
#     as the first resource of its type, as the Key Vault plan was.
#   - no workloads cell beside this one. The only other cell in this
#     subscription is the orders-api app cell under apps/, which names the
#     workspace created here for its registry's and its vault's audit logs,
#     which is why the release train applies this cell first, the same rule
#     as in prod.
# Everything else is the same shape as prod: the stack creates the baseline
# resource group and locks it, creates the Log Analytics workspace in it,
# sends the subscription's activity log there (all eight categories, the
# stack default), and assigns the Microsoft cloud security benchmark with
# the same non-compliance message. The lock stays on in dev because the
# activity log is the one record of what a developer subscription did.
#
# Which subscription this is is not in this file. The locator beside this
# cell (../subscription.hcl) addresses it: tenants/azure/root.hcl reads the
# subscription id from it and points the azurerm provider there in place of
# ARM_SUBSCRIPTION_ID. The tenant still comes from ARM_TENANT_ID, because the
# tenant is the tree (corp/), not a locator. No GUID anywhere in this file.
# See docs/adr/0017.
#
# State key (derived by root.hcl):
# azure/corp/subscriptions/sub-example-dev/azure-subscription-baseline/terraform.tfstate

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
  # Retention is a quarter, not a year: see the header.
  # -------------------------------------------------------------------------
  create_workspace = true

  baseline_resource_group = {
    name        = "rg-example-dev-baseline"
    location    = "eastus"
    delete_lock = true
  }

  log_analytics_workspace = {
    name              = "law-example-dev-activity"
    retention_in_days = 90
  }

  # -------------------------------------------------------------------------
  # Defender plans, keyed by resource type. An empty entry is Standard with
  # the full plan and no extensions; a type absent here is left as the
  # portal has it. The key is the import id suffix. Posture, the control
  # plane, and the vault the app cell creates: see the header for why the
  # other two prod plans are not here.
  # -------------------------------------------------------------------------
  defender_plans = {
    CloudPosture = {}
    Arm          = {}
    KeyVaults    = {}
  }

  # -------------------------------------------------------------------------
  # Initiatives, by display name. Setting this map replaces the stack default
  # (the same benchmark, enforced, without a message). No remediation
  # identity is offered: the benchmark audits, it does not deploy. The same
  # benchmark and the same message as prod: a developer subscription is
  # held to the same bar, it just keeps less evidence for less time.
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
