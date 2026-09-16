# modules/azure/automation-runbooks

Publishes runbooks from files in the repository into an Automation account,
creates schedules, and links them with job schedules that carry the runbook
parameters. Everything is keyed by the caller's logical names.

## Design notes

- **The file is the runbook.** `content = file(content_path)`, so editing a
  runbook is a pull request whose plan shows the change and whose apply publishes
  it. A `content_sha256` tag carries the file hash so the plan summary and the
  portal show which revision is deployed without anyone reading the body.
- **Verbose logging is on by default.** The runbooks in `automation/runbooks` write
  their structured log through the verbose stream, which Azure Automation keeps
  with the job only when `log_verbose` is true.
- **Parameters are the job schedule's.** A runbook is published once; each job
  schedule passes its own parameter map. The same runbook can therefore run dry on
  one schedule and live on another, which is how a new runbook is soaked.
- **Keys of the three maps are Terraform addresses.** Renaming one moves the
  resource in state; change the Azure-side name with `name` instead.

## Three provider behaviours worth knowing

None of these is specific to any account; all of them show up on the first apply
of a fresh configuration.

1. **`start_time` must be at least five minutes in the future when the schedule is
   created.** Azure rejects a past instant. After creation the instant only anchors
   the time of day (and, for `Week`, the day of week) and is not sent again unless
   the schedule changes. Any change to a schedule re-sends `start_time`, so a
   schedule edit needs a fresh future instant in the same pull request; leaving the
   old one produces an apply error, not silent drift.
2. **Every job schedule argument forces replacement, including `parameters`.**
   Changing a parameter (for example `dryrun` from `"true"` to `"false"`) is a
   destroy and a create of the link between runbook and schedule. That is harmless
   (the next run happens at the next scheduled time) but it means a parameter
   change reads as a destroy in the plan, and the release summary will say so.
3. **Parameter keys must be lowercase.** Azure Automation normalises parameter
   names to lowercase and the provider compares against that form, so a key such
   as `DryRun` produces a permanent diff. Validation rejects mixed case.

## Usage

```hcl
module "runbooks" {
  source = "../../modules/azure/automation-runbooks"

  automation_account_name = "aa-example-identity"
  resource_group_name     = "rg-example-identity-automation"
  location                = "eastus2"

  runbooks = {
    app-credential-hygiene = {
      name         = "Invoke-AppCredentialHygiene"
      content_path = "${path.module}/../../automation/runbooks/Invoke-AppCredentialHygiene.ps1"
    }
  }

  schedules = {
    daily-0600-utc = {
      name       = "daily-0600-utc"
      frequency  = "Day"
      start_time = "2027-01-04T06:00:00Z"
    }
  }

  job_schedules = {
    app-credential-hygiene = {
      runbook_key  = "app-credential-hygiene"
      schedule_key = "daily-0600-utc"
      parameters = {
        sendermailbox = "iam-noreply@corp.example.com"
        dryrun        = "true"
      }
    }
  }
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `automation_account_name` | `string` | n/a | Target account. |
| `resource_group_name` | `string` | n/a | Its resource group. |
| `location` | `string` | n/a | Its region. |
| `runbooks` | `map(object)` | n/a | Runbooks keyed by logical name; see `variables.tf`. |
| `schedules` | `map(object)` | `{}` | Schedules keyed by logical name. |
| `job_schedules` | `map(object)` | `{}` | Runbook to schedule links with parameters. |
| `tags` | `map(string)` | `{}` | Tags for every runbook. |

## Outputs

| Name | Description |
|------|-------------|
| `runbook_ids` | Key to runbook resource ID. |
| `runbook_names` | Key to runbook name. |
| `content_hashes` | Key to SHA-256 of the published file. |
| `schedule_ids` | Key to schedule resource ID. |
| `job_schedule_ids` | Key to job schedule resource ID. |

## Import

```hcl
import {
  to = module.runbooks.azurerm_automation_runbook.this["app-credential-hygiene"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity/runbooks/Invoke-AppCredentialHygiene"
}

import {
  to = module.runbooks.azurerm_automation_schedule.this["daily-0600-utc"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity/schedules/daily-0600-utc"
}

import {
  to = module.runbooks.azurerm_automation_job_schedule.this["app-credential-hygiene"]
  id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity/schedules/daily-0600-utc|/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-example-identity/runbooks/Invoke-AppCredentialHygiene"
}
```
