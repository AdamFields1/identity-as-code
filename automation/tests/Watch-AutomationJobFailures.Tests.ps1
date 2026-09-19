# Pester tests for automation/runbooks/Watch-AutomationJobFailures.ps1.
#
# Pester 3/4 assertion syntax ("Should Be"), because Windows PowerShell 5.1
# ships Pester 3.4.0. The runbook is dot-sourced, which dot-sources
# automation/lib/Runbook.Common.ps1 through its INLINE_LIBRARY block, so the
# schedule math, the finding selection, the state handling, and the digest
# are tested as plain functions with the clock as a parameter. Runs against
# a mocked Automation account go through the library's one HTTP seam,
# Invoke-HttpCore, answered by a router whose responses follow the shapes in
# the ARM Automation reference (api-version 2023-11-01) and the Graph
# sendMail reference. The router applies the jobs list filters the way the
# service does (a start-time filter drops jobs whose startTime is null),
# pages the error stream with nextLink, and keeps what the state PUT wrote.
# One context replaces ConvertFrom-Json with a wrapper that turns ISO times
# into DateTime values, as PowerShell 7 (the Automation runtime) does. The
# last context runs the runbook file from disk and assembled the way
# modules/azure/automation-runbooks inlines the library, with
# Invoke-WebRequest mocked one level lower, because a script started with the
# call operator defines its own Invoke-HttpCore. Each of those runs goes
# through Suspend-MockAlias (Pester.Support.ps1), which lifts the
# Invoke-HttpCore mock so the file's own definition is the one that runs.
# Nothing here leaves the machine or waits.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path -Path $here -ChildPath 'Pester.Support.ps1')
$automationRoot = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $automationRoot
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Watch-AutomationJobFailures.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$runbooksModule = Join-Path -Path $repoRoot -ChildPath 'modules\azure\automation-runbooks\main.tf'
$corpCell = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'

# The real ConvertFrom-Json cmdlet. Pester 3.4 points both ConvertFrom-Json
# and Microsoft.PowerShell.Utility\ConvertFrom-Json at a mock, so the router
# and the fixtures call the cmdlet through this CmdletInfo; the PowerShell 7
# context's mock then never changes what the fake service sees.
$global:JwfJsonCmdlet = Get-Command -Name ConvertFrom-Json -CommandType Cmdlet

# The router both HTTP mocks use. Global so that a runbook started with the
# call operator, in its own script scope, reaches it through the mock too.
function global:Get-JwfTestResponse {
    param(
        [string]$Method,
        [string]$Uri,
        [AllowNull()][object]$Body,
        [AllowNull()][System.Collections.IDictionary]$RequestHeaders
    )

    $tenant = $global:JwfTenant
    $parsed = [Uri]$Uri
    $path = $parsed.AbsolutePath
    $query = @{}
    if ($parsed.Query.Length -gt 1) {
        foreach ($pair in $parsed.Query.Substring(1).Split('&')) {
            $separator = $pair.IndexOf('=')
            if ($separator -lt 0) { $query[[Uri]::UnescapeDataString($pair)] = ''; continue }
            $query[[Uri]::UnescapeDataString($pair.Substring(0, $separator))] = [Uri]::UnescapeDataString($pair.Substring($separator + 1))
        }
    }
    $filterText = ''
    if ($query.ContainsKey('$filter')) { $filterText = [string]$query['$filter'] }
    $auth = ''
    if ($null -ne $RequestHeaders -and $RequestHeaders.Contains('Authorization')) { $auth = [string]$RequestHeaders['Authorization'] }
    $record = [PSCustomObject]@{ Method = $Method; Uri = $Uri; Path = $path; Host = $parsed.Host; Filter = $filterText; Body = $Body; Auth = $auth; Returned = @() }
    [void]$global:JwfRequests.Add($record)

    $json = { param($Value) @{ StatusCode = 200; Content = (ConvertTo-Json -InputObject $Value -Depth 20 -Compress); Headers = @{} } }
    $notFound = @{ StatusCode = 404; Content = '{"error":{"code":"NotFound","message":"The requested resource was not found."}}'; Headers = @{} }
    $culture = [Globalization.CultureInfo]::InvariantCulture

    if ($Method -eq 'POST' -and $path -like '*/sendMail') {
        if ([int]$tenant.MailStatus -ge 400) {
            return @{ StatusCode = [int]$tenant.MailStatus; Content = '{"error":{"code":"ErrorAccessDenied","message":"Access is denied. Check credentials and try again."}}'; Headers = @{} }
        }
        return @{ StatusCode = 202; Content = ''; Headers = @{} }
    }
    if ($tenant.AccountMissing -and $path -like '*/automationAccounts/*') {
        return @{ StatusCode = 404; Content = '{"error":{"code":"ResourceNotFound","message":"The Resource Microsoft.Automation/automationAccounts/aa-example-watch was not found."}}'; Headers = @{} }
    }
    if ($Method -eq 'PUT' -and $path -like '*/variables/*') {
        $tenant.StatePuts = [int]$tenant.StatePuts + 1
        if ([int]$tenant.StatePutStatus -ge 400 -and [int]$tenant.StatePuts -gt [int]$tenant.StatePutFailAfter) {
            return @{ StatusCode = [int]$tenant.StatePutStatus; Content = '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.Automation/automationAccounts/variables/write."}}'; Headers = @{} }
        }
        $sent = & $global:JwfJsonCmdlet -InputObject ([string]$Body)
        $tenant.State = [string](& $global:JwfJsonCmdlet -InputObject ([string]$sent.properties.value))
        $tenant.StateEncrypted = $false
        return @{ StatusCode = 200; Content = [string]$Body; Headers = @{} }
    }
    if ($Method -ne 'GET') {
        return @{ StatusCode = 405; Content = '{"error":{"code":"MethodNotAllowed","message":"No test route."}}'; Headers = @{} }
    }
    if ($path -eq '/subscriptions') { return (& $json @{ value = @($tenant.Subscriptions) }) }
    if ($path -like '*/schedules') { return (& $json @{ value = @($tenant.Schedules) }) }
    if ($path -like '*/jobSchedules') { return (& $json @{ value = @($tenant.JobSchedules) }) }
    if ($path -match '/jobs/([^/]+)/streams/([^/]+)$') {
        $streamId = [Uri]::UnescapeDataString($Matches[2])
        if ($tenant.StreamRecords.ContainsKey($streamId)) { return (& $json $tenant.StreamRecords[$streamId]) }
        return $notFound
    }
    if ($path -match '/jobs/([^/]+)/streams$') {
        $jobId = $Matches[1]
        if ($filterText -ne "properties/streamType eq 'Error'") {
            return @{ StatusCode = 400; Content = ('{"error":{"code":"BadRequest","message":"Unexpected stream filter ' + $filterText + '"}}'); Headers = @{} }
        }
        if ($tenant.StreamPages.ContainsKey($jobId)) {
            $pages = $tenant.StreamPages[$jobId]
            $pageIndex = 0
            if ($query.ContainsKey('$skiptoken')) { $pageIndex = [int]$query['$skiptoken'] }
            $nextLink = $null
            if ($pageIndex + 1 -lt $pages.Count) {
                $nextLink = 'https://{0}{1}?$filter={2}&api-version=2023-11-01&$skiptoken={3}' -f $parsed.Host, $path, [Uri]::EscapeDataString($filterText), ($pageIndex + 1)
            }
            return (& $json @{ value = @($pages[$pageIndex]); nextLink = $nextLink })
        }
        $streams = @()
        if ($tenant.Streams.ContainsKey($jobId)) { $streams = @($tenant.Streams[$jobId]) }
        return (& $json @{ value = $streams; nextLink = $null })
    }
    if ($path -match '/jobs/([^/]+)$') {
        $jobId = $Matches[1]
        if ($tenant.JobDetails.ContainsKey($jobId)) { return (& $json $tenant.JobDetails[$jobId]) }
        return $notFound
    }
    if ($path -like '*/jobs') {
        $selected = @($tenant.Jobs)
        if ($filterText -match '^properties/startTime ge (\S+)$') {
            $since = [DateTimeOffset]::Parse($Matches[1], $culture).UtcDateTime
            $selected = @($selected | Where-Object {
                    $startText = [string]$_.properties.startTime
                    (-not [string]::IsNullOrEmpty($startText)) -and ([DateTimeOffset]::Parse($startText, $culture).UtcDateTime -ge $since)
                })
        }
        elseif ($filterText -match "^properties/status eq '([A-Za-z]+)'$") {
            $wanted = $Matches[1]
            $selected = @($selected | Where-Object { [string]$_.properties.status -eq $wanted })
        }
        elseif ($filterText) {
            return @{ StatusCode = 400; Content = ('{"error":{"code":"BadRequest","message":"Unsupported job filter ' + $filterText + '"}}'); Headers = @{} }
        }
        $record.Returned = @($selected | ForEach-Object { [string]$_.name })
        return (& $json @{ value = $selected; nextLink = $null })
    }
    if ($path -like '*/variables') {
        # Variable - List By Automation Account: names and times, no values.
        if ([int]$tenant.VariableListStatus -ge 400) {
            return @{ StatusCode = [int]$tenant.VariableListStatus; Content = '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization to perform action Microsoft.Automation/automationAccounts/variables/read."}}'; Headers = @{} }
        }
        return (& $json @{ value = @($tenant.Variables); nextLink = $null })
    }
    if ($path -like '*/variables/*') {
        if ($null -eq $tenant.State) { return $notFound }
        $properties = @{ isEncrypted = [bool]$tenant.StateEncrypted; description = 'test'; creationTime = '2026-09-15T00:00:00+00:00' }
        if (-not $tenant.StateEncrypted) { $properties.value = (ConvertTo-Json -InputObject ([string]$tenant.State) -Compress) }
        return (& $json @{ id = $path; name = 'JobWatch_AlertedJobIds'; properties = $properties })
    }
    return @{ StatusCode = 400; Content = ('{"error":{"code":"NoTestRoute","message":"No test route for ' + $Method + ' ' + $path + '"}}'); Headers = @{} }
}

# What PowerShell 7 does to a JSON string that looks like an ISO 8601 time:
# a Z makes a Utc DateTime, an offset makes a Local DateTime (the same
# instant in this machine's zone), and no suffix makes an Unspecified one.
function global:ConvertTo-JwfPowerShell7Date {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})?$') { return $null }
    $parsedTime = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedTime)) { return $null }
    if ($Text.EndsWith('Z')) { return $parsedTime.UtcDateTime }
    if ($Text -match '[+-]\d{2}:\d{2}$') { return $parsedTime.LocalDateTime }
    return [DateTime]::SpecifyKind($parsedTime.DateTime, [DateTimeKind]::Unspecified)
}

function global:Update-JwfPowerShell7Dates {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
    if ($Value -is [System.Array]) {
        for ($i = 0; $i -lt $Value.Length; $i++) {
            $item = $Value[$i]
            if ($item -is [string]) {
                $asDate = ConvertTo-JwfPowerShell7Date -Text $item
                if ($null -ne $asDate) { $Value[$i] = $asDate }
            }
            else { Update-JwfPowerShell7Dates -Value $item }
        }
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            $item = $property.Value
            if ($item -is [string]) {
                $asDate = ConvertTo-JwfPowerShell7Date -Text $item
                if ($null -ne $asDate) { $property.Value = $asDate }
            }
            else { Update-JwfPowerShell7Dates -Value $item }
        }
    }
}

Describe 'Watch-AutomationJobFailures' {
    . $runbook -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example-automation' -SubscriptionName 'Example Identity Subscription'
    # The library's own Test-CircuitBreaker, copied before any context mocks
    # it: once a function has been mocked, Pester 3.4 leaves its prototype
    # in place for later contexts, so it cannot be looked up there.
    $global:JwfRealBreaker = [scriptblock]::Create((Get-Command -Name Test-CircuitBreaker -CommandType Function).Definition)
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\PSPrivateMetaData -ErrorAction SilentlyContinue

    $global:JwfTenant = @{}
    $global:JwfRequests = New-Object System.Collections.ArrayList

    # Fake values only. The GUIDs are all-same-digit on purpose.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $armToken = 'eyJ0eXAiOiJKV1QifQ.watcharmpayload0000.watcharmsignature00'
    $graphToken = 'eyJ0eXAiOiJKV1QifQ.watchgraphpayload000.watchgraphsignature'
    $tokens = ConvertTo-Json -InputObject @{ Arm = $armToken; Graph = $graphToken } -Compress
    $runId = '00000000-0000-0000-0000-000000000000'
    $subscriptionId = '33333333-3333-3333-3333-333333333333'
    $accountPath = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-example-automation/providers/Microsoft.Automation/automationAccounts/aa-example-watch'
    $ids = @{
        AlphaFailed   = '11111111-1111-1111-1111-111111111111'
        AlphaDone     = '22222222-2222-2222-2222-222222222222'
        WatcherFailed = '44444444-4444-4444-4444-444444444444'
        DeltaStopped  = '55555555-5555-5555-5555-555555555555'
        EchoOld       = '66666666-6666-6666-6666-666666666666'
        BravoDone     = '77777777-7777-7777-7777-777777777777'
        DeltaDone     = '88888888-8888-8888-8888-888888888888'
        Renamed       = '99999999-9999-9999-9999-999999999999'
        LongRun       = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        NeverStarted  = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        Suspended     = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    }

    # Thursday 2026-09-17 12:10 UTC.
    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 12, 10, 0, ([DateTimeKind]::Utc)
    # Recipients in the semicolon form a job schedule carries.
    $live = @{ DryRun = $false; Recipients = 'iam@corp.example.com;ops@corp.example.com'; SenderMailbox = 'iam-noreply@corp.example.com' }

    function New-Utc {
        param([int]$Year, [int]$Month, [int]$Day, [int]$Hour = 0, [int]$Minute = 0, [int]$Second = 0)
        return (New-Object -TypeName DateTime -ArgumentList $Year, $Month, $Day, $Hour, $Minute, $Second, ([DateTimeKind]::Utc))
    }

    # The same instant as a Utc DateTime, a Local DateTime, or a
    # DateTimeOffset at +02:00, the three shapes PowerShell 7 can hand over.
    function ConvertTo-TimeShape {
        param([DateTime]$Utc, [ValidateSet('Utc', 'Local', 'Offset')][string]$Shape)
        if ($Shape -eq 'Utc') { return $Utc }
        if ($Shape -eq 'Local') { return $Utc.ToLocalTime() }
        $clock = [DateTime]::SpecifyKind($Utc.AddHours(2), [DateTimeKind]::Unspecified)
        return (New-Object -TypeName DateTimeOffset -ArgumentList $clock, ([TimeSpan]::FromHours(2)))
    }

    function ConvertTo-TestObject {
        param([Parameter(Mandatory = $true)][object]$Value)
        return (& $global:JwfJsonCmdlet -InputObject (ConvertTo-Json -InputObject $Value -Depth 20))
    }

    function ConvertTo-TestTime {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value) { return $null }
        return (([DateTime]$Value).ToString('yyyy-MM-ddTHH:mm:ss.fff', $inv) + '+00:00')
    }

    function New-TestSchedule {
        param(
            [string]$Name,
            [string]$Frequency = 'Hour',
            [int]$Interval = 1,
            [string]$StartTime = '2026-09-01T00:00:00+00:00',
            [AllowNull()][object]$ExpiryTime = '9999-12-31T23:59:59.9999999+00:00',
            [object]$Enabled = $true,
            [string]$TimeZone = 'Etc/UTC',
            [string[]]$WeekDays = @(),
            [int[]]$MonthDays = @(),
            [object[]]$MonthlyOccurrences = @(),
            [double]$StartOffsetMinutes = 0,
            [AllowNull()][object]$NextRun = $null,
            [AllowNull()][object]$LastModified = '2026-08-01T00:00:00+00:00'
        )
        return (ConvertTo-TestObject -Value @{
                id         = ('{0}/schedules/{1}' -f $accountPath, $Name)
                name       = $Name
                properties = @{
                    description             = 'test schedule'
                    startTime               = $StartTime
                    startTimeOffsetMinutes  = $StartOffsetMinutes
                    expiryTime              = $ExpiryTime
                    expiryTimeOffsetMinutes = 0
                    isEnabled               = $Enabled
                    interval                = $Interval
                    frequency               = $Frequency
                    creationTime            = '2026-08-01T00:00:00+00:00'
                    lastModifiedTime        = $LastModified
                    nextRun                 = $NextRun
                    nextRunOffsetMinutes    = 0
                    timeZone                = $TimeZone
                    advancedSchedule        = @{ weekDays = @($WeekDays); monthDays = @($MonthDays); monthlyOccurrences = @($MonthlyOccurrences) }
                }
            })
    }

    # lastModifiedTime follows the documented sample: the end time for a
    # finished job, otherwise the latest time the job has.
    function New-TestJob {
        param(
            [string]$JobId,
            [string]$Runbook,
            [string]$Status = 'Completed',
            [AllowNull()][object]$Start = $null,
            [AllowNull()][object]$End = $null,
            [AllowNull()][object]$Created = $null,
            [AllowNull()][object]$LastModified = $null
        )
        $createdAt = $now.AddHours(-3)
        if ($null -ne $Start) { $createdAt = ([DateTime]$Start).AddSeconds(-5) }
        if ($null -ne $Created) { $createdAt = [DateTime]$Created }
        $modifiedAt = $createdAt
        if ($null -ne $Start) { $modifiedAt = [DateTime]$Start }
        if ($null -ne $End) { $modifiedAt = [DateTime]$End }
        if ($null -ne $LastModified) { $modifiedAt = [DateTime]$LastModified }
        return (ConvertTo-TestObject -Value @{
                id         = ('{0}/jobs/{1}' -f $accountPath, $JobId)
                name       = $JobId
                type       = 'Microsoft.Automation/AutomationAccounts/Jobs'
                properties = @{
                    jobId             = $JobId
                    runbook           = @{ name = $Runbook }
                    provisioningState = 'Succeeded'
                    status            = $Status
                    creationTime      = (ConvertTo-TestTime -Value $createdAt)
                    startTime         = (ConvertTo-TestTime -Value $Start)
                    endTime           = (ConvertTo-TestTime -Value $End)
                    lastModifiedTime  = (ConvertTo-TestTime -Value $modifiedAt)
                }
            })
    }

    function New-TestJobSchedule {
        param([string]$Runbook, [string]$Schedule, [string]$Id)
        return (ConvertTo-TestObject -Value @{
                id         = ('{0}/jobSchedules/{1}' -f $accountPath, $Id)
                name       = $Id
                properties = @{ jobScheduleId = $Id; runbook = @{ name = $Runbook }; schedule = @{ name = $Schedule }; runOn = $null; parameters = $null }
            })
    }

    function New-TestStream {
        param([string]$JobId, [int]$Sequence, [DateTime]$Time, [AllowNull()][string]$Summary, [string]$Type = 'Error', [string]$Text = '')
        $properties = @{ jobStreamId = ('{0}_00636535675981232703_{1:D20}' -f $JobId, $Sequence); summary = $Summary; time = $Time.ToString('o', $inv); streamType = $Type }
        if ($Text) { $properties.streamText = $Text }
        return (ConvertTo-TestObject -Value @{ id = ('{0}/jobs/{1}/streams/{2}' -f $accountPath, $JobId, $properties.jobStreamId); properties = $properties })
    }

    function New-TestVariable {
        param(
            [string]$Name,
            [string]$LastModified,
            [string]$Created = '2026-01-01T00:00:00+00:00'
        )
        return (ConvertTo-TestObject -Value @{
                id         = ('{0}/variables/{1}' -f $accountPath, $Name)
                name       = $Name
                properties = @{ isEncrypted = $false; description = 'desired state'; creationTime = $Created; lastModifiedTime = $LastModified }
            })
    }

    function New-TestTenant {
        param([switch]$Clean)

        $jobs = @()
        if ($Clean) {
            $jobs = @(
                (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Start (New-Utc 2026 9 17 11 0 30) -End (New-Utc 2026 9 17 11 1 10)),
                (New-TestJob -JobId $ids.BravoDone -Runbook 'Invoke-Bravo' -Start (New-Utc 2026 9 17 6 0 20) -End (New-Utc 2026 9 17 6 2 0)),
                (New-TestJob -JobId $ids.WatcherFailed -Runbook 'Watch-AutomationJobFailures' -Start (New-Utc 2026 9 17 11 15 5) -End (New-Utc 2026 9 17 11 15 40)),
                (New-TestJob -JobId $ids.DeltaDone -Runbook 'Invoke-Delta' -Start (New-Utc 2026 9 17 11 30 0) -End (New-Utc 2026 9 17 11 31 0))
            )
        }
        else {
            # Invoke-Delta is a cloud job that fair share stopped after three
            # hours: it started long before the lookback window and ended
            # inside it.
            $jobs = @(
                (New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start (New-Utc 2026 9 17 11 0 30) -End (New-Utc 2026 9 17 11 1 10)),
                (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Start (New-Utc 2026 9 17 10 0 20) -End (New-Utc 2026 9 17 10 1 0)),
                (New-TestJob -JobId $ids.WatcherFailed -Runbook 'Watch-AutomationJobFailures' -Status 'Failed' -Start (New-Utc 2026 9 17 11 15 5) -End (New-Utc 2026 9 17 11 15 40)),
                (New-TestJob -JobId $ids.DeltaStopped -Runbook 'Invoke-Delta' -Status 'Stopped' -Start (New-Utc 2026 9 17 9 5 0) -End (New-Utc 2026 9 17 12 5 0)),
                (New-TestJob -JobId $ids.EchoOld -Runbook 'Invoke-Echo' -Status 'Failed' -Start (New-Utc 2026 9 17 9 0 0) -End (New-Utc 2026 9 17 9 0 30))
            )
        }

        $streams = @{}
        $streams[$ids.AlphaFailed] = @(
            (New-TestStream -JobId $ids.AlphaFailed -Sequence 3 -Time (New-Utc 2026 9 17 11 0 50) -Summary 'Graph GET /v1.0/users failed with HTTP 403 after 1 attempt(s): Authorization_RequestDenied: Insufficient privileges to complete the operation.'),
            (New-TestStream -JobId $ids.AlphaFailed -Sequence 1 -Time (New-Utc 2026 9 17 11 0 40) -Summary 'first error'),
            (New-TestStream -JobId $ids.AlphaFailed -Sequence 2 -Time (New-Utc 2026 9 17 11 0 45) -Summary 'second error'),
            (New-TestStream -JobId $ids.AlphaFailed -Sequence 4 -Time (New-Utc 2026 9 17 11 1 5) -Summary ('Unhandled error; the request carried Authorization: Bearer ' + $graphToken))
        )

        $details = @{}
        $details[$ids.DeltaStopped] = ConvertTo-TestObject -Value @{
            id         = ('{0}/jobs/{1}' -f $accountPath, $ids.DeltaStopped)
            name       = $ids.DeltaStopped
            properties = @{
                jobId     = $ids.DeltaStopped
                runbook   = @{ name = 'Invoke-Delta' }
                status    = 'Stopped'
                exception = 'The job was stopped because it reached the fair share limit of three hours.'
                startTime = '2026-09-17T09:05:00+00:00'
                endTime   = '2026-09-17T12:05:00+00:00'
            }
        }

        return @{
            Subscriptions     = @((ConvertTo-TestObject -Value @{ id = ('/subscriptions/' + $subscriptionId); subscriptionId = $subscriptionId; displayName = 'Example Identity Subscription'; state = 'Enabled' }))
            Schedules         = @(
                (New-TestSchedule -Name 'hourly-at-00' -Frequency 'Hour' -StartTime '2026-09-01T00:00:00+00:00' -NextRun '2026-09-17T13:00:00+00:00'),
                (New-TestSchedule -Name 'daily-0600' -Frequency 'Day' -StartTime '2026-09-01T06:00:00+00:00' -NextRun '2026-09-18T06:00:00+00:00'),
                (New-TestSchedule -Name 'daily-disabled' -Frequency 'Day' -StartTime '2026-09-01T07:00:00+00:00' -Enabled $false -NextRun '2026-09-01T07:00:00+00:00')
            )
            JobSchedules      = @(
                (New-TestJobSchedule -Runbook 'Invoke-Alpha' -Schedule 'hourly-at-00' -Id 'js-alpha'),
                (New-TestJobSchedule -Runbook 'Invoke-Bravo' -Schedule 'daily-0600' -Id 'js-bravo'),
                (New-TestJobSchedule -Runbook 'Invoke-Charlie' -Schedule 'daily-disabled' -Id 'js-charlie'),
                (New-TestJobSchedule -Runbook 'Watch-AutomationJobFailures' -Schedule 'hourly-at-00' -Id 'js-watcher')
            )
            Jobs              = $jobs
            Streams           = $streams
            StreamPages       = @{}
            StreamRecords     = @{}
            JobDetails         = $details
            Variables          = @()
            VariableListStatus = 200
            State             = $null
            StateEncrypted    = $false
            StatePutStatus    = 200
            StatePutFailAfter = 0
            StatePuts         = 0
            MailStatus        = 202
            AccountMissing    = $false
        }
    }

    function Reset-TestState {
        param([switch]$Clean)
        $global:JwfTenant = New-TestTenant -Clean:$Clean
        $global:JwfRequests.Clear()
    }

    function Invoke-TestRun {
        param([hashtable]$Extra = @{})
        $params = @{
            AutomationAccountName = 'aa-example-watch'
            ResourceGroupName     = 'rg-example-automation'
            SubscriptionName      = 'Example Identity Subscription'
            AccessToken           = $tokens
            RunId                 = $runId
            Now                   = $now
            CurrentJobId          = ''
        }
        foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
        return (Invoke-WatchAutomationJobFailuresRun @params)
    }

    function Get-TestRequests {
        param([string]$Method = '', [string]$PathLike = '*')
        return @($global:JwfRequests | Where-Object { ($Method -eq '' -or $_.Method -eq $Method) -and $_.Path -like $PathLike })
    }

    function Get-WriteSequence {
        return ((@($global:JwfRequests | Where-Object { $_.Method -ne 'GET' } | ForEach-Object { $_.Method })) -join ',')
    }

    function Get-StoredState {
        param([Parameter(Mandatory = $true)][object]$Request)
        $sent = & $global:JwfJsonCmdlet -InputObject ([string]$Request.Body)
        return (ConvertFrom-JobWatchState -Text (ConvertFrom-AutomationVariableValue -Value $sent.properties.value))
    }

    function New-StateText {
        param([hashtable]$Entries)
        return (ConvertTo-JobWatchState -Entries $Entries)
    }

    Mock Invoke-HttpCore { return (Get-JwfTestResponse -Method $Method -Uri $Uri -Body $Body -RequestHeaders $Headers) }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }

    Context 'schedule math' {
        It 'judges the hourly run before the one still inside its grace window' {
            $schedule = New-TestSchedule -Name 'hourly-at-00' -Frequency 'Hour'
            $e = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now -GraceMinutes 30
            $e.Evaluate | Should Be $true
            $e.Reason | Should Be 'Due'
            $e.ExpectedUtc | Should Be (New-Utc 2026 9 17 11 0)
            (Get-ScheduleExpectation -Schedule $schedule -NowUtc $now -GraceMinutes 5).ExpectedUtc | Should Be (New-Utc 2026 9 17 12 0)
        }

        It 'steps hour and minute intervals greater than one from the start' {
            Get-ScheduleLastOccurrence -StartUtc (New-Utc 2026 9 17 0 30) -Frequency Hour -Interval 4 -AsOfUtc (New-Utc 2026 9 17 11 40) | Should Be (New-Utc 2026 9 17 8 30)
            Get-ScheduleLastOccurrence -StartUtc (New-Utc 2026 9 17 0 5) -Frequency Minute -Interval 15 -AsOfUtc (New-Utc 2026 9 17 11 40) | Should Be (New-Utc 2026 9 17 11 35)
            Get-ScheduleLastOccurrence -StartUtc (New-Utc 2026 9 17 0 30) -Frequency Hour -Interval 4 -AsOfUtc (New-Utc 2026 9 17 0 29) | Should BeNullOrEmpty
        }

        It 'counts a daily interval greater than one from the start date' {
            $start = New-Utc 2026 9 1 6 0
            Get-ScheduleLastOccurrence -StartUtc $start -Frequency Day -Interval 3 -AsOfUtc (New-Utc 2026 9 17 11 40) | Should Be (New-Utc 2026 9 16 6 0)
            Get-ScheduleLastOccurrence -StartUtc $start -Frequency Day -Interval 3 -AsOfUtc (New-Utc 2026 9 16 5 0) | Should Be (New-Utc 2026 9 13 6 0)
            Get-ScheduleLastOccurrence -StartUtc $start -Frequency Day -Interval 3 -AsOfUtc (New-Utc 2026 9 1 6 0) | Should Be $start
        }

        It 'finds the Friday run across the weekend on a Monday and Friday schedule' {
            (New-Utc 2026 8 31).DayOfWeek | Should Be ([DayOfWeek]::Monday)
            (New-Utc 2026 9 11).DayOfWeek | Should Be ([DayOfWeek]::Friday)
            $week = @{ StartUtc = (New-Utc 2026 8 31 7 0); Frequency = 'Week'; WeekDays = @('Monday', 'Friday') }
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 13 12 0) | Should Be (New-Utc 2026 9 11 7 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 14 6 30) | Should Be (New-Utc 2026 9 11 7 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 14 7 30) | Should Be (New-Utc 2026 9 14 7 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 11 6 59) | Should Be (New-Utc 2026 9 7 7 0)
        }

        It 'runs a weekend-only schedule on Saturday and Sunday' {
            $week = @{ StartUtc = (New-Utc 2026 9 5 22 0); Frequency = 'Week'; WeekDays = @('Saturday', 'Sunday') }
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 14 10 0) | Should Be (New-Utc 2026 9 13 22 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 13 21 0) | Should Be (New-Utc 2026 9 12 22 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 18 23 0) | Should Be (New-Utc 2026 9 13 22 0)
        }

        It 'skips the off weeks of a two-week schedule' {
            $week = @{ StartUtc = (New-Utc 2026 8 31 7 0); Frequency = 'Week'; Interval = 2; WeekDays = @('Monday') }
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 21 12 0) | Should Be (New-Utc 2026 9 14 7 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 13 12 0) | Should Be (New-Utc 2026 8 31 7 0)
            Get-ScheduleLastOccurrence @week -AsOfUtc (New-Utc 2026 9 28 7 0) | Should Be (New-Utc 2026 9 28 7 0)
        }

        It 'uses the start weekday when a weekly schedule names none' {
            (New-Utc 2026 9 3).DayOfWeek | Should Be ([DayOfWeek]::Thursday)
            Get-ScheduleLastOccurrence -StartUtc (New-Utc 2026 9 3 9 0) -Frequency Week -AsOfUtc (New-Utc 2026 9 17 8 0) | Should Be (New-Utc 2026 9 10 9 0)
        }

        It 'runs on the last day with -1 and skips months without day 31' {
            $month = @{ StartUtc = (New-Utc 2026 1 31 6 0); Frequency = 'Month' }
            Get-ScheduleLastOccurrence @month -MonthDays @(-1) -AsOfUtc (New-Utc 2026 10 1 0 0) | Should Be (New-Utc 2026 9 30 6 0)
            Get-ScheduleLastOccurrence @month -MonthDays @(31) -AsOfUtc (New-Utc 2026 10 1 0 0) | Should Be (New-Utc 2026 8 31 6 0)
            Get-ScheduleLastOccurrence @month -MonthDays @(1, 15) -AsOfUtc (New-Utc 2026 9 17 0 0) | Should Be (New-Utc 2026 9 15 6 0)
            @(Get-MonthOccurrenceDays -Year 2026 -Month 2 -MonthDays @(30, 31, -1, 1)) -join ',' | Should Be '28,1'
        }

        It 'runs on the first Monday and on the last Friday of a month' {
            $firstMonday = @((ConvertTo-TestObject -Value @{ occurrence = 1; day = 'Monday' }))
            $lastFriday = @((ConvertTo-TestObject -Value @{ occurrence = -1; day = 'Friday' }))
            $month = @{ StartUtc = (New-Utc 2026 1 5 6 0); Frequency = 'Month'; AsOfUtc = (New-Utc 2026 9 17 12 0) }
            Get-ScheduleLastOccurrence @month -MonthlyOccurrences $firstMonday | Should Be (New-Utc 2026 9 7 6 0)
            Get-ScheduleLastOccurrence @month -MonthlyOccurrences $lastFriday | Should Be (New-Utc 2026 8 28 6 0)
            @(Get-MonthOccurrenceDays -Year 2026 -Month 9 -MonthlyOccurrences @((ConvertTo-TestObject -Value @{ occurrence = 5; day = 'Monday' }))).Count | Should Be 0
        }

        It 'counts a monthly interval from the start month' {
            $month = @{ StartUtc = (New-Utc 2026 1 15 6 0); Frequency = 'Month'; Interval = 3; AsOfUtc = (New-Utc 2026 9 17 12 0) }
            Get-ScheduleLastOccurrence @month -MonthDays @(15) | Should Be (New-Utc 2026 7 15 6 0)
            Get-ScheduleLastOccurrence @month | Should Be (New-Utc 2026 7 15 6 0)
        }

        It 'keeps the wall-clock time of a daily schedule across daylight saving' {
            foreach ($zone in @('Eastern Standard Time', 'America/New_York')) {
                $schedule = New-TestSchedule -Name 'daily-0600-eastern' -Frequency 'Day' -StartTime '2026-01-05T06:00:00-05:00' -TimeZone $zone -StartOffsetMinutes -300
                $summer = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now -GraceMinutes 30
                $summer.TimeZoneResolved | Should Be $true
                $summer.ExpectedUtc | Should Be (New-Utc 2026 9 17 10 0)
                $winter = Get-ScheduleExpectation -Schedule $schedule -NowUtc (New-Utc 2026 12 1 12 10) -GraceMinutes 30
                $winter.ExpectedUtc | Should Be (New-Utc 2026 12 1 11 0)
            }
        }

        It 'moves a run in the spring-forward gap to the first valid time' {
            $schedule = New-TestSchedule -Name 'daily-0230-eastern' -Frequency 'Day' -StartTime '2026-01-05T02:30:00-05:00' -TimeZone 'Eastern Standard Time'
            (Get-ScheduleExpectation -Schedule $schedule -NowUtc (New-Utc 2026 3 8 12 10) -GraceMinutes 30).ExpectedUtc | Should Be (New-Utc 2026 3 8 7 30)
            (Get-ScheduleExpectation -Schedule $schedule -NowUtc (New-Utc 2026 3 9 12 10) -GraceMinutes 30).ExpectedUtc | Should Be (New-Utc 2026 3 9 6 30)
        }

        It 'does not judge a daily, weekly, or monthly schedule in a time zone this host does not know' {
            foreach ($frequency in @('Day', 'Week', 'Month')) {
                $schedule = New-TestSchedule -Name 'mars' -Frequency $frequency -StartTime '2026-09-01T08:00:00+02:00' -TimeZone 'Mars/Olympus_Mons' -StartOffsetMinutes 120
                $e = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now -GraceMinutes 30
                $e.TimeZoneResolved | Should Be $false
                $e.Evaluate | Should Be $false
                $e.Reason | Should Be 'TimeZoneUnknown'
                $e.ExpectedUtc | Should BeNullOrEmpty
            }
            $link = @(New-TestJobSchedule -Runbook 'Invoke-Mars' -Schedule 'mars' -Id 'js-mars')
            $r = Get-MissedRunFindings -Schedules @(New-TestSchedule -Name 'mars' -Frequency 'Day' -StartTime '2026-09-01T08:00:00+02:00' -TimeZone 'Mars/Olympus_Mons') -JobSchedules $link -Jobs @() -NowUtc $now
            @($r.Findings).Count | Should Be 0
            (@($r.Skipped | ForEach-Object { $_.Reason }) -join ',') | Should Be 'TimeZoneUnknown'
        }

        It 'still judges an hourly schedule in an unknown time zone, which steps in absolute time' {
            $schedule = New-TestSchedule -Name 'hourly-mars' -Frequency 'Hour' -StartTime '2026-09-01T02:00:00+02:00' -TimeZone 'Mars/Olympus_Mons'
            $e = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now -GraceMinutes 30
            $e.TimeZoneResolved | Should Be $false
            $e.Reason | Should Be 'Due'
            $e.ExpectedUtc | Should Be (New-Utc 2026 9 17 11 0)
        }

        It 'judges a schedule whose nextRun agrees with the schedule math, seconds aside' {
            $hourly = New-TestSchedule -Name 'hourly' -Frequency 'Hour' -NextRun '2026-09-17T13:00:00+00:00'
            $e = Get-ScheduleExpectation -Schedule $hourly -NowUtc $now
            $e.Reason | Should Be 'Due'
            $e.NextRunUtc | Should Be (New-Utc 2026 9 17 13 0)
            $seconds = New-TestSchedule -Name 'daily-seconds' -Frequency 'Day' -StartTime '2026-09-01T06:00:27.1234567+00:00' -NextRun '2026-09-18T06:00:00+00:00'
            (Get-ScheduleExpectation -Schedule $seconds -NowUtc $now).Reason | Should Be 'Due'
            $eastern = New-TestSchedule -Name 'daily-0600-eastern' -Frequency 'Day' -StartTime '2026-01-05T06:00:00-05:00' -TimeZone 'Eastern Standard Time' -NextRun '2026-09-18T06:00:00-04:00'
            (Get-ScheduleExpectation -Schedule $eastern -NowUtc $now).ExpectedUtc | Should Be (New-Utc 2026 9 17 10 0)
        }

        It 'does not judge a schedule whose nextRun the schedule math does not produce' {
            $hourly = New-TestSchedule -Name 'hourly' -Frequency 'Hour' -NextRun '2026-09-17T13:30:00+00:00'
            $e = Get-ScheduleExpectation -Schedule $hourly -NowUtc $now
            $e.Evaluate | Should Be $false
            $e.Reason | Should Be 'NextRunMismatch'
            $e.ExpectedUtc | Should BeNullOrEmpty
            $e.NextRunUtc | Should Be (New-Utc 2026 9 17 13 30)

            # Wall-clock time kept across daylight saving would put the
            # Eastern run at 10:00 UTC in September; 11:00 disagrees.
            $eastern = New-TestSchedule -Name 'daily-0600-eastern' -Frequency 'Day' -StartTime '2026-01-05T06:00:00-05:00' -TimeZone 'Eastern Standard Time' -NextRun '2026-09-18T11:00:00+00:00'
            (Get-ScheduleExpectation -Schedule $eastern -NowUtc $now).Reason | Should Be 'NextRunMismatch'

            # An off week of a two-week schedule is not a run.
            $fortnight = New-TestSchedule -Name 'fortnight' -Frequency 'Week' -Interval 2 -StartTime '2026-08-31T07:00:00+00:00' -WeekDays @('Monday') -NextRun '2026-09-21T07:00:00+00:00'
            (Get-ScheduleExpectation -Schedule $fortnight -NowUtc (New-Utc 2026 9 14 8 0)).Reason | Should Be 'NextRunMismatch'
            $fortnight.properties.nextRun = '2026-09-28T07:00:00+00:00'
            (Get-ScheduleExpectation -Schedule $fortnight -NowUtc (New-Utc 2026 9 14 8 0)).Reason | Should Be 'Due'

            $link = @(New-TestJobSchedule -Runbook 'Invoke-Bravo' -Schedule 'daily-0600' -Id 'js-bravo')
            $daily = New-TestSchedule -Name 'daily-0600' -Frequency 'Day' -StartTime '2026-09-01T06:00:00+00:00' -NextRun '2026-09-18T07:00:00+00:00'
            $r = Get-MissedRunFindings -Schedules @($daily) -JobSchedules $link -Jobs @() -NowUtc $now
            @($r.Findings).Count | Should Be 0
            @($r.Evaluated).Count | Should Be 0
            (@($r.Skipped | ForEach-Object { $_.Reason }) -join ',') | Should Be 'NextRunMismatch'
        }

        It 'resolves UTC aliases and returns nothing for an unknown zone' {
            (Resolve-JobWatchTimeZone -TimeZoneId 'Etc/UTC').Id | Should Be ([TimeZoneInfo]::Utc.Id)
            (Resolve-JobWatchTimeZone -TimeZoneId '').Id | Should Be ([TimeZoneInfo]::Utc.Id)
            Resolve-JobWatchTimeZone -TimeZoneId 'Nowhere/Zone' | Should BeNullOrEmpty
        }

        It 'reads ARM times with and without offsets, and the far-future expiry' {
            ConvertTo-JobWatchUtc -Value '2026-09-17T08:00:00+02:00' | Should Be (New-Utc 2026 9 17 6 0)
            ConvertTo-JobWatchUtc -Value '2026-09-17T06:00:00' | Should Be (New-Utc 2026 9 17 6 0)
            (ConvertTo-JobWatchUtc -Value '9999-12-31T17:59:00-06:00').Year | Should Be 9999
            ConvertTo-JobWatchUtc -Value '' | Should BeNullOrEmpty
            (ConvertTo-JobWatchUtc -Value (New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 6, 0, 0)).Kind | Should Be ([DateTimeKind]::Utc)
        }
    }

    Context 'schedule expectation' {
        It 'ignores a disabled schedule, including isEnabled written as a string' {
            $schedule = New-TestSchedule -Name 'off' -Frequency 'Day' -Enabled $false
            $e = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now
            $e.Evaluate | Should Be $false
            $e.Reason | Should Be 'Disabled'
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'off' -Frequency 'Day' -Enabled 'false') -NowUtc $now).Reason | Should Be 'Disabled'
        }

        It 'ignores an expired schedule and keeps one that never expires' {
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'done' -Frequency 'Hour' -ExpiryTime '2026-09-17T12:00:00+00:00') -NowUtc $now).Reason | Should Be 'Expired'
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'forever' -Frequency 'Hour') -NowUtc $now).Reason | Should Be 'Due'
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'no-expiry' -Frequency 'Hour' -ExpiryTime $null) -NowUtc $now).Reason | Should Be 'Due'
        }

        It 'ignores a one-time schedule whose time has passed' {
            $e = Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'once' -Frequency 'OneTime' -StartTime '2026-09-17T09:00:00+00:00' -ExpiryTime '2026-09-17T09:00:00+00:00') -NowUtc $now
            $e.Reason | Should Be 'Expired'
            $e = Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'once' -Frequency 'OneTime' -StartTime '2026-09-17T09:00:00+00:00') -NowUtc $now
            $e.Evaluate | Should Be $false
            $e.Reason | Should Be 'OneTimePast'
        }

        It 'ignores a schedule whose start is in the future or still inside the grace window' {
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'later' -Frequency 'Day' -StartTime '2026-09-18T06:00:00+00:00') -NowUtc $now).Reason | Should Be 'NotStarted'
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'once-later' -Frequency 'OneTime' -StartTime '2026-09-18T06:00:00+00:00') -NowUtc $now).Reason | Should Be 'NotStarted'
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'just-now' -Frequency 'Hour' -StartTime '2026-09-17T12:00:00+00:00') -NowUtc $now -GraceMinutes 30).Reason | Should Be 'NotStarted'
        }

        It 'does not judge a due run older than the horizon' {
            $weekly = New-TestSchedule -Name 'weekly-monday' -Frequency 'Week' -StartTime '2026-08-31T07:00:00+00:00' -WeekDays @('Monday')
            $e = Get-ScheduleExpectation -Schedule $weekly -NowUtc $now -HorizonHours 48
            $e.Reason | Should Be 'OutsideHorizon'
            $e.ExpectedUtc | Should Be (New-Utc 2026 9 14 7 0)
            (Get-ScheduleExpectation -Schedule $weekly -NowUtc (New-Utc 2026 9 14 8 0) -HorizonHours 48).Reason | Should Be 'Due'
        }

        It 'does not judge a frequency it does not know' {
            (Get-ScheduleExpectation -Schedule (New-TestSchedule -Name 'odd' -Frequency 'Fortnight') -NowUtc $now).Reason | Should Be 'Unsupported'
        }
    }

    Context 'heartbeat' {
        $tenant = New-TestTenant
        $schedules = $tenant.Schedules
        $bravoLink = @(New-TestJobSchedule -Runbook 'Invoke-Bravo' -Schedule 'daily-0600' -Id 'js-bravo')

        It 'reports a due run when no job for the runbook started since it was due' {
            $jobs = @(ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Start (New-Utc 2026 9 17 11 0 30)))
            $r = Get-MissedRunFindings -Schedules $schedules -JobSchedules $bravoLink -Jobs $jobs -NowUtc $now -GraceMinutes 30
            @($r.Findings).Count | Should Be 1
            $f = @($r.Findings)[0]
            $f.Kind | Should Be 'MissedRun'
            $f.Key | Should Be 'missed:invoke-bravo|2026-09-17T06:00:00Z'
            $f.ScheduleName | Should Be 'daily-0600'
            $f.ExpectedUtc | Should Be (New-Utc 2026 9 17 6 0)
            @($r.Evaluated).Count | Should Be 1
        }

        It 'counts a job that has started but has no end time yet' {
            $running = New-TestJob -JobId $ids.BravoDone -Runbook 'Invoke-Bravo' -Status 'Running' -Start (New-Utc 2026 9 17 6 0 40)
            $record = ConvertTo-JobWatchJob -Job $running
            $record.EndUtc | Should BeNullOrEmpty
            $record.StartUtc | Should Be (New-Utc 2026 9 17 6 0 40)
            $r = Get-MissedRunFindings -Schedules $schedules -JobSchedules $bravoLink -Jobs @($record) -NowUtc $now
            @($r.Findings).Count | Should Be 0
            Test-JobStartedSince -Jobs @($record) -RunbookName 'invoke-bravo' -SinceUtc (New-Utc 2026 9 17 6 0) | Should Be $true
        }

        It 'counts a failed run as a run, and a queued job as not started' {
            $failed = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start (New-Utc 2026 9 17 11 0 30) -End (New-Utc 2026 9 17 11 1 0))
            $queued = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Status 'New')
            $alphaLink = @(New-TestJobSchedule -Runbook 'Invoke-Alpha' -Schedule 'hourly-at-00' -Id 'js-alpha')
            @((Get-MissedRunFindings -Schedules $schedules -JobSchedules $alphaLink -Jobs @($failed) -NowUtc $now).Findings).Count | Should Be 0
            @((Get-MissedRunFindings -Schedules $schedules -JobSchedules $alphaLink -Jobs @($queued) -NowUtc $now).Findings).Count | Should Be 1
        }

        It 'does not count a job that started before the due time or belongs to another runbook' {
            $early = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.BravoDone -Runbook 'Invoke-Bravo' -Start (New-Utc 2026 9 17 5 40 0))
            $other = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.DeltaDone -Runbook 'Invoke-Bravo2' -Start (New-Utc 2026 9 17 6 0 10))
            @((Get-MissedRunFindings -Schedules $schedules -JobSchedules $bravoLink -Jobs @($early, $other) -NowUtc $now).Findings).Count | Should Be 1
            $tolerated = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.BravoDone -Runbook 'Invoke-Bravo' -Start (New-Utc 2026 9 17 5 59 0))
            @((Get-MissedRunFindings -Schedules $schedules -JobSchedules $bravoLink -Jobs @($tolerated) -NowUtc $now -ToleranceMinutes 2).Findings).Count | Should Be 0
        }

        It 'skips the watcher, excluded runbooks, disabled schedules, and unknown schedules' {
            $links = @(
                (New-TestJobSchedule -Runbook 'Watch-AutomationJobFailures' -Schedule 'hourly-at-00' -Id 'js-watcher'),
                (New-TestJobSchedule -Runbook 'Invoke-Charlie' -Schedule 'daily-disabled' -Id 'js-charlie'),
                (New-TestJobSchedule -Runbook 'Invoke-Foxtrot' -Schedule 'deleted-schedule' -Id 'js-foxtrot')
            )
            $r = Get-MissedRunFindings -Schedules $schedules -JobSchedules $links -Jobs @() -NowUtc $now -ExcludedRunbooks @('watch-automationjobfailures')
            @($r.Findings).Count | Should Be 0
            @($r.Evaluated).Count | Should Be 0
            (@($r.Skipped | ForEach-Object { '{0}={1}' -f $_.RunbookName, $_.Reason }) -join ';') | Should Be 'Watch-AutomationJobFailures=Excluded;Invoke-Charlie=Disabled;Invoke-Foxtrot=ScheduleNotFound'
        }

        # A schedule enabled after its due time looks exactly like this. The
        # scheduler may move lastModifiedTime on its own, so the finding is
        # kept and only annotated.
        It 'still reports a due run whose schedule changed after it was due, and notes the change' {
            $changed = New-TestSchedule -Name 'daily-0600' -Frequency 'Day' -StartTime '2026-09-01T06:00:00+00:00' -NextRun '2026-09-18T06:00:00+00:00' -LastModified '2026-09-17T09:00:00+00:00'
            $e = Get-ScheduleExpectation -Schedule $changed -NowUtc $now
            $e.Reason | Should Be 'Due'
            $e.Evaluate | Should Be $true
            $e.LastModifiedUtc | Should Be (New-Utc 2026 9 17 9 0)
            $r = Get-MissedRunFindings -Schedules @($changed) -JobSchedules $bravoLink -Jobs @() -NowUtc $now
            @($r.Findings).Count | Should Be 1
            @($r.Findings)[0].Key | Should Be 'missed:invoke-bravo|2026-09-17T06:00:00Z'
            @($r.Findings)[0].ScheduleChangedUtc | Should Be (New-Utc 2026 9 17 9 0)

            $justAfter = New-TestSchedule -Name 'daily-0600' -Frequency 'Day' -StartTime '2026-09-01T06:00:00+00:00' -NextRun '2026-09-18T06:00:00+00:00' -LastModified '2026-09-17T06:02:01+00:00'
            @((Get-MissedRunFindings -Schedules @($justAfter) -JobSchedules $bravoLink -Jobs @() -NowUtc $now -ToleranceMinutes 2).Findings)[0].ScheduleChangedUtc | Should Be (New-Utc 2026 9 17 6 2 1)

            foreach ($modified in @('2026-09-17T06:02:00+00:00', '2026-09-17T05:00:00+00:00', $null)) {
                $schedule = New-TestSchedule -Name 'daily-0600' -Frequency 'Day' -StartTime '2026-09-01T06:00:00+00:00' -NextRun '2026-09-18T06:00:00+00:00' -LastModified $modified
                $findings = @((Get-MissedRunFindings -Schedules @($schedule) -JobSchedules $bravoLink -Jobs @() -NowUtc $now -ToleranceMinutes 2).Findings)
                $findings.Count | Should Be 1
                $findings[0].ScheduleChangedUtc | Should BeNullOrEmpty
            }

            # A run that happened is not a finding, whatever the change time.
            $ran = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.BravoDone -Runbook 'Invoke-Bravo' -Start (New-Utc 2026 9 17 6 0 20) -End (New-Utc 2026 9 17 6 2 0))
            @((Get-MissedRunFindings -Schedules @($changed) -JobSchedules $bravoLink -Jobs @($ran) -NowUtc $now).Findings).Count | Should Be 0
        }

        It 'reports one finding when two links expect the same run' {
            $links = @(
                (New-TestJobSchedule -Runbook 'Invoke-Bravo' -Schedule 'daily-0600' -Id 'js-bravo-1'),
                (New-TestJobSchedule -Runbook 'Invoke-Bravo' -Schedule 'DAILY-0600' -Id 'js-bravo-2')
            )
            $r = Get-MissedRunFindings -Schedules $schedules -JobSchedules $links -Jobs @() -NowUtc $now
            @($r.Findings).Count | Should Be 1
            @($r.Evaluated).Count | Should Be 2
        }
    }

    Context 'failed jobs, exclusions, and state' {
        It 'takes the completion time from endTime, then lastModifiedTime, startTime, and creationTime' {
            $job = New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start (New-Utc 2026 9 17 11 0) -End (New-Utc 2026 9 17 11 30) -LastModified (New-Utc 2026 9 17 11 31)
            $r = ConvertTo-JobWatchJob -Job $job
            $r.CompletedUtc | Should Be (New-Utc 2026 9 17 11 30)
            $r.LastModifiedUtc | Should Be (New-Utc 2026 9 17 11 31)
            $job.properties.endTime = $null
            (ConvertTo-JobWatchJob -Job $job).CompletedUtc | Should Be (New-Utc 2026 9 17 11 31)
            $job.properties.lastModifiedTime = $null
            (ConvertTo-JobWatchJob -Job $job).CompletedUtc | Should Be (New-Utc 2026 9 17 11 0)
            $job.properties.startTime = $null
            $r = ConvertTo-JobWatchJob -Job $job
            $r.StartUtc | Should BeNullOrEmpty
            $r.CompletedUtc | Should Be (New-Utc 2026 9 17 10 59 55)
        }

        It 'selects jobs by when they failed, were suspended, or were stopped, not by when they started' {
            $jobs = @(
                (New-TestJob -JobId $ids.Suspended -Runbook 'Invoke-Delta' -Status 'Suspended' -Start (New-Utc 2026 9 17 9 0) -LastModified (New-Utc 2026 9 17 11 30)),
                (New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start (New-Utc 2026 9 17 11 5) -End (New-Utc 2026 9 17 11 6)),
                (New-TestJob -JobId $ids.DeltaStopped -Runbook 'Invoke-Bravo' -Status 'Stopped' -Start (New-Utc 2026 9 17 8 20) -End (New-Utc 2026 9 17 11 20)),
                (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Status 'Completed' -Start (New-Utc 2026 9 17 11 10) -End (New-Utc 2026 9 17 11 12)),
                (New-TestJob -JobId $ids.DeltaDone -Runbook 'Invoke-Delta' -Status 'Running' -Start (New-Utc 2026 9 17 11 40)),
                (New-TestJob -JobId $ids.EchoOld -Runbook 'Invoke-Echo' -Status 'Failed' -Start (New-Utc 2026 9 17 11 1) -End (New-Utc 2026 9 17 10 59)),
                (New-TestJob -JobId $ids.WatcherFailed -Runbook 'Watch-AutomationJobFailures' -Status 'Failed' -Start (New-Utc 2026 9 17 11 15) -End (New-Utc 2026 9 17 11 16)),
                (New-TestJob -JobId $ids.NeverStarted -Runbook 'Invoke-Hotel' -Status 'Failed' -Created (New-Utc 2026 9 17 11 44) -LastModified (New-Utc 2026 9 17 11 45))
            ) | ForEach-Object { ConvertTo-JobWatchJob -Job $_ }
            $found = @(Get-FailedJobFindings -Jobs $jobs -WindowStartUtc (New-Utc 2026 9 17 11 0) -ExcludedRunbooks @('WATCH-AUTOMATIONJOBFAILURES'))
            (@($found | ForEach-Object { $_.Status }) -join ',') | Should Be 'Failed,Stopped,Suspended,Failed'
            $found[0].Key | Should Be ('job:' + $ids.AlphaFailed)
            $found[0].RunbookName | Should Be 'Invoke-Alpha'
            $found[0].StartUtc | Should Be (New-Utc 2026 9 17 11 5)
            $found[0].CompletedUtc | Should Be (New-Utc 2026 9 17 11 6)
            $found[1].StartUtc | Should Be (New-Utc 2026 9 17 8 20)
            $found[3].JobId | Should Be $ids.NeverStarted
            $found[3].StartUtc | Should BeNullOrEmpty
            $found[3].CompletedUtc | Should Be (New-Utc 2026 9 17 11 45)
        }

        It 'keeps one record per job, the one read last' {
            $running = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.LongRun -Runbook 'Invoke-Golf' -Status 'Running' -Start (New-Utc 2026 9 17 8 0))
            $failed = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.LongRun.ToUpperInvariant() -Runbook 'Invoke-Golf' -Status 'Failed' -Start (New-Utc 2026 9 17 8 0) -End (New-Utc 2026 9 17 12 0))
            $other = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.AlphaDone -Runbook 'Invoke-Alpha' -Start (New-Utc 2026 9 17 11 0))
            $merged = @(Merge-JobWatchJobs -Jobs @($running, $other, $null, $failed))
            (@($merged | ForEach-Object { '{0}={1}' -f $_.JobId, $_.Status }) -join ',') | Should Be ('{0}=Failed,{1}=Completed' -f $ids.LongRun, $ids.AlphaDone)
        }

        It 'always excludes the watcher and adds the runbook of the running job' {
            $jobs = @(ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.Renamed -Runbook 'Watch-Renamed' -Status 'Running' -Start (New-Utc 2026 9 17 12 9)))
            (@(Get-JobWatchExclusions -Names @('Invoke-Sandbox', 'invoke-sandbox', ' ') -Jobs $jobs -CurrentJobId $ids.Renamed.ToUpperInvariant()) -join ',') | Should Be 'Watch-AutomationJobFailures,Invoke-Sandbox,Watch-Renamed'
            (@(Get-JobWatchExclusions -Jobs $jobs -CurrentJobId '') -join ',') | Should Be 'Watch-AutomationJobFailures'
        }

        It 'reads the running job id from the environment when the metadata variable is absent' {
            Get-WatcherJobId | Should Be ''
            try {
                $env:PSPrivateMetaData = ('{{"JobId":"{0}"}}' -f $ids.Renamed.ToUpperInvariant())
                Get-WatcherJobId | Should Be $ids.Renamed
            }
            finally {
                Remove-Item -Path Env:\PSPrivateMetaData -ErrorAction SilentlyContinue
            }
        }

        It 'round-trips the state document in a stable order' {
            $entries = @{
                'missed:invoke-bravo|2026-09-17T06:00:00Z' = (New-Utc 2026 9 17 7 10)
                ('job:' + $ids.AlphaFailed)                = (New-Utc 2026 9 17 11 10)
            }
            $text = ConvertTo-JobWatchState -Entries $entries
            $text | Should Be ('{"version":1,"alerted":[{"k":"job:' + $ids.AlphaFailed + '","t":"2026-09-17T11:10:00Z"},{"k":"missed:invoke-bravo|2026-09-17T06:00:00Z","t":"2026-09-17T07:10:00Z"}]}')
            $back = ConvertFrom-JobWatchState -Text $text
            $back.Count | Should Be 2
            $back['missed:invoke-bravo|2026-09-17T06:00:00Z'] | Should Be (New-Utc 2026 9 17 7 10)
            (ConvertTo-JobWatchState -Entries @{}) | Should Be '{"version":1,"alerted":[]}'
            (ConvertFrom-JobWatchState -Text '{"version":1,"alerted":[]}').Count | Should Be 0
        }

        It 'reads an empty state and rejects text that is not the state document' {
            (ConvertFrom-JobWatchState -Text '').Count | Should Be 0
            { ConvertFrom-JobWatchState -Text 'not json' } | Should Throw 'not valid JSON'
            { ConvertFrom-JobWatchState -Text '{"other":1}' } | Should Throw 'no "alerted" list'
            { ConvertFrom-JobWatchState -Text '["job:1"]' } | Should Throw 'no "alerted" list'
            { ConvertFrom-JobWatchStateDocument -Document $null } | Should Throw 'no "alerted" list'
        }

        It 'prunes entries older than 48 hours and keeps the newest when over the cap' {
            $entries = @{
                'job:old'    = $now.AddHours(-49)
                'job:recent' = $now.AddHours(-47)
                'job:newest' = $now.AddMinutes(-5)
                'job:bad'    = 'not a time'
            }
            $kept = Limit-JobWatchState -Entries $entries -NowUtc $now
            (@($kept.Keys | Sort-Object) -join ',') | Should Be 'job:newest,job:recent'
            $capped = Limit-JobWatchState -Entries $entries -NowUtc $now -MaxEntries 1
            (@($capped.Keys) -join ',') | Should Be 'job:newest'
            (Limit-JobWatchState -Entries $null -NowUtc $now).Count | Should Be 0
        }

        It 'never repeats a reported key and reports each key once' {
            $state = @{ ('job:' + $ids.AlphaFailed) = $now }
            $findings = @(
                [PSCustomObject]@{ Key = ('JOB:' + $ids.AlphaFailed.ToUpperInvariant()) },
                [PSCustomObject]@{ Key = ('job:' + $ids.DeltaStopped) },
                [PSCustomObject]@{ Key = ('job:' + $ids.DeltaStopped) },
                $null
            )
            $new = @(Select-NewFindings -Findings $findings -State $state)
            $new.Count | Should Be 1
            $new[0].Key | Should Be ('job:' + $ids.DeltaStopped)
            @(Select-NewFindings -Findings @() -State $state).Count | Should Be 0
        }

        It 'decodes the JSON-encoded value ARM returns for a string variable' {
            ConvertFrom-AutomationVariableValue -Value '"ComputerName.domain.com"' | Should Be 'ComputerName.domain.com'
            $text = '{"version":1,"alerted":[{"k":"missed:a<b>|x","t":"2026-09-17T06:00:00Z"}]}'
            ConvertFrom-AutomationVariableValue -Value (ConvertTo-Json -InputObject $text -Compress) | Should Be $text
            ConvertFrom-AutomationVariableValue -Value $null | Should Be ''
            ConvertFrom-AutomationVariableValue -Value 'plain' | Should Be 'plain'
        }

        It 'summarises the latest error records and removes tokens' {
            $tenant = New-TestTenant
            $streams = @($tenant.Streams[$ids.AlphaFailed]) + @(New-TestStream -JobId $ids.AlphaFailed -Sequence 5 -Time (New-Utc 2026 9 17 11 2) -Summary 'an output line' -Type 'Output')
            $summaryText = Format-JobErrorSummary -Streams $streams -Exception 'not used'
            $summaryText | Should Match '^second error \| Graph GET /v1.0/users failed with HTTP 403'
            $summaryText | Should Match 'Insufficient privileges'
            $summaryText.Contains('first error') | Should Be $false
            $summaryText.Contains('an output line') | Should Be $false
            $summaryText.Contains($graphToken) | Should Be $false
            $summaryText.Contains('not used') | Should Be $false
        }

        It 'orders stream records by time, with the list order breaking ties' {
            $late = New-TestStream -JobId $ids.AlphaFailed -Sequence 1 -Time (New-Utc 2026 9 17 11 5) -Summary 'late'
            $early = New-TestStream -JobId $ids.AlphaFailed -Sequence 2 -Time (New-Utc 2026 9 17 11 0) -Summary 'early'
            $tieA = New-TestStream -JobId $ids.AlphaFailed -Sequence 3 -Time (New-Utc 2026 9 17 11 2) -Summary 'tie a'
            $tieB = New-TestStream -JobId $ids.AlphaFailed -Sequence 4 -Time (New-Utc 2026 9 17 11 2) -Summary 'tie b'
            (@(Sort-JobWatchStreams -Streams @($late, $null, $early, $tieA, $tieB) | ForEach-Object { $_.properties.summary }) -join ',') | Should Be 'early,tie a,tie b,late'
        }

        It 'falls back to the exception text, reads streamText, and cuts long text' {
            Format-JobErrorSummary -Streams @() -Exception 'The job was suspended.' | Should Be 'The job was suspended.'
            Format-JobErrorSummary -Streams @() -Exception '' | Should Be ''
            $record = New-TestStream -JobId $ids.AlphaFailed -Sequence 1 -Time (New-Utc 2026 9 17 11 0) -Summary $null -Text 'Full record text.'
            Format-JobErrorSummary -Streams @($record) | Should Be 'Full record text.'
            $long = Format-JobErrorSummary -Exception ('x' * 500) -MaxLength 50
            ($long.Length -le 53) | Should Be $true
        }
    }

    Context 'times as PowerShell 7 hands them over' {
        It 'reads schedule times given as a DateTime of either kind or a DateTimeOffset' {
            $fromText = Get-ScheduleExpectation -NowUtc $now -Schedule (New-TestSchedule -Name 'daily-0600-eastern' -Frequency 'Day' -StartTime '2026-01-05T06:00:00-05:00' -TimeZone 'Eastern Standard Time' -NextRun '2026-09-18T06:00:00-04:00')
            $fromText.Reason | Should Be 'Due'
            $fromText.ExpectedUtc | Should Be (New-Utc 2026 9 17 10 0)
            $farFuture = @{
                Utc    = [DateTime]::SpecifyKind([DateTime]::MaxValue, [DateTimeKind]::Utc)
                Local  = [DateTime]::SpecifyKind([DateTime]::MaxValue, [DateTimeKind]::Local)
                Offset = [DateTimeOffset]::MaxValue
            }
            foreach ($shape in @('Utc', 'Local', 'Offset')) {
                $schedule = New-TestSchedule -Name 'daily-0600-eastern' -Frequency 'Day' -TimeZone 'Eastern Standard Time'
                $schedule.properties.startTime = ConvertTo-TimeShape -Utc (New-Utc 2026 1 5 11 0) -Shape $shape
                $schedule.properties.nextRun = ConvertTo-TimeShape -Utc (New-Utc 2026 9 18 10 0) -Shape $shape
                $schedule.properties.lastModifiedTime = ConvertTo-TimeShape -Utc (New-Utc 2026 9 17 10 30) -Shape $shape
                $schedule.properties.expiryTime = $farFuture[$shape]
                $e = Get-ScheduleExpectation -Schedule $schedule -NowUtc $now
                $e.Reason | Should Be 'Due'
                $e.ExpectedUtc | Should Be $fromText.ExpectedUtc
                $e.ExpectedUtc.Kind | Should Be ([DateTimeKind]::Utc)
                $e.NextRunUtc | Should Be (New-Utc 2026 9 18 10 0)
                $e.LastModifiedUtc | Should Be (New-Utc 2026 9 17 10 30)
                $e.LastModifiedUtc.Kind | Should Be ([DateTimeKind]::Utc)

                $schedule.properties.expiryTime = ConvertTo-TimeShape -Utc (New-Utc 2026 9 17 12 0) -Shape $shape
                (Get-ScheduleExpectation -Schedule $schedule -NowUtc $now).Reason | Should Be 'Expired'
                $schedule.properties.expiryTime = ConvertTo-TimeShape -Utc (New-Utc 2026 9 17 12 11) -Shape $shape
                (Get-ScheduleExpectation -Schedule $schedule -NowUtc $now).Reason | Should Be 'Due'
                $schedule.properties.nextRun = ConvertTo-TimeShape -Utc (New-Utc 2026 9 18 11 0) -Shape $shape
                (Get-ScheduleExpectation -Schedule $schedule -NowUtc $now).Reason | Should Be 'NextRunMismatch'
            }
        }

        It 'reads job times given as a DateTime of either kind or a DateTimeOffset' {
            $times = @{ startTime = (New-Utc 2026 9 17 8 0 30); endTime = (New-Utc 2026 9 17 11 1 10); creationTime = (New-Utc 2026 9 17 8 0 25); lastModifiedTime = (New-Utc 2026 9 17 11 1 10) }
            $fromText = ConvertTo-JobWatchJob -Job (New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start $times.startTime -End $times.endTime)
            foreach ($shape in @('Utc', 'Local', 'Offset')) {
                $job = New-TestJob -JobId $ids.AlphaFailed -Runbook 'Invoke-Alpha' -Status 'Failed' -Start $times.startTime -End $times.endTime
                foreach ($name in @($times.Keys)) { $job.properties.$name = ConvertTo-TimeShape -Utc $times[$name] -Shape $shape }
                $r = ConvertTo-JobWatchJob -Job $job
                $r.StartUtc | Should Be $fromText.StartUtc
                $r.StartUtc.Kind | Should Be ([DateTimeKind]::Utc)
                $r.EndUtc | Should Be $fromText.EndUtc
                $r.CreationUtc | Should Be $fromText.CreationUtc
                $r.CompletedUtc | Should Be (New-Utc 2026 9 17 11 1 10)
                $r.CompletedUtc.Kind | Should Be ([DateTimeKind]::Utc)
                @(Get-FailedJobFindings -Jobs @($r) -WindowStartUtc (New-Utc 2026 9 17 11 1 10)).Count | Should Be 1
                @(Get-FailedJobFindings -Jobs @($r) -WindowStartUtc (New-Utc 2026 9 17 11 1 11)).Count | Should Be 0

                $job.properties.endTime = $null
                $job.properties.lastModifiedTime = $null
                $job.properties.startTime = $null
                (ConvertTo-JobWatchJob -Job $job).CompletedUtc | Should Be (New-Utc 2026 9 17 8 0 25)
            }
        }

        It 'reads and prunes state times given as a DateTime of either kind or a DateTimeOffset' {
            $recent = $now.AddHours(-47)
            $old = $now.AddHours(-49)
            $fromText = ConvertFrom-JobWatchState -Text (New-StateText -Entries @{ 'job:recent' = $recent; 'job:old' = $old })
            $expectedText = New-StateText -Entries @{ 'job:recent' = $recent }
            foreach ($shape in @('Utc', 'Local', 'Offset')) {
                $document = [PSCustomObject]@{
                    version = 1
                    alerted = @(
                        [PSCustomObject]@{ k = 'JOB:Recent'; t = (ConvertTo-TimeShape -Utc $recent -Shape $shape) },
                        [PSCustomObject]@{ k = 'job:old'; t = (ConvertTo-TimeShape -Utc $old -Shape $shape) }
                    )
                }
                $entries = ConvertFrom-JobWatchStateDocument -Document $document
                $entries['job:recent'] | Should Be $fromText['job:recent']
                $entries['job:recent'].Kind | Should Be ([DateTimeKind]::Utc)
                $entries['job:old'] | Should Be $fromText['job:old']

                $raw = @{ 'job:recent' = (ConvertTo-TimeShape -Utc $recent -Shape $shape); 'job:old' = (ConvertTo-TimeShape -Utc $old -Shape $shape) }
                $kept = Limit-JobWatchState -Entries $raw -NowUtc $now
                (@($kept.Keys) -join ',') | Should Be 'job:recent'
                $kept['job:recent'] | Should Be $recent
                (ConvertTo-JobWatchState -Entries $kept) | Should Be $expectedText
                (ConvertTo-JobWatchState -Entries @{ 'job:recent' = (ConvertTo-TimeShape -Utc $recent -Shape $shape) }) | Should Be $expectedText
            }
            (@((Limit-JobWatchState -Entries @{ 'job:recent' = $recent; 'job:old' = $old } -NowUtc $now.ToLocalTime()).Keys) -join ',') | Should Be 'job:recent'
        }

        It 'writes a local time as its UTC time, in log text and in the digest' {
            $local = (New-Utc 2026 9 17 11 0 30).ToLocalTime()
            ConvertTo-JobWatchTimeText -Value $local | Should Be '2026-09-17T11:00:30Z'
            ConvertTo-JobWatchTimeText -Value (ConvertTo-TimeShape -Utc (New-Utc 2026 9 17 11 0 30) -Shape Offset) | Should Be '2026-09-17T11:00:30Z'
            $finding = [PSCustomObject]@{ Kind = 'FailedJob'; Key = 'job:1'; JobId = $ids.AlphaFailed; RunbookName = 'Invoke-Alpha'; Status = 'Failed'; StartUtc = $local; CompletedUtc = (New-Utc 2026 9 17 11 1 10).ToLocalTime(); ErrorSummary = '' }
            $missed = [PSCustomObject]@{ Kind = 'MissedRun'; Key = 'missed:x'; RunbookName = 'Invoke-Bravo'; ScheduleName = 'daily-0600'; ExpectedUtc = (New-Utc 2026 9 17 6 0).ToLocalTime(); TimeZoneId = '' }
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -FailedJobs @($finding) -MissedRuns @($missed) -NowUtc $now
            $html | Should Match '2026-09-17 11:00</td>'
            $html | Should Match '2026-09-17 11:01</td>'
            $html | Should Match '2026-09-17 06:00</td>'
        }
    }

    # Its own context: a Pester 3.4 mock stays in force for the rest of the
    # context it is made in.
    Context 'runs with times parsed the way PowerShell 7 parses them' {
        # The real cmdlet parses, with -NoEnumerate where it has it so a
        # top-level array keeps its shape, and the result goes back in the
        # comma form: on PowerShell 7, Write-Output -NoEnumerate wraps a
        # single object in a list, which the library then rejects.
        Mock ConvertFrom-Json {
            $real = @{ InputObject = $InputObject }
            if ($global:JwfJsonCmdlet.Parameters.ContainsKey('NoEnumerate')) { $real.NoEnumerate = $true }
            $parsedJson = & $global:JwfJsonCmdlet @real
            if ($parsedJson -is [string]) {
                $asDate = ConvertTo-JwfPowerShell7Date -Text $parsedJson
                if ($null -ne $asDate) { return $asDate }
                return $parsedJson
            }
            Update-JwfPowerShell7Dates -Value $parsedJson
            return ,$parsedJson
        }

        It 'turns ISO times into DateTime values, as PowerShell 7 does' {
            $parsed = ConvertFrom-Json -InputObject '{"a":"2026-09-17T08:00:00+02:00","b":"2026-09-17T06:00:00Z","c":"not a time","d":[{"e":"2026-09-17T06:00:00.123+00:00"}]}'
            ($parsed.a -is [DateTime]) | Should Be $true
            $parsed.a.Kind | Should Be ([DateTimeKind]::Local)
            $parsed.a.ToUniversalTime() | Should Be (New-Utc 2026 9 17 6 0)
            $parsed.b.Kind | Should Be ([DateTimeKind]::Utc)
            $parsed.c | Should Be 'not a time'
            ($parsed.d[0].e -is [DateTime]) | Should Be $true
        }

        It 'reports the same findings in a dry run' {
            Reset-TestState
            $s = Invoke-TestRun
            $s.Errors | Should Be 0
            $s.JobsScanned | Should Be 5
            $s.SchedulesJudged | Should Be 2
            $s.FailedJobs | Should Be 2
            $s.MissedRuns | Should Be 1
            $s.WindowStartUtc | Should Be '2026-09-17T11:00:00Z'
            $s.JobListStartUtc | Should Be '2026-09-17T05:58:00Z'
            (Get-TestRequests -PathLike '*/jobs')[0].Filter | Should Be 'properties/startTime ge 2026-09-17T05:58:00.0000000Z'
            $warnings = @(Get-RunLogEntries -Level Warn | ForEach-Object { $_.Message })
            @($warnings | Where-Object { $_ -like 'Failed job: runbook "Invoke-Delta" is Stopped since 2026-09-17T12:05:00Z (started 2026-09-17T09:05:00Z)*fair share*' }).Count | Should Be 1
            @($warnings | Where-Object { $_ -like 'Missed run: runbook "Invoke-Bravo" was due at 2026-09-17T06:00:00Z*' }).Count | Should Be 1
            $warnings.Count | Should Be 3
        }

        It 'dates a schedule change in UTC when lastModifiedTime arrives as a local time' {
            Reset-TestState
            $global:JwfTenant.Schedules[1].properties.lastModifiedTime = '2026-09-17T11:00:00+02:00'
            $s = Invoke-TestRun
            $s.MissedRuns | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Missed run: runbook "Invoke-Bravo" was due at 2026-09-17T06:00:00Z*The schedule changed at 2026-09-17T09:00:00Z, after this run was due*' }).Count | Should Be 1
        }

        It 'records, reads back, and prunes the state the same way when live' {
            Reset-TestState
            $global:JwfTenant.State = New-StateText -Entries @{ 'job:expired-entry' = $now.AddHours(-49); 'job:recent-entry' = $now.AddHours(-2) }
            $first = Invoke-TestRun -Extra $live
            $first.Errors | Should Be 0
            $first.FailedJobs | Should Be 2
            $first.MissedRuns | Should Be 1
            $first.StatePruned | Should Be 1
            $first.StateEntries | Should Be 4
            $stored = ConvertFrom-JobWatchState -Text $global:JwfTenant.State
            (@($stored.Keys | Sort-Object) -join ',') | Should Be ('job:{0},job:{1},job:recent-entry,missed:invoke-bravo|2026-09-17T06:00:00Z' -f $ids.AlphaFailed, $ids.DeltaStopped)
            $stored['job:recent-entry'] | Should Be $now.AddHours(-2)
            $stored[('job:' + $ids.AlphaFailed)] | Should Be $now
            $html = [string](& $global:JwfJsonCmdlet -InputObject (Get-TestRequests -Method 'POST')[0].Body).message.body.content
            $html | Should Match '2026-09-17 09:05</td><td [^>]*>2026-09-17 12:05</td>'
            $html | Should Match '2026-09-17 06:00</td>'

            $global:JwfRequests.Clear()
            $second = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be ''
            $second.Clean | Should Be $true
            $second.AlreadyReported | Should Be 3
            $second.StatePruned | Should Be 0
        }
    }

    Context 'digest' {
        $failed = @(
            [PSCustomObject]@{ Kind = 'FailedJob'; Key = 'job:1'; JobId = $ids.AlphaFailed; RunbookName = 'Invoke-<Alpha>&Co'; Status = 'Failed'; StartUtc = (New-Utc 2026 9 17 11 0 30); CompletedUtc = (New-Utc 2026 9 17 11 1 10); ErrorSummary = '<script>alert(1)</script>' },
            [PSCustomObject]@{ Kind = 'FailedJob'; Key = 'job:2'; JobId = $ids.NeverStarted; RunbookName = 'Invoke-Hotel'; Status = 'Stopped'; StartUtc = $null; CompletedUtc = (New-Utc 2026 9 17 11 25); ErrorSummary = '' },
            [PSCustomObject]@{ Kind = 'FailedJob'; Key = 'job:3'; JobId = $ids.EchoOld; RunbookName = 'Invoke-Echo'; Status = 'Stopped'; StartUtc = (New-Utc 2026 9 17 11 40); CompletedUtc = (New-Utc 2026 9 17 11 45); ErrorSummary = 'stopped by an operator' }
        )
        $missed = @(
            [PSCustomObject]@{ Kind = 'MissedRun'; Key = 'missed:invoke-bravo|2026-09-17T06:00:00Z'; RunbookName = 'Invoke-Bravo'; ScheduleName = 'daily-0600'; ExpectedUtc = (New-Utc 2026 9 17 6 0); TimeZoneId = 'Etc/UTC' }
        )

        It 'lists failed jobs and missed runs with every value encoded' {
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -FailedJobs $failed -MissedRuns $missed -NowUtc $now -RunIdText $runId
            $html | Should Match '^<html><body'
            $html | Should Match '3 failed job\(s\), 1 missed scheduled run\(s\), and 0 variable change\(s\)'
            $html | Should Match 'failed, suspended, or stopped in the last 70 minutes'
            $html | Should Match 'Ended or suspended \(UTC\)'
            $html | Should Match 'Invoke-&lt;Alpha&gt;&amp;Co'
            $html | Should Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
            $html.Contains('<script>') | Should Be $false
            $html | Should Match '\(no error output recorded\)'
            $html | Should Match '2026-09-17 11:00</td><td [^>]*>2026-09-17 11:01</td>'
            $html | Should Match 'Stopped</td><td [^>]*>\(not started\)</td><td [^>]*>2026-09-17 11:25</td>'
            $html | Should Match 'daily-0600'
            $html | Should Match '2026-09-17 06:00'
            $html | Should Match $runId
            $html | Should Match 'exits cleanly ends Completed'
            @([char[]]$html | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
        }

        It 'cuts each table at MaxRows and counts the rest' {
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -FailedJobs $failed -MissedRuns $missed -NowUtc $now -MaxRows 2
            $html | Should Match '1 more failed job\(s\) are not listed'
            $html.Contains('stopped by an operator') | Should Be $false
            $html.Contains('more missed run') | Should Be $false
        }

        It 'leaves out a table that has no rows' {
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -MissedRuns $missed -NowUtc $now
            $html.Contains('Failed jobs') | Should Be $false
            $html | Should Match 'Missed runs'
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -FailedJobs $failed -NowUtc $now
            $html.Contains('Missed runs') | Should Be $false
            $html.Contains('no run was due') | Should Be $false
        }

        It 'notes, in UTC, a schedule that changed after the missed run was due, and names the one false case' {
            $changedMiss = [PSCustomObject]@{ Kind = 'MissedRun'; Key = 'missed:invoke-kilo|2026-09-17T06:00:00Z'; RunbookName = 'Invoke-Kilo'; ScheduleName = 'daily-0600-b'; ExpectedUtc = (New-Utc 2026 9 17 6 0); TimeZoneId = 'Etc/UTC'; ScheduleChangedUtc = (New-Utc 2026 9 17 9 0 30).ToLocalTime() }
            $plainMiss = [PSCustomObject]@{ Kind = 'MissedRun'; Key = 'missed:invoke-lima|2026-09-17T06:00:00Z'; RunbookName = 'Invoke-Lima'; ScheduleName = 'daily-0600-c'; ExpectedUtc = (New-Utc 2026 9 17 6 0); TimeZoneId = 'Etc/UTC'; ScheduleChangedUtc = $null }
            $html = New-JobWatchDigestHtml -AccountName 'aa-example-watch' -MissedRuns @($missed[0], $changedMiss, $plainMiss) -NowUtc $now
            $html | Should Match '<th [^>]*>Schedule time zone</th><th [^>]*>Note</th></tr>'
            $html | Should Match 'daily-0600-b</td><td [^>]*>2026-09-17 06:00</td><td [^>]*>Etc/UTC</td><td [^>]*>Schedule changed 2026-09-17 09:00 UTC, after this run was due\. If that change enabled the schedule, no run was due\.</td></tr>'
            # A finding without the property (older shape) and one with $null both get an empty note.
            $html | Should Match 'daily-0600</td><td [^>]*>2026-09-17 06:00</td><td [^>]*>Etc/UTC</td><td [^>]*></td></tr>'
            $html | Should Match 'daily-0600-c</td><td [^>]*>2026-09-17 06:00</td><td [^>]*>Etc/UTC</td><td [^>]*></td></tr>'
            $html | Should Match '</table><p>A schedule enabled, or a runbook linked to a schedule, after the expected time is listed here once although no run was due'
            @([char[]]$html | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
        }
    }

    Context 'run against a mocked Automation account' {
        It 'reports what it would send in a dry run and writes nothing' {
            Reset-TestState
            $s = Invoke-TestRun
            (Get-WriteSequence) | Should Be ''
            $s.Runbook | Should Be 'Watch-AutomationJobFailures'
            $s.RunId | Should Be $runId
            $s.DryRun | Should Be $true
            $s.Environment | Should Be 'Global'
            $s.AutomationAccount | Should Be 'aa-example-watch'
            $s.JobsScanned | Should Be 5
            $s.SchedulesScanned | Should Be 3
            $s.JobSchedulesScanned | Should Be 4
            $s.SchedulesJudged | Should Be 2
            $s.FailedJobs | Should Be 2
            $s.MissedRuns | Should Be 1
            $s.AlreadyReported | Should Be 0
            $s.Clean | Should Be $false
            $s.Counts.SendDigest.Planned | Should Be 1
            $s.Counts.SaveState.Planned | Should Be 1
            $s.Counts.AlertFailedJob.Planned | Should Be 2
            $s.Counts.AlertMissedRun.Planned | Should Be 1
            $s.Counts.PSObject.Properties['RestoreState'] | Should BeNullOrEmpty
            $s.Done | Should Be 0
            $s.Errors | Should Be 0
            $s.WindowStartUtc | Should Be '2026-09-17T11:00:00Z'
            $s.JobListStartUtc | Should Be '2026-09-17T05:58:00Z'
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -eq 'Would send the digest (2 failed job(s), 1 missed run(s), 0 variable change(s)) to (no recipients configured).' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Would update Automation variable "JobWatch_AlertedJobIds"*' }).Count | Should Be 1
            $warnings = @(Get-RunLogEntries -Level Warn | ForEach-Object { $_.Message })
            @($warnings | Where-Object { $_ -like 'Failed job: runbook "Invoke-Alpha" is Failed since 2026-09-17T11:01:10Z (started 2026-09-17T11:00:30Z)*' }).Count | Should Be 1
            @($warnings | Where-Object { $_ -like 'Failed job: runbook "Invoke-Delta" is Stopped since 2026-09-17T12:05:00Z (started 2026-09-17T09:05:00Z)*fair share*' }).Count | Should Be 1
            @($warnings | Where-Object { $_ -like 'Missed run: runbook "Invoke-Bravo" was due at 2026-09-17T06:00:00Z*' }).Count | Should Be 1
            @($warnings | Where-Object { $_ -like '*Watch-AutomationJobFailures*' -or $_ -like '*Invoke-Echo*' -or $_ -like '*Invoke-Charlie*' }).Count | Should Be 0
        }

        It 'names the recipients in the dry-run digest line, after the state line' {
            Reset-TestState
            $s = Invoke-TestRun -Extra @{ Recipients = 'iam@corp.example.com' }
            (Get-WriteSequence) | Should Be ''
            $s.DryRun | Should Be $true
            $actions = @(Get-RunLogEntries -Level Action | ForEach-Object { $_.Message })
            $actions.Count | Should Be 2
            $actions[0] | Should Match '^Would update Automation variable "JobWatch_AlertedJobIds" \(3 reported key\(s\): 3 added, 0 pruned\)\.$'
            $actions[1] | Should Be 'Would send the digest (2 failed job(s), 1 missed run(s), 0 variable change(s)) to iam@corp.example.com.'
        }

        It 'calls the documented ARM operations with the documented filters' {
            Reset-TestState
            $null = Invoke-TestRun
            $arm = 'https://management.azure.com' + $accountPath
            (Get-TestRequests -PathLike '/subscriptions')[0].Uri | Should Be 'https://management.azure.com/subscriptions?api-version=2022-12-01'
            (Get-TestRequests -PathLike '*/schedules')[0].Uri | Should Be ($arm + '/schedules?api-version=2023-11-01')
            (Get-TestRequests -PathLike '*/jobSchedules')[0].Uri | Should Be ($arm + '/jobSchedules?api-version=2023-11-01')
            $jobLists = @(Get-TestRequests -PathLike '*/jobs')
            $jobLists.Count | Should Be 4
            (@($jobLists | ForEach-Object { $_.Filter }) -join ' | ') | Should Be "properties/startTime ge 2026-09-17T05:58:00.0000000Z | properties/status eq 'Failed' | properties/status eq 'Suspended' | properties/status eq 'Stopped'"
            $jobLists[0].Uri | Should Be ($arm + '/jobs?$filter=' + [Uri]::EscapeDataString('properties/startTime ge 2026-09-17T05:58:00.0000000Z') + '&api-version=2023-11-01')
            $jobLists[3].Uri | Should Be ($arm + '/jobs?$filter=' + [Uri]::EscapeDataString("properties/status eq 'Stopped'") + '&api-version=2023-11-01')
            $streamFilter = [Uri]::EscapeDataString("properties/streamType eq 'Error'")
            (Get-TestRequests -PathLike ('*/jobs/' + $ids.AlphaFailed + '/streams'))[0].Uri | Should Be ($arm + '/jobs/' + $ids.AlphaFailed + '/streams?$filter=' + $streamFilter + '&api-version=2023-11-01')
            (Get-TestRequests -PathLike ('*/jobs/' + $ids.DeltaStopped))[0].Uri | Should Be ($arm + '/jobs/' + $ids.DeltaStopped + '?api-version=2023-11-01')
            (Get-TestRequests -PathLike '*/variables/*')[0].Uri | Should Be ($arm + '/variables/JobWatch_AlertedJobIds?api-version=2023-11-01')
            $variableLists = @(Get-TestRequests -PathLike '*/variables')
            $variableLists.Count | Should Be 1
            $variableLists[0].Uri | Should Be ($arm + '/variables?api-version=2023-11-01')
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.WatcherFailed + '*')).Count | Should Be 0
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.EchoOld + '*')).Count | Should Be 0
            @(Get-TestRequests -PathLike '*/automationAccounts/aa-example-watch').Count | Should Be 0
            @($global:JwfRequests | Where-Object { $_.Auth -ne ('Bearer ' + $armToken) }).Count | Should Be 0
        }

        It 'saves the state first and then sends one digest when live' {
            Reset-TestState
            $s = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be 'PUT,POST'
            $posts = @(Get-TestRequests -Method 'POST')
            $puts = @(Get-TestRequests -Method 'PUT')

            $posts[0].Uri | Should Be 'https://graph.microsoft.com/v1.0/users/iam-noreply%40corp.example.com/sendMail'
            $posts[0].Auth | Should Be ('Bearer ' + $graphToken)
            $mail = ConvertFrom-Json -InputObject $posts[0].Body
            $mail.saveToSentItems | Should Be $false
            (@($mail.message.toRecipients | ForEach-Object { $_.emailAddress.address }) -join ',') | Should Be 'iam@corp.example.com,ops@corp.example.com'
            $mail.message.subject | Should Be 'Automation watch: aa-example-watch: 2 failed job(s), 1 missed run(s), 0 variable change(s)'
            $mail.message.body.contentType | Should Be 'HTML'
            $html = [string]$mail.message.body.content
            $html | Should Match 'Invoke-Alpha'
            $html | Should Match $ids.AlphaFailed
            $html | Should Match 'Insufficient privileges'
            $html | Should Match 'Invoke-Delta'
            $html | Should Match 'Stopped'
            $html | Should Match 'fair share'
            $html | Should Match '2026-09-17 09:05</td><td [^>]*>2026-09-17 12:05</td>'
            $html | Should Match 'Invoke-Bravo'
            $html | Should Match 'daily-0600'
            $html | Should Match '2026-09-17 06:00'
            $html.Contains($ids.WatcherFailed) | Should Be $false
            $html.Contains('Invoke-Echo') | Should Be $false
            $html.Contains('Invoke-Charlie') | Should Be $false
            $html.Contains('first error') | Should Be $false
            $html.Contains($graphToken) | Should Be $false

            $put = ConvertFrom-Json -InputObject $puts[0].Body
            $put.name | Should Be 'JobWatch_AlertedJobIds'
            $put.properties.isEncrypted | Should Be $false
            $put.properties.description | Should Match 'Watch-AutomationJobFailures'
            $stored = Get-StoredState -Request $puts[0]
            (@($stored.Keys | Sort-Object) -join ',') | Should Be ('job:{0},job:{1},missed:invoke-bravo|2026-09-17T06:00:00Z' -f $ids.AlphaFailed, $ids.DeltaStopped)
            $stored[('job:' + $ids.AlphaFailed)] | Should Be $now

            $s.DryRun | Should Be $false
            $s.Counts.SendDigest.Done | Should Be 1
            $s.Counts.SaveState.Done | Should Be 1
            $s.Counts.AlertFailedJob.Done | Should Be 2
            $s.Counts.AlertMissedRun.Done | Should Be 1
            $s.Counts.PSObject.Properties['RestoreState'] | Should BeNullOrEmpty
            $s.Planned | Should Be 0
            $s.StateEntries | Should Be 3
            $s.Errors | Should Be 0
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -eq 'Done: send the digest (2 failed job(s), 1 missed run(s), 0 variable change(s)) to iam@corp.example.com; ops@corp.example.com.' }).Count | Should Be 1
        }

        It 'stays silent on the next run because everything was reported' {
            Reset-TestState
            $null = Invoke-TestRun -Extra $live
            $global:JwfTenant.State | Should Match '"alerted"'
            $global:JwfRequests.Clear()

            $s = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be ''
            @(Get-TestRequests -PathLike '*/streams').Count | Should Be 0
            $s.Clean | Should Be $true
            $s.FailedJobs | Should Be 0
            $s.MissedRuns | Should Be 0
            $s.AlreadyReported | Should Be 3
            $s.Planned | Should Be 0
            $s.Done | Should Be 0
            $s.Warnings | Should Be 0
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'Clean: *' }).Count | Should Be 1
        }

        It 'reports another variable of the account changed inside the window, once, with no value' {
            Reset-TestState -Clean
            $global:JwfTenant.Variables = @(
                (New-TestVariable -Name 'PimPolicy_EntraBaseline' -LastModified '2026-09-17T11:40:00+00:00'),
                (New-TestVariable -Name 'AuthMethods_Fido2' -LastModified '2026-09-17T12:05:00+00:00' -Created '2026-09-17T12:05:00+00:00'),
                # Older than the window, and the watcher's own state: neither is
                # a finding.
                (New-TestVariable -Name 'PimPolicy_AzureBaseline' -LastModified '2026-09-16T09:00:00+00:00'),
                (New-TestVariable -Name 'JobWatch_AlertedJobIds' -LastModified '2026-09-17T12:09:00+00:00')
            )
            $s = Invoke-TestRun -Extra $live
            $s.VariableChanges | Should Be 2
            (@($s.VariablesChanged | Sort-Object) -join ',') | Should Be 'AuthMethods_Fido2,PimPolicy_EntraBaseline'
            $s.FailedJobs | Should Be 0
            $s.MissedRuns | Should Be 0
            $s.Clean | Should Be $false
            $s.Counts.AlertVariableChange.Done | Should Be 2
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Automation variable "PimPolicy_EntraBaseline" was changed at 2026-09-17T11:40:00Z.*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Automation variable "AuthMethods_Fido2" was created at 2026-09-17T12:05:00Z.*' }).Count | Should Be 1

            $mail = ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body
            $mail.message.subject | Should Be 'Automation watch: aa-example-watch: 0 failed job(s), 0 missed run(s), 2 variable change(s)'
            $html = [string]$mail.message.body.content
            $html | Should Match 'Automation variables changed in the last 70 minutes'
            $html | Should Match 'PimPolicy_EntraBaseline'
            $html | Should Match 'AuthMethods_Fido2'
            $html.Contains('PimPolicy_AzureBaseline') | Should Be $false
            $html.Contains('JobWatch_AlertedJobIds</td>') | Should Be $false
            $html.Contains('desired state') | Should Be $true

            # Reported once: the same change is not mailed again.
            $global:JwfRequests.Clear()
            $again = Invoke-TestRun -Extra $live
            $again.VariableChanges | Should Be 0
            $again.AlreadyReported | Should Be 2
            (Get-WriteSequence) | Should Be ''
        }

        It 'carries on and records a failure when the variables cannot be listed' {
            Reset-TestState
            $global:JwfTenant.VariableListStatus = 403
            $s = Invoke-TestRun -Extra $live
            $s.VariableChanges | Should Be 0
            # The failed jobs are still reported: detection that cannot run
            # does not silence the alerting the runbook exists for.
            $s.FailedJobs | Should Be 2
            $s.MissedRuns | Should Be 1
            $s.Counts.ListVariables.Failed | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'The account''s variables could not be listed*403*' }).Count | Should Be 1
            @(Get-TestRequests -Method 'POST').Count | Should Be 1
        }

        It 'reports a new hourly miss an hour later without repeating the old findings' {
            Reset-TestState
            $null = Invoke-TestRun -Extra $live
            $global:JwfRequests.Clear()

            $s = Invoke-TestRun -Extra ($live + @{ Now = $now.AddHours(1) })
            # The Alpha failure fell out of the window. The Delta stop (12:05)
            # and the Bravo miss are still inside it and were reported.
            $s.MissedRuns | Should Be 1
            $s.FailedJobs | Should Be 0
            $s.AlreadyReported | Should Be 2
            $mail = ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body
            $mail.message.subject | Should Be 'Automation watch: aa-example-watch: 0 failed job(s), 1 missed run(s), 0 variable change(s)'
            $stored = Get-StoredState -Request (Get-TestRequests -Method 'PUT')[0]
            $stored.ContainsKey('missed:invoke-alpha|2026-09-17T12:00:00Z') | Should Be $true
            $stored.Count | Should Be 4
        }

        It 'reports a job that ran for three hours and was stopped inside the window, even when only the status list returns it' {
            Reset-TestState
            $global:JwfTenant.JobSchedules = @($global:JwfTenant.JobSchedules | Where-Object { $_.name -ne 'js-bravo' })
            $s = Invoke-TestRun -Extra @{ MaxJobRuntimeMinutes = 0 }
            $startList = (Get-TestRequests -PathLike '*/jobs')[0]
            $startList.Filter | Should Be 'properties/startTime ge 2026-09-17T10:58:00.0000000Z'
            (@($startList.Returned) -contains $ids.DeltaStopped) | Should Be $false
            $s.FailedJobs | Should Be 2
            $s.JobsScanned | Should Be 4
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Failed job: runbook "Invoke-Delta" is Stopped since 2026-09-17T12:05:00Z (started 2026-09-17T09:05:00Z)*' }).Count | Should Be 1
        }

        It 'reaches back MaxJobRuntimeMinutes before the window with the start-time list' {
            Reset-TestState
            $s = Invoke-TestRun -Extra @{ MaxJobRuntimeMinutes = 600 }
            (Get-TestRequests -PathLike '*/jobs')[0].Filter | Should Be 'properties/startTime ge 2026-09-17T01:00:00.0000000Z'
            $s.JobListStartUtc | Should Be '2026-09-17T01:00:00Z'
            $s.WindowStartUtc | Should Be '2026-09-17T11:00:00Z'
            $s.FailedJobs | Should Be 2
        }

        It 'reports a job that was running at one run and failed before the next, exactly once' {
            Reset-TestState -Clean
            $global:JwfTenant.Jobs = @($global:JwfTenant.Jobs) + @(New-TestJob -JobId $ids.LongRun -Runbook 'Invoke-Golf' -Status 'Running' -Start (New-Utc 2026 9 17 11 50))
            $first = Invoke-TestRun -Extra $live
            $first.FailedJobs | Should Be 0
            (Get-WriteSequence) | Should Be ''

            $global:JwfTenant.Jobs = @(@($global:JwfTenant.Jobs | Where-Object { $_.name -ne $ids.LongRun }) + @(New-TestJob -JobId $ids.LongRun -Runbook 'Invoke-Golf' -Status 'Failed' -Start (New-Utc 2026 9 17 11 50) -End (New-Utc 2026 9 17 12 40)))
            $global:JwfRequests.Clear()
            $second = Invoke-TestRun -Extra ($live + @{ Now = $now.AddHours(1) })
            $second.FailedJobs | Should Be 1
            $html = [string](ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body).message.body.content
            $html | Should Match $ids.LongRun
            $html | Should Match '2026-09-17 11:50</td><td [^>]*>2026-09-17 12:40</td>'

            # 13:40: the 12:40 failure is still inside the 70-minute window.
            $global:JwfRequests.Clear()
            $third = Invoke-TestRun -Extra ($live + @{ Now = $now.AddMinutes(90) })
            $third.FailedJobs | Should Be 0
            $third.AlreadyReported | Should BeGreaterThan 0
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.LongRun + '*')).Count | Should Be 0
            ($first.FailedJobs + $second.FailedJobs + $third.FailedJobs) | Should Be 1
        }

        It 'reports a stopped job that never started, which the start-time list cannot return' {
            Reset-TestState
            $global:JwfTenant.Jobs = @($global:JwfTenant.Jobs) + @(New-TestJob -JobId $ids.NeverStarted -Runbook 'Invoke-Hotel' -Status 'Stopped' -Created (New-Utc 2026 9 17 11 20) -LastModified (New-Utc 2026 9 17 11 25))
            $s = Invoke-TestRun -Extra $live
            $s.FailedJobs | Should Be 3
            $startList = (Get-TestRequests -PathLike '*/jobs')[0]
            $startList.Filter | Should Match '^properties/startTime ge '
            (@($startList.Returned) -contains $ids.NeverStarted) | Should Be $false
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like ('Failed job: runbook "Invoke-Hotel" is Stopped since 2026-09-17T11:25:00Z (never started), job {0}.*' -f $ids.NeverStarted) }).Count | Should Be 1
            $html = [string](ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body).message.body.content
            $html | Should Match 'Invoke-Hotel</td><td [^>]*>Stopped</td><td [^>]*>\(not started\)</td><td [^>]*>2026-09-17 11:25</td>'
            (Get-StoredState -Request (Get-TestRequests -Method 'PUT')[0]).ContainsKey(('job:' + $ids.NeverStarted)) | Should Be $true
        }

        It 'makes no write at all when clean and nothing is stored' {
            Reset-TestState -Clean
            $s = Invoke-TestRun -Extra $live
            $global:JwfRequests.Count | Should BeGreaterThan 0
            (Get-WriteSequence) | Should Be ''
            $s.Clean | Should Be $true
            $s.Planned | Should Be 0
            $s.Done | Should Be 0
            $s.StateEntries | Should Be 0
            $s.Warnings | Should Be 0
            $s.Errors | Should Be 0
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'State variable "JobWatch_AlertedJobIds" does not exist yet*' }).Count | Should Be 1
        }

        It 'prunes old entries without sending anything' {
            Reset-TestState -Clean
            $global:JwfTenant.State = New-StateText -Entries @{ 'job:expired-entry' = $now.AddHours(-49); ('job:' + $ids.AlphaFailed) = $now.AddHours(-1) }
            $s = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be 'PUT'
            $stored = Get-StoredState -Request (Get-TestRequests -Method 'PUT')[0]
            (@($stored.Keys) -join ',') | Should Be ('job:' + $ids.AlphaFailed)
            $s.Clean | Should Be $true
            $s.StatePruned | Should Be 1
            $s.Counts.SaveState.Done | Should Be 1
            $s.Counts.PSObject.Properties['SendDigest'] | Should BeNullOrEmpty
        }

        It 'excludes configured runbooks and the running watcher under another name' {
            Reset-TestState
            $global:JwfTenant.Jobs = @($global:JwfTenant.Jobs) + @(New-TestJob -JobId $ids.Renamed -Runbook 'Watch-Renamed' -Status 'Failed' -Start (New-Utc 2026 9 17 11 20) -End (New-Utc 2026 9 17 11 21))
            $s = Invoke-TestRun -Extra @{ ExcludeRunbookNames = 'Invoke-Alpha; Invoke-Bravo'; CurrentJobId = $ids.Renamed }
            $s.FailedJobs | Should Be 1
            $s.MissedRuns | Should Be 0
            (@($s.ExcludedRunbooks) -join ',') | Should Be 'Watch-AutomationJobFailures,Invoke-Alpha,Invoke-Bravo,Watch-Renamed'
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.AlphaFailed + '*')).Count | Should Be 0
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.Renamed + '*')).Count | Should Be 0
            @(Get-TestRequests -PathLike ('*/jobs/' + $ids.DeltaStopped + '*')).Count | Should Be 2
        }

        It 'reads both lists in the semicolon form a schedule carries' {
            Reset-TestState
            $s = Invoke-TestRun -Extra @{ DryRun = $false; SenderMailbox = 'iam-noreply@corp.example.com'; Recipients = ' iam@corp.example.com ; ops@corp.example.com;'; ExcludeRunbookNames = 'Invoke-Delta;Invoke_Kilo-2;' }
            $s.Errors | Should Be 0
            $s.FailedJobs | Should Be 1
            $s.MissedRuns | Should Be 1
            (@($s.ExcludedRunbooks) -join ',') | Should Be 'Watch-AutomationJobFailures,Invoke-Delta,Invoke_Kilo-2'
            $mail = ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body
            (@($mail.message.toRecipients | ForEach-Object { $_.emailAddress.address }) -join ',') | Should Be 'iam@corp.example.com,ops@corp.example.com'
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like '*recipients iam@corp.example.com; ops@corp.example.com.' }).Count | Should Be 1
        }

        It 'refuses, before any request, a list that did not arrive in the semicolon form' {
            Reset-TestState
            # What a JSON array bound to [string] turns into: the elements joined by spaces.
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = 'Invoke-Alpha Invoke-Bravo' } } | Should Throw 'ExcludeRunbookNames: "Invoke-Alpha Invoke-Bravo" is not a runbook name'
            { Invoke-TestRun -Extra @{ Recipients = 'iam@corp.example.com ops@corp.example.com' } } | Should Throw 'Recipients: "iam@corp.example.com ops@corp.example.com" is not a mail address. Separate addresses with semicolons.'
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = '@{name=Invoke-Alpha}' } } | Should Throw 'is not a runbook name'
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = 'Invoke-Alpha;9-Invoke' } } | Should Throw 'ExcludeRunbookNames: "9-Invoke" is not a runbook name'
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = ('I' + ('x' * 63)) } } | Should Throw 'is not a runbook name'
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = 'Invoke.Alpha' } } | Should Throw 'Separate names with semicolons'
            $global:JwfRequests.Count | Should Be 0
            $s = Invoke-TestRun -Extra @{ ExcludeRunbookNames = ('I' + ('x' * 62)) }
            @($s.ExcludedRunbooks)[1].Length | Should Be 63
        }

        It 'still reads a JSON array in a local run' {
            Reset-TestState
            $s = Invoke-TestRun -Extra @{ ExcludeRunbookNames = '["Invoke-Delta"]'; Recipients = '["iam@corp.example.com","ops@corp.example.com"]' }
            $s.FailedJobs | Should Be 1
            $s.MissedRuns | Should Be 1
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -eq 'Would send the digest (1 failed job(s), 1 missed run(s), 0 variable change(s)) to iam@corp.example.com; ops@corp.example.com.' }).Count | Should Be 1
            { Invoke-TestRun -Extra @{ ExcludeRunbookNames = '["Invoke-Delta"' } } | Should Throw 'ExcludeRunbookNames'
        }

        It 'still reports a missed run whose schedule was changed after it was due, and says so' {
            Reset-TestState
            $global:JwfTenant.Schedules[1].properties.lastModifiedTime = '2026-09-17T09:00:00+00:00'
            $s = Invoke-TestRun -Extra $live
            $s.MissedRuns | Should Be 1
            (Get-WriteSequence) | Should Be 'PUT,POST'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -eq 'Missed run: runbook "Invoke-Bravo" was due at 2026-09-17T06:00:00Z on schedule "daily-0600" and no job has started since. The schedule changed at 2026-09-17T09:00:00Z, after this run was due; if that change enabled it, no run was due.' }).Count | Should Be 1
            $html = [string](ConvertFrom-Json -InputObject (Get-TestRequests -Method 'POST')[0].Body).message.body.content
            $html | Should Match 'Etc/UTC</td><td [^>]*>Schedule changed 2026-09-17 09:00 UTC, after this run was due\.'
            @($s.Items | Where-Object { $_.Action -eq 'AlertMissedRun' })[0].Detail | Should Be 'due 2026-09-17T06:00:00Z on schedule daily-0600, schedule changed 2026-09-17T09:00:00Z'
            (Get-StoredState -Request (Get-TestRequests -Method 'PUT')[0]).ContainsKey('missed:invoke-bravo|2026-09-17T06:00:00Z') | Should Be $true

            $global:JwfRequests.Clear()
            $next = Invoke-TestRun -Extra ($live + @{ Now = $now.AddMinutes(10) })
            $next.MissedRuns | Should Be 0
            (Get-WriteSequence) | Should Be ''
        }

        It 'has no note on a missed run whose schedule last changed before it was due' {
            Reset-TestState
            $s = Invoke-TestRun
            $s.MissedRuns | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -eq 'Missed run: runbook "Invoke-Bravo" was due at 2026-09-17T06:00:00Z on schedule "daily-0600" and no job has started since.' }).Count | Should Be 1
            @($s.Items | Where-Object { $_.Action -eq 'AlertMissedRun' })[0].Detail | Should Be 'due 2026-09-17T06:00:00Z on schedule daily-0600'
        }

        It 'refuses a live run without recipients or sender before any request' {
            Reset-TestState
            { Invoke-TestRun -Extra @{ DryRun = $false; SenderMailbox = 'iam-noreply@corp.example.com' } } | Should Throw 'Recipients is required for a live run: the watcher must be able to send its digest. Pass the addresses separated by semicolons.'
            { Invoke-TestRun -Extra @{ DryRun = $false; Recipients = 'iam@corp.example.com' } } | Should Throw 'SenderMailbox is required'
            { Invoke-TestRun -Extra @{ Recipients = 'iam@corp.example.com, not-an-address' } } | Should Throw 'is not a mail address'
            { Invoke-TestRun -Extra @{ SenderMailbox = 'no-at-sign' } } | Should Throw 'is not a mail address'
            $global:JwfRequests.Count | Should Be 0
        }

        It 'fails with a clear message when the account does not exist' {
            Reset-TestState
            $global:JwfTenant.AccountMissing = $true
            { Invoke-TestRun } | Should Throw 'Automation account "aa-example-watch" was not found in resource group "rg-example-automation"'
            @(Get-TestRequests -PathLike '*/jobs').Count | Should Be 0
        }

        It 'puts the previous state back when the digest cannot be sent, so the next run sends it' {
            Reset-TestState
            $previous = New-StateText -Entries @{ 'job:earlier-entry' = $now.AddHours(-2) }
            $global:JwfTenant.State = $previous
            $global:JwfTenant.MailStatus = 403
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'sendMail failed with HTTP 403'
            (Get-WriteSequence) | Should Be 'PUT,POST,PUT'
            $puts = @(Get-TestRequests -Method 'PUT')
            (Get-StoredState -Request $puts[0]).Count | Should Be 4
            (@((Get-StoredState -Request $puts[1]).Keys) -join ',') | Should Be 'job:earlier-entry'
            $global:JwfTenant.State | Should Be $previous
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Failed: send the digest*HTTP 403*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Done: put back Automation variable "JobWatch_AlertedJobIds" as it was before this run (1 reported key(s))*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'The digest was not sent*' }).Count | Should Be 0

            $global:JwfTenant.MailStatus = 202
            $global:JwfRequests.Clear()
            $s = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be 'PUT,POST'
            $s.FailedJobs | Should Be 2
            $s.MissedRuns | Should Be 1
            $s.Errors | Should Be 0
        }

        It 'puts back an empty state when there was no variable before the failed digest' {
            Reset-TestState
            $global:JwfTenant.MailStatus = 403
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'HTTP 403'
            (Get-WriteSequence) | Should Be 'PUT,POST,PUT'
            $global:JwfTenant.State | Should Be '{"version":1,"alerted":[]}'
        }

        # Graph may have sent a mail that answered 503, so the library does
        # not repeat it; the watcher still puts the state back, preferring a
        # possible second digest to a lost one.
        It 'does not repeat the digest after a server error, puts the state back, and sends on the next run' {
            Reset-TestState
            $global:JwfTenant.MailStatus = 503
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'sendMail failed with HTTP 503 after 1 attempt(s)'
            (Get-WriteSequence) | Should Be 'PUT,POST,PUT'
            @(Get-TestRequests -Method 'POST').Count | Should Be 1
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Failed: send the digest*HTTP 503*POST is not repeated automatically after a server error or a lost response*' }).Count | Should Be 1
            $global:JwfTenant.State | Should Be '{"version":1,"alerted":[]}'
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It

            $global:JwfTenant.MailStatus = 202
            $global:JwfRequests.Clear()
            $s = Invoke-TestRun -Extra $live
            (Get-WriteSequence) | Should Be 'PUT,POST'
            $s.FailedJobs | Should Be 2
            $s.Errors | Should Be 0
        }

        It 'sends nothing, hour after hour, while the state cannot be saved' {
            Reset-TestState
            $global:JwfTenant.StatePutStatus = 403
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'HTTP 403'
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Failed: update Automation variable "JobWatch_AlertedJobIds"*HTTP 403*variables/write*' }).Count | Should Be 1
            { Invoke-TestRun -Extra ($live + @{ Now = $now.AddHours(1) }) 2>$null } | Should Throw 'HTTP 403'
            (Get-WriteSequence) | Should Be 'PUT,PUT'
            @(Get-TestRequests -Method 'POST').Count | Should Be 0
        }

        It 'logs the lost digest when neither the mail nor the put-back succeeds' {
            Reset-TestState
            $global:JwfTenant.MailStatus = 403
            $global:JwfTenant.StatePutStatus = 403
            $global:JwfTenant.StatePutFailAfter = 1
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'sendMail failed with HTTP 403'
            (Get-WriteSequence) | Should Be 'PUT,POST,PUT'
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Failed: put back Automation variable*' }).Count | Should Be 1
            $lost = @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'The digest was not sent and the state could not be put back, so 3 finding(s) are recorded as reported*' })
            $lost.Count | Should Be 1
            $lost[0].Message | Should Match ('job:' + $ids.AlphaFailed)
            $lost[0].Message | Should Match 'missed:invoke-bravo'
        }

        It 'stops when the state variable is encrypted' {
            Reset-TestState
            $global:JwfTenant.State = 'hidden'
            $global:JwfTenant.StateEncrypted = $true
            { Invoke-TestRun -Extra $live } | Should Throw 'is encrypted'
            (Get-WriteSequence) | Should Be ''
        }

        It 'starts from an empty state, with a warning, when the variable holds something else' {
            Reset-TestState
            $global:JwfTenant.State = 'not the watcher state'
            $s = Invoke-TestRun
            $s.FailedJobs | Should Be 2
            $s.MissedRuns | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'State variable "JobWatch_AlertedJobIds" could not be read*' }).Count | Should Be 1
        }

        It 'reads the latest error record by time in full when the list carries no summary' {
            Reset-TestState
            $later = New-TestStream -JobId $ids.AlphaFailed -Sequence 9 -Time (New-Utc 2026 9 17 11 1) -Summary $null
            $earlier = New-TestStream -JobId $ids.AlphaFailed -Sequence 8 -Time (New-Utc 2026 9 17 11 0 40) -Summary $null
            $global:JwfTenant.Streams[$ids.AlphaFailed] = @($later, $earlier)
            $global:JwfTenant.StreamRecords[[string]$later.properties.jobStreamId] = New-TestStream -JobId $ids.AlphaFailed -Sequence 9 -Time (New-Utc 2026 9 17 11 1) -Summary $null -Text 'Exception: terminating error from the full record.'
            $global:JwfTenant.StreamRecords[[string]$earlier.properties.jobStreamId] = New-TestStream -JobId $ids.AlphaFailed -Sequence 8 -Time (New-Utc 2026 9 17 11 0 40) -Summary $null -Text 'An earlier error.'
            $null = Invoke-TestRun
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Failed job: runbook "Invoke-Alpha"*terminating error from the full record.' }).Count | Should Be 1
            @(Get-TestRequests -PathLike ('*/streams/' + $earlier.properties.jobStreamId)).Count | Should Be 0
        }

        It 'follows the error stream to its second page for the error that ended the job' {
            Reset-TestState
            $global:JwfTenant.Streams.Remove($ids.AlphaFailed)
            $firstPage = @(1, 2, 3 | ForEach-Object { New-TestStream -JobId $ids.AlphaFailed -Sequence $_ -Time (New-Utc 2026 9 17 11 0 (10 * $_)) -Summary ('early error ' + $_) })
            $secondPage = @(New-TestStream -JobId $ids.AlphaFailed -Sequence 4 -Time (New-Utc 2026 9 17 11 1 5) -Summary 'terminating error on page two')
            $pages = New-Object System.Collections.ArrayList
            [void]$pages.Add($firstPage)
            [void]$pages.Add($secondPage)
            $global:JwfTenant.StreamPages[$ids.AlphaFailed] = $pages
            $null = Invoke-TestRun
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Failed job: runbook "Invoke-Alpha"*early error 2 | early error 3 | terminating error on page two' }).Count | Should Be 1
            $streamCalls = @(Get-TestRequests -PathLike ('*/jobs/' + $ids.AlphaFailed + '/streams'))
            $streamCalls.Count | Should Be 2
            $streamCalls[1].Uri | Should Match '&\$skiptoken=1$'

            $global:JwfRequests.Clear()
            Get-JobErrorSummary -AccountPath $accountPath -JobId $ids.AlphaFailed -MaxPages 1 | Should Be 'early error 1 | early error 2 | early error 3'
            @(Get-TestRequests -PathLike '*/streams').Count | Should Be 1
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'The error stream of job 11111111* has more than 1 pages*' }).Count | Should Be 1
        }

        It 'reports a failed job even when its error output cannot be read' {
            Reset-TestState
            $global:JwfTenant.JobDetails = @{}
            $s = Invoke-TestRun
            $s.FailedJobs | Should Be 2
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Could not read job 55555555*HTTP 404*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Failed job: runbook "Invoke-Delta"*(error output could not be read)' }).Count | Should Be 1
        }

        It 'warns about and skips a schedule the scheduler disagrees with' {
            Reset-TestState
            $global:JwfTenant.Schedules[1].properties.nextRun = '2026-09-18T07:00:00+00:00'
            $s = Invoke-TestRun
            $s.MissedRuns | Should Be 0
            $s.SchedulesJudged | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Schedule "daily-0600": the scheduler reports its next run at 2026-09-18T07:00:00Z*not judged*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'Heartbeat: 1 scheduled runbook link(s) judged, skipped: Disabled=1 Excluded=1 NextRunMismatch=1.' }).Count | Should Be 1
        }

        It 'uses the US Government endpoints' {
            Reset-TestState
            $null = Invoke-TestRun -Extra ($live + @{ Environment = 'USGov' })
            $hosts = @($global:JwfRequests | ForEach-Object { $_.Host } | Sort-Object -Unique)
            ($hosts -join ',') | Should Be 'graph.microsoft.us,management.usgovcloudapi.net'
            (Get-TestRequests -Method 'POST')[0].Uri | Should Be 'https://graph.microsoft.us/v1.0/users/iam-noreply%40corp.example.com/sendMail'
        }

        It 'uses a subscription id without listing subscriptions' {
            Reset-TestState
            $s = Invoke-TestRun -Extra @{ SubscriptionName = $subscriptionId }
            @(Get-TestRequests -PathLike '/subscriptions').Count | Should Be 0
            (Get-TestRequests -PathLike '*/jobs')[0].Path | Should Be ($accountPath + '/jobs')
            $s.FailedJobs | Should Be 2
        }

        It 'fails when the subscription name is unknown' {
            Reset-TestState
            { Invoke-TestRun -Extra @{ SubscriptionName = 'Some Other Subscription' } } | Should Throw 'was not found'
            @(Get-TestRequests -PathLike '*/jobs').Count | Should Be 0
        }

        It 'never writes the access tokens' {
            Reset-TestState
            $s = Invoke-TestRun -Extra $live
            $logText = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
            $logText.Contains($armToken) | Should Be $false
            $logText.Contains($graphToken) | Should Be $false
            $logText | Should Match 'caller-supplied token'
            $summaryJson = ConvertTo-Json -InputObject $s -Depth 8
            $summaryJson.Contains($armToken) | Should Be $false
            $summaryJson.Contains($graphToken) | Should Be $false
            foreach ($request in @($global:JwfRequests | Where-Object { $null -ne $_.Body })) {
                ([string]$request.Body).Contains($armToken) | Should Be $false
                ([string]$request.Body).Contains($graphToken) | Should Be $false
            }
        }

        It 'emits one summary object whose standard fields come first' {
            Reset-TestState
            $out = @(Invoke-TestRun)
            $out.Count | Should Be 1
            (@($out[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should Match '^RunId,Runbook,DryRun,Environment,StartedUtc,CompletedUtc,DurationSeconds,Counts,Planned,Done,Failed,Skipped,ItemCount,FailureCount,Items,ItemsTruncated,Failures,Warnings,Errors,AutomationAccount,'
        }
    }

    # Its own context: a Pester 3.4 mock made inside an It stays in force for
    # the rest of the enclosing context.
    Context 'write bound, checked before the first write' {
        Mock Test-CircuitBreaker { throw 'Circuit breaker tripped: test' }

        It 'asserts the bound of three writes before the state update and the digest' {
            Reset-TestState
            { Invoke-TestRun -Extra $live } | Should Throw 'Circuit breaker tripped'
            Assert-MockCalled Test-CircuitBreaker -Exactly 1 -Scope It -ParameterFilter { $Planned -eq 3 -and $Cap -eq 3 }
            (Get-WriteSequence) | Should Be ''
        }

        It 'counts one write when only pruning is due' {
            Reset-TestState -Clean
            $global:JwfTenant.State = New-StateText -Entries @{ 'job:expired-entry' = $now.AddHours(-49) }
            { Invoke-TestRun -Extra $live } | Should Throw 'Circuit breaker tripped'
            Assert-MockCalled Test-CircuitBreaker -Exactly 1 -Scope It -ParameterFilter { $Planned -eq 1 -and $Cap -eq 3 }
            (Get-WriteSequence) | Should Be ''
        }

        It 'asserts the bound in a dry run too' {
            Reset-TestState
            { Invoke-TestRun } | Should Throw 'Circuit breaker tripped'
            Assert-MockCalled Test-CircuitBreaker -Exactly 1 -Scope It -ParameterFilter { $Planned -eq 3 -and $Cap -eq 3 }
        }
    }

    Context 'write bound, with the real breaker' {
        $global:JwfBreakerCalls = New-Object System.Collections.ArrayList
        Mock Test-CircuitBreaker {
            [void]$global:JwfBreakerCalls.Add([PSCustomObject]@{ Planned = $Planned; Cap = $Cap })
            & $global:JwfRealBreaker -Planned $Planned -Cap $Cap -Label $Label
        }

        It 'passes the real breaker at the bound, which one more write would trip' {
            $global:JwfRealBreaker.ToString() | Should Match 'Circuit breaker tripped: \{0\}'
            $global:JwfRealBreaker.ToString().Contains('Invoke-Mock') | Should Be $false
            Reset-TestState
            $global:JwfBreakerCalls.Clear()
            $s = Invoke-TestRun -Extra $live
            $s.Errors | Should Be 0
            (Get-WriteSequence) | Should Be 'PUT,POST'
            $global:JwfBreakerCalls.Count | Should Be 1
            $global:JwfBreakerCalls[0].Planned | Should Be 3
            $global:JwfBreakerCalls[0].Cap | Should Be 3
            { & $global:JwfRealBreaker -Planned 4 -Cap 3 -Label 'watcher writes' } | Should Throw 'Circuit breaker tripped: watcher writes: 4 planned, cap is 3'
        }

        It 'passes the real breaker when the digest fails and the state is put back' {
            Reset-TestState
            $global:JwfBreakerCalls.Clear()
            $global:JwfTenant.MailStatus = 403
            { Invoke-TestRun -Extra $live 2>$null } | Should Throw 'HTTP 403'
            (Get-WriteSequence) | Should Be 'PUT,POST,PUT'
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Circuit breaker*' }).Count | Should Be 0
            $global:JwfBreakerCalls.Count | Should Be 1
        }

        Remove-Variable -Name JwfBreakerCalls -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'runbook file contract' {
        $begin = '# INLINE_LIBRARY_BEGIN'
        $end = '# INLINE_LIBRARY_END'
        $runbookText = [System.IO.File]::ReadAllText($runbook)
        $libraryText = [System.IO.File]::ReadAllText($library)
        $parseTokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($runbookText, [ref]$parseTokens, [ref]$parseErrors)
        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $parameters = @($ast.ParamBlock.Parameters)

        Mock Invoke-WebRequest {
            $sent = $null
            if ($null -ne $Body) {
                if ($Body -is [byte[]]) { $sent = [System.Text.Encoding]::UTF8.GetString($Body) } else { $sent = [string]$Body }
            }
            $target = [string]$Uri
            if ($Uri -is [Uri]) { $target = $Uri.AbsoluteUri }
            $answer = Get-JwfTestResponse -Method ([string]$Method).ToUpperInvariant() -Uri $target -Body $sent -RequestHeaders $Headers
            return [PSCustomObject]@{ StatusCode = $answer.StatusCode; Headers = $answer.Headers; Content = $answer.Content }
        }

        It 'is ASCII with no byte order mark and no long dashes' {
            $bytes = [System.IO.File]::ReadAllBytes($runbook)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            $runbookText.Contains([string][char]0x2013) | Should Be $false
            $runbookText.Contains([string][char]0x2014) | Should Be $false
            $testBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $here -ChildPath 'Watch-AutomationJobFailures.Tests.ps1'))
            @($testBytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        }

        It 'parses without errors' {
            @($parseErrors).Count | Should Be 0
        }

        It 'carries each library marker exactly once, around the dot-source line' {
            $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
            $lines = @($begin, ". (Join-Path -Path `$PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')", $end)
            $pattern = '(?m)^' + ((@($lines | ForEach-Object { [regex]::Escape($_) })) -join '\r?\n') + '\r?$'
            $runbookText | Should Match $pattern
            $runbookText.IndexOf($begin) | Should BeGreaterThan $runbookText.IndexOf("`$VerbosePreference = 'Continue'")
        }

        It 'uses the same marker strings as the runbooks module' {
            $moduleText = [System.IO.File]::ReadAllText($runbooksModule)
            $moduleText.Contains(('library_begin = "{0}"' -f $begin)) | Should Be $true
            $moduleText.Contains(('library_end   = "{0}"' -f $end)) | Should Be $true
        }

        It 'defines no function the library defines, and gives every function help' {
            $libraryErrors = $null
            $libraryTokens = $null
            $libraryAst = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$libraryTokens, [ref]$libraryErrors)
            $libraryNames = @($libraryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            # No exact count: it changes with every library version. The names
            # below prove the scan reached the current library.
            $libraryNames.Count | Should BeGreaterThan 40
            foreach ($known in @('Invoke-CloudRequest', 'Get-AutomationStringVariable', 'Test-RunbookJsonObject', 'Assert-StorageBlobName', 'Resolve-RunbookOutFile')) {
                ($libraryNames -contains $known) | Should Be $true
            }
            $clashes = @($functions | Where-Object { $libraryNames -contains $_.Name } | ForEach-Object { $_.Name })
            ($clashes -join ', ') | Should Be ''
            $functions.Count | Should BeGreaterThan 20
            $missing = @($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name })
            ($missing -join ', ') | Should Be ''
        }

        It 'binds only bool, int, and string parameters, with DryRun on by default' {
            $names = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($names -join ',') | Should Be 'AutomationAccountName,ResourceGroupName,SubscriptionName,LookbackMinutes,MaxJobRuntimeMinutes,HeartbeatGraceMinutes,StateVariableName,ExcludeRunbookNames,Recipients,SenderMailbox,DryRun,Environment,ClientId,AccessToken,RunId'
            $wrong = @($parameters | Where-Object { @([bool], [int], [string]) -notcontains $_.StaticType } | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($wrong -join ', ') | Should Be ''
            $defaults = @{ DryRun = '$true'; LookbackMinutes = '70'; MaxJobRuntimeMinutes = '240'; HeartbeatGraceMinutes = '30'; StateVariableName = "'JobWatch_AlertedJobIds'" }
            foreach ($name in @($defaults.Keys)) {
                $parameter = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name })[0]
                $parameter.DefaultValue.Extent.Text | Should Be $defaults[$name]
            }
        }

        It 'passes every script parameter on to the run function' {
            $entry = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-WatchAutomationJobFailuresRun' }, $true))
            $entry.Count | Should Be 1
            $passed = @($entry[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
            $notPassed = @($parameters | Where-Object { $passed -notcontains $_.Name.VariablePath.UserPath } | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($notPassed -join ', ') | Should Be ''
        }

        It 'documents every parameter, the permissions, the schedule, the limits, and a local run with a token' {
            $help = $ast.GetHelpContent()
            $help | Should Not BeNullOrEmpty
            $documented = @($help.Parameters.Keys | ForEach-Object { ([string]$_).ToUpperInvariant() })
            $undocumented = @($parameters | Where-Object { $documented -notcontains $_.Name.VariablePath.UserPath.ToUpperInvariant() } | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($undocumented -join ', ') | Should Be ''
            (@($help.Examples) -join "`n") | Should Match '-AccessToken \$tokens'
            $help.Synopsis | Should Match 'who watches the automation'
            $help.Description | Should Match 'Completed and is invisible'
            $help.Description | Should Match 'DryRun defaults to \$true'
            $help.Description | Should Match 'not by when they started|not when it started'
            $help.Description | Should Match 'never started'
            $help.Description | Should Match 'at most three writes, by construction'
            $help.Description | Should Match 'The state is saved before the mail is sent'
            $help.Description | Should Match 'NextRunMismatch'
            $help.Description | Should Match 'TimeZoneUnknown'
            $help.Description | Should Match 'one-time\s+alert'
            $help.Description | Should Match 'flagged rather than\s+suppressed'
            $help.Description | Should Match 'not\s+through the sandbox''s Get-AutomationVariable'
            $help.Description | Should Match 'can arrive twice rather than not at\s+all'
            $help.Notes | Should Match "properties/status eq '<status>'"
            (@($help.Examples) -join "`n") | Should Not Match '\[\s*"'
            (@($help.Examples) -join "`n") | Should Match "-Recipients 'iam@corp\.example\.com;secops@corp\.example\.com'"

            $parameterHelp = @{}
            foreach ($key in @($help.Parameters.Keys)) { $parameterHelp[([string]$key).ToUpperInvariant()] = [string]$help.Parameters[$key] }
            $parameterHelp['LOOKBACKMINUTES'] | Should Match 'minute 45 of every hour'
            $parameterHelp['LOOKBACKMINUTES'] | Should Match 'minute 35 of the hour before'
            $parameterHelp['HEARTBEATGRACEMINUTES'] | Should Match '\(05:15\) at 05:45'
            $parameterHelp['EXCLUDERUNBOOKNAMES'] | Should Match 'separated by semicolons'
            $parameterHelp['EXCLUDERUNBOOKNAMES'] | Should Match '63 characters'
            $parameterHelp['RECIPIENTS'] | Should Match 'separated by\s+semicolons'
            $parameterHelp['RECIPIENTS'] | Should Not Match 'JSON array'
        }

        It 'documents the observer tier permissions: Reader and Automation Variable Writer on the account, and Mail.Send only' {
            $notes = [string]$ast.GetHelpContent().Notes
            $notes | Should Match 'observer tier identity'
            $notes | Should Match 'Mail\.Send only'
            $notes | Should Match 'Exchange Online application access policy'
            $notes | Should Match 'both assignments on the Automation account and nowhere\s+else'
            $notes | Should Match 'Reader, for every read'
            $notes | Should Match 'Automation Variable Writer, the custom role'
            $notes | Should Match 'watcher-reader-on-account and watcher-state-on-account'
            $notes | Should Match 'automationAccounts/variables/write'
            $notes | Should Match 'jobs/streams/read'
            $notes | Should Not Match 'automationAccounts/read'
            $notes | Should Not Match 'Automation Contributor'
            $notes | Should Not Match 'least privilege as a custom'

            # The cell grants exactly that pair to this runbook, and the
            # custom role holds only the two variables actions.
            $cellText = [System.IO.File]::ReadAllText($corpCell)
            $cellText | Should Match '(?ms)^\s*watcher-reader-on-account = \{\s*role_name\s*=\s*"Reader"\s*scope\s*=\s*\{ type = "automation_account" \}'
            $cellText | Should Match '(?ms)^\s*watcher-state-on-account = \{\s*role_name\s*=\s*"Automation Variable Writer"\s*scope\s*=\s*\{ type = "automation_account" \}'
            $rolesText = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-rbac-roles\terragrunt.hcl'))
            $roleBlock = [regex]::Match($rolesText, '(?s)name\s*=\s*"Automation Variable Writer".*?actions\s*=\s*\[(?<actions>[^\]]*)\]')
            $roleBlock.Success | Should Be $true
            $actions = @([regex]::Matches($roleBlock.Groups['actions'].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            ($actions -join ',') | Should Be 'Microsoft.Automation/automationAccounts/variables/read,Microsoft.Automation/automationAccounts/variables/write'
        }

        It 'states the schedule the corp cell gives it, and the lookback and grace the cell passes' {
            $notes = [string]$ast.GetHelpContent().Notes
            $cellText = [System.IO.File]::ReadAllText($corpCell)
            $schedule = [regex]::Match($cellText, '(?ms)^\s*hourly-45-utc = \{(?<body>.*?)^\s*\}')
            $schedule.Success | Should Be $true
            $body = $schedule.Groups['body'].Value
            $frequency = [regex]::Match($body, 'frequency\s*=\s*"([^"]+)"').Groups[1].Value
            $interval = [regex]::Match($body, 'interval\s*=\s*(\d+)').Groups[1].Value
            $zone = [regex]::Match($body, 'timezone\s*=\s*"([^"]+)"').Groups[1].Value
            $start = [regex]::Match($body, 'start_time\s*=\s*"([^"]+)"').Groups[1].Value
            ('{0}|{1}|{2}|{3}' -f $frequency, $interval, $zone, $start) | Should Be 'Hour|1|Etc/UTC|2027-01-04T00:45:00Z'
            $notes | Should Match ([regex]::Escape(('hourly-45-utc: frequency {0}, interval {1}, time zone {2},' -f $frequency, $interval, $zone)) + '\s+' + [regex]::Escape(('start time {0}' -f $start)))
            $notes | Should Match 'minute 45 of\s+every hour'
            $notes | Should Not Match 'quarter past the hour'

            $watch = [regex]::Match($cellText, '(?ms)^\s*job-failure-watch = \{(?<body>.*?)^    \}')
            $watch.Success | Should Be $true
            $watchBody = $watch.Groups['body'].Value
            $watchBody | Should Match 'schedule_key\s*=\s*"hourly-45-utc"'
            $watchBody | Should Match 'lookbackminutes\s*=\s*"70"'
            $watchBody | Should Match 'heartbeatgraceminutes\s*=\s*"30"'
            $watchBody | Should Match 'subscriptionname\s*=\s*"subscription_id"'
            $notes | Should Match 'LookbackMinutes 70 and HeartbeatGraceMinutes 30'
            # Every key the cell sets names a parameter of this runbook.
            $declared = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() })
            $keys = @([regex]::Matches($watchBody, '(?m)^\s*([a-z]+)\s*=\s*"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { @('name', 'file', 'library', 'description', 'schedule_key') -notcontains $_ })
            $keys += @([regex]::Matches($watchBody, '(?m)^\s*([a-z]+)\s*=\s*(jsonencode|join)\(') | ForEach-Object { $_.Groups[1].Value })
            $keys.Count | Should BeGreaterThan 5
            (@($keys | Where-Object { $declared -notcontains $_ }) -join ', ') | Should Be ''
        }

        It 'writes no Automation variable whose name is outside the JobWatch_ prefix' {
            # The identity's Automation Variable Writer role is account-wide,
            # so the prefix is what keeps this runbook's one write off the PIM
            # baselines and the AuthMethods_ desired state in the same account.
            Reset-TestState
            { Write-JobWatchState -AccountPath $accountPath -VariableName 'PimPolicy_EntraBaseline' -StateText '{"version":1,"alerted":[]}' } | Should Throw 'JobWatch_'
            { Write-JobWatchState -AccountPath $accountPath -VariableName 'AuthMethods_Fido2' -StateText '{"version":1,"alerted":[]}' } | Should Throw 'JobWatch_'
            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            { Write-JobWatchState -AccountPath $accountPath -VariableName 'JobWatch_AlertedJobIds' -StateText '{"version":1,"alerted":[]}' } | Should Not Throw

            # Every StateVariableName that is validated at all is validated
            # against the prefix, so a job schedule cannot bind another name.
            $declared = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'StateVariableName' }, $true) | ForEach-Object { $_.Extent.Text })
            $validated = @($declared | Where-Object { $_ -match 'ValidatePattern' })
            $validated.Count | Should Be 2
            @($validated | Where-Object { $_ -match 'ValidatePattern\(''\^JobWatch_' }).Count | Should Be 2
            $runbookText.Contains('^[A-Za-z0-9_-]{1,128}') | Should Be $false
        }

        It 'reports other variables of the account as a finding, with no value read' {
            Reset-TestState
            $accountVariables = @(
                (New-TestVariable -Name 'PimPolicy_EntraBaseline' -LastModified '2026-09-17T11:40:00+00:00'),
                (New-TestVariable -Name 'JobWatch_AlertedJobIds' -LastModified '2026-09-17T12:09:00+00:00'),
                (New-TestVariable -Name 'PimPolicy_AzureBaseline' -LastModified '2026-09-17T10:00:00+00:00')
            )
            $global:JwfTenant.Variables = $accountVariables
            $findings = @(Get-VariableChangeFindings -AccountPath $accountPath -WindowStartUtc $now.AddMinutes(-70) -StateVariableName 'JobWatch_AlertedJobIds')
            $findings.Count | Should Be 1
            $findings[0].VariableName | Should Be 'PimPolicy_EntraBaseline'
            $findings[0].Key | Should Be 'variable:pimpolicy_entrabaseline|2026-09-17T11:40:00Z'
            $findings[0].WasCreated | Should Be $false
            $findings[0].PSObject.Properties['Value'] | Should BeNullOrEmpty
            # Nothing is excluded by name except the state variable given.
            @(Get-VariableChangeFindings -AccountPath $accountPath -WindowStartUtc $now.AddMinutes(-70) -StateVariableName '').Count | Should Be 2
        }

        It 'keeps its state on ARM, with no sandbox variable cmdlet' {
            $sandbox = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and @('Get-AutomationVariable', 'Set-AutomationVariable', 'Get-AutomationStringVariable') -contains $node.GetCommandName() }, $true))
            $sandbox.Count | Should Be 0
            (Get-Command -Name Read-JobWatchState -CommandType Function).Definition | Should Match 'Invoke-CloudRequest -Api Arm -Uri \$uri'
            (Get-Command -Name Write-JobWatchState -CommandType Function).Definition | Should Match 'Invoke-CloudRequest -Api Arm -Method PUT -Uri \$uri'
        }

        It 'keeps to what Windows PowerShell 5.1 and Azure Automation accept' {
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Host' }, $true)).Count | Should Be 0
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'input' }, $true)).Count | Should Be 0
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [switch] }, $true)).Count | Should Be 0
            $ast.ScriptRequirements | Should BeNullOrEmpty
            $runbookText.Contains('??') | Should Be $false
            $runbookText | Should Match "(?m)^if \(\`$MyInvocation\.InvocationName -ne '\.'\) \{"
        }

        It 'wraps every list-returning call in @()' {
            $listCommands = @('ConvertTo-StringList', 'Get-TransitiveGroupMemberIds', 'Get-ManagementGroupDescendantSubscriptions', 'Get-RunLogEntries', 'Get-FailedJobFindings', 'Select-NewFindings', 'Get-JobWatchExclusions', 'Get-MonthOccurrenceDays', 'Merge-JobWatchJobs', 'Sort-JobWatchStreams')
            $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object {
                    $name = $_.GetCommandName()
                    ($listCommands -contains $name) -or ($name -eq 'Invoke-CloudRequest' -and @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'AllPages' }).Count -gt 0)
                })
            $calls.Count | Should BeGreaterThan 10
            $bare = @($calls | Where-Object {
                    $pipeline = $_.Parent
                    $block = $null
                    if ($null -ne $pipeline) { $block = $pipeline.Parent }
                    $outer = $null
                    if ($null -ne $block) { $outer = $block.Parent }
                    -not ($outer -is [System.Management.Automation.Language.ArrayExpressionAst])
                } | ForEach-Object { '{0} (line {1})' -f $_.GetCommandName(), $_.Extent.StartLineNumber })
            ($bare -join '; ') | Should Be ''
        }

        It 'runs from disk with the dot-source between the markers' {
            Reset-TestState
            $global:JwfTenant.State = New-StateText -Entries @{ ('job:' + $ids.AlphaFailed) = $now }
            $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'automation\runbooks'
            $libDir = Join-Path -Path $TestDrive -ChildPath 'automation\lib'
            New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
            $copy = Join-Path -Path $runbooksDir -ChildPath 'Watch-AutomationJobFailures.ps1'
            Copy-Item -Path $runbook -Destination $copy

            $summary = Suspend-MockAlias -Name 'Invoke-HttpCore' -ScriptBlock { & $copy -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example-automation' -SubscriptionName 'Example Identity Subscription' -Recipients 'iam@corp.example.com' -AccessToken $tokens -RunId $runId 3>$null 4>$null }
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Watch-AutomationJobFailures'
            $summary.RunId | Should Be $runId
            $summary.DryRun | Should Be $true
            $summary.Environment | Should Be 'Global'
            $summary.AutomationAccount | Should Be 'aa-example-watch'
            $summary.Done | Should Be 0
            @(Get-TestRequests -PathLike '/subscriptions').Count | Should Be 1
            @(Get-TestRequests -PathLike '*/jobs').Count | Should Be 4
            (Get-WriteSequence) | Should Be ''
            Assert-MockCalled Invoke-WebRequest -Scope It -ParameterFilter { $UseBasicParsing -and ([string]$Headers['Authorization']).StartsWith('Bearer eyJ') }
            @($global:JwfRequests | Where-Object { $_.Auth -ne ('Bearer ' + $armToken) }).Count | Should Be 0
        }

        It 'passes MaxJobRuntimeMinutes from the script to the run' {
            Reset-TestState
            # This run uses the real clock; without schedule links no due run
            # can move the list start, so it is exactly the window minus 600.
            $global:JwfTenant.JobSchedules = @()
            $copy = Join-Path -Path $TestDrive -ChildPath 'automation\runbooks\Watch-AutomationJobFailures.ps1'
            $summary = Suspend-MockAlias -Name 'Invoke-HttpCore' -ScriptBlock { & $copy -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example-automation' -SubscriptionName $subscriptionId -MaxJobRuntimeMinutes 600 -AccessToken $tokens 3>$null 4>$null }
            $summary.JobListStartUtc | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            $listStart = [DateTimeOffset]::Parse($summary.JobListStartUtc, $inv).UtcDateTime
            $windowStart = [DateTimeOffset]::Parse($summary.WindowStartUtc, $inv).UtcDateTime
            ($windowStart - $listStart).TotalMinutes | Should Be 600
        }

        It 'runs when assembled the way Terraform inlines library_path' {
            Reset-TestState
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail
            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $assembledTokens = $null
            $assembledErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$assembledTokens, [ref]$assembledErrors) | Out-Null
            @($assembledErrors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Watch-AutomationJobFailures.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))

            $summary = Suspend-MockAlias -Name 'Invoke-HttpCore' -ScriptBlock { & $published -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example-automation' -SubscriptionName $subscriptionId -Environment USGov -AccessToken $tokens -RunId $runId 3>$null 4>$null }
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Watch-AutomationJobFailures'
            $summary.Environment | Should Be 'USGov'
            $summary.DryRun | Should Be $true
            (@($global:JwfRequests | ForEach-Object { $_.Host } | Sort-Object -Unique) -join ',') | Should Be 'management.usgovcloudapi.net'
            @(Get-TestRequests -PathLike '/subscriptions').Count | Should Be 0
            (Get-WriteSequence) | Should Be ''

            $global:JwfRequests.Clear()
            { Suspend-MockAlias -Name 'Invoke-HttpCore' -ScriptBlock { & $published -AutomationAccountName 'aa-example-watch' -ResourceGroupName 'rg-example-automation' -SubscriptionName $subscriptionId -DryRun $false -AccessToken $tokens 3>$null 4>$null } } | Should Throw 'Recipients is required'
            $global:JwfRequests.Count | Should Be 0
        }
    }
}

Remove-Item -Path Function:\Get-JwfTestResponse, Function:\ConvertTo-JwfPowerShell7Date, Function:\Update-JwfPowerShell7Dates -ErrorAction SilentlyContinue
Remove-Variable -Name JwfTenant, JwfRequests, JwfJsonCmdlet, JwfRealBreaker -Scope Global -ErrorAction SilentlyContinue
