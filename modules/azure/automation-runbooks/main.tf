# Runbooks from files, schedules, and the job schedules that join them, all
# keyed by the caller's logical names.
#
# The runbook body is the file in the repository (content = file(...)), so a
# change to a runbook is a pull request, a plan that shows the diff, and an
# apply that publishes the new version. A content_sha256 tag carries the hash
# of the file so the plan summary and the portal both show which revision is
# deployed without anyone reading the body.
#
# Three provider behaviours worth knowing before the first apply, none of
# them specific to any tenant:
#
#   1. A schedule's start_time must be at least five minutes in the future
#      when the schedule is created; Azure rejects a past instant. After
#      creation the instant is only the anchor for the time of day and the day
#      of week, and it is never sent again unless the schedule changes. A
#      change to any schedule attribute re-sends start_time, so a schedule
#      edit needs a fresh future instant in the same pull request.
#   2. Every job schedule argument forces replacement, including parameters.
#      Changing a runbook parameter (say DryRun from true to false) destroys
#      and recreates the link between runbook and schedule. That is harmless,
#      the next run happens at the next scheduled time, and it means the plan
#      for a parameter change reads as a destroy and a create.
#   3. Job schedule parameter keys must be lowercase. Azure Automation
#      normalises them and the provider compares against the normalised form,
#      so a mixed-case key produces a permanent diff. Validation rejects it.
#
# Shared library inlining. Azure Automation runs one file, and a plain .ps1
# cannot be a module asset (azurerm_automation_module takes a packaged
# module from a URL, which is a second artifact to build, host, and version).
# A runbook that shares logic with a workstation script therefore carries two
# marker lines, and when library_path is set the block between them is
# replaced with the library file's content at plan time. The runbook keeps a
# dot-source of the same file inside the block for workstation runs and
# tests, so both paths execute identical code. Plain split and join are used
# rather than a regex replace because a replacement string containing "$"
# (every PowerShell file) would be read as a backreference.

locals {
  library_begin = "# INLINE_LIBRARY_BEGIN"
  library_end   = "# INLINE_LIBRARY_END"

  runbook_content = {
    for key, r in var.runbooks : key => (
      r.library_path == null ? file(r.content_path) : join("", [
        split(local.library_begin, file(r.content_path))[0],
        local.library_begin,
        "\n",
        file(r.library_path),
        "\n",
        local.library_end,
        split(local.library_end, file(r.content_path))[1],
      ])
    )
  }
}

resource "azurerm_automation_runbook" "this" {
  for_each = var.runbooks

  name                    = each.value.name
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name

  runbook_type = each.value.runbook_type
  log_verbose  = each.value.log_verbose
  log_progress = each.value.log_progress
  description  = each.value.description
  content      = local.runbook_content[each.key]

  runtime_environment_name = each.value.runtime_environment_name

  tags = merge(var.tags, each.value.tags, { content_sha256 = sha256(local.runbook_content[each.key]) })
}

resource "azurerm_automation_schedule" "this" {
  for_each = var.schedules

  name                    = each.value.name
  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name

  frequency   = each.value.frequency
  interval    = each.value.frequency == "OneTime" ? null : each.value.interval
  timezone    = each.value.timezone
  start_time  = each.value.start_time
  expiry_time = each.value.expiry_time
  description = each.value.description

  week_days  = length(each.value.week_days) > 0 ? each.value.week_days : null
  month_days = length(each.value.month_days) > 0 ? each.value.month_days : null
}

resource "azurerm_automation_job_schedule" "this" {
  for_each = var.job_schedules

  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name

  runbook_name  = azurerm_automation_runbook.this[each.value.runbook_key].name
  schedule_name = azurerm_automation_schedule.this[each.value.schedule_key].name

  parameters = length(each.value.parameters) > 0 ? each.value.parameters : null
  run_on     = each.value.run_on
}
