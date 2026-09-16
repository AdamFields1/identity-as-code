# Azure corp tenant, automation cell.
#
# Values only. No resources, no provider configuration, no logic. If you find
# yourself adding a resource here, it belongs in the stack.
#
# Two runbooks, two schedules, both dry. dry_run = true is the shipped default
# and stays true until the job output of a few dry runs has been read and the
# counts look right; flipping it is a one-line change here whose plan shows
# the job schedules being replaced. The three lifecycle stage groups the guest
# runbook names below are ordinary security groups created with the tenant's
# other groups, and the sender mailbox is a shared mailbox restricted to this
# identity by an Exchange application access policy applied outside Terraform.
#
# Schedule start_time values are anchors: the date must be in the future when
# the schedule is first created, and only the time of day (and the weekday for
# the weekly one) matters afterwards. 2027-01-04 is a Monday.
#
# tenant_id and subscription_id are not set here. root.hcl supplies them from
# ARM_TENANT_ID and ARM_SUBSCRIPTION_ID so no cell ever contains a GUID.
#
# State key (derived by root.hcl): azure/corp/azure-automation/terraform.tfstate

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../stacks/azure-automation"
}

inputs = {
  # -------------------------------------------------------------------------
  # Account. The resource group exists already; the identity is created.
  # -------------------------------------------------------------------------
  resource_group_name     = "rg-example-identity-automation"
  automation_account_name = "aa-example-identity-corp"
  identity_name           = "id-example-identity-automation-corp"
  tenant_label            = "corp"

  tags = {
    workload = "identity-automation"
    owner    = "iam"
  }

  # -------------------------------------------------------------------------
  # Values every runbook receives. Dry by default.
  # -------------------------------------------------------------------------
  sender_mailbox    = "iam-noreply@corp.example.com"
  graph_environment = "Global"
  dry_run           = true

  # -------------------------------------------------------------------------
  # Schedules. Credential hygiene daily at 06:00 UTC, guest lifecycle weekly
  # on Monday at 07:00 UTC.
  # -------------------------------------------------------------------------
  schedules = {
    daily-0600-utc = {
      name        = "daily-0600-utc"
      description = "Every day at 06:00 UTC."
      frequency   = "Day"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T06:00:00Z"
    }

    weekly-monday-0700-utc = {
      name        = "weekly-monday-0700-utc"
      description = "Every Monday at 07:00 UTC."
      frequency   = "Week"
      interval    = 1
      timezone    = "Etc/UTC"
      start_time  = "2027-01-04T07:00:00Z"
      week_days   = ["Monday"]
    }
  }

  # -------------------------------------------------------------------------
  # Runbooks. Parameter keys are lowercase (Azure Automation normalises them).
  # clientid, environment, sendermailbox, and dryrun are added by the stack.
  # -------------------------------------------------------------------------
  runbooks = {
    app-credential-hygiene = {
      name         = "Invoke-AppCredentialHygiene"
      file         = "Invoke-AppCredentialHygiene.ps1"
      description  = "Expiring and expired application credentials: digest to owners, removal after a grace period."
      schedule_key = "daily-0600-utc"
      parameters = {
        warndays          = "30"
        removeexpired     = "false"
        removeafterdays   = "30"
        maxremovalsperrun = "25"
        excludedapptag    = "NoCredentialHygiene"
        fallbackrecipient = "iam@corp.example.com"
      }
    }

    guest-lifecycle = {
      name         = "Invoke-GuestLifecycle"
      file         = "Invoke-GuestLifecycle.ps1"
      description  = "Dormant guests: warn at 60 days, disable at 90, purge 120 days after disable. Stage held in group membership."
      schedule_key = "weekly-monday-0700-utc"
      parameters = {
        warndays          = "60"
        disabledays       = "90"
        purgedays         = "120"
        warnedgroupname   = "LC Guests Warned"
        disabledgroupname = "LC Guests Disabled"
        exemptgroupname   = "LC Guests Exempt"
        maxdisableperrun  = "25"
        maxpurgeperrun    = "10"
        fallbackrecipient = "iam@corp.example.com"
      }
    }
  }
}
