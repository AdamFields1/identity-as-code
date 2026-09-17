<#
.SYNOPSIS
    Watches one Azure Automation account every hour and mails one digest when
    a job has failed or a scheduled run did not happen. It is the answer to
    "who watches the automation".

.DESCRIPTION
    Runs as an Azure Automation runbook on the account's user-assigned managed
    identity. Each run does two checks against one Automation account, reads
    what it has already reported, and stays silent unless something is new.

    Failures. Selects the jobs whose status is Failed, Suspended, or Stopped
    and that reached that status inside the lookback window. The time that
    counts is when the job got there (endTime, else lastModifiedTime, else
    startTime, else creationTime), not when it started, so a job that ran
    for hours before it failed, or a cloud job stopped by fair share after
    three hours, is still reported. Jobs come from two kinds of ARM jobs
    list. One is filtered on properties/startTime and reaches back
    LookbackMinutes plus MaxJobRuntimeMinutes (or to the earliest due
    scheduled run, when that is earlier); the heartbeat reads it too. The
    other is one list per alert status, filtered on properties/status. It
    finds the jobs the first list cannot: jobs that never started (their
    startTime is null, and a start-time filter drops them) and jobs that ran
    longer than MaxJobRuntimeMinutes. For each selected job it reads the
    error stream (following next links, up to 10 pages) and puts a short,
    scrubbed summary of the latest error records by time (or the job's
    exception text when the stream is empty) in the digest.

    Missed runs (heartbeat). Lists the schedules and the job schedules that
    link them to runbooks. For every enabled, unexpired schedule linked to a
    runbook it computes the most recent run the schedule should have started,
    from startTime, frequency (Minute, Hour, Day, Week, Month), interval,
    weekDays, monthDays (-1 is the last day), monthlyOccurrences, timeZone,
    and expiryTime. The expected run is the latest occurrence at or before
    now minus HeartbeatGraceMinutes, so a run still inside its grace window is
    never judged and the run before it is. When no job for that runbook has
    started between the expected time and now, the run is reported as missed.
    Day, Week, and Month schedules keep their wall-clock time in the
    schedule's time zone across daylight saving changes; Minute and Hour
    schedules step in absolute time. Weeks for an interval above one are
    counted from the Sunday on or before the start date. A one-time schedule
    is never judged: before its time there is nothing to expect, and after it
    the schedule is spent, so a missing run is not a heartbeat question.

    The schedule math rests on assumptions about the scheduler, so it is
    checked against the scheduler before any alert. When a schedule reports
    nextRun, the occurrence computed for that moment must be nextRun, within
    a minute. If it is not, the schedule is skipped with a warning
    (NextRunMismatch) and not judged, because a wrong model would raise a
    new false alert at every occurrence. Day, Week, and Month schedules
    whose time zone this host cannot resolve are skipped with a warning
    (TimeZoneUnknown) instead of being judged at a fixed offset.

    One false alert remains known, and it is flagged rather than
    suppressed. A schedule enabled, or a runbook linked to a schedule, after
    a due time but before the watcher judges that time gives one MissedRun,
    although nothing was meant to run. The ARM lists carry no time for a
    link, and the documentation does not say whether the scheduler itself
    moves a schedule's lastModifiedTime when it runs or recovers. If it
    does, a rule that dropped a MissedRun whose schedule changed after the
    due time would also drop a real miss, which is what the heartbeat is
    for, so no such rule exists. Instead, when a schedule's lastModifiedTime
    is more than two minutes after the run it was expected to start, the
    warning and the digest row say when the schedule changed and that no
    run was due if that change enabled it. The key makes it a one-time
    alert either way.

    Alert once. Every finding has a key: job:<job id> for a failure,
    missed:<runbook>|<expected UTC time> for a missed run,
    variable:<name>|<changed UTC time> for a variable change. Keys already
    reported are kept, with the time they were reported, in the Automation
    string variable named by StateVariableName. The variable is read and
    written through ARM (Variable - Get, Variable - Create Or Update), not
    through the sandbox's Get-AutomationVariable or the library's
    Get-AutomationStringVariable: one API serves the read and the write, a
    variable that does not exist yet is a plain 404, the isEncrypted flag is
    visible, and a local run with a token reads the same state as the job.
    Entries older than 48 hours are pruned. A key present in the variable is
    never reported again. Missed runs are only judged when the expected time
    is inside the same 48 hours, so pruning can never make a finding new
    again. Failures are selected by a time inside the last LookbackMinutes,
    which is capped at 1440 (24 hours), so a job is no longer selected by the
    time its key is pruned. Create no Terraform resource for this variable:
    the runbook creates it on the first live run that has something to
    record and rewrites it afterwards.

    Silent when clean. With nothing new there is no mail and no write, only
    one Info line and the summary object. With findings there is one HTML
    digest to Recipients, sent from SenderMailbox, listing failed jobs
    (runbook, status, start time, end time, job id, error summary), missed
    runs (runbook, schedule, expected time, time zone, and a note when the
    schedule changed after the expected time), and Automation variables of
    the account other than this runbook's own state whose value changed
    inside the same window (name, created or changed, when).

    Why a variable change is a finding. The identity this runbook uses holds
    the custom role Automation Variable Writer at the Automation account so
    that it can save its own state, and Azure RBAC has no per-variable scope
    for Automation: that assignment is write on every variable in the
    account, which in the corp cell includes PimPolicy_AzureBaseline,
    PimPolicy_EntraBaseline, and the nine AuthMethods_ variables Terraform
    publishes as desired state (docs/adr/0016). Those are tier 0 input. Two
    checks answer that here. The runbook writes no variable whose name does
    not begin with JobWatch_, on the parameter and again in
    Write-JobWatchState, so neither a bad job-schedule parameter nor a defect
    in that path can aim its one write at a baseline. And the hourly run
    lists the account's variables and reports any other one whose
    lastModifiedTime falls inside LookbackMinutes, once per change, with no
    value read or mailed. A Terraform release that changes a desired-state
    file produces one such row; a row that lines up with no release did not
    come from the repository. That is detection, and it runs as the same
    identity, so where the tenant has activity log alerting, add an alert on
    Microsoft.Automation/automationAccounts/variables/write by this principal
    for any name other than JobWatch_AlertedJobIds. A variables list that
    fails is a Failed summary item, not a stopped run: the failed jobs still
    have to be reported.

    What this watcher cannot see. Runbooks in this repository throw on
    failure, so their jobs end Failed and appear here. A runbook that catches
    its own errors and exits cleanly ends Completed and is invisible to this
    watcher; make it throw. The watcher always excludes itself (by the name
    Watch-AutomationJobFailures and, inside Azure Automation, by the runbook
    of its own job id), so its own failures need a second signal: an Azure
    Monitor alert on the account's TotalJob metric filtered to this runbook
    and status Failed, or the SIEM rule on the job streams the diagnostic
    settings forward. If watcher runs are skipped, a job that ended more than
    LookbackMinutes before the next run is not listed; raising
    LookbackMinutes (up to 1440) is safe because nothing is reported twice.
    A job is reported once per job id, so a suspended job that is resumed
    and fails again within 48 hours is not reported a second time. The
    status lists return every job Azure Automation still keeps in that
    status (job records are kept for 30 days), so an account with many
    failures reads a few more pages each run.

    Safety model. DryRun defaults to $true: a dry run reads everything,
    computes every finding, logs each one as a warning, logs "Would update
    Automation variable" and "Would send the digest", and writes nothing. A
    live run makes at most three writes, by construction: the state update,
    one digest mail, and, only when the mail fails, a second state update
    that puts the previous state back. Test-CircuitBreaker asserts that bound
    before the first write. It is an assertion, not a limit: there is
    deliberately no cap on findings, because aborting during a mass failure
    would suppress the one alert that matters (each digest table is cut at
    200 rows instead). The state is saved before the mail is sent. If the
    state cannot be saved (for example, the identity lacks variables/write),
    nothing is sent and the run fails, which the second signal above
    reports, instead of the same digest going out every hour. If the mail
    cannot be sent, the previous state is put back and the run fails, so the
    digest is attempted again on the next run. The library does not repeat
    the mail request within the run after a server error or a lost
    response, because Graph may have sent it; the state is put back all the
    same, so in that case the digest can arrive twice rather than not at
    all. The digest is lost only when both the mail and the put-back fail,
    and that case is logged as an error that lists the findings. A live run
    refuses to start without Recipients and SenderMailbox. Error text from
    job streams is scrubbed of token-shaped values before it is mailed or
    logged, and no access token is ever written anywhere.

    Design rules shared by every runbook in this repository are in
    automation/README.md. Logging, identity, transport, and the run summary
    come from automation/lib/Runbook.Common.ps1, inlined at deploy time.

.PARAMETER AutomationAccountName
    Name of the Automation account to watch, usually the account this runbook
    runs in.

.PARAMETER ResourceGroupName
    Resource group that holds the Automation account.

.PARAMETER SubscriptionName
    Display name of the subscription that holds the account, resolved through
    ARM. A subscription id (GUID) is also accepted and used without a lookup.

.PARAMETER LookbackMinutes
    A job is reported when it reached Failed, Suspended, or Stopped at most
    this many minutes before now. 5 to 1440. Default 70, for the hourly
    schedule: the corp cell starts the watcher at minute 45 of every hour,
    so each run looks back to minute 35 of the hour before. The ten minutes
    of overlap with the previous run cover a watcher job that starts up to
    ten minutes later than the one before it; a job that ended inside the
    overlap is seen by both runs and reported once. On another interval,
    keep this at least the interval plus ten minutes.

.PARAMETER MaxJobRuntimeMinutes
    How far before the lookback window the start-time jobs list reaches, so
    that a job which ran this long and then ended inside the window is read
    from the same list the heartbeat uses. Default 240: the three-hour fair
    share limit of cloud jobs, plus margin. Raise it for Hybrid Runbook
    Workers, which have no fair share limit. A job that ran longer, or never
    started, is still found through the per-status lists. 0 to 10080.

.PARAMETER HeartbeatGraceMinutes
    A scheduled run is judged only once this many minutes have passed since
    it was due. Default 30. 0 to 1440. With the watcher at minute 45, the
    first run at least this long after the due time judges it: a run due on
    the hour (02:00) at 02:45, one due at a quarter past (05:15) at 05:45,
    and one due at half past (03:30) at 04:45.

.PARAMETER StateVariableName
    Unencrypted Automation string variable that records what has been
    reported. Default JobWatch_AlertedJobIds. Created by the first live run
    that has something to record. The name must begin with JobWatch_, and a
    name that does not is refused at parameter binding and again in
    Write-JobWatchState. That is deliberate: the identity's Automation
    Variable Writer role reaches every variable in the account, the PIM
    baselines and the AuthMethods_ desired state among them, so the prefix is
    what keeps this runbook's one write off them.

.PARAMETER ExcludeRunbookNames
    Runbooks to ignore for both checks, as one string with the names
    separated by semicolons, for example 'Invoke-Sandbox;Invoke-Scratch'.
    That is the form a job schedule carries: a schedule binds only [bool],
    [int], and [string] values reliably, and the Automation service may
    parse JSON-looking text before it binds it, so a tenant cell should
    write the list with join(";", [...]) rather than jsonencode(). A comma
    also separates. Neither can occur in a runbook name, which Azure limits
    to letters, digits, underscores, and hyphens, starting with a letter, 1
    to 63 characters. Each name is checked against that rule, so a list that
    arrives joined by spaces fails the run instead of excluding nothing. A
    JSON array is still read in a local run. The watcher always excludes
    itself.

.PARAMETER Recipients
    Digest recipients, as one string with the addresses separated by
    semicolons, for example 'iam@corp.example.com;secops@corp.example.com'
    (the schedule form, as for ExcludeRunbookNames; a comma also
    separates). Each entry must be one mail address, so a list that arrives
    joined by spaces fails the run. Required for a live run.

.PARAMETER SenderMailbox
    Shared mailbox the digest is sent from. Requires Mail.Send restricted to
    this mailbox by an Exchange application access policy. Required for a
    live run; the azure-automation stack injects it into every job schedule.

.PARAMETER DryRun
    Default $true. Everything is read and computed, every finding is logged,
    and nothing is sent or written. Pass -DryRun:$false to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov.

.PARAMETER ClientId
    Client id of the user-assigned managed identity.

.PARAMETER AccessToken
    Local runs only. One token for every resource, or a JSON object with Arm
    and Graph keys. The Graph token is needed only for a live run. Never
    logged.

.PARAMETER RunId
    Correlation id stamped on every log line and on the summary.

.EXAMPLE
    $arm = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    $tokens = @{ Arm = $arm } | ConvertTo-Json -Compress
    .\Watch-AutomationJobFailures.ps1 -AutomationAccountName aa-example-identity-corp -ResourceGroupName rg-example-identity-automation -SubscriptionName 'Identity Production' -Recipients 'iam@corp.example.com' -AccessToken $tokens

    A local dry run: reads the account with the caller's ARM token, logs what
    it would report, and sends and writes nothing.

.EXAMPLE
    .\Watch-AutomationJobFailures.ps1 -AutomationAccountName aa-example-identity-corp -ResourceGroupName rg-example-identity-automation -SubscriptionName 00000000-0000-0000-0000-000000000000 -Recipients 'iam@corp.example.com;secops@corp.example.com' -SenderMailbox iam-noreply@corp.example.com -ExcludeRunbookNames 'Invoke-Sandbox;Invoke-Scratch' -DryRun:$false -ClientId <identity client id>

    The live form the job schedule runs, on the managed identity, with the
    subscription id the stack supplies and the lists in semicolon form.

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.

    Identity: an observer tier identity. The watcher reads the account and
    reports what it finds; the only thing it changes is its own state
    variable. The user-assigned managed identity that runs it (ClientId)
    needs exactly this:

      Microsoft Graph application permission: Mail.Send only, used by live
      runs only (a dry run makes no Graph call). Restrict it to
      SenderMailbox with an Exchange Online application access policy.

      Azure RBAC, both assignments on the Automation account and nowhere
      else (watcher-reader-on-account and watcher-state-on-account in
      tenants/azure/corp/azure-automation):
        Reader, for every read: schedules, job schedules, jobs, job
        streams, and the state variable.
        Automation Variable Writer, the custom role in
        tenants/azure/corp/azure-rbac-roles that holds only
        Microsoft.Automation/automationAccounts/variables/read and
        Microsoft.Automation/automationAccounts/variables/write, for the
        state write. Azure RBAC has no per-variable scope for Automation,
        so this is write on every variable in the account, not only this
        runbook's state: see "Why a variable change is a finding" above
        for the two checks that answer it and for the alert to add.

    The actions the runbook uses, all covered by that pair:
        Microsoft.Automation/automationAccounts/schedules/read
        Microsoft.Automation/automationAccounts/jobSchedules/read
        Microsoft.Automation/automationAccounts/jobs/read
        Microsoft.Automation/automationAccounts/jobs/streams/read
        Microsoft.Automation/automationAccounts/variables/read
        Microsoft.Automation/automationAccounts/variables/write
    The account resource itself is never read; a wrong account name fails
    on the schedules list with a clear message. Automation Operator and
    Automation Job Operator cannot replace the pair: neither holds a
    variables action, and both can create jobs (jobs/write), which the
    watcher never does. Reader also lets the identity read the account's
    runbook content and the values of unencrypted variables, so keep
    secrets in encrypted variables or credentials. Resolving
    SubscriptionName by name lists the subscriptions the identity can see
    (GET /subscriptions); the corp cell passes the subscription id instead,
    which skips that call and needs no subscription-level role.

    ARM endpoints, api-version 2023-11-01 (learn.microsoft.com, Azure
    Automation REST): Job - List By Automation Account ($filter), Job - Get,
    Job Stream - List By Job ($filter), Job Stream - Get, Schedule - List By
    Automation Account, Job Schedule - List By Automation Account, Variable -
    Get, Variable - List By Automation Account (names and times only; the
    change report never reads a value), Variable - Create Or Update
    (properties.value is the JSON encoding of the string). The filter grammar, properties/startTime ge <round-trip UTC>,
    properties/status eq '<status>', and properties/streamType eq 'Error',
    is the one the Az.Automation cmdlets send for Get-AzAutomationJob
    -StartTime, Get-AzAutomationJob -Status, and the error stream. The jobs
    and job streams lists page with nextLink; the schedules list reports
    nextRun, which the heartbeat checks its schedule math against.

    Schedule: the corp cell (tenants/azure/corp/azure-automation) links this
    runbook to hourly-45-utc: frequency Hour, interval 1, time zone Etc/UTC,
    start time 2027-01-04T00:45:00Z. It therefore runs at minute 45 of
    every hour, a minute at which no other runbook in the cell starts (they
    start on the hour, at a quarter past, or at half past). The cell passes
    LookbackMinutes 70 and HeartbeatGraceMinutes 30 (their help above says
    how they fit minute 45) and the subscription id, and, like every
    runbook in the shipped cell, runs dry (dryrun true) until a few runs
    have been read.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$')]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionName,

    [ValidateRange(5, 1440)]
    [int]$LookbackMinutes = 70,

    [ValidateRange(0, 10080)]
    [int]$MaxJobRuntimeMinutes = 240,

    [ValidateRange(0, 1440)]
    [int]$HeartbeatGraceMinutes = 30,

    # JobWatch_ is not decoration: the identity's Automation Variable Writer
    # role is write on every variable in the account, so the prefix is what
    # keeps a job-schedule parameter from pointing this runbook's one write at
    # a PIM baseline or an AuthMethods_ variable. Write-JobWatchState checks
    # it again.
    [ValidatePattern('^JobWatch_[A-Za-z0-9_-]{1,119}$')]
    [string]$StateVariableName = 'JobWatch_AlertedJobIds',

    [string]$ExcludeRunbookNames = '',

    [string]$Recipients = '',

    [string]$SenderMailbox = '',

    [bool]$DryRun = $true,

    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',

    [string]$ClientId = '',

    [string]$AccessToken = '',

    [string]$RunId = ([Guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')
# INLINE_LIBRARY_END

# ---------------------------------------------------------------------------
# Constants.
# ---------------------------------------------------------------------------

$script:JobWatchRunbookName = 'Watch-AutomationJobFailures'
$script:JobWatchApiVersion = '2023-11-01'
$script:JobWatchRetentionHours = 48
$script:JobWatchMaxStateEntries = 2000
$script:JobWatchMaxDigestRows = 200
$script:JobWatchToleranceMinutes = 2
$script:JobWatchMaxStreamPages = 10
# The state update, the digest, and the state put back if the digest fails.
$script:JobWatchMaxWrites = 3
$script:JobWatchAlertStatuses = @('Failed', 'Suspended', 'Stopped')
# Every Automation variable this runbook may write begins with this. The
# identity's Automation Variable Writer role is account-wide, so the prefix is
# what keeps its one write off the PIM baselines and the AuthMethods_ desired
# state that the same account holds (docs/adr/0016).
$script:JobWatchStatePrefix = 'JobWatch_'
$script:JobWatchGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# Azure naming rule for automationAccounts/runbooks (learn.microsoft.com,
# "Naming rules and restrictions for Azure resources"): 1 to 63 letters,
# digits, underscores, and hyphens, starting with a letter.
$script:JobWatchRunbookNamePattern = '^[A-Za-z][A-Za-z0-9_-]{0,62}$'

# Windows PowerShell 5.1 (.NET Framework) knows only Windows time zone ids.
# PowerShell 7 on Windows resolves IANA ids itself; this table covers the
# common IANA ids for 5.1. A Day, Week, or Month schedule whose id resolves
# nowhere is not judged, with a warning.
$script:JobWatchIanaToWindows = @{
    'America/New_York'    = 'Eastern Standard Time'
    'America/Detroit'     = 'Eastern Standard Time'
    'America/Toronto'     = 'Eastern Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Phoenix'     = 'US Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'America/Anchorage'   = 'Alaskan Standard Time'
    'Pacific/Honolulu'    = 'Hawaiian Standard Time'
    'America/Sao_Paulo'   = 'E. South America Standard Time'
    'Europe/London'       = 'GMT Standard Time'
    'Europe/Dublin'       = 'GMT Standard Time'
    'Europe/Lisbon'       = 'GMT Standard Time'
    'Europe/Amsterdam'    = 'W. Europe Standard Time'
    'Europe/Berlin'       = 'W. Europe Standard Time'
    'Europe/Rome'         = 'W. Europe Standard Time'
    'Europe/Stockholm'    = 'W. Europe Standard Time'
    'Europe/Zurich'       = 'W. Europe Standard Time'
    'Europe/Brussels'     = 'Romance Standard Time'
    'Europe/Madrid'       = 'Romance Standard Time'
    'Europe/Paris'        = 'Romance Standard Time'
    'Europe/Warsaw'       = 'Central European Standard Time'
    'Europe/Prague'       = 'Central Europe Standard Time'
    'Europe/Helsinki'     = 'FLE Standard Time'
    'Europe/Athens'       = 'GTB Standard Time'
    'Europe/Istanbul'     = 'Turkey Standard Time'
    'Europe/Moscow'       = 'Russian Standard Time'
    'Asia/Dubai'          = 'Arabian Standard Time'
    'Asia/Kolkata'        = 'India Standard Time'
    'Asia/Singapore'      = 'Singapore Standard Time'
    'Asia/Shanghai'       = 'China Standard Time'
    'Asia/Hong_Kong'      = 'China Standard Time'
    'Asia/Tokyo'          = 'Tokyo Standard Time'
    'Asia/Seoul'          = 'Korea Standard Time'
    'Australia/Perth'     = 'W. Australia Standard Time'
    'Australia/Brisbane'  = 'E. Australia Standard Time'
    'Australia/Sydney'    = 'AUS Eastern Standard Time'
    'Australia/Melbourne' = 'AUS Eastern Standard Time'
    'Pacific/Auckland'    = 'New Zealand Standard Time'
    'Africa/Johannesburg' = 'South Africa Standard Time'
}

# ---------------------------------------------------------------------------
# Values and times. Pure.
# ---------------------------------------------------------------------------

function Get-JobWatchValue {
    <#
    .SYNOPSIS
        A nested value from a parsed ARM object or a hashtable, or $null.
    .DESCRIPTION
        Walks a dotted path such as properties.runbook.name and returns $null
        at the first missing step, so a sparse ARM response never throws,
        with or without strict mode.
    .PARAMETER Object
        Parsed JSON object or dictionary.
    .PARAMETER Path
        Dotted property path.
    .EXAMPLE
        Get-JobWatchValue -Object $job -Path 'properties.runbook.name'
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
    )

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        }
        else {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $current = $property.Value
        }
    }
    return $current
}

function ConvertTo-JobWatchBool {
    <#
    .SYNOPSIS
        A JSON boolean, or its string form, as [bool]. $null is $false.
    .PARAMETER Value
        true, false, "true", "false", or $null.
    .EXAMPLE
        ConvertTo-JobWatchBool -Value 'false'
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $parsed = $false
    if ([bool]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    return $false
}

function ConvertTo-JobWatchUtc {
    <#
    .SYNOPSIS
        A UTC DateTime from an ARM time value, or $null.
    .DESCRIPTION
        Accepts an ISO 8601 string with or without an offset (Windows
        PowerShell 5.1 leaves ARM times as strings), a DateTime (PowerShell 7
        converts them; Local is converted, Unspecified is taken as UTC), or a
        DateTimeOffset. A far-future value such as 9999-12-31 that cannot be
        represented after applying its offset becomes DateTime.MaxValue.
    .PARAMETER Value
        The value.
    .EXAMPLE
        ConvertTo-JobWatchUtc -Value '2026-09-17T08:00:00+02:00'
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value }
        if ($Value.Kind -eq [DateTimeKind]::Local) {
            try { return $Value.ToUniversalTime() }
            catch {
                if ($Value.Year -ge 9999) { return [DateTime]::SpecifyKind([DateTime]::MaxValue, [DateTimeKind]::Utc) }
                return [DateTime]::SpecifyKind([DateTime]::MinValue, [DateTimeKind]::Utc)
            }
        }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    if ($text.StartsWith('9999-')) { return [DateTime]::SpecifyKind([DateTime]::MaxValue, [DateTimeKind]::Utc) }
    return $null
}

function ConvertTo-JobWatchTimeText {
    <#
    .SYNOPSIS
        A time as yyyy-MM-ddTHH:mm:ssZ in UTC, or '' for $null.
    .DESCRIPTION
        The value goes through ConvertTo-JobWatchUtc first, so a Local
        DateTime or a DateTimeOffset is written as its UTC time, never as
        its local clock time with a Z.
    .PARAMETER Value
        A time in any form ConvertTo-JobWatchUtc reads.
    .EXAMPLE
        ConvertTo-JobWatchTimeText -Value $expectedUtc
    #>
    param([AllowNull()][object]$Value)

    $utc = ConvertTo-JobWatchUtc -Value $Value
    if ($null -eq $utc) { return '' }
    return $utc.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Resolve-JobWatchTimeZone {
    <#
    .SYNOPSIS
        The TimeZoneInfo for a schedule's timeZone value, or $null.
    .DESCRIPTION
        Empty and the UTC aliases (UTC, Etc/UTC, Etc/GMT, and so on) are UTC.
        Otherwise the id is looked up as given (Windows ids everywhere, IANA
        ids on PowerShell 7), then through the IANA to Windows table for
        Windows PowerShell 5.1. Returns $null when nothing matches.
    .PARAMETER TimeZoneId
        The schedule's timeZone.
    .EXAMPLE
        Resolve-JobWatchTimeZone -TimeZoneId 'America/New_York'
    #>
    param([AllowNull()][AllowEmptyString()][string]$TimeZoneId)

    $id = ''
    if ($null -ne $TimeZoneId) { $id = $TimeZoneId.Trim() }
    $utcAliases = @('UTC', 'Etc/UTC', 'Etc/GMT', 'GMT', 'Etc/Universal', 'Etc/Zulu', 'Universal', 'Zulu', 'Coordinated Universal Time')
    if ($id.Length -eq 0 -or $utcAliases -contains $id) { return [TimeZoneInfo]::Utc }

    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($id)
    if ($script:JobWatchIanaToWindows.ContainsKey($id)) { [void]$candidates.Add([string]$script:JobWatchIanaToWindows[$id]) }
    foreach ($candidate in $candidates) {
        try { return [TimeZoneInfo]::FindSystemTimeZoneById([string]$candidate) }
        catch { continue }
    }
    return $null
}

function ConvertFrom-ScheduleLocalTime {
    <#
    .SYNOPSIS
        The UTC instant of a wall-clock time in a time zone.
    .DESCRIPTION
        A wall-clock time that does not exist because the clocks moved
        forward is moved forward by the daylight delta, which is when the
        scheduler can fire. An ambiguous time is taken as standard time.
    .PARAMETER LocalTime
        Wall-clock time (its Kind is ignored).
    .PARAMETER TimeZone
        The schedule's time zone.
    .EXAMPLE
        ConvertFrom-ScheduleLocalTime -LocalTime $local -TimeZone $tz
    #>
    param(
        [Parameter(Mandatory = $true)][DateTime]$LocalTime,
        [Parameter(Mandatory = $true)][TimeZoneInfo]$TimeZone
    )

    $local = [DateTime]::SpecifyKind($LocalTime, [DateTimeKind]::Unspecified)
    if ($TimeZone.IsInvalidTime($local)) {
        $delta = New-TimeSpan -Hours 1
        foreach ($rule in $TimeZone.GetAdjustmentRules()) {
            if ($rule.DateStart -le $local -and $rule.DateEnd -ge $local -and $rule.DaylightDelta -gt [TimeSpan]::Zero) { $delta = $rule.DaylightDelta }
        }
        $local = $local.Add($delta)
    }
    return [TimeZoneInfo]::ConvertTimeToUtc($local, $TimeZone)
}

function ConvertTo-ScheduleLocalTime {
    <#
    .SYNOPSIS
        The wall-clock time in a time zone for a UTC instant.
    .PARAMETER UtcTime
        UTC instant.
    .PARAMETER TimeZone
        The schedule's time zone.
    .EXAMPLE
        ConvertTo-ScheduleLocalTime -UtcTime $startUtc -TimeZone $tz
    #>
    param(
        [Parameter(Mandatory = $true)][DateTime]$UtcTime,
        [Parameter(Mandatory = $true)][TimeZoneInfo]$TimeZone
    )

    $converted = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($UtcTime, [DateTimeKind]::Utc), $TimeZone)
    return [DateTime]::SpecifyKind($converted, [DateTimeKind]::Unspecified)
}

# ---------------------------------------------------------------------------
# Schedule math. Pure: the clock and the schedule are parameters.
# ---------------------------------------------------------------------------

function Get-MonthOccurrenceDays {
    <#
    .SYNOPSIS
        The days of one month on which a monthly schedule runs, latest first.
    .DESCRIPTION
        monthDays: 1 to 31, where a day the month does not have is skipped,
        and -1 for the last day. monthlyOccurrences: occurrence 1 to 5 of a
        weekday, where a fifth weekday the month does not have is skipped,
        and -1 for the last one. With neither, DefaultDay (the start date's
        day), moved back to the month's last day when the month is shorter.
        Writes the days to the pipeline; wrap in @().
    .PARAMETER Year
        Year.
    .PARAMETER Month
        Month, 1 to 12.
    .PARAMETER MonthDays
        advancedSchedule.monthDays.
    .PARAMETER MonthlyOccurrences
        advancedSchedule.monthlyOccurrences (objects with occurrence and day).
    .PARAMETER DefaultDay
        Day of month of the schedule's start.
    .EXAMPLE
        @(Get-MonthOccurrenceDays -Year 2026 -Month 9 -MonthDays @(1, -1))
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][ValidateRange(1, 12)][int]$Month,
        [int[]]$MonthDays = @(),
        [object[]]$MonthlyOccurrences = @(),
        [ValidateRange(1, 31)][int]$DefaultDay = 1
    )

    $last = [DateTime]::DaysInMonth($Year, $Month)
    $days = New-Object System.Collections.ArrayList
    $dayList = @($MonthDays | Where-Object { $null -ne $_ })
    $occurrenceList = @($MonthlyOccurrences | Where-Object { $null -ne $_ })

    foreach ($day in $dayList) {
        if ($day -eq -1) { [void]$days.Add($last) }
        elseif ($day -ge 1 -and $day -le $last) { [void]$days.Add([int]$day) }
    }

    foreach ($entry in $occurrenceList) {
        $dayName = ([string](Get-JobWatchValue -Object $entry -Path 'day')).Trim()
        $occurrenceText = [string](Get-JobWatchValue -Object $entry -Path 'occurrence')
        $occurrence = 0
        if (-not [int]::TryParse($occurrenceText, [ref]$occurrence)) { continue }
        $weekday = $null
        try { $weekday = [DayOfWeek]$dayName } catch { continue }

        if ($occurrence -eq -1) {
            $candidate = New-Object -TypeName DateTime -ArgumentList $Year, $Month, $last
            while ($candidate.DayOfWeek -ne $weekday) { $candidate = $candidate.AddDays(-1) }
            [void]$days.Add($candidate.Day)
        }
        elseif ($occurrence -ge 1 -and $occurrence -le 5) {
            $first = New-Object -TypeName DateTime -ArgumentList $Year, $Month, 1
            $offset = ([int]$weekday - [int]$first.DayOfWeek + 7) % 7
            $day = 1 + $offset + 7 * ($occurrence - 1)
            if ($day -le $last) { [void]$days.Add($day) }
        }
    }

    if ($dayList.Count -eq 0 -and $occurrenceList.Count -eq 0) {
        [void]$days.Add([Math]::Min($DefaultDay, $last))
    }

    foreach ($day in @($days | Sort-Object -Descending -Unique)) { [int]$day }
}

function Get-ScheduleLastOccurrence {
    <#
    .SYNOPSIS
        The latest time at or before AsOfUtc at which a schedule runs, or
        $null when it has not run yet.
    .DESCRIPTION
        OneTime: the start time. Minute and Hour: start plus whole intervals,
        in absolute time. Day, Week, Month: the start's wall-clock time in the
        schedule's time zone on the qualifying dates, converted to UTC per
        date, so the local time holds across daylight saving changes. Week
        uses WeekDays (the start's weekday when empty) and counts weeks from
        the Sunday on or before the start date. Month uses MonthDays and
        MonthlyOccurrences (see Get-MonthOccurrenceDays). An occurrence is
        never earlier than the start. Expiry and enablement are the caller's
        business.
    .PARAMETER StartUtc
        Schedule start, UTC.
    .PARAMETER Frequency
        OneTime, Minute, Hour, Day, Week, or Month.
    .PARAMETER Interval
        Units between runs. Values below 1 are treated as 1.
    .PARAMETER WeekDays
        Day names for Week.
    .PARAMETER MonthDays
        Days for Month; -1 is the last day.
    .PARAMETER MonthlyOccurrences
        Objects with occurrence (1 to 5, or -1) and day, for Month.
    .PARAMETER TimeZone
        The schedule's time zone. Default UTC.
    .PARAMETER AsOfUtc
        The latest acceptable time, UTC.
    .EXAMPLE
        Get-ScheduleLastOccurrence -StartUtc $start -Frequency Week -WeekDays @('Monday', 'Friday') -AsOfUtc $now.AddMinutes(-30)
    #>
    param(
        [Parameter(Mandatory = $true)][DateTime]$StartUtc,
        [Parameter(Mandatory = $true)][ValidateSet('OneTime', 'Minute', 'Hour', 'Day', 'Week', 'Month')][string]$Frequency,
        [int]$Interval = 1,
        [string[]]$WeekDays = @(),
        [int[]]$MonthDays = @(),
        [object[]]$MonthlyOccurrences = @(),
        [TimeZoneInfo]$TimeZone = [TimeZoneInfo]::Utc,
        [Parameter(Mandatory = $true)][DateTime]$AsOfUtc
    )

    if ($Interval -lt 1) { $Interval = 1 }
    if ($null -eq $TimeZone) { $TimeZone = [TimeZoneInfo]::Utc }
    $start = [DateTime]::SpecifyKind($StartUtc, [DateTimeKind]::Utc)
    $asOf = [DateTime]::SpecifyKind($AsOfUtc, [DateTimeKind]::Utc)
    if ($start -gt $asOf) { return $null }

    if ($Frequency -eq 'OneTime') { return $start }

    if ($Frequency -eq 'Minute' -or $Frequency -eq 'Hour') {
        $stepMinutes = [double]$Interval
        if ($Frequency -eq 'Hour') { $stepMinutes = [double]$Interval * 60 }
        $steps = [Math]::Floor(($asOf - $start).TotalMinutes / $stepMinutes)
        return $start.AddMinutes($steps * $stepMinutes)
    }

    $localStart = ConvertTo-ScheduleLocalTime -UtcTime $start -TimeZone $TimeZone
    $localAsOf = ConvertTo-ScheduleLocalTime -UtcTime $asOf -TimeZone $TimeZone
    $timeOfDay = $localStart.TimeOfDay

    if ($Frequency -eq 'Day') {
        $elapsedDays = [int]($localAsOf.Date - $localStart.Date).TotalDays
        $index = [int][Math]::Floor($elapsedDays / $Interval)
        for ($i = $index; $i -ge 0 -and $i -ge ($index - 2); $i--) {
            $candidate = ConvertFrom-ScheduleLocalTime -LocalTime $localStart.Date.AddDays($i * $Interval).Add($timeOfDay) -TimeZone $TimeZone
            if ($candidate -le $asOf -and $candidate -ge $start) { return $candidate }
        }
        return $null
    }

    if ($Frequency -eq 'Week') {
        $allowed = New-Object System.Collections.ArrayList
        foreach ($name in @($WeekDays | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
            $trimmed = ([string]$name).Trim()
            try {
                $weekday = [DayOfWeek]$trimmed
                [void]$allowed.Add([int]$weekday)
            }
            catch { continue }
        }
        if ($allowed.Count -eq 0) { [void]$allowed.Add([int]$localStart.DayOfWeek) }

        $anchor = $localStart.Date.AddDays(-[int]$localStart.DayOfWeek)
        $stop = $localAsOf.Date.AddDays(-(7 * $Interval + 7))
        if ($stop -lt $localStart.Date) { $stop = $localStart.Date }
        $day = $localAsOf.Date
        while ($day -ge $stop) {
            $weekIndex = [int][Math]::Floor(($day - $anchor).TotalDays / 7)
            if (($weekIndex % $Interval) -eq 0 -and $allowed.Contains([int]$day.DayOfWeek)) {
                $candidate = ConvertFrom-ScheduleLocalTime -LocalTime $day.Add($timeOfDay) -TimeZone $TimeZone
                if ($candidate -le $asOf -and $candidate -ge $start) { return $candidate }
            }
            $day = $day.AddDays(-1)
        }
        return $null
    }

    # Month.
    $startMonth = $localStart.Year * 12 + ($localStart.Month - 1)
    $asOfMonth = $localAsOf.Year * 12 + ($localAsOf.Month - 1)
    $limit = 12 * $Interval + 12
    for ($offset = 0; $offset -le $limit; $offset++) {
        $monthNumber = $asOfMonth - $offset
        if ($monthNumber -lt $startMonth) { break }
        if ((($monthNumber - $startMonth) % $Interval) -ne 0) { continue }
        $year = [int][Math]::Floor($monthNumber / 12)
        $month = ($monthNumber % 12) + 1
        $days = @(Get-MonthOccurrenceDays -Year $year -Month $month -MonthDays $MonthDays -MonthlyOccurrences $MonthlyOccurrences -DefaultDay $localStart.Day)
        foreach ($dayOfMonth in $days) {
            $localDate = New-Object -TypeName DateTime -ArgumentList $year, $month, $dayOfMonth
            $candidate = ConvertFrom-ScheduleLocalTime -LocalTime $localDate.Add($timeOfDay) -TimeZone $TimeZone
            if ($candidate -le $asOf -and $candidate -ge $start) { return $candidate }
        }
    }
    return $null
}

function Get-ScheduleExpectation {
    <#
    .SYNOPSIS
        Decides whether a schedule is judged by the heartbeat and, if so,
        which run was due.
    .DESCRIPTION
        Returns ScheduleName, Frequency, Interval, TimeZoneId,
        TimeZoneResolved, NextRunUtc, LastModifiedUtc, Evaluate,
        ExpectedUtc, and Reason. LastModifiedUtc (properties.lastModifiedTime)
        is reported for the caller's note and never changes the reason.
        Reasons, in the order they are tested:

          Disabled         isEnabled is not true
          NoStartTime      startTime is missing or unreadable
          Expired          expiryTime is at or before now
          NotStarted       the first run is not yet past the grace window
          OneTimePast      a one-time schedule whose time has passed
          Unsupported      a frequency this function does not know
          TimeZoneUnknown  a Day, Week, or Month schedule whose time zone
                           this host cannot resolve
          NextRunMismatch  the schedule reports nextRun, and the occurrence
                           computed for that moment is not nextRun
          NoOccurrence     no run between start and now minus grace
          OutsideHorizon   the due run is older than HorizonHours
          Due              judged: Evaluate is $true

        The due run is the latest occurrence at or before NowUtc minus
        GraceMinutes. The nextRun check asks for the latest occurrence at or
        before nextRun plus NextRunToleranceMinutes and accepts it when it is
        within NextRunToleranceMinutes of nextRun, which absorbs a nextRun
        written without the seconds of the start time. Minute and Hour
        schedules step in absolute time, so an unknown time zone does not
        matter to them and only sets TimeZoneResolved to $false.
    .PARAMETER Schedule
        One item of the ARM schedules list.
    .PARAMETER NowUtc
        The clock.
    .PARAMETER GraceMinutes
        Minutes a run may be late before it is judged.
    .PARAMETER HorizonHours
        Oldest due run that is still judged. Equal to the state retention.
    .PARAMETER NextRunToleranceMinutes
        Largest accepted difference between nextRun and the computed
        occurrence. Default 1.
    .EXAMPLE
        Get-ScheduleExpectation -Schedule $schedule -NowUtc ([DateTime]::UtcNow) -GraceMinutes 30
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Schedule,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc,
        [ValidateRange(0, 100000)][int]$GraceMinutes = 30,
        [ValidateRange(1, 100000)][int]$HorizonHours = 48,
        [ValidateRange(0, 60)][int]$NextRunToleranceMinutes = 1
    )

    $now = ConvertTo-JobWatchUtc -Value $NowUtc
    $asOf = $now.AddMinutes(-$GraceMinutes)
    $frequency = [string](Get-JobWatchValue -Object $Schedule -Path 'properties.frequency')
    $intervalValue = Get-JobWatchValue -Object $Schedule -Path 'properties.interval'
    $interval = 1
    if ($null -ne $intervalValue) {
        $parsedInterval = 0
        if ([int]::TryParse(([string]$intervalValue).Trim(), [ref]$parsedInterval) -and $parsedInterval -ge 1) { $interval = $parsedInterval }
    }
    $startUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Schedule -Path 'properties.startTime')
    $expiryUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Schedule -Path 'properties.expiryTime')
    $nextRunUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Schedule -Path 'properties.nextRun')
    $lastModifiedUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Schedule -Path 'properties.lastModifiedTime')
    $timeZoneId = [string](Get-JobWatchValue -Object $Schedule -Path 'properties.timeZone')

    $result = [ordered]@{
        ScheduleName     = [string](Get-JobWatchValue -Object $Schedule -Path 'name')
        Frequency        = $frequency
        Interval         = $interval
        TimeZoneId       = $timeZoneId
        TimeZoneResolved = $true
        NextRunUtc       = $nextRunUtc
        LastModifiedUtc  = $lastModifiedUtc
        Evaluate         = $false
        ExpectedUtc      = $null
        Reason           = ''
    }

    if (-not (ConvertTo-JobWatchBool -Value (Get-JobWatchValue -Object $Schedule -Path 'properties.isEnabled'))) {
        $result.Reason = 'Disabled'
    }
    elseif ($null -eq $startUtc) {
        $result.Reason = 'NoStartTime'
    }
    elseif ($null -ne $expiryUtc -and $expiryUtc -le $now) {
        $result.Reason = 'Expired'
    }
    elseif ($startUtc -gt $asOf) {
        $result.Reason = 'NotStarted'
    }
    elseif ($frequency -eq 'OneTime') {
        $result.Reason = 'OneTimePast'
    }
    elseif (@('Minute', 'Hour', 'Day', 'Week', 'Month') -notcontains $frequency) {
        $result.Reason = 'Unsupported'
    }
    else {
        $timeZone = Resolve-JobWatchTimeZone -TimeZoneId $timeZoneId
        if ($null -eq $timeZone) {
            $result.TimeZoneResolved = $false
            $timeZone = [TimeZoneInfo]::Utc
        }

        $weekDays = @(Get-JobWatchValue -Object $Schedule -Path 'properties.advancedSchedule.weekDays' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $monthDays = @(Get-JobWatchValue -Object $Schedule -Path 'properties.advancedSchedule.monthDays' | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
        $monthly = @(Get-JobWatchValue -Object $Schedule -Path 'properties.advancedSchedule.monthlyOccurrences' | Where-Object { $null -ne $_ })
        $occurrence = @{
            StartUtc           = $startUtc
            Frequency          = $frequency
            Interval           = $interval
            WeekDays           = $weekDays
            MonthDays          = $monthDays
            MonthlyOccurrences = $monthly
            TimeZone           = $timeZone
        }

        $nextRunAgrees = $true
        if ($null -ne $nextRunUtc -and $nextRunUtc.Year -lt 9999) {
            $atNextRun = Get-ScheduleLastOccurrence @occurrence -AsOfUtc $nextRunUtc.AddMinutes($NextRunToleranceMinutes)
            $nextRunAgrees = ($null -ne $atNextRun) -and ([Math]::Abs(($atNextRun - $nextRunUtc).TotalMinutes) -le $NextRunToleranceMinutes)
        }

        if (-not $result.TimeZoneResolved -and @('Day', 'Week', 'Month') -contains $frequency) {
            $result.Reason = 'TimeZoneUnknown'
        }
        elseif (-not $nextRunAgrees) {
            $result.Reason = 'NextRunMismatch'
        }
        else {
            $expected = Get-ScheduleLastOccurrence @occurrence -AsOfUtc $asOf
            $result.ExpectedUtc = $expected
            if ($null -eq $expected) {
                $result.Reason = 'NoOccurrence'
            }
            elseif ($expected -lt $now.AddHours(-$HorizonHours)) {
                $result.Reason = 'OutsideHorizon'
            }
            else {
                $result.Evaluate = $true
                $result.Reason = 'Due'
            }
        }
    }

    return [PSCustomObject]$result
}

# ---------------------------------------------------------------------------
# Jobs and findings. Pure.
# ---------------------------------------------------------------------------

function ConvertTo-JobWatchJob {
    <#
    .SYNOPSIS
        A flat job record from one item of the ARM jobs list.
    .DESCRIPTION
        Returns JobId (lower case; properties.jobId, else the resource name),
        RunbookName, Status, StartUtc, EndUtc, CreationUtc, LastModifiedUtc,
        and CompletedUtc. EndUtc is $null for a job that is still running or
        suspended, and StartUtc is $null for a job that never started.
        CompletedUtc is when the job reached its current status as far as the
        list shows: endTime, else lastModifiedTime, else startTime, else
        creationTime.
    .PARAMETER Job
        The ARM item.
    .EXAMPLE
        $jobs = @(foreach ($item in $items) { ConvertTo-JobWatchJob -Job $item })
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Job)

    $jobId = [string](Get-JobWatchValue -Object $Job -Path 'properties.jobId')
    if ([string]::IsNullOrWhiteSpace($jobId)) { $jobId = [string](Get-JobWatchValue -Object $Job -Path 'name') }
    $startUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Job -Path 'properties.startTime')
    $endUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Job -Path 'properties.endTime')
    $creationUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Job -Path 'properties.creationTime')
    $lastModifiedUtc = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $Job -Path 'properties.lastModifiedTime')

    $completedUtc = $null
    foreach ($candidate in @($endUtc, $lastModifiedUtc, $startUtc, $creationUtc)) {
        if ($null -ne $candidate) {
            $completedUtc = $candidate
            break
        }
    }

    return [PSCustomObject]@{
        JobId           = $jobId.Trim().ToLowerInvariant()
        RunbookName     = [string](Get-JobWatchValue -Object $Job -Path 'properties.runbook.name')
        Status          = [string](Get-JobWatchValue -Object $Job -Path 'properties.status')
        StartUtc        = $startUtc
        EndUtc          = $endUtc
        CreationUtc     = $creationUtc
        LastModifiedUtc = $lastModifiedUtc
        CompletedUtc    = $completedUtc
    }
}

function Merge-JobWatchJobs {
    <#
    .SYNOPSIS
        One record per job id from several job lists, later lists winning.
    .DESCRIPTION
        The start-time list is read before the per-status lists, so a job
        that changed status in between appears in both; the later record
        carries the newer status and is kept. Records without a job id are
        dropped. Written to the pipeline in first-seen order; wrap in @().
    .PARAMETER Jobs
        Records from ConvertTo-JobWatchJob, oldest read first.
    .EXAMPLE
        $jobs = @(Merge-JobWatchJobs -Jobs ($windowJobs + $statusJobs))
    #>
    param([object[]]$Jobs = @())

    $order = New-Object System.Collections.ArrayList
    $byId = @{}
    foreach ($job in @($Jobs)) {
        if ($null -eq $job -or [string]::IsNullOrWhiteSpace([string]$job.JobId)) { continue }
        $id = ([string]$job.JobId).ToLowerInvariant()
        if (-not $byId.ContainsKey($id)) { [void]$order.Add($id) }
        $byId[$id] = $job
    }
    foreach ($id in $order) { $byId[$id] }
}

function Test-JobStartedSince {
    <#
    .SYNOPSIS
        True when a job for the runbook started at or after SinceUtc.
    .DESCRIPTION
        Any status counts, and a job without an end time (still running) counts:
        the heartbeat asks whether the run happened, and a failed run is
        reported by the failure check. A job with no start time has not
        started.
    .PARAMETER Jobs
        Records from ConvertTo-JobWatchJob.
    .PARAMETER RunbookName
        Runbook name, compared without case.
    .PARAMETER SinceUtc
        Earliest acceptable start.
    .EXAMPLE
        Test-JobStartedSince -Jobs $jobs -RunbookName 'Invoke-GuestLifecycle' -SinceUtc $expected
    #>
    param(
        [object[]]$Jobs = @(),
        [Parameter(Mandatory = $true)][string]$RunbookName,
        [Parameter(Mandatory = $true)][DateTime]$SinceUtc
    )

    foreach ($job in @($Jobs)) {
        if ($null -eq $job -or $null -eq $job.StartUtc) { continue }
        if (-not ([string]$job.RunbookName).Equals($RunbookName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($job.StartUtc -ge $SinceUtc) { return $true }
    }
    return $false
}

function Get-JobWatchExclusions {
    <#
    .SYNOPSIS
        The runbook names both checks ignore.
    .DESCRIPTION
        Always the watcher's own name, then the configured names, then the
        runbook of the job whose id is CurrentJobId (the running watcher job,
        whatever it was published as). Unique without case, in that order.
    .PARAMETER Names
        Configured names.
    .PARAMETER Jobs
        Records from ConvertTo-JobWatchJob.
    .PARAMETER CurrentJobId
        Id of the job this code runs in, or empty.
    .PARAMETER WatcherName
        The watcher's runbook name.
    .EXAMPLE
        @(Get-JobWatchExclusions -Names @('Invoke-Sandbox') -Jobs $jobs -CurrentJobId $jobId)
    #>
    param(
        [string[]]$Names = @(),
        [object[]]$Jobs = @(),
        [AllowEmptyString()][string]$CurrentJobId = '',
        [ValidateNotNullOrEmpty()][string]$WatcherName = 'Watch-AutomationJobFailures'
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.ArrayList
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($WatcherName)
    foreach ($name in @($Names)) { [void]$candidates.Add([string]$name) }
    if (-not [string]::IsNullOrWhiteSpace($CurrentJobId)) {
        foreach ($job in @($Jobs)) {
            if ($null -ne $job -and ([string]$job.JobId).Equals($CurrentJobId.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                [void]$candidates.Add([string]$job.RunbookName)
            }
        }
    }
    foreach ($candidate in $candidates) {
        $trimmed = ([string]$candidate).Trim()
        if ($trimmed.Length -gt 0 -and $set.Add($trimmed)) { [void]$ordered.Add($trimmed) }
    }
    foreach ($name in $ordered) { [string]$name }
}

function Get-FailedJobFindings {
    <#
    .SYNOPSIS
        One finding per job that reached Failed, Suspended, or Stopped
        inside the window.
    .DESCRIPTION
        A job qualifies when its status is one of Statuses, its CompletedUtc
        (see ConvertTo-JobWatchJob) is at or after WindowStartUtc, and its
        runbook is not excluded. When it started does not matter, so a job
        that ran for hours, or never started, is selected by when it ended.
        Each finding has Kind FailedJob, Key job:<job id>, JobId,
        RunbookName, Status, StartUtc ($null when the job never started),
        CompletedUtc, and an empty ErrorSummary for the caller to fill.
        Written to the pipeline in the order the jobs ended; wrap in @().
    .PARAMETER Jobs
        Records from ConvertTo-JobWatchJob.
    .PARAMETER WindowStartUtc
        Start of the lookback window.
    .PARAMETER ExcludedRunbooks
        Runbook names to ignore, compared without case.
    .PARAMETER Statuses
        Statuses that count as failures.
    .EXAMPLE
        $failed = @(Get-FailedJobFindings -Jobs $jobs -WindowStartUtc $now.AddMinutes(-70) -ExcludedRunbooks $excluded)
    #>
    param(
        [object[]]$Jobs = @(),
        [Parameter(Mandatory = $true)][DateTime]$WindowStartUtc,
        [string[]]$ExcludedRunbooks = @(),
        [string[]]$Statuses = @('Failed', 'Suspended', 'Stopped')
    )

    $findings = New-Object System.Collections.ArrayList
    foreach ($job in @($Jobs)) {
        if ($null -eq $job -or [string]::IsNullOrWhiteSpace([string]$job.JobId)) { continue }
        if ($Statuses -notcontains [string]$job.Status) { continue }
        if (@($ExcludedRunbooks) -contains [string]$job.RunbookName) { continue }
        $completed = $job.CompletedUtc
        if ($null -eq $completed -or $completed -lt $WindowStartUtc) { continue }
        [void]$findings.Add([PSCustomObject]@{
                Kind         = 'FailedJob'
                Key          = 'job:' + ([string]$job.JobId).ToLowerInvariant()
                JobId        = [string]$job.JobId
                RunbookName  = [string]$job.RunbookName
                Status       = [string]$job.Status
                StartUtc     = $job.StartUtc
                CompletedUtc = $completed
                ErrorSummary = ''
            })
    }
    foreach ($finding in @($findings | Sort-Object -Property CompletedUtc, JobId)) { $finding }
}

function Get-MissedRunFindings {
    <#
    .SYNOPSIS
        The heartbeat: one finding per runbook whose due scheduled run has
        not started.
    .DESCRIPTION
        For each job schedule (a runbook linked to a schedule) whose runbook
        is not excluded, looks up the schedule by name and asks
        Get-ScheduleExpectation whether it is due. A due run with no job for
        the runbook started since ExpectedUtc minus ToleranceMinutes is a
        finding: Kind MissedRun, Key missed:<runbook>|<expected UTC>,
        RunbookName, ScheduleName, ExpectedUtc, TimeZoneId, and
        ScheduleChangedUtc. Two links that expect the same runbook at the
        same time give one finding.

        ScheduleChangedUtc is the schedule's lastModifiedTime when that is
        more than ToleranceMinutes after ExpectedUtc, else $null. It never
        drops the finding: it tells the reader that the schedule changed
        after the run was due, and if that change enabled the schedule, no
        run was due. Whether the scheduler itself moves lastModifiedTime is
        not documented, so it cannot be trusted to suppress a real miss.

        Returns one object with Findings, Evaluated (the links judged), and
        Skipped (RunbookName, ScheduleName, Reason for the rest).
    .PARAMETER Schedules
        ARM schedules list items.
    .PARAMETER JobSchedules
        ARM job schedules list items.
    .PARAMETER Jobs
        Records from ConvertTo-JobWatchJob.
    .PARAMETER NowUtc
        The clock.
    .PARAMETER GraceMinutes
        Minutes a run may be late before it is judged.
    .PARAMETER ExcludedRunbooks
        Runbook names to ignore.
    .PARAMETER HorizonHours
        Oldest due run that is still judged.
    .PARAMETER ToleranceMinutes
        A job that started this many minutes before the due time still
        counts, to absorb clock differences.
    .EXAMPLE
        $heartbeat = Get-MissedRunFindings -Schedules $schedules -JobSchedules $links -Jobs $jobs -NowUtc $now -GraceMinutes 30
    #>
    param(
        [object[]]$Schedules = @(),
        [object[]]$JobSchedules = @(),
        [object[]]$Jobs = @(),
        [Parameter(Mandatory = $true)][DateTime]$NowUtc,
        [ValidateRange(0, 100000)][int]$GraceMinutes = 30,
        [string[]]$ExcludedRunbooks = @(),
        [ValidateRange(1, 100000)][int]$HorizonHours = 48,
        [ValidateRange(0, 1440)][int]$ToleranceMinutes = 2
    )

    $byName = @{}
    foreach ($schedule in @($Schedules)) {
        if ($null -eq $schedule) { continue }
        $name = [string](Get-JobWatchValue -Object $schedule -Path 'name')
        if ($name) { $byName[$name.ToLowerInvariant()] = $schedule }
    }

    $expectations = @{}
    $findings = New-Object System.Collections.ArrayList
    $evaluated = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($link in @($JobSchedules)) {
        if ($null -eq $link) { continue }
        $runbookName = [string](Get-JobWatchValue -Object $link -Path 'properties.runbook.name')
        $scheduleName = [string](Get-JobWatchValue -Object $link -Path 'properties.schedule.name')
        if ([string]::IsNullOrWhiteSpace($runbookName) -or [string]::IsNullOrWhiteSpace($scheduleName)) { continue }

        if (@($ExcludedRunbooks) -contains $runbookName) {
            [void]$skipped.Add([PSCustomObject]@{ RunbookName = $runbookName; ScheduleName = $scheduleName; Reason = 'Excluded' })
            continue
        }
        $scheduleKey = $scheduleName.ToLowerInvariant()
        if (-not $byName.ContainsKey($scheduleKey)) {
            [void]$skipped.Add([PSCustomObject]@{ RunbookName = $runbookName; ScheduleName = $scheduleName; Reason = 'ScheduleNotFound' })
            continue
        }
        if (-not $expectations.ContainsKey($scheduleKey)) {
            $expectations[$scheduleKey] = Get-ScheduleExpectation -Schedule $byName[$scheduleKey] -NowUtc $NowUtc -GraceMinutes $GraceMinutes -HorizonHours $HorizonHours
        }
        $expectation = $expectations[$scheduleKey]
        if (-not $expectation.Evaluate) {
            [void]$skipped.Add([PSCustomObject]@{ RunbookName = $runbookName; ScheduleName = $scheduleName; Reason = $expectation.Reason })
            continue
        }

        [void]$evaluated.Add([PSCustomObject]@{ RunbookName = $runbookName; ScheduleName = $scheduleName; ExpectedUtc = $expectation.ExpectedUtc })
        $since = ([DateTime]$expectation.ExpectedUtc).AddMinutes(-$ToleranceMinutes)
        if (Test-JobStartedSince -Jobs $Jobs -RunbookName $runbookName -SinceUtc $since) { continue }

        $key = 'missed:{0}|{1}' -f $runbookName.ToLowerInvariant(), (ConvertTo-JobWatchTimeText -Value $expectation.ExpectedUtc)
        if (-not $seen.Add($key)) { continue }
        $changedUtc = $null
        $lastModifiedUtc = $expectation.LastModifiedUtc
        if ($null -ne $lastModifiedUtc -and $lastModifiedUtc -gt ([DateTime]$expectation.ExpectedUtc).AddMinutes($ToleranceMinutes)) {
            $changedUtc = $lastModifiedUtc
        }
        [void]$findings.Add([PSCustomObject]@{
                Kind               = 'MissedRun'
                Key                = $key
                RunbookName        = $runbookName
                ScheduleName       = $scheduleName
                ExpectedUtc        = $expectation.ExpectedUtc
                TimeZoneId         = $expectation.TimeZoneId
                ScheduleChangedUtc = $changedUtc
            })
    }

    return [PSCustomObject]@{
        Findings  = $findings.ToArray()
        Evaluated = $evaluated.ToArray()
        Skipped   = $skipped.ToArray()
    }
}

function Sort-JobWatchStreams {
    <#
    .SYNOPSIS
        Job stream records oldest first, by properties.time.
    .DESCRIPTION
        The ARM list does not document its order, so the latest record is
        found by time, with the list order breaking ties. A record without a
        readable time sorts first. $null items are dropped. Written to the
        pipeline; wrap in @().
    .PARAMETER Streams
        Items of the ARM job streams list, from any number of pages.
    .EXAMPLE
        $ordered = @(Sort-JobWatchStreams -Streams $records)
    #>
    param([object[]]$Streams = @())

    $rows = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($stream in @($Streams)) {
        if ($null -eq $stream) { continue }
        $index++
        $time = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $stream -Path 'properties.time')
        if ($null -eq $time) { $time = [DateTime]::MinValue }
        [void]$rows.Add([PSCustomObject]@{ Time = $time; Index = $index; Stream = $stream })
    }
    foreach ($row in @($rows | Sort-Object -Property Time, Index)) { $row.Stream }
}

function Format-JobErrorSummary {
    <#
    .SYNOPSIS
        A short, scrubbed description of why a job failed.
    .DESCRIPTION
        Takes the error stream records (summary, else streamText), keeps the
        last MaxRecords by time (see Sort-JobWatchStreams), and joins them
        with " | ", oldest first. With no usable record, uses Exception (the
        job's exception text). The result is scrubbed of token-shaped values,
        collapsed to one line, and cut at MaxLength. Returns '' when there is
        nothing.
    .PARAMETER Streams
        Items of the ARM job streams list (or Job Stream - Get results).
    .PARAMETER Exception
        properties.exception of the job.
    .PARAMETER MaxLength
        Longest result.
    .PARAMETER MaxRecords
        Most records joined.
    .EXAMPLE
        Format-JobErrorSummary -Streams $page.value -Exception $job.properties.exception
    #>
    param(
        [object[]]$Streams = @(),
        [AllowNull()][AllowEmptyString()][string]$Exception = '',
        [ValidateRange(20, 4000)][int]$MaxLength = 400,
        [ValidateRange(1, 20)][int]$MaxRecords = 3
    )

    $texts = New-Object System.Collections.ArrayList
    foreach ($stream in @(Sort-JobWatchStreams -Streams $Streams)) {
        $type = [string](Get-JobWatchValue -Object $stream -Path 'properties.streamType')
        if ($type -and $type -ne 'Error') { continue }
        $text = [string](Get-JobWatchValue -Object $stream -Path 'properties.summary')
        if ([string]::IsNullOrWhiteSpace($text)) { $text = [string](Get-JobWatchValue -Object $stream -Path 'properties.streamText') }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        [void]$texts.Add((($text -replace '\s+', ' ').Trim()))
    }

    $joined = @($texts | Select-Object -Last $MaxRecords) -join ' | '
    if ([string]::IsNullOrWhiteSpace($joined) -and -not [string]::IsNullOrWhiteSpace($Exception)) { $joined = $Exception }
    if ([string]::IsNullOrWhiteSpace($joined)) { return '' }
    return (Protect-RunbookText -Text $joined -MaxLength $MaxLength)
}

# ---------------------------------------------------------------------------
# State. The Automation variable holds a JSON document:
#   {"version":1,"alerted":[{"k":"job:<id>","t":"<UTC>"}, ...]}
# ---------------------------------------------------------------------------

function ConvertFrom-JobWatchState {
    <#
    .SYNOPSIS
        The alerted keys and their times from the state document.
    .DESCRIPTION
        Returns a hashtable of lower-case key to UTC DateTime. Empty text is
        an empty table. Text that is not the state document throws.
    .PARAMETER Text
        The state document.
    .EXAMPLE
        $entries = ConvertFrom-JobWatchState -Text '{"version":1,"alerted":[]}'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @{} }
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $Text }
    catch { throw 'the state is not valid JSON' }
    return (ConvertFrom-JobWatchStateDocument -Document $parsed)
}

function ConvertFrom-JobWatchStateDocument {
    <#
    .SYNOPSIS
        The alerted keys and their times from the parsed state document.
    .DESCRIPTION
        Returns a hashtable of lower-case key to UTC DateTime. Each t value
        may be a string (Windows PowerShell 5.1), a DateTime of any kind
        (PowerShell 7 converts ISO times while parsing JSON), or a
        DateTimeOffset. Entries without a key or a readable time are
        skipped; a key listed twice keeps its latest time. Anything that is
        not an object with an "alerted" list throws.
    .PARAMETER Document
        The output of ConvertFrom-Json for the state text.
    .EXAMPLE
        $entries = ConvertFrom-JobWatchStateDocument -Document (ConvertFrom-Json -InputObject $text)
    #>
    param([AllowNull()][object]$Document)

    $entries = @{}
    $parsed = $Document
    if ($null -eq $parsed -or -not ($parsed -is [PSCustomObject]) -or $null -eq $parsed.PSObject.Properties['alerted']) {
        throw 'the state has no "alerted" list'
    }
    foreach ($item in @($parsed.alerted)) {
        if ($null -eq $item) { continue }
        $key = [string](Get-JobWatchValue -Object $item -Path 'k')
        $at = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $item -Path 't')
        if ([string]::IsNullOrWhiteSpace($key) -or $null -eq $at) { continue }
        $key = $key.Trim().ToLowerInvariant()
        if (-not $entries.ContainsKey($key) -or $entries[$key] -lt $at) { $entries[$key] = $at }
    }
    return $entries
}

function ConvertTo-JobWatchState {
    <#
    .SYNOPSIS
        The state document for a table of alerted keys.
    .DESCRIPTION
        Compact JSON with the keys in order, so the same state always
        serialises to the same text.
    .PARAMETER Entries
        Hashtable of key to UTC DateTime.
    .EXAMPLE
        ConvertTo-JobWatchState -Entries @{ 'job:abc' = [DateTime]::UtcNow }
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Entries)

    $list = New-Object System.Collections.ArrayList
    foreach ($key in @($Entries.Keys | Sort-Object)) {
        [void]$list.Add([ordered]@{ k = [string]$key; t = (ConvertTo-JobWatchTimeText -Value (ConvertTo-JobWatchUtc -Value $Entries[$key])) })
    }
    $document = [ordered]@{ version = 1; alerted = $list.ToArray() }
    return (ConvertTo-Json -InputObject $document -Depth 5 -Compress)
}

function Limit-JobWatchState {
    <#
    .SYNOPSIS
        The alerted keys still inside the retention window, newest first up
        to MaxEntries.
    .PARAMETER Entries
        Hashtable of key to time.
    .PARAMETER NowUtc
        The clock.
    .PARAMETER RetentionHours
        Entries reported longer ago than this are dropped. Default 48.
    .PARAMETER MaxEntries
        Upper bound on the entries kept. Default 2000.
    .EXAMPLE
        $kept = Limit-JobWatchState -Entries $entries -NowUtc $now
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][hashtable]$Entries,
        [Parameter(Mandatory = $true)][DateTime]$NowUtc,
        [ValidateRange(1, 100000)][int]$RetentionHours = 48,
        [ValidateRange(1, 1000000)][int]$MaxEntries = 2000
    )

    $kept = @{}
    if ($null -eq $Entries) { return $kept }
    $cutoff = (ConvertTo-JobWatchUtc -Value $NowUtc).AddHours(-$RetentionHours)
    $rows = New-Object System.Collections.ArrayList
    foreach ($key in @($Entries.Keys)) {
        $at = ConvertTo-JobWatchUtc -Value $Entries[$key]
        if ($null -eq $at -or $at -lt $cutoff) { continue }
        [void]$rows.Add([PSCustomObject]@{ Key = ([string]$key).Trim().ToLowerInvariant(); At = $at })
    }
    $selected = @($rows | Sort-Object -Property @{ Expression = 'At'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | Select-Object -First $MaxEntries)
    foreach ($row in $selected) {
        if (-not $kept.ContainsKey($row.Key)) { $kept[$row.Key] = $row.At }
    }
    return $kept
}

function Select-NewFindings {
    <#
    .SYNOPSIS
        The findings whose key has not been reported, each key once.
    .PARAMETER Findings
        Findings with a Key property.
    .PARAMETER State
        Hashtable of already reported keys.
    .EXAMPLE
        $new = @(Select-NewFindings -Findings $failed -State $kept)
    #>
    param(
        [object[]]$Findings = @(),
        [AllowEmptyCollection()][hashtable]$State = @{}
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }
        $key = ([string]$finding.Key).Trim().ToLowerInvariant()
        if ($key.Length -eq 0) { continue }
        if ($null -ne $State -and $State.ContainsKey($key)) { continue }
        if (-not $seen.Add($key)) { continue }
        $finding
    }
}

function Get-VariableChangeFindings {
    <#
    .SYNOPSIS
        Variables of the account, other than the watcher's own state, whose
        value changed inside the window.
    .DESCRIPTION
        GET <account>/variables (Variable - List By Automation Account) and
        keeps every variable whose properties.lastModifiedTime is at or after
        WindowStartUtc and whose name is not StateVariableName. No value is
        read, logged, or mailed: only the name and the times.

        Why the watcher reports this at all. The identity's Automation
        Variable Writer role has no per-variable scope, so every identity
        attached to this account that holds it can write every variable in it,
        the PIM baselines and the AuthMethods_ desired state included, and
        those are tier 0 input (docs/adr/0016). Terraform owns them, so a
        change outside a release is drift. This is the detection half: one row
        per change, keyed on the name and the time so it is reported once. A
        release that changes a desired-state file produces one of these rows.
        It runs as the observer identity itself, so it is not a substitute for
        an activity log alert raised outside the account.
    .PARAMETER AccountPath
        From Get-AutomationAccountPath.
    .PARAMETER WindowStartUtc
        Changes at or after this time are reported.
    .PARAMETER StateVariableName
        The watcher's own state variable, which it writes itself and does not
        report.
    .EXAMPLE
        $changes = @(Get-VariableChangeFindings -AccountPath $accountPath -WindowStartUtc $start -StateVariableName 'JobWatch_AlertedJobIds')
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountPath,
        [Parameter(Mandatory = $true)][DateTime]$WindowStartUtc,
        [AllowEmptyString()][string]$StateVariableName = 'JobWatch_AlertedJobIds'
    )

    $windowStart = ConvertTo-JobWatchUtc -Value $WindowStartUtc
    foreach ($variable in @(Invoke-CloudRequest -Api Arm -Uri ($AccountPath + '/variables') -ApiVersion $script:JobWatchApiVersion -AllPages)) {
        $name = [string](Get-JobWatchValue -Object $variable -Path 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name.Equals($StateVariableName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $changed = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $variable -Path 'properties.lastModifiedTime')
        if ($null -eq $changed -or $changed -lt $windowStart) { continue }
        $created = ConvertTo-JobWatchUtc -Value (Get-JobWatchValue -Object $variable -Path 'properties.creationTime')
        $wasCreated = ($null -ne $created -and $created -ge $windowStart)
        [PSCustomObject]@{
            Key          = ('variable:{0}|{1}' -f $name.ToLowerInvariant(), (ConvertTo-JobWatchTimeText -Value $changed))
            VariableName = $name
            ChangedUtc   = $changed
            CreatedUtc   = $created
            WasCreated   = $wasCreated
        }
    }
}

function ConvertFrom-AutomationVariableValue {
    <#
    .SYNOPSIS
        The string held by an Automation variable, from its ARM value.
    .DESCRIPTION
        ARM returns properties.value as the JSON encoding of the variable's
        value, so a string variable reads as a quoted JSON string. That is
        decoded; an unquoted value is returned as it is. $null is ''.
    .PARAMETER Value
        properties.value.
    .EXAMPLE
        ConvertFrom-AutomationVariableValue -Value '"text"'
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return '' }
    if ($text.StartsWith('"') -and $text.EndsWith('"')) {
        return [string](ConvertFrom-Json -InputObject $text)
    }
    return $text
}

# ---------------------------------------------------------------------------
# Mail.
# ---------------------------------------------------------------------------

function New-JobWatchDigestHtml {
    <#
    .SYNOPSIS
        The HTML body of the digest.
    .DESCRIPTION
        One table of failed jobs (runbook, status, start, end, job id, error
        summary), one of missed runs (runbook, schedule, expected time,
        time zone, note), and one of Automation variables of the account
        other than the watcher's own state that changed inside the window
        (variable, what, when), each cut at MaxRows with a count of the rest.
        No variable value is included, only names and times. Every value is
        HTML-encoded. A job that never started shows "(not started)". A
        missed run whose ScheduleChangedUtc is set says in its note when the
        schedule changed, and the missed runs table is followed by the one
        case in which such a row is not a real miss.
    .PARAMETER AccountName
        Automation account name.
    .PARAMETER FailedJobs
        Findings from Get-FailedJobFindings.
    .PARAMETER MissedRuns
        Findings from Get-MissedRunFindings.
    .PARAMETER VariableChanges
        Findings from Get-VariableChangeFindings.
    .PARAMETER NowUtc
        The clock.
    .PARAMETER LookbackMinutes
        For the heading.
    .PARAMETER GraceMinutes
        For the heading.
    .PARAMETER StateVariableName
        For the footer.
    .PARAMETER RunIdText
        For the footer.
    .PARAMETER MaxRows
        Rows per table.
    .EXAMPLE
        New-JobWatchDigestHtml -AccountName 'aa-example' -FailedJobs $failed -MissedRuns $missed -NowUtc $now
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountName,
        [object[]]$FailedJobs = @(),
        [object[]]$MissedRuns = @(),
        [object[]]$VariableChanges = @(),
        [Parameter(Mandatory = $true)][DateTime]$NowUtc,
        [int]$LookbackMinutes = 70,
        [int]$GraceMinutes = 30,
        [string]$StateVariableName = 'JobWatch_AlertedJobIds',
        [AllowEmptyString()][string]$RunIdText = '',
        [ValidateRange(1, 100000)][int]$MaxRows = 200
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $format = 'yyyy-MM-dd HH:mm'
    $failed = @($FailedJobs | Where-Object { $null -ne $_ })
    $missed = @($MissedRuns | Where-Object { $null -ne $_ })
    $variables = @($VariableChanges | Where-Object { $null -ne $_ })
    $cell = 'style="border:1px solid #999;padding:4px;text-align:left;vertical-align:top"'

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>Automation account <b>{0}</b>: {1} failed job(s), {2} missed scheduled run(s), and {3} variable change(s) not reported before. Checked {4} UTC.</p>' -f (ConvertTo-HtmlSafe -Value $AccountName), $failed.Count, $missed.Count, $variables.Count, $NowUtc.ToString($format, $culture)))

    if ($failed.Count -gt 0) {
        [void]$sb.Append(('<h3>Failed jobs (failed, suspended, or stopped in the last {0} minutes)</h3>' -f $LookbackMinutes))
        [void]$sb.Append(('<table style="border-collapse:collapse"><tr><th {0}>Runbook</th><th {0}>Status</th><th {0}>Started (UTC)</th><th {0}>Ended or suspended (UTC)</th><th {0}>Job id</th><th {0}>Error summary</th></tr>' -f $cell))
        $shown = 0
        foreach ($finding in $failed) {
            if ($shown -ge $MaxRows) { break }
            $shown++
            $started = '(not started)'
            if ($null -ne $finding.StartUtc) { $started = (ConvertTo-JobWatchUtc -Value $finding.StartUtc).ToString($format, $culture) }
            $ended = ''
            $completedProperty = $finding.PSObject.Properties['CompletedUtc']
            if ($null -ne $completedProperty -and $null -ne $completedProperty.Value) { $ended = (ConvertTo-JobWatchUtc -Value $completedProperty.Value).ToString($format, $culture) }
            $errorText = [string]$finding.ErrorSummary
            if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = '(no error output recorded)' }
            [void]$sb.Append(('<tr><td {0}>{1}</td><td {0}>{2}</td><td {0}>{3}</td><td {0}>{4}</td><td {0}>{5}</td><td {0}>{6}</td></tr>' -f $cell, (ConvertTo-HtmlSafe -Value $finding.RunbookName), (ConvertTo-HtmlSafe -Value $finding.Status), $started, $ended, (ConvertTo-HtmlSafe -Value $finding.JobId), (ConvertTo-HtmlSafe -Value $errorText)))
        }
        [void]$sb.Append('</table>')
        if ($failed.Count -gt $shown) {
            [void]$sb.Append(('<p>{0} more failed job(s) are not listed here; see the jobs list of the account.</p>' -f ($failed.Count - $shown)))
        }
    }

    if ($missed.Count -gt 0) {
        [void]$sb.Append(('<h3>Missed runs (no job started within {0} minutes of the scheduled time)</h3>' -f $GraceMinutes))
        [void]$sb.Append(('<table style="border-collapse:collapse"><tr><th {0}>Runbook</th><th {0}>Schedule</th><th {0}>Expected (UTC)</th><th {0}>Schedule time zone</th><th {0}>Note</th></tr>' -f $cell))
        $shown = 0
        foreach ($finding in $missed) {
            if ($shown -ge $MaxRows) { break }
            $shown++
            $expected = ''
            if ($null -ne $finding.ExpectedUtc) { $expected = (ConvertTo-JobWatchUtc -Value $finding.ExpectedUtc).ToString($format, $culture) }
            $zone = [string]$finding.TimeZoneId
            if ([string]::IsNullOrWhiteSpace($zone)) { $zone = 'UTC' }
            $note = ''
            $changedProperty = $finding.PSObject.Properties['ScheduleChangedUtc']
            if ($null -ne $changedProperty -and $null -ne $changedProperty.Value) {
                $note = 'Schedule changed {0} UTC, after this run was due. If that change enabled the schedule, no run was due.' -f (ConvertTo-JobWatchUtc -Value $changedProperty.Value).ToString($format, $culture)
            }
            [void]$sb.Append(('<tr><td {0}>{1}</td><td {0}>{2}</td><td {0}>{3}</td><td {0}>{4}</td><td {0}>{5}</td></tr>' -f $cell, (ConvertTo-HtmlSafe -Value $finding.RunbookName), (ConvertTo-HtmlSafe -Value $finding.ScheduleName), $expected, (ConvertTo-HtmlSafe -Value $zone), (ConvertTo-HtmlSafe -Value $note)))
        }
        [void]$sb.Append('</table>')
        if ($missed.Count -gt $shown) {
            [void]$sb.Append(('<p>{0} more missed run(s) are not listed here.</p>' -f ($missed.Count - $shown)))
        }
        [void]$sb.Append('<p>A schedule enabled, or a runbook linked to a schedule, after the expected time is listed here once although no run was due: the job schedule list does not say when a runbook was linked, so the watcher cannot tell. The Note column says when a schedule itself changed after the expected time.</p>')
    }

    if ($variables.Count -gt 0) {
        [void]$sb.Append(('<h3>Automation variables changed in the last {0} minutes</h3>' -f $LookbackMinutes))
        [void]$sb.Append(('<table style="border-collapse:collapse"><tr><th {0}>Variable</th><th {0}>What</th><th {0}>When (UTC)</th></tr>' -f $cell))
        $shown = 0
        foreach ($finding in $variables) {
            if ($shown -ge $MaxRows) { break }
            $shown++
            $when = ''
            if ($null -ne $finding.ChangedUtc) { $when = (ConvertTo-JobWatchUtc -Value $finding.ChangedUtc).ToString($format, $culture) }
            $what = 'Value changed'
            if ($finding.WasCreated) { $what = 'Created' }
            [void]$sb.Append(('<tr><td {0}>{1}</td><td {0}>{2}</td><td {0}>{3}</td></tr>' -f $cell, (ConvertTo-HtmlSafe -Value $finding.VariableName), (ConvertTo-HtmlSafe -Value $what), $when))
        }
        [void]$sb.Append('</table>')
        if ($variables.Count -gt $shown) {
            [void]$sb.Append(('<p>{0} more changed variable(s) are not listed here.</p>' -f ($variables.Count - $shown)))
        }
        [void]$sb.Append('<p>Every variable in this account is either desired state Terraform publishes from the identity-as-code repository (the PIM baselines, the authentication methods files) or this runbook&#39;s own state, which is not listed here. A row that does not line up with a release is a change nobody made through the repository: check it. No variable value is read or shown.</p>')
    }

    [void]$sb.Append(('<p style="color:#666">Sent by Watch-AutomationJobFailures (run {0}). Each failed job, each missed run, and each variable change is reported once; what has been reported is kept for 48 hours in the Automation variable {1}. A runbook that catches its own errors and exits cleanly ends Completed and does not appear here. This mailbox is not monitored.</p>' -f (ConvertTo-HtmlSafe -Value $RunIdText), (ConvertTo-HtmlSafe -Value $StateVariableName)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# ARM access. Every call goes through Invoke-CloudRequest.
# ---------------------------------------------------------------------------

function Get-WatcherJobId {
    <#
    .SYNOPSIS
        The id of the Automation job this code runs in, or ''.
    .DESCRIPTION
        Reads $PSPrivateMetadata.JobId, which Azure Automation sets for cloud
        jobs, then $env:PSPrivateMetaData, which Microsoft documents for
        PowerShell 7.2 hybrid jobs. Outside Automation both are absent.
    .EXAMPLE
        $jobId = Get-WatcherJobId
    #>
    $metadata = $null
    try { $metadata = Get-Variable -Name 'PSPrivateMetadata' -ValueOnly -ErrorAction Stop }
    catch { $metadata = $null }
    if ($null -ne $metadata) {
        $jobId = $null
        try { $jobId = $metadata.JobId } catch { $jobId = $null }
        if ($null -ne $jobId -and ([string]$jobId) -match $script:JobWatchGuidPattern) { return $Matches[0].ToLowerInvariant() }
    }
    $fromEnvironment = [string]$env:PSPrivateMetaData
    if ($fromEnvironment -match $script:JobWatchGuidPattern) { return $Matches[0].ToLowerInvariant() }
    return ''
}

function Get-AutomationAccountPath {
    <#
    .SYNOPSIS
        The ARM path of the Automation account.
    .DESCRIPTION
        A subscription name is resolved with Resolve-ArmScope; a subscription
        id is used without a lookup.
    .PARAMETER SubscriptionName
        Subscription display name or id.
    .PARAMETER ResourceGroupName
        Resource group.
    .PARAMETER AutomationAccountName
        Account name.
    .EXAMPLE
        Get-AutomationAccountPath -SubscriptionName 'Identity Production' -ResourceGroupName 'rg-example' -AutomationAccountName 'aa-example'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AutomationAccountName
    )

    $trimmed = $SubscriptionName.Trim()
    if ($trimmed -match ('^' + $script:JobWatchGuidPattern + '$')) {
        $scope = Resolve-ArmScope -SubscriptionId $trimmed -ResourceGroupName $ResourceGroupName
    }
    else {
        $scope = Resolve-ArmScope -SubscriptionName $trimmed -ResourceGroupName $ResourceGroupName
    }
    return ('{0}/providers/Microsoft.Automation/automationAccounts/{1}' -f $scope, $AutomationAccountName)
}

function Read-JobWatchState {
    <#
    .SYNOPSIS
        Reads the state variable through ARM.
    .DESCRIPTION
        GET <account>/variables/<name>. Returns Exists and Entries (see
        ConvertFrom-JobWatchState). A missing variable is an empty state. An
        encrypted variable throws, because ARM does not return its value. A
        value that is not the state document is logged as a warning and
        treated as empty, which can repeat findings inside the lookback
        window once.
    .PARAMETER AccountPath
        From Get-AutomationAccountPath.
    .PARAMETER VariableName
        Variable name.
    .EXAMPLE
        $state = Read-JobWatchState -AccountPath $accountPath -VariableName 'JobWatch_AlertedJobIds'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountPath,
        [Parameter(Mandatory = $true)][string]$VariableName
    )

    $uri = '{0}/variables/{1}' -f $AccountPath, [Uri]::EscapeDataString($VariableName)
    $variable = $null
    try {
        $variable = Invoke-CloudRequest -Api Arm -Uri $uri -ApiVersion $script:JobWatchApiVersion
    }
    catch {
        if ((Get-CloudErrorStatus -ErrorRecord $_) -eq 404) {
            Write-RunLog -Level Info -Message ('State variable "{0}" does not exist yet; nothing has been reported. The first live run with something to record creates it.' -f $VariableName)
            return [PSCustomObject]@{ Exists = $false; Entries = @{} }
        }
        throw
    }

    if (ConvertTo-JobWatchBool -Value (Get-JobWatchValue -Object $variable -Path 'properties.isEncrypted')) {
        throw ('State variable "{0}" is encrypted, and ARM does not return encrypted values. It holds only job ids and times: delete it and let the watcher create it unencrypted.' -f $VariableName)
    }

    $entries = @{}
    try {
        $text = ConvertFrom-AutomationVariableValue -Value (Get-JobWatchValue -Object $variable -Path 'properties.value')
        $entries = ConvertFrom-JobWatchState -Text $text
    }
    catch {
        Write-RunLog -Level Warn -Message ('State variable "{0}" could not be read ({1}); starting from an empty state, so findings inside the lookback window may be reported once more.' -f $VariableName, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 200))
        $entries = @{}
    }
    return [PSCustomObject]@{ Exists = $true; Entries = $entries }
}

function Write-JobWatchState {
    <#
    .SYNOPSIS
        Creates or replaces the state variable through ARM.
    .DESCRIPTION
        PUT <account>/variables/<name> with name, properties.value (the JSON
        encoding of the state document, as Variable - Create Or Update
        expects for a string), a description, and isEncrypted false. Always
        writes: the caller decides about DryRun. Refuses any name that does
        not begin with JobWatch_ and throws before the request. The identity's
        Automation Variable Writer role has no per-variable scope, so it can
        write every variable in the account, the PIM baselines and the
        AuthMethods_ desired state among them; this is the check that keeps
        the watcher's one write off them whatever it is asked to do
        (docs/adr/0016).
    .PARAMETER AccountPath
        From Get-AutomationAccountPath.
    .PARAMETER VariableName
        Variable name.
    .PARAMETER StateText
        From ConvertTo-JobWatchState.
    .EXAMPLE
        Write-JobWatchState -AccountPath $accountPath -VariableName 'JobWatch_AlertedJobIds' -StateText $text
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountPath,
        [Parameter(Mandatory = $true)][string]$VariableName,
        [Parameter(Mandatory = $true)][string]$StateText
    )

    if ($VariableName -cnotmatch ('^' + $script:JobWatchStatePrefix + '[A-Za-z0-9_-]{1,119}$')) {
        throw ('This runbook writes only Automation variables whose name begins with "{0}"; it was asked to write "{1}". Its identity can write every variable in the account, so the name is checked here as well as on the parameter.' -f $script:JobWatchStatePrefix, $VariableName)
    }
    $uri = '{0}/variables/{1}' -f $AccountPath, [Uri]::EscapeDataString($VariableName)
    $body = @{
        name       = $VariableName
        properties = @{
            value       = (ConvertTo-Json -InputObject $StateText -Compress)
            description = 'Written by Watch-AutomationJobFailures: failed jobs and missed runs already reported, with the time they were reported (UTC). Do not edit.'
            isEncrypted = $false
        }
    }
    Invoke-CloudRequest -Api Arm -Method PUT -Uri $uri -ApiVersion $script:JobWatchApiVersion -Body $body | Out-Null
}

function Get-JobErrorSummary {
    <#
    .SYNOPSIS
        The error summary for one failed job, read from ARM.
    .DESCRIPTION
        Reads the job's error stream
        (streams?$filter=properties/streamType eq 'Error'), following
        nextLink for up to MaxPages pages, and summarises the latest records
        by time, wherever they were in the list. When no record carries a
        summary, reads the latest record by time in full; when there is still
        nothing, reads the job's exception text. A page that fails after
        others were read is logged and the summary uses what was read. Read
        failures are logged as warnings and give a placeholder, never a
        failed run.
    .PARAMETER AccountPath
        From Get-AutomationAccountPath.
    .PARAMETER JobId
        Job id.
    .PARAMETER MaxPages
        Most stream pages read. Default 10.
    .EXAMPLE
        Get-JobErrorSummary -AccountPath $accountPath -JobId $finding.JobId
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountPath,
        [Parameter(Mandatory = $true)][string]$JobId,
        [ValidateRange(1, 1000)][int]$MaxPages = 10
    )

    $jobPath = '{0}/jobs/{1}' -f $AccountPath, [Uri]::EscapeDataString($JobId)
    $records = New-Object System.Collections.ArrayList
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $next = '{0}/streams?$filter={1}' -f $jobPath, [Uri]::EscapeDataString("properties/streamType eq 'Error'")
    $pages = 0
    try {
        while (-not [string]::IsNullOrWhiteSpace($next)) {
            if ($pages -ge $MaxPages) {
                Write-RunLog -Level Info -Message ('The error stream of job {0} has more than {1} pages; the summary uses the first {1}.' -f $JobId, $MaxPages)
                break
            }
            if (-not $visited.Add($next)) { break }
            $pages++
            $page = Invoke-CloudRequest -Api Arm -Uri $next -ApiVersion $script:JobWatchApiVersion
            foreach ($item in @(Get-JobWatchValue -Object $page -Path 'value')) {
                if ($null -ne $item) { [void]$records.Add($item) }
            }
            $next = [string](Get-JobWatchValue -Object $page -Path 'nextLink')
        }
    }
    catch {
        Write-RunLog -Level Warn -Message ('Could not read the error stream of job {0}: {1}' -f $JobId, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
        if ($records.Count -eq 0) { return '(error output could not be read)' }
    }

    $streams = @(Sort-JobWatchStreams -Streams $records.ToArray())
    $summaryText = Format-JobErrorSummary -Streams $streams
    if ($summaryText) { return $summaryText }

    if ($streams.Count -gt 0) {
        $latest = $streams[$streams.Count - 1]
        $streamId = [string](Get-JobWatchValue -Object $latest -Path 'properties.jobStreamId')
        if ($streamId) {
            try {
                $record = Invoke-CloudRequest -Api Arm -Uri ('{0}/streams/{1}' -f $jobPath, [Uri]::EscapeDataString($streamId)) -ApiVersion $script:JobWatchApiVersion
                $summaryText = Format-JobErrorSummary -Streams @($record)
                if ($summaryText) { return $summaryText }
            }
            catch {
                Write-RunLog -Level Warn -Message ('Could not read error record {0} of job {1}: {2}' -f $streamId, $JobId, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
            }
        }
    }

    try {
        $job = Invoke-CloudRequest -Api Arm -Uri $jobPath -ApiVersion $script:JobWatchApiVersion
        return (Format-JobErrorSummary -Exception ([string](Get-JobWatchValue -Object $job -Path 'properties.exception')))
    }
    catch {
        Write-RunLog -Level Warn -Message ('Could not read job {0}: {1}' -f $JobId, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
        return '(error output could not be read)'
    }
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-WatchAutomationJobFailuresRun {
    <#
    .SYNOPSIS
        One watcher run: read, decide, and at most three writes (the state
        update, one mail, and a state put-back if the mail fails). Returns
        the run summary.
    .DESCRIPTION
        See the script help. Now and CurrentJobId exist for tests: Now is the
        clock, and CurrentJobId replaces the lookup of the running job's id.
    .PARAMETER AutomationAccountName
        Account to watch.
    .PARAMETER ResourceGroupName
        Its resource group.
    .PARAMETER SubscriptionName
        Its subscription, by name or id.
    .PARAMETER LookbackMinutes
        Failure window, by the time a job reached its status.
    .PARAMETER MaxJobRuntimeMinutes
        How far before the failure window the start-time jobs list reaches.
    .PARAMETER HeartbeatGraceMinutes
        Grace before a scheduled run is judged.
    .PARAMETER StateVariableName
        State variable.
    .PARAMETER ExcludeRunbookNames
        Runbooks to ignore, as one semicolon-separated string. Each entry
        must be a valid runbook name.
    .PARAMETER Recipients
        Digest recipients, as one semicolon-separated string. Each entry
        must be one mail address.
    .PARAMETER SenderMailbox
        Sender mailbox.
    .PARAMETER DryRun
        Default $true.
    .PARAMETER Environment
        Global or USGov.
    .PARAMETER ClientId
        Managed identity client id.
    .PARAMETER AccessToken
        Local runs and tests only.
    .PARAMETER RunId
        Correlation id.
    .PARAMETER Now
        The clock. Default now.
    .PARAMETER CurrentJobId
        The running job's id. Default: Get-WatcherJobId.
    .EXAMPLE
        Invoke-WatchAutomationJobFailuresRun -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example' -SubscriptionName 'Identity Production' -AccessToken $tokens
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AutomationAccountName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SubscriptionName,
        [ValidateRange(5, 1440)][int]$LookbackMinutes = 70,
        [ValidateRange(0, 10080)][int]$MaxJobRuntimeMinutes = 240,
        [ValidateRange(0, 1440)][int]$HeartbeatGraceMinutes = 30,
        [ValidatePattern('^JobWatch_[A-Za-z0-9_-]{1,119}$')][string]$StateVariableName = 'JobWatch_AlertedJobIds',
        [AllowEmptyString()][string]$ExcludeRunbookNames = '',
        [AllowEmptyString()][string]$Recipients = '',
        [AllowEmptyString()][string]$SenderMailbox = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$AccessToken = '',
        [AllowEmptyString()][string]$RunId = '',
        [DateTime]$Now = [DateTime]::UtcNow,
        [AllowEmptyString()][string]$CurrentJobId = ''
    )

    Initialize-RunContext -RunbookName $script:JobWatchRunbookName -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $nowUtc = ConvertTo-JobWatchUtc -Value $Now
    $apiVersion = $script:JobWatchApiVersion
    $retentionHours = $script:JobWatchRetentionHours
    $culture = [Globalization.CultureInfo]::InvariantCulture

    # Parameters first, so a misconfigured schedule fails before any call.
    # Both lists come from a schedule as one semicolon-separated string; an
    # entry that breaks the name or address rule is most likely a list that
    # reached the job joined some other way, and it stops the run.
    $recipientList = @(ConvertTo-StringList -Value $Recipients -Label 'Recipients')
    $excludeList = @(ConvertTo-StringList -Value $ExcludeRunbookNames -Label 'ExcludeRunbookNames')
    foreach ($name in $excludeList) {
        if ($name -notmatch $script:JobWatchRunbookNamePattern) {
            throw ('ExcludeRunbookNames: "{0}" is not a runbook name (1 to 63 letters, digits, underscores, and hyphens, starting with a letter). Separate names with semicolons.' -f $name)
        }
    }
    foreach ($address in $recipientList) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients: "{0}" is not a mail address. Separate addresses with semicolons.' -f $address) }
    }
    if (-not [string]::IsNullOrWhiteSpace($SenderMailbox) -and $SenderMailbox -notmatch '^[^@\s]+@[^@\s]+$') {
        throw ('SenderMailbox "{0}" is not a mail address.' -f $SenderMailbox)
    }
    if (-not $DryRun) {
        if ($recipientList.Count -eq 0) { throw 'Recipients is required for a live run: the watcher must be able to send its digest. Pass the addresses separated by semicolons.' }
        if ([string]::IsNullOrWhiteSpace($SenderMailbox)) { throw 'SenderMailbox is required for a live run.' }
    }
    if (-not $PSBoundParameters.ContainsKey('CurrentJobId')) { $CurrentJobId = Get-WatcherJobId }

    $recipientText = '(none)'
    if ($recipientList.Count -gt 0) { $recipientText = $recipientList -join '; ' }
    Write-RunLog -Level Info -Message ('Watching Automation account {0} in resource group {1}. Lookback {2} min, longest job {3} min, heartbeat grace {4} min, state variable {5}, recipients {6}.' -f $AutomationAccountName, $ResourceGroupName, $LookbackMinutes, $MaxJobRuntimeMinutes, $HeartbeatGraceMinutes, $StateVariableName, $recipientText)

    $accountPath = Get-AutomationAccountPath -SubscriptionName $SubscriptionName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName

    # Schedules first: the heartbeat decides how far back the job list must go.
    # This is the first call on the account, so a wrong name fails here.
    try {
        $schedules = @(Invoke-CloudRequest -Api Arm -Uri ($accountPath + '/schedules') -ApiVersion $apiVersion -AllPages)
    }
    catch {
        if ((Get-CloudErrorStatus -ErrorRecord $_) -eq 404) {
            throw ('Automation account "{0}" was not found in resource group "{1}" of subscription "{2}" (HTTP 404 on the schedules list). Check AutomationAccountName, ResourceGroupName, and SubscriptionName. {3}' -f $AutomationAccountName, $ResourceGroupName, $SubscriptionName, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
        }
        throw
    }
    $jobSchedules = @(Invoke-CloudRequest -Api Arm -Uri ($accountPath + '/jobSchedules') -ApiVersion $apiVersion -AllPages)

    $linkedSchedules = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($link in $jobSchedules) {
        $linkedName = [string](Get-JobWatchValue -Object $link -Path 'properties.schedule.name')
        if ($linkedName) { [void]$linkedSchedules.Add($linkedName) }
    }

    $failureWindowStart = $nowUtc.AddMinutes(-$LookbackMinutes)
    $jobWindowStart = $failureWindowStart.AddMinutes(-$MaxJobRuntimeMinutes)
    foreach ($schedule in $schedules) {
        $scheduleName = [string](Get-JobWatchValue -Object $schedule -Path 'name')
        if (-not $linkedSchedules.Contains($scheduleName)) { continue }
        $expectation = Get-ScheduleExpectation -Schedule $schedule -NowUtc $nowUtc -GraceMinutes $HeartbeatGraceMinutes -HorizonHours $retentionHours
        if ($expectation.Reason -eq 'TimeZoneUnknown') {
            Write-RunLog -Level Warn -Message ('Schedule "{0}": time zone "{1}" is not known on this host, so its runs are not judged by the heartbeat.' -f $scheduleName, $expectation.TimeZoneId)
        }
        elseif ($expectation.Reason -eq 'NextRunMismatch') {
            Write-RunLog -Level Warn -Message ('Schedule "{0}": the scheduler reports its next run at {1}, which the watcher''s schedule math ({2}, interval {3}, time zone "{4}") does not produce, so its runs are not judged by the heartbeat.' -f $scheduleName, (ConvertTo-JobWatchTimeText -Value $expectation.NextRunUtc), $expectation.Frequency, $expectation.Interval, $expectation.TimeZoneId)
        }
        if ($expectation.Evaluate) {
            $candidate = (ConvertTo-JobWatchUtc -Value $expectation.ExpectedUtc).AddMinutes(-$script:JobWatchToleranceMinutes)
            if ($candidate -lt $jobWindowStart) { $jobWindowStart = $candidate }
        }
    }

    # One list by start time, for the heartbeat and most failures, then one
    # per alert status, for jobs that never started or ran longer than
    # MaxJobRuntimeMinutes. Later lists win when a job appears twice.
    $listFilters = New-Object System.Collections.ArrayList
    [void]$listFilters.Add('properties/startTime ge ' + $jobWindowStart.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', $culture))
    foreach ($alertStatus in $script:JobWatchAlertStatuses) { [void]$listFilters.Add(("properties/status eq '{0}'" -f $alertStatus)) }
    $jobRecords = New-Object System.Collections.ArrayList
    foreach ($listFilter in $listFilters) {
        $rawJobs = @(Invoke-CloudRequest -Api Arm -Uri ('{0}/jobs?$filter={1}' -f $accountPath, [Uri]::EscapeDataString($listFilter)) -ApiVersion $apiVersion -AllPages)
        foreach ($rawJob in $rawJobs) { [void]$jobRecords.Add((ConvertTo-JobWatchJob -Job $rawJob)) }
    }
    $jobs = @(Merge-JobWatchJobs -Jobs $jobRecords.ToArray())

    $excluded = @(Get-JobWatchExclusions -Names $excludeList -Jobs $jobs -CurrentJobId $CurrentJobId -WatcherName $script:JobWatchRunbookName)
    Write-RunLog -Level Info -Message ('Read {0} job(s) that started since {1} or are {2}, {3} schedule(s), {4} job schedule(s). Excluded runbooks: {5}.' -f $jobs.Count, (ConvertTo-JobWatchTimeText -Value $jobWindowStart), ($script:JobWatchAlertStatuses -join ', '), $schedules.Count, $jobSchedules.Count, ($excluded -join ', '))

    $state = Read-JobWatchState -AccountPath $accountPath -VariableName $StateVariableName
    $kept = Limit-JobWatchState -Entries $state.Entries -NowUtc $nowUtc -RetentionHours $retentionHours -MaxEntries $script:JobWatchMaxStateEntries
    $pruned = $state.Entries.Count - $kept.Count

    $failedAll = @(Get-FailedJobFindings -Jobs $jobs -WindowStartUtc $failureWindowStart -ExcludedRunbooks $excluded -Statuses $script:JobWatchAlertStatuses)
    $heartbeat = Get-MissedRunFindings -Schedules $schedules -JobSchedules $jobSchedules -Jobs $jobs -NowUtc $nowUtc -GraceMinutes $HeartbeatGraceMinutes -ExcludedRunbooks $excluded -HorizonHours $retentionHours -ToleranceMinutes $script:JobWatchToleranceMinutes
    $missedAll = @($heartbeat.Findings)
    # Detection, not prevention: this identity's Automation Variable Writer
    # role reaches every variable in the account, the PIM baselines among them
    # (docs/adr/0016). A list that fails is a Failed item, not a stopped run:
    # the failed jobs still have to be reported.
    $variableAll = @()
    try {
        $variableAll = @(Get-VariableChangeFindings -AccountPath $accountPath -WindowStartUtc $failureWindowStart -StateVariableName $StateVariableName)
    }
    catch {
        $variableProblem = Protect-RunbookText -Text $_.Exception.Message -MaxLength 300
        Write-RunLog -Level Warn -Message ('The account''s variables could not be listed, so changes to them are not reported this run: {0}' -f $variableProblem)
        Add-RunSummaryItem -Summary $summary -Action 'ListVariables' -Target $AutomationAccountName -Outcome Failed -Detail $variableProblem
    }

    $newFailed = @(Select-NewFindings -Findings $failedAll -State $kept)
    $newMissed = @(Select-NewFindings -Findings $missedAll -State $kept)
    $newVariables = @(Select-NewFindings -Findings $variableAll -State $kept)
    $alreadyReported = ($failedAll.Count + $missedAll.Count + $variableAll.Count) - ($newFailed.Count + $newMissed.Count + $newVariables.Count)

    $skipText = (@($heartbeat.Skipped | Group-Object -Property Reason | Sort-Object -Property Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ' ')
    if ([string]::IsNullOrWhiteSpace($skipText)) { $skipText = 'none' }
    Write-RunLog -Level Info -Message ('Heartbeat: {0} scheduled runbook link(s) judged, skipped: {1}.' -f @($heartbeat.Evaluated).Count, $skipText)
    if ($alreadyReported -gt 0) {
        Write-RunLog -Level Info -Message ('{0} finding(s) were reported in the last {1} hours and are not repeated.' -f $alreadyReported, $retentionHours)
    }

    $row = 0
    foreach ($finding in $newFailed) {
        $row++
        if ($row -le $script:JobWatchMaxDigestRows) { $finding.ErrorSummary = Get-JobErrorSummary -AccountPath $accountPath -JobId $finding.JobId -MaxPages $script:JobWatchMaxStreamPages }
        $startedText = 'never started'
        if ($null -ne $finding.StartUtc) { $startedText = 'started ' + (ConvertTo-JobWatchTimeText -Value $finding.StartUtc) }
        Write-RunLog -Level Warn -Message ('Failed job: runbook "{0}" is {1} since {2} ({3}), job {4}. {5}' -f $finding.RunbookName, $finding.Status, (ConvertTo-JobWatchTimeText -Value $finding.CompletedUtc), $startedText, $finding.JobId, $finding.ErrorSummary)
    }
    foreach ($finding in $newMissed) {
        $changeText = ''
        if ($null -ne $finding.ScheduleChangedUtc) {
            $changeText = ' The schedule changed at {0}, after this run was due; if that change enabled it, no run was due.' -f (ConvertTo-JobWatchTimeText -Value $finding.ScheduleChangedUtc)
        }
        Write-RunLog -Level Warn -Message ('Missed run: runbook "{0}" was due at {1} on schedule "{2}" and no job has started since.{3}' -f $finding.RunbookName, (ConvertTo-JobWatchTimeText -Value $finding.ExpectedUtc), $finding.ScheduleName, $changeText)
    }

    foreach ($finding in $newVariables) {
        $what = 'was changed'
        if ($finding.WasCreated) { $what = 'was created' }
        Write-RunLog -Level Warn -Message ('Automation variable "{0}" {1} at {2}. Every variable in this account is Terraform-owned desired state or this runbook''s own state, so a change that did not come from a release is worth a look. No value is read or reported.' -f $finding.VariableName, $what, (ConvertTo-JobWatchTimeText -Value $finding.ChangedUtc))
    }

    $findingCount = $newFailed.Count + $newMissed.Count + $newVariables.Count
    $nextEntries = @{}
    foreach ($key in @($kept.Keys)) { $nextEntries[$key] = $kept[$key] }
    foreach ($finding in @($newFailed + $newMissed + $newVariables)) { $nextEntries[([string]$finding.Key).ToLowerInvariant()] = $nowUtc }
    $nextState = Limit-JobWatchState -Entries $nextEntries -NowUtc $nowUtc -RetentionHours $retentionHours -MaxEntries $script:JobWatchMaxStateEntries
    $stateChanged = ($findingCount -gt 0) -or ($pruned -gt 0)

    # The writes are bounded by construction: the state update when the state
    # changed and, with findings, the digest plus the put-back of the previous
    # state should the digest fail. The breaker asserts that bound before the
    # first write. It is not a cap on findings: aborting during a mass failure
    # would suppress the one alert that matters.
    $plannedWrites = 0
    if ($stateChanged) { $plannedWrites++ }
    if ($findingCount -gt 0) { $plannedWrites += 2 }
    Test-CircuitBreaker -Planned $plannedWrites -Cap $script:JobWatchMaxWrites -Label 'watcher writes (one state update, one digest, and one state put-back if the digest fails)'

    # State first: a run that cannot record what it reports sends nothing and
    # fails, instead of mailing the same digest every hour.
    if ($stateChanged) {
        $stateText = ConvertTo-JobWatchState -Entries $nextState
        Invoke-RunbookAction -Summary $summary -Action 'SaveState' -Target $StateVariableName -Description ('update Automation variable "{0}" ({1} reported key(s): {2} added, {3} pruned)' -f $StateVariableName, $nextState.Count, $findingCount, $pruned) -StopOnError -ScriptBlock {
            Write-JobWatchState -AccountPath $accountPath -VariableName $StateVariableName -StateText $stateText
        }
    }

    if ($findingCount -gt 0) {
        $digestTo = $recipientList
        $digestSubject = 'Automation watch: {0}: {1} failed job(s), {2} missed run(s), {3} variable change(s)' -f $AutomationAccountName, $newFailed.Count, $newMissed.Count, $newVariables.Count
        $digestHtml = New-JobWatchDigestHtml -AccountName $AutomationAccountName -FailedJobs $newFailed -MissedRuns $newMissed -VariableChanges $newVariables -NowUtc $nowUtc -LookbackMinutes $LookbackMinutes -GraceMinutes $HeartbeatGraceMinutes -StateVariableName $StateVariableName -RunIdText ((Get-RunContext).RunId) -MaxRows $script:JobWatchMaxDigestRows
        $digestTarget = '(no recipients configured)'
        if ($digestTo.Count -gt 0) { $digestTarget = $digestTo -join '; ' }
        $previousStateText = ConvertTo-JobWatchState -Entries $kept
        try {
            Invoke-RunbookAction -Summary $summary -Action 'SendDigest' -Target $digestTarget -Description ('send the digest ({0} failed job(s), {1} missed run(s), {2} variable change(s)) to {3}' -f $newFailed.Count, $newMissed.Count, $newVariables.Count, $digestTarget) -StopOnError -ScriptBlock {
                Send-RunbookMail -SenderMailbox $SenderMailbox -To $digestTo -Subject $digestSubject -HtmlBody $digestHtml
            }
        }
        catch {
            $sendFailure = $_
            $restoreOutcome = Invoke-RunbookAction -Summary $summary -Action 'RestoreState' -Target $StateVariableName -Description ('put back Automation variable "{0}" as it was before this run ({1} reported key(s)), so the digest is attempted again on the next run' -f $StateVariableName, $kept.Count) -PassThru -ScriptBlock {
                Write-JobWatchState -AccountPath $accountPath -VariableName $StateVariableName -StateText $previousStateText
            }
            if ($restoreOutcome -ne 'Done') {
                $lostKeys = @(@($newFailed + $newMissed + $newVariables) | Select-Object -First 50 | ForEach-Object { [string]$_.Key })
                Write-RunLog -Level Error -Message ('The digest was not sent and the state could not be put back, so {0} finding(s) are recorded as reported and will not be mailed. Each is logged as a warning above. Keys: {1}' -f $findingCount, ($lostKeys -join ', '))
            }
            throw $sendFailure
        }
        foreach ($finding in $newFailed) {
            Add-RunSummaryItem -Summary $summary -Action 'AlertFailedJob' -Target ('{0} {1}' -f $finding.RunbookName, $finding.JobId) -Detail ('{0} since {1}, started {2}' -f $finding.Status, (ConvertTo-JobWatchTimeText -Value $finding.CompletedUtc), (ConvertTo-JobWatchTimeText -Value $finding.StartUtc))
        }
        foreach ($finding in $newMissed) {
            $detail = 'due {0} on schedule {1}' -f (ConvertTo-JobWatchTimeText -Value $finding.ExpectedUtc), $finding.ScheduleName
            if ($null -ne $finding.ScheduleChangedUtc) { $detail += ', schedule changed {0}' -f (ConvertTo-JobWatchTimeText -Value $finding.ScheduleChangedUtc) }
            Add-RunSummaryItem -Summary $summary -Action 'AlertMissedRun' -Target $finding.RunbookName -Detail $detail
        }
        foreach ($finding in $newVariables) {
            $what = 'changed'
            if ($finding.WasCreated) { $what = 'created' }
            Add-RunSummaryItem -Summary $summary -Action 'AlertVariableChange' -Target $finding.VariableName -Detail ('{0} {1}' -f $what, (ConvertTo-JobWatchTimeText -Value $finding.ChangedUtc))
        }
    }
    else {
        Write-RunLog -Level Info -Message ('Clean: no new failed job since {0}, no missed run among {1} judged schedule link(s), and no other variable in the account changed in that window; nothing to send.' -f (ConvertTo-JobWatchTimeText -Value $failureWindowStart), @($heartbeat.Evaluated).Count)
    }

    $extra = [ordered]@{
        AutomationAccount   = $AutomationAccountName
        WindowStartUtc      = (ConvertTo-JobWatchTimeText -Value $failureWindowStart)
        JobListStartUtc     = (ConvertTo-JobWatchTimeText -Value $jobWindowStart)
        JobsScanned         = $jobs.Count
        SchedulesScanned    = $schedules.Count
        JobSchedulesScanned = $jobSchedules.Count
        SchedulesJudged     = @($heartbeat.Evaluated).Count
        FailedJobs          = $newFailed.Count
        MissedRuns          = $newMissed.Count
        VariableChanges     = $newVariables.Count
        VariablesChanged    = @($newVariables | ForEach-Object { [string]$_.VariableName })
        AlreadyReported     = $alreadyReported
        StateEntries        = $nextState.Count
        StatePruned         = $pruned
        ExcludedRunbooks    = $excluded
        Clean               = ($findingCount -eq 0)
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WatchAutomationJobFailuresRun -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName -SubscriptionName $SubscriptionName `
        -LookbackMinutes $LookbackMinutes -MaxJobRuntimeMinutes $MaxJobRuntimeMinutes -HeartbeatGraceMinutes $HeartbeatGraceMinutes -StateVariableName $StateVariableName `
        -ExcludeRunbookNames $ExcludeRunbookNames -Recipients $Recipients -SenderMailbox $SenderMailbox -DryRun ([bool]$DryRun) `
        -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
}
