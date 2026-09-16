<#
.SYNOPSIS
    Walks dormant guest accounts up a warn, disable, purge ladder, with every
    stage recorded as membership of a named group so the whole lifecycle is
    visible in the directory and in its audit log.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity. It
    reads every guest (userType eq 'Guest') with signInActivity, computes how
    long each has been dormant from the most recent sign-in (interactive or
    non-interactive) or from createdDateTime when the guest has never signed
    in, and moves each guest one rung at a time:

      Active   dormant  <  WarnDays                 nothing; stage groups cleared
      Warn     dormant >=  WarnDays                 join "LC Guests Warned", mail guest and sponsor
      Disable  dormant >=  DisableDays              accountEnabled = false, move to "LC Guests Disabled"
      Purge    dormant >=  DisableDays + PurgeDays  delete (soft-deleted for 30 days in Entra)

    A guest is never moved more than one rung per run, and never disabled
    without having been warned first, so the first run against an old tenant
    warns everybody and disables nobody. Membership of "LC Guests Exempt"
    takes a guest out of the ladder entirely.

    Why the stage is a group membership rather than a tag or a spreadsheet.
    A group membership change is written to the Entra audit log with the
    actor (the runbook's identity), the target, and the time. Anyone with
    Global Reader can list who is at which stage right now, an access review
    can be pointed at the Disabled group, and a helpdesk agent can take a
    guest off the ladder by adding them to Exempt without touching this code.
    See docs/adr/0011-lifecycle-stage-tracked-in-groups.md.

    Circuit breakers. Before anything is written, the run counts the
    disables and purges it is about to do. If either count exceeds its cap
    the run stops with an error and does nothing, rather than doing the first
    N and leaving the rest for later without anyone noticing. A tripped
    breaker is a signal (a bad clock, a bulk import, a broken filter), and the
    right response is a human looking, not a partial run.

    NIST SP 800-53 AC-2 mapping, in plain words:
      AC-2(1)  Automated account management: the ladder runs on a schedule
               from a managed identity, not from a person's session.
      AC-2(2)  Automated temporary account management: guests are removed
               once dormant, so an invitation does not outlive its purpose.
      AC-2(3)  Disable accounts after a period of inactivity: the Disable
               stage, at DisableDays of dormancy, with the period recorded in
               the job schedule parameters.
      AC-2(4)  Automated audit actions: every stage change is a group
               membership write or an account write in the Entra audit log,
               every notification is a Mail.Send entry, and the run summary
               carries a RunId for the SIEM.

    Design rules shared by every runbook in this repository are in
    automation/README.md.

.PARAMETER SenderMailbox
    Shared mailbox warnings are sent from. Requires Mail.Send restricted to
    this mailbox by an Exchange application access policy.

.PARAMETER WarnDays
    Dormancy at which a guest is warned. Default 60.

.PARAMETER DisableDays
    Dormancy at which a warned guest is disabled. Default 90.

.PARAMETER PurgeDays
    Days after the disable threshold at which a disabled guest is deleted, so
    the purge threshold is DisableDays + PurgeDays of dormancy. Default 120.

.PARAMETER WarnedGroupName
    Display name of the stage group for warned guests. Default "LC Guests Warned".

.PARAMETER DisabledGroupName
    Display name of the stage group for disabled guests. Default "LC Guests Disabled".

.PARAMETER ExemptGroupName
    Display name of the exclusion group. Default "LC Guests Exempt".

.PARAMETER MaxDisablePerRun
    Circuit breaker. More planned disables than this aborts the run. Default 25.

.PARAMETER MaxPurgePerRun
    Circuit breaker. More planned purges than this aborts the run. Default 10.

.PARAMETER FallbackRecipient
    Receives the warning copy when a guest has no resolvable sponsor. Optional.

.PARAMETER ReportPath
    Optional path for a CSV of every guest with its computed stage and action.

.PARAMETER DryRun
    Default $true. Nothing is written or sent; every action is logged as
    "would". Circuit breakers are still evaluated. Pass -DryRun:$false to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov.

.PARAMETER ClientId
    Client ID of the user-assigned managed identity.

.PARAMETER AccessToken
    Local testing only: a Graph access token obtained by the caller. Never logged.

.PARAMETER RunId
    Correlation ID stamped on every log line and on the summary.

.EXAMPLE
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Invoke-GuestLifecycle.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $token -ReportPath .\out\guests.csv

.EXAMPLE
    .\Invoke-GuestLifecycle.ps1 -SenderMailbox iam-noreply@corp.example.com -DryRun:$false -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Graph application permissions: User.ReadWrite.All (User.Read.All for a dry
    run), Group.ReadWrite.All, AuditLog.Read.All (signInActivity), Mail.Send.
    signInActivity requires a Microsoft Entra ID P1 or P2 licence in the tenant.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox,

    [ValidateRange(1, 3650)]
    [int]$WarnDays = 60,

    [ValidateRange(1, 3650)]
    [int]$DisableDays = 90,

    [ValidateRange(1, 3650)]
    [int]$PurgeDays = 120,

    [ValidateNotNullOrEmpty()]
    [string]$WarnedGroupName = 'LC Guests Warned',

    [ValidateNotNullOrEmpty()]
    [string]$DisabledGroupName = 'LC Guests Disabled',

    [ValidateNotNullOrEmpty()]
    [string]$ExemptGroupName = 'LC Guests Exempt',

    [ValidateRange(0, 10000)]
    [int]$MaxDisablePerRun = 25,

    [ValidateRange(0, 10000)]
    [int]$MaxPurgePerRun = 10,

    [string]$FallbackRecipient = '',

    [string]$ReportPath = '',

    [bool]$DryRun = $true,

    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',

    [string]$ClientId = '',

    [string]$AccessToken = '',

    [string]$RunId = ([Guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# ---------------------------------------------------------------------------
# Logging. Same contract as every runbook here: UTC timestamp, level, RunId.
# ---------------------------------------------------------------------------

$script:RunLog = New-Object System.Collections.ArrayList
$script:RunId = $RunId

function Write-RunLog {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Info', 'Action', 'Warn', 'Error')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    $entry = [PSCustomObject]@{
        Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Level     = $Level
        RunId     = $script:RunId
        Message   = $Message
    }
    [void]$script:RunLog.Add($entry)

    $line = '{0} [{1}] run={2} {3}' -f $entry.Timestamp, $Level.ToUpperInvariant(), $script:RunId, $Message
    switch ($Level) {
        'Warn' { Write-Warning -Message $line }
        'Error' {
            $ErrorActionPreference = 'Continue'
            Write-Error -Message $line
        }
        default { Write-Verbose -Message $line }
    }
}

function Get-RunLogCount {
    param([Parameter(Mandatory = $true)][string]$Level)
    return @($script:RunLog | Where-Object { $_.Level -eq $Level }).Count
}

# ---------------------------------------------------------------------------
# Identity. Caller token (local), Automation identity endpoint (production),
# Az.Accounts (fallback). Token values are never logged.
# ---------------------------------------------------------------------------

function Get-CloudEndpoints {
    param([Parameter(Mandatory = $true)][ValidateSet('Global', 'USGov')][string]$Environment)

    if ($Environment -eq 'USGov') {
        return @{ Graph = 'https://graph.microsoft.us'; Arm = 'https://management.usgovcloudapi.net' }
    }
    return @{ Graph = 'https://graph.microsoft.com'; Arm = 'https://management.azure.com' }
}

function ConvertFrom-SecureStringToPlain {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Value)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-RunbookAccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$Resource,
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$SuppliedToken = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SuppliedToken)) {
        Write-RunLog -Level Info -Message 'Token source: supplied by the caller (local mode).'
        return $SuppliedToken
    }

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $uri = '{0}?resource={1}' -f $env:IDENTITY_ENDPOINT, [Uri]::EscapeDataString($Resource)
        if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $uri += '&client_id=' + $ClientId }
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        if (-not $response.access_token) { throw 'The Automation identity endpoint returned no access_token.' }
        Write-RunLog -Level Info -Message ('Token source: Automation identity endpoint (client_id {0}).' -f $(if ($ClientId) { $ClientId } else { 'default' }))
        return [string]$response.access_token
    }

    if (Get-Command -Name Connect-AzAccount -ErrorAction SilentlyContinue) {
        $context = $null
        try { $context = Get-AzContext -ErrorAction SilentlyContinue } catch { $context = $null }
        if (-not $context) {
            if (-not [string]::IsNullOrWhiteSpace($ClientId)) { Connect-AzAccount -Identity -AccountId $ClientId | Out-Null }
            else { Connect-AzAccount -Identity | Out-Null }
        }
        $result = Get-AzAccessToken -ResourceUrl $Resource
        $token = $result.Token
        if ($token -is [System.Security.SecureString]) { $token = ConvertFrom-SecureStringToPlain -Value $token }
        Write-RunLog -Level Info -Message 'Token source: Az.Accounts.'
        return [string]$token
    }

    throw 'No credential source. Run inside Azure Automation with a managed identity, load Az.Accounts, or pass -AccessToken for local testing.'
}

# ---------------------------------------------------------------------------
# Transport with retries. Identical to the credential hygiene runbook; each
# runbook is self-contained because Azure Automation runs one file.
# ---------------------------------------------------------------------------

function Invoke-RestCall {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [AllowNull()][string]$Body = $null
    )

    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = 'application/json; charset=utf-8'
    }

    try {
        $response = Invoke-WebRequest @params
        $headers = @{}
        try { foreach ($key in $response.Headers.Keys) { $headers[[string]$key] = [string]($response.Headers[$key] -join ',') } } catch { }
        return @{ StatusCode = [int]$response.StatusCode; Content = [string]$response.Content; Headers = $headers }
    }
    catch {
        $errorResponse = $null
        try { $errorResponse = $_.Exception.Response } catch { $errorResponse = $null }
        if ($null -eq $errorResponse) { throw }

        $status = 0
        try { $status = [int]$errorResponse.StatusCode } catch { $status = 0 }

        $content = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = [string]$_.ErrorDetails.Message }
        elseif ($errorResponse.PSObject.Methods['GetResponseStream']) {
            try {
                $reader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream())
                $content = $reader.ReadToEnd()
            }
            catch { $content = '' }
        }

        $headers = @{}
        try {
            if ($errorResponse.Headers.PSObject.Properties['AllKeys']) {
                foreach ($key in $errorResponse.Headers.AllKeys) { $headers[[string]$key] = [string]$errorResponse.Headers[$key] }
            }
            else {
                foreach ($pair in $errorResponse.Headers) { $headers[[string]$pair.Key] = [string]($pair.Value -join ',') }
            }
        }
        catch { }

        return @{ StatusCode = $status; Content = $content; Headers = $headers }
    }
}

function Get-BackoffSeconds {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [AllowNull()][AllowEmptyString()][string]$RetryAfter = ''
    )

    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($RetryAfter) -and [int]::TryParse($RetryAfter, [ref]$parsed) -and $parsed -gt 0) {
        return [Math]::Min(300, $parsed)
    }
    return [int][Math]::Min(60, [Math]::Pow(2, $Attempt))
}

function ConvertTo-SafeErrorText {
    param([AllowNull()][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '(no body)' }
    $text = $Content -replace '\s+', ' '
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
    return $text
}

function Initialize-GraphSession {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Global', 'USGov')][string]$Environment,
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$AccessToken = ''
    )

    $endpoints = Get-CloudEndpoints -Environment $Environment
    $script:GraphBaseUri = $endpoints.Graph
    $script:GraphToken = Get-RunbookAccessToken -Resource $endpoints.Graph -ClientId $ClientId -SuppliedToken $AccessToken
    Write-RunLog -Level Info -Message ('Graph endpoint: {0} ({1}).' -f $script:GraphBaseUri, $Environment)
}

function Invoke-GraphRequest {
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowNull()][object]$Body = $null,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5
    )

    if ($Uri -match '^https://') { $fullUri = $Uri } else { $fullUri = '{0}/v1.0/{1}' -f $script:GraphBaseUri, $Uri.TrimStart('/') }
    $headers = @{ Authorization = 'Bearer ' + $script:GraphToken; Accept = 'application/json' }

    $json = $null
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body } else { $json = $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $attempt = 0
    while ($true) {
        $attempt++
        $result = Invoke-RestCall -Method $Method -Uri $fullUri -Headers $headers -Body $json
        $status = [int]$result.StatusCode

        if ($status -ge 200 -and $status -lt 300) {
            if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
            return ($result.Content | ConvertFrom-Json)
        }

        $retryable = ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
        if ($retryable -and $attempt -lt $MaxAttempts) {
            $retryAfter = ''
            if ($result.Headers -and $result.Headers.ContainsKey('Retry-After')) { $retryAfter = [string]$result.Headers['Retry-After'] }
            $wait = Get-BackoffSeconds -Attempt $attempt -RetryAfter $retryAfter
            Write-RunLog -Level Warn -Message ('Graph {0} {1} returned HTTP {2}; retrying in {3}s (attempt {4} of {5}).' -f $Method, $fullUri, $status, $wait, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $wait
            continue
        }

        throw ('Graph {0} {1} failed with HTTP {2} after {3} attempt(s): {4}' -f $Method, $fullUri, $status, $attempt, (ConvertTo-SafeErrorText -Content $result.Content))
    }
}

function Invoke-GraphGetAll {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $results = New-Object System.Collections.ArrayList
    $next = $Uri
    while ($next) {
        $page = Invoke-GraphRequest -Method GET -Uri $next
        if ($null -eq $page) { break }
        $value = $page.PSObject.Properties['value']
        if ($null -ne $value) {
            foreach ($item in @($value.Value)) { if ($null -ne $item) { [void]$results.Add($item) } }
        }
        else {
            [void]$results.Add($page)
        }
        $nextProp = $page.PSObject.Properties['@odata.nextLink']
        if ($nextProp) { $next = [string]$nextProp.Value } else { $next = $null }
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Directory lookups. Groups by display name, never by ID.
# ---------------------------------------------------------------------------

function ConvertTo-ODataLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-GroupByDisplayName {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    $found = @(Invoke-GraphGetAll -Uri ('groups?$filter=displayName eq {0}&$select=id,displayName,securityEnabled' -f [Uri]::EscapeDataString((ConvertTo-ODataLiteral -Value $DisplayName))))
    if ($found.Count -eq 0) { throw ('Stage group "{0}" was not found. Create it (security-enabled, not mail-enabled) before running.' -f $DisplayName) }
    if ($found.Count -gt 1) { throw ('Stage group "{0}" is not unique in this tenant ({1} matches). Rename so the lookup by name is unambiguous.' -f $DisplayName, $found.Count) }
    return $found[0]
}

function Get-GroupMemberIdSet {
    param([Parameter(Mandatory = $true)][string]$GroupId)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @(Invoke-GraphGetAll -Uri ('groups/{0}/members?$select=id&$top=999' -f $GroupId))) {
        if ($member.id) { [void]$set.Add([string]$member.id) }
    }
    return , $set
}

function Add-GroupMember {
    param([Parameter(Mandatory = $true)][string]$GroupId, [Parameter(Mandatory = $true)][string]$UserId)

    $body = @{ '@odata.id' = ('{0}/v1.0/directoryObjects/{1}' -f $script:GraphBaseUri, $UserId) }
    Invoke-GraphRequest -Method POST -Uri ('groups/{0}/members/$ref' -f $GroupId) -Body $body | Out-Null
}

function Remove-GroupMember {
    param([Parameter(Mandatory = $true)][string]$GroupId, [Parameter(Mandatory = $true)][string]$UserId)

    Invoke-GraphRequest -Method DELETE -Uri ('groups/{0}/members/{1}/$ref' -f $GroupId, $UserId) | Out-Null
}

function Get-SponsorAddresses {
    param([Parameter(Mandatory = $true)][string]$UserId)

    $addresses = New-Object System.Collections.ArrayList
    try {
        foreach ($sponsor in @(Invoke-GraphGetAll -Uri ('users/{0}/sponsors?$select=id,mail,userPrincipalName' -f $UserId))) {
            $address = ''
            if ($sponsor.PSObject.Properties['mail'] -and $sponsor.mail) { $address = [string]$sponsor.mail }
            elseif ($sponsor.PSObject.Properties['userPrincipalName'] -and $sponsor.userPrincipalName) { $address = [string]$sponsor.userPrincipalName }
            if ($address -and -not $addresses.Contains($address)) { [void]$addresses.Add($address) }
        }
    }
    catch {
        Write-RunLog -Level Warn -Message ('Could not read sponsors of guest {0}: {1}' -f $UserId, $_.Exception.Message)
    }
    return @($addresses.ToArray())
}

# ---------------------------------------------------------------------------
# Dormancy and stage. Pure, with the clock and the memberships passed in.
# ---------------------------------------------------------------------------

function ConvertTo-UtcDateTime {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    return [DateTime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture, $styles)
}

function Get-GuestLastActivity {
    <# Most recent of the sign-in timestamps Graph exposes, else the creation
       date, else $null when neither is known. #>
    param([Parameter(Mandatory = $true)][object]$Guest)

    $candidates = New-Object System.Collections.ArrayList
    $activity = $null
    $activityProp = $Guest.PSObject.Properties['signInActivity']
    if ($activityProp) { $activity = $activityProp.Value }
    if ($null -ne $activity) {
        foreach ($name in @('lastSignInDateTime', 'lastNonInteractiveSignInDateTime', 'lastSuccessfulSignInDateTime')) {
            $prop = $activity.PSObject.Properties[$name]
            if ($prop -and $prop.Value) {
                $parsed = ConvertTo-UtcDateTime -Value $prop.Value
                if ($null -ne $parsed) { [void]$candidates.Add($parsed) }
            }
        }
    }
    if ($candidates.Count -gt 0) { return ($candidates | Sort-Object -Descending | Select-Object -First 1) }

    $createdProp = $Guest.PSObject.Properties['createdDateTime']
    if ($createdProp -and $createdProp.Value) { return (ConvertTo-UtcDateTime -Value $createdProp.Value) }
    return $null
}

function Get-GuestLifecycleStage {
    <# Decides the stage and the single action for one guest. Actions:
       None, Reset, Warn, Disable, Purge, Hold. A guest climbs one rung per
       run and is never disabled without having been warned. #>
    param(
        [Parameter(Mandatory = $true)][object]$Guest,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][int]$WarnDays,
        [Parameter(Mandatory = $true)][int]$DisableDays,
        [Parameter(Mandatory = $true)][int]$PurgeDays,
        [bool]$IsExempt = $false,
        [bool]$IsWarned = $false,
        [bool]$IsDisabled = $false
    )

    $accountEnabled = $true
    $enabledProp = $Guest.PSObject.Properties['accountEnabled']
    if ($enabledProp -and $null -ne $enabledProp.Value) { $accountEnabled = [bool]$enabledProp.Value }

    $lastActivity = Get-GuestLastActivity -Guest $Guest
    $dormantDays = $null
    if ($null -ne $lastActivity) { $dormantDays = [int][Math]::Floor(($Now - $lastActivity).TotalDays) }

    $stage = 'Hold'
    $action = 'Hold'
    $reason = ''

    if ($IsExempt) {
        $stage = 'Exempt'; $action = 'None'; $reason = 'member of the exempt group'
    }
    elseif ($null -eq $dormantDays) {
        $reason = 'no sign-in activity and no creation date; cannot compute dormancy'
    }
    elseif ($dormantDays -lt $WarnDays) {
        $stage = 'Active'
        if ($IsWarned -or $IsDisabled) { $action = 'Reset'; $reason = 'active again; clearing stage groups' }
        else { $action = 'None'; $reason = 'active' }
    }
    elseif ($dormantDays -lt $DisableDays) {
        $stage = 'Warn'
        if ($IsWarned) { $action = 'None'; $reason = 'already warned' }
        elseif ($IsDisabled) { $action = 'Hold'; $reason = 'in the disabled group but below the disable threshold; left for review' }
        else { $action = 'Warn'; $reason = ('dormant {0} day(s), warn threshold {1}' -f $dormantDays, $WarnDays) }
    }
    elseif ($dormantDays -lt ($DisableDays + $PurgeDays)) {
        $stage = 'Disable'
        if ($IsDisabled) { $action = 'None'; $reason = 'already disabled' }
        elseif ($IsWarned) { $action = 'Disable'; $reason = ('dormant {0} day(s), disable threshold {1}' -f $dormantDays, $DisableDays) }
        else { $action = 'Warn'; $reason = 'past the disable threshold but never warned; warning first' }
    }
    else {
        $stage = 'Purge'
        if ($IsDisabled -and -not $accountEnabled) { $action = 'Purge'; $reason = ('dormant {0} day(s), purge threshold {1}' -f $dormantDays, ($DisableDays + $PurgeDays)) }
        elseif ($IsDisabled -and $accountEnabled) { $action = 'Hold'; $reason = 'in the disabled group but the account is enabled; someone re-enabled it outside the ladder' }
        elseif ($IsWarned) { $action = 'Disable'; $reason = 'past the purge threshold but only warned; disabling first' }
        else { $action = 'Warn'; $reason = 'past the purge threshold but never warned; warning first' }
    }

    $lastActivityText = $null
    if ($null -ne $lastActivity) { $lastActivityText = $lastActivity.ToString('yyyy-MM-dd') }

    return [PSCustomObject]@{
        UserId            = [string]$Guest.id
        UserPrincipalName = [string]$Guest.userPrincipalName
        DisplayName       = [string]$Guest.displayName
        Mail              = [string]$Guest.mail
        AccountEnabled    = $accountEnabled
        LastActivity      = $lastActivityText
        DormantDays       = $dormantDays
        Stage             = $stage
        Action            = $action
        Reason            = $reason
    }
}

function Test-CircuitBreaker {
    <# Throws when a planned action count exceeds its cap. Called before any
       write so a tripped breaker means nothing happened. #>
    param(
        [Parameter(Mandatory = $true)][int]$PlannedDisables,
        [Parameter(Mandatory = $true)][int]$PlannedPurges,
        [Parameter(Mandatory = $true)][int]$MaxDisablePerRun,
        [Parameter(Mandatory = $true)][int]$MaxPurgePerRun
    )

    $problems = @()
    if ($PlannedDisables -gt $MaxDisablePerRun) { $problems += ('{0} disable(s) planned, cap is {1}' -f $PlannedDisables, $MaxDisablePerRun) }
    if ($PlannedPurges -gt $MaxPurgePerRun) { $problems += ('{0} purge(s) planned, cap is {1}' -f $PlannedPurges, $MaxPurgePerRun) }
    if ($problems.Count -gt 0) {
        throw ('Circuit breaker tripped: {0}. Nothing was changed. Review the guest report, then raise the cap for one run or exempt the affected guests.' -f ($problems -join '; '))
    }
}

# ---------------------------------------------------------------------------
# Mail.
# ---------------------------------------------------------------------------

function ConvertTo-HtmlText {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '' }
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-GuestWarningHtml {
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][int]$DisableDays,
        [Parameter(Mandatory = $true)][int]$PurgeDays
    )

    $daysLeft = [Math]::Max(0, $DisableDays - $Decision.DormantDays)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>The guest account <b>{0}</b> ({1}) has not signed in since {2}.</p>' -f (ConvertTo-HtmlText -Value $Decision.DisplayName), (ConvertTo-HtmlText -Value $Decision.UserPrincipalName), (ConvertTo-HtmlText -Value $Decision.LastActivity)))
    [void]$sb.Append(('<p>If it is still needed, sign in within {0} day(s). Otherwise it will be disabled after {1} days without a sign-in and deleted {2} days after that.</p>' -f $daysLeft, $DisableDays, $PurgeDays))
    [void]$sb.Append('<p>Sponsors who need the account kept without a sign-in can ask the identity team to exempt it.</p>')
    [void]$sb.Append(('<p style="color:#666">Sent by the guest lifecycle runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlText -Value $script:RunId)))
    [void]$sb.Append('</body></html>')
    return $sb.ToString()
}

function Send-GraphMail {
    param(
        [Parameter(Mandatory = $true)][string]$SenderMailbox,
        [Parameter(Mandatory = $true)][string[]]$To,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$HtmlBody
    )

    $recipients = @()
    foreach ($address in $To) { $recipients += @{ emailAddress = @{ address = $address } } }
    $message = @{
        message         = @{
            subject      = $Subject
            body         = @{ contentType = 'HTML'; content = $HtmlBody }
            toRecipients = $recipients
        }
        saveToSentItems = $false
    }
    Invoke-GraphRequest -Method POST -Uri ('users/{0}/sendMail' -f [Uri]::EscapeDataString($SenderMailbox)) -Body $message | Out-Null
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-GuestLifecycleRun {
    param(
        [Parameter(Mandatory = $true)][string]$SenderMailbox,
        [int]$WarnDays = 60,
        [int]$DisableDays = 90,
        [int]$PurgeDays = 120,
        [string]$WarnedGroupName = 'LC Guests Warned',
        [string]$DisabledGroupName = 'LC Guests Disabled',
        [string]$ExemptGroupName = 'LC Guests Exempt',
        [int]$MaxDisablePerRun = 25,
        [int]$MaxPurgePerRun = 10,
        [string]$FallbackRecipient = '',
        [string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [string]$ClientId = '',
        [string]$AccessToken = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    if ($WarnDays -ge $DisableDays) { throw ('WarnDays ({0}) must be less than DisableDays ({1}).' -f $WarnDays, $DisableDays) }

    Write-RunLog -Level Info -Message ('Starting guest lifecycle. DryRun={0} WarnDays={1} DisableDays={2} PurgeDays={3} MaxDisablePerRun={4} MaxPurgePerRun={5}' -f $DryRun, $WarnDays, $DisableDays, $PurgeDays, $MaxDisablePerRun, $MaxPurgePerRun)

    Initialize-GraphSession -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken

    $warnedGroup = Get-GroupByDisplayName -DisplayName $WarnedGroupName
    $disabledGroup = Get-GroupByDisplayName -DisplayName $DisabledGroupName
    $exemptGroup = Get-GroupByDisplayName -DisplayName $ExemptGroupName
    $warnedIds = Get-GroupMemberIdSet -GroupId ([string]$warnedGroup.id)
    $disabledIds = Get-GroupMemberIdSet -GroupId ([string]$disabledGroup.id)
    $exemptIds = Get-GroupMemberIdSet -GroupId ([string]$exemptGroup.id)
    Write-RunLog -Level Info -Message ('Stage groups: warned={0} disabled={1} exempt={2} member(s).' -f $warnedIds.Count, $disabledIds.Count, $exemptIds.Count)

    $guests = @(Invoke-GraphGetAll -Uri "users?`$filter=userType eq 'Guest'&`$select=id,displayName,userPrincipalName,mail,accountEnabled,createdDateTime,externalUserState,signInActivity&`$top=500")
    Write-RunLog -Level Info -Message ('Read {0} guest(s).' -f $guests.Count)

    $decisions = New-Object System.Collections.ArrayList
    foreach ($guest in $guests) {
        $id = [string]$guest.id
        $decision = Get-GuestLifecycleStage -Guest $guest -Now $Now -WarnDays $WarnDays -DisableDays $DisableDays -PurgeDays $PurgeDays `
            -IsExempt $exemptIds.Contains($id) -IsWarned $warnedIds.Contains($id) -IsDisabled $disabledIds.Contains($id)
        [void]$decisions.Add($decision)
    }

    $stageCounts = @{}
    foreach ($s in @('Exempt', 'Active', 'Warn', 'Disable', 'Purge', 'Hold')) { $stageCounts[$s] = @($decisions | Where-Object { $_.Stage -eq $s }).Count }
    $plannedWarn = @($decisions | Where-Object { $_.Action -eq 'Warn' }).Count
    $plannedDisable = @($decisions | Where-Object { $_.Action -eq 'Disable' }).Count
    $plannedPurge = @($decisions | Where-Object { $_.Action -eq 'Purge' }).Count
    $plannedReset = @($decisions | Where-Object { $_.Action -eq 'Reset' }).Count
    $held = @($decisions | Where-Object { $_.Action -eq 'Hold' }).Count
    Write-RunLog -Level Info -Message ('Stages: exempt={0} active={1} warn={2} disable={3} purge={4} hold={5}. Planned: warn={6} disable={7} purge={8} reset={9}' -f $stageCounts.Exempt, $stageCounts.Active, $stageCounts.Warn, $stageCounts.Disable, $stageCounts.Purge, $stageCounts.Hold, $plannedWarn, $plannedDisable, $plannedPurge, $plannedReset)
    foreach ($h in @($decisions | Where-Object { $_.Action -eq 'Hold' })) {
        Write-RunLog -Level Warn -Message ('Holding guest {0}: {1}.' -f $h.UserPrincipalName, $h.Reason)
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $directory = Split-Path -Path $ReportPath -Parent
        if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $decisions | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    # Breakers first, in dry runs too, so a dry run tells you the live run
    # would have refused.
    try {
        Test-CircuitBreaker -PlannedDisables $plannedDisable -PlannedPurges $plannedPurge -MaxDisablePerRun $MaxDisablePerRun -MaxPurgePerRun $MaxPurgePerRun
    }
    catch {
        Write-RunLog -Level Error -Message $_.Exception.Message
        throw
    }

    $counts = @{ Warned = 0; Disabled = 0; Purged = 0; Reset = 0; MailsSent = 0 }
    foreach ($d in ($decisions | Where-Object { $_.Action -ne 'None' -and $_.Action -ne 'Hold' } | Sort-Object -Property Action, UserPrincipalName)) {
        $label = ('{0} ({1}, dormant {2} day(s))' -f $d.UserPrincipalName, $d.UserId, $d.DormantDays)
        try {
            switch ($d.Action) {
                'Warn' {
                    $recipients = @()
                    if ($d.Mail) { $recipients += $d.Mail }
                    $sponsors = @()
                    if (-not $DryRun) { $sponsors = @(Get-SponsorAddresses -UserId $d.UserId) }
                    if ($sponsors.Count -gt 0) { $recipients += $sponsors }
                    elseif (-not [string]::IsNullOrWhiteSpace($FallbackRecipient)) { $recipients += $FallbackRecipient }

                    if ($DryRun) {
                        Write-RunLog -Level Action -Message ('Would warn {0}: add to "{1}" and mail the guest plus sponsor. {2}' -f $label, $WarnedGroupName, $d.Reason)
                        break
                    }
                    Add-GroupMember -GroupId ([string]$warnedGroup.id) -UserId $d.UserId
                    if ($recipients.Count -gt 0) {
                        $html = New-GuestWarningHtml -Decision $d -DisableDays $DisableDays -PurgeDays $PurgeDays
                        Send-GraphMail -SenderMailbox $SenderMailbox -To $recipients -Subject ('Guest account {0} will be disabled for inactivity' -f $d.UserPrincipalName) -HtmlBody $html
                        $counts.MailsSent++
                    }
                    else {
                        Write-RunLog -Level Warn -Message ('No mail address or sponsor for {0}; warned by group membership only.' -f $label)
                    }
                    $counts.Warned++
                    Write-RunLog -Level Action -Message ('Warned {0}. {1}' -f $label, $d.Reason)
                }
                'Disable' {
                    if ($DryRun) {
                        Write-RunLog -Level Action -Message ('Would disable {0}: accountEnabled=false, move "{1}" -> "{2}". {3}' -f $label, $WarnedGroupName, $DisabledGroupName, $d.Reason)
                        break
                    }
                    Invoke-GraphRequest -Method PATCH -Uri ('users/{0}' -f $d.UserId) -Body @{ accountEnabled = $false } | Out-Null
                    Add-GroupMember -GroupId ([string]$disabledGroup.id) -UserId $d.UserId
                    if ($warnedIds.Contains($d.UserId)) { Remove-GroupMember -GroupId ([string]$warnedGroup.id) -UserId $d.UserId }
                    $counts.Disabled++
                    Write-RunLog -Level Action -Message ('Disabled {0}. {1}' -f $label, $d.Reason)
                }
                'Purge' {
                    if ($DryRun) {
                        Write-RunLog -Level Action -Message ('Would delete {0}. {1}' -f $label, $d.Reason)
                        break
                    }
                    Invoke-GraphRequest -Method DELETE -Uri ('users/{0}' -f $d.UserId) | Out-Null
                    $counts.Purged++
                    Write-RunLog -Level Action -Message ('Deleted {0} (recoverable from the Entra recycle bin for 30 days). {1}' -f $label, $d.Reason)
                }
                'Reset' {
                    if ($DryRun) {
                        Write-RunLog -Level Action -Message ('Would reset {0}: remove from stage groups. {1}' -f $label, $d.Reason)
                        break
                    }
                    if ($warnedIds.Contains($d.UserId)) { Remove-GroupMember -GroupId ([string]$warnedGroup.id) -UserId $d.UserId }
                    if ($disabledIds.Contains($d.UserId)) { Remove-GroupMember -GroupId ([string]$disabledGroup.id) -UserId $d.UserId }
                    $counts.Reset++
                    Write-RunLog -Level Action -Message ('Reset {0}. {1}' -f $label, $d.Reason)
                }
            }
        }
        catch {
            Write-RunLog -Level Error -Message ('Action {0} failed for {1}: {2}' -f $d.Action, $label, $_.Exception.Message)
        }
    }

    $summary = [PSCustomObject]@{
        RunId           = $script:RunId
        Runbook         = 'Invoke-GuestLifecycle'
        DryRun          = $DryRun
        Environment     = $Environment
        GuestsScanned   = $guests.Count
        StageExempt     = $stageCounts.Exempt
        StageActive     = $stageCounts.Active
        StageWarn       = $stageCounts.Warn
        StageDisable    = $stageCounts.Disable
        StagePurge      = $stageCounts.Purge
        Held            = $held
        PlannedWarn     = $plannedWarn
        PlannedDisable  = $plannedDisable
        PlannedPurge    = $plannedPurge
        PlannedReset    = $plannedReset
        Warned          = $counts.Warned
        Disabled        = $counts.Disabled
        Purged          = $counts.Purged
        Reset           = $counts.Reset
        MailsSent       = $counts.MailsSent
        Warnings        = (Get-RunLogCount -Level 'Warn')
        Errors          = (Get-RunLogCount -Level 'Error')
        ReportPath      = $ReportPath
        CompletedUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-RunLog -Level Info -Message ('Finished. warned={0} disabled={1} purged={2} reset={3} warnings={4} errors={5}' -f $summary.Warned, $summary.Disabled, $summary.Purged, $summary.Reset, $summary.Warnings, $summary.Errors)
    return $summary
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-GuestLifecycleRun -SenderMailbox $SenderMailbox -WarnDays $WarnDays -DisableDays $DisableDays -PurgeDays $PurgeDays `
        -WarnedGroupName $WarnedGroupName -DisabledGroupName $DisabledGroupName -ExemptGroupName $ExemptGroupName `
        -MaxDisablePerRun $MaxDisablePerRun -MaxPurgePerRun $MaxPurgePerRun -FallbackRecipient $FallbackRecipient `
        -ReportPath $ReportPath -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken
}
