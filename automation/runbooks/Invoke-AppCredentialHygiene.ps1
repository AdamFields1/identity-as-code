<#
.SYNOPSIS
    Finds expiring and expired application credentials in an Entra tenant, tells
    each application's owners, and, when explicitly allowed, removes credentials
    that have been expired for longer than a grace period.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity. It
    reads every application registration through Microsoft Graph with its
    passwordCredentials (client secrets) and keyCredentials (certificates),
    classifies each credential as Healthy, Expiring (ends within -WarnDays), or
    Expired, resolves the registration's owners, and sends one HTML digest per
    owner from a shared mailbox. With -RemoveExpired and -DryRun:$false it also
    removes credentials that expired more than -RemoveAfterDays ago, up to
    -MaxRemovalsPerRun per run.

    Why owners are told before anything is removed. An expired secret is not
    always dead: a workload may still present it and fail loudly on the next
    restart, or a second copy of the same secret may be about to be rotated in.
    Deleting on sight turns a quiet expiry into an outage with no warning and
    no owner in the loop. The digest gives the owner the list, the dates, and
    the removal date, so the removal is expected, and the expired credential is
    only removed after it has been unusable for the grace period, when nothing
    can still depend on it working.

    How this closes the loop with the SIEM. Every run emits a summary object
    with a RunId, and every removal is logged with that RunId, the application,
    and the key ID. The Automation account streams job output to the SIEM
    through diagnostic settings. A SIEM rule opens one ticket per run that
    removed anything, keyed on the RunId, and the Entra audit log entry for the
    removal (actor: the runbook's managed identity) is the evidence that closes
    it. Nothing is deleted that cannot be traced to a run, a digest, and a
    ticket.

    Certificates are removed by writing the keyCredentials collection back
    without the expired entry (PATCH /applications/{id}), because the removeKey
    action requires a proof-of-possession token signed by a key the runbook
    does not have. Secrets are removed with the removePassword action.

    Design rules shared by every runbook in this repository are in
    automation/README.md: managed identity only, DryRun on by default, a cap on
    every destructive action, a national cloud switch, and structured logging.

.PARAMETER SenderMailbox
    Shared mailbox the digests are sent from, as a user principal name. The
    managed identity needs Mail.Send and an Exchange application access policy
    that restricts it to this mailbox (see automation/README.md).

.PARAMETER WarnDays
    A credential ending within this many days is Expiring. Default 30.

.PARAMETER RemoveExpired
    Allow removal of credentials that have been expired for at least
    -RemoveAfterDays. Has no effect unless -DryRun:$false is also given.

.PARAMETER RemoveAfterDays
    Grace period after expiry before a credential may be removed. Default 30.

.PARAMETER MaxRemovalsPerRun
    Cap on removals in one run. Candidates beyond the cap are logged and left
    for the next run. Default 25.

.PARAMETER ExcludedAppTag
    Registrations carrying this tag are skipped entirely. Default
    NoCredentialHygiene.

.PARAMETER ExcludedAppNames
    Display names of registrations to skip, in addition to the tag.

.PARAMETER FallbackRecipient
    Where the digest for a registration with no resolvable owner goes. When
    empty, ownerless findings are only logged.

.PARAMETER ReportPath
    Optional path for a CSV of every finding. On an Automation worker use a path
    under $env:TEMP.

.PARAMETER DryRun
    Default $true. Nothing is sent and nothing is removed; every action is
    logged as "would". Pass -DryRun:$false to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov. Selects the Graph base URL and
    the token resource.

.PARAMETER ClientId
    Client ID of the user-assigned managed identity. Passed to the Automation
    identity endpoint so the right identity is used when the account has more
    than one.

.PARAMETER AccessToken
    Local testing only: a Graph access token obtained by the caller. Never
    logged. When set, the identity endpoint and Az.Accounts are not used.

.PARAMETER RunId
    Correlation ID stamped on every log line and on the summary. Defaults to a
    new GUID; a SIEM ticket references it.

.EXAMPLE
    # Dry run on a workstation with a token from the Azure CLI.
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Invoke-AppCredentialHygiene.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $token

.EXAMPLE
    # Live run from Azure Automation: parameters come from the job schedule.
    .\Invoke-AppCredentialHygiene.ps1 -SenderMailbox iam-noreply@corp.example.com -DryRun:$false -RemoveExpired $true -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Graph application permissions: Application.ReadWrite.All (Application.Read.All
    is enough for a dry run), Directory.Read.All for owners, Mail.Send.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox,

    [ValidateRange(1, 365)]
    [int]$WarnDays = 30,

    [bool]$RemoveExpired = $false,

    [ValidateRange(0, 3650)]
    [int]$RemoveAfterDays = 30,

    [ValidateRange(1, 1000)]
    [int]$MaxRemovalsPerRun = 25,

    [string]$ExcludedAppTag = 'NoCredentialHygiene',

    [string[]]$ExcludedAppNames = @(),

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
# Logging. Every line carries a UTC timestamp, a level, and the RunId. Info and
# Action lines go to the verbose stream (the runbook is deployed with
# log_verbose = true, so Azure Automation keeps them with the job); Warn and
# Error go to their own streams so a job filter finds them. No line ever
# contains a token or a header.
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
# Identity. Three sources, tried in order: a caller-supplied token (local
# testing), the Azure Automation identity endpoint (the production path), and
# Az.Accounts when it happens to be loaded. The token value is held in a
# script variable and is never written to any stream.
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
# Transport. Invoke-RestCall is the only place Invoke-WebRequest is called, so
# tests can mock it and so both PowerShell editions are handled in one spot.
# It never throws on an HTTP status; it returns the status so the caller can
# decide what is retryable.
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
    <# One Graph call with retries on 429 and 5xx. Relative URIs are resolved
       against the v1.0 endpoint of the selected cloud; absolute URIs (nextLink)
       are used as given. Returns the parsed JSON body, or $null for 204. #>
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
    <# Paginated GET. Follows @odata.nextLink until exhausted. #>
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
# Classification. Pure functions with the clock passed in, so the boundaries
# are testable without a tenant.
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

function Get-CredentialAssessment {
    <# Classifies one credential. Expired when the end date is at or before now;
       Expiring when it ends within WarnDays; Healthy otherwise. Removable is
       true when it has been expired for at least RemoveAfterDays. #>
    param(
        [Parameter(Mandatory = $true)][object]$Credential,
        [Parameter(Mandatory = $true)][ValidateSet('Secret', 'Certificate')][string]$Kind,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][int]$WarnDays,
        [Parameter(Mandatory = $true)][int]$RemoveAfterDays
    )

    $end = ConvertTo-UtcDateTime -Value $Credential.endDateTime
    $state = 'Healthy'
    $daysToExpiry = $null
    $daysExpired = $null
    $removable = $false

    if ($null -ne $end) {
        if ($end -le $Now) {
            $state = 'Expired'
            $daysExpired = [int][Math]::Floor(($Now - $end).TotalDays)
            $removable = ($daysExpired -ge $RemoveAfterDays)
        }
        elseif ($end -le $Now.AddDays($WarnDays)) {
            $state = 'Expiring'
            $daysToExpiry = [int][Math]::Ceiling(($end - $Now).TotalDays)
        }
        else {
            $daysToExpiry = [int][Math]::Ceiling(($end - $Now).TotalDays)
        }
    }

    $endText = $null
    if ($null -ne $end) { $endText = $end.ToString('yyyy-MM-dd') }

    return [PSCustomObject]@{
        Kind         = $Kind
        KeyId        = [string]$Credential.keyId
        DisplayName  = [string]$Credential.displayName
        EndDate      = $endText
        State        = $state
        DaysToExpiry = $daysToExpiry
        DaysExpired  = $daysExpired
        Removable    = $removable
    }
}

function Test-ApplicationExcluded {
    param(
        [Parameter(Mandatory = $true)][object]$Application,
        [AllowEmptyString()][string]$ExcludedAppTag,
        [AllowNull()][string[]]$ExcludedAppNames
    )

    $name = [string]$Application.displayName
    if ($ExcludedAppNames -and (@($ExcludedAppNames) -contains $name)) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($ExcludedAppTag)) {
        $tags = @()
        $tagsProp = $Application.PSObject.Properties['tags']
        if ($tagsProp) { $tags = @($tagsProp.Value) }
        if ($tags -contains $ExcludedAppTag) { return $true }
    }
    return $false
}

function Get-ApplicationFindings {
    <# Every non-healthy credential of every non-excluded registration, one row
       per credential, plus per-application counters. #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Applications,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][int]$WarnDays,
        [Parameter(Mandatory = $true)][int]$RemoveAfterDays,
        [AllowEmptyString()][string]$ExcludedAppTag = '',
        [AllowNull()][string[]]$ExcludedAppNames = @()
    )

    $findings = New-Object System.Collections.ArrayList
    $counters = @{ Applications = 0; Excluded = 0; Healthy = 0; Expiring = 0; Expired = 0; Removable = 0 }

    foreach ($app in $Applications) {
        $counters.Applications++
        if (Test-ApplicationExcluded -Application $app -ExcludedAppTag $ExcludedAppTag -ExcludedAppNames $ExcludedAppNames) {
            $counters.Excluded++
            continue
        }

        $credentials = @()
        $pw = $app.PSObject.Properties['passwordCredentials']
        if ($pw) { foreach ($c in @($pw.Value)) { if ($null -ne $c) { $credentials += , @{ Kind = 'Secret'; Credential = $c } } } }
        $keys = $app.PSObject.Properties['keyCredentials']
        if ($keys) { foreach ($c in @($keys.Value)) { if ($null -ne $c) { $credentials += , @{ Kind = 'Certificate'; Credential = $c } } } }

        foreach ($entry in $credentials) {
            $assessment = Get-CredentialAssessment -Credential $entry.Credential -Kind $entry.Kind -Now $Now -WarnDays $WarnDays -RemoveAfterDays $RemoveAfterDays
            $counters[$assessment.State]++
            if ($assessment.Removable) { $counters.Removable++ }
            if ($assessment.State -eq 'Healthy') { continue }

            [void]$findings.Add([PSCustomObject]@{
                    ApplicationObjectId = [string]$app.id
                    ApplicationClientId = [string]$app.appId
                    ApplicationName     = [string]$app.displayName
                    Kind                = $assessment.Kind
                    KeyId               = $assessment.KeyId
                    CredentialName      = $assessment.DisplayName
                    EndDate             = $assessment.EndDate
                    State               = $assessment.State
                    DaysToExpiry        = $assessment.DaysToExpiry
                    DaysExpired         = $assessment.DaysExpired
                    Removable           = $assessment.Removable
                    Owners              = @()
                })
        }
    }

    return @{ Findings = $findings.ToArray(); Counters = $counters }
}

# ---------------------------------------------------------------------------
# Owners and mail.
# ---------------------------------------------------------------------------

function Get-ApplicationOwnerAddresses {
    param([Parameter(Mandatory = $true)][string]$ApplicationObjectId)

    $owners = @(Invoke-GraphGetAll -Uri ('applications/{0}/owners?$select=id,mail,userPrincipalName' -f $ApplicationObjectId))
    $addresses = New-Object System.Collections.ArrayList
    foreach ($owner in $owners) {
        $type = ''
        $typeProp = $owner.PSObject.Properties['@odata.type']
        if ($typeProp) { $type = [string]$typeProp.Value }
        if ($type -and $type -ne '#microsoft.graph.user') { continue }
        $address = ''
        if ($owner.PSObject.Properties['mail'] -and $owner.mail) { $address = [string]$owner.mail }
        elseif ($owner.PSObject.Properties['userPrincipalName'] -and $owner.userPrincipalName) { $address = [string]$owner.userPrincipalName }
        if ($address -and -not $addresses.Contains($address)) { [void]$addresses.Add($address) }
    }
    return @($addresses.ToArray())
}

function ConvertTo-HtmlText {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '' }
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-OwnerDigestHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Recipient,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory = $true)][int]$WarnDays,
        [Parameter(Mandatory = $true)][int]$RemoveAfterDays,
        [Parameter(Mandatory = $true)][bool]$RemovalEnabled
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append('<p>You are listed as an owner of application registrations with credentials that are expiring or expired.</p>')
    [void]$sb.Append(('<p>Credentials ending within {0} days are listed as expiring. ' -f $WarnDays))
    if ($RemovalEnabled) {
        [void]$sb.Append(('Credentials expired for more than {0} days are removed automatically by the identity automation runbook; the removal is recorded in the Entra audit log. ' -f $RemoveAfterDays))
    }
    [void]$sb.Append('Rotate expiring credentials before the end date, and prefer a federated credential over a secret where the workload supports it.</p>')
    [void]$sb.Append('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse">')
    [void]$sb.Append('<tr><th>Application</th><th>Client ID</th><th>Kind</th><th>Credential</th><th>End date</th><th>State</th><th>Detail</th></tr>')

    foreach ($f in ($Findings | Sort-Object -Property ApplicationName, EndDate)) {
        $detail = ''
        if ($f.State -eq 'Expiring') { $detail = ('expires in {0} day(s)' -f $f.DaysToExpiry) }
        elseif ($f.State -eq 'Expired') {
            $detail = ('expired {0} day(s) ago' -f $f.DaysExpired)
            if ($RemovalEnabled -and $f.Removable) { $detail += '; scheduled for removal' }
            elseif ($RemovalEnabled) { $detail += ('; removal after {0} day(s)' -f ($RemoveAfterDays - $f.DaysExpired)) }
        }
        [void]$sb.Append('<tr>')
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.ApplicationName)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.ApplicationClientId)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.Kind)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.CredentialName)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.EndDate)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $f.State)))
        [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value $detail)))
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</table>')
    [void]$sb.Append(('<p style="color:#666">Sent to {0} by the application credential hygiene runbook (run {1}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlText -Value $Recipient), (ConvertTo-HtmlText -Value $script:RunId)))
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
# Removal. Secrets through removePassword. Certificates by writing back the
# keyCredentials collection without the expired entry, because removeKey needs
# a proof-of-possession JWT signed by a private key the runbook does not hold.
# ---------------------------------------------------------------------------

function Remove-ExpiredCredential {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$AllKeyCredentials
    )

    if ($Finding.Kind -eq 'Secret') {
        Invoke-GraphRequest -Method POST -Uri ('applications/{0}/removePassword' -f $Finding.ApplicationObjectId) -Body @{ keyId = $Finding.KeyId } | Out-Null
        return
    }

    $remaining = @()
    foreach ($key in $AllKeyCredentials) {
        if ([string]$key.keyId -eq $Finding.KeyId) { continue }
        $remaining += @{
            keyId       = [string]$key.keyId
            type        = [string]$key.type
            usage       = [string]$key.usage
            displayName = [string]$key.displayName
            key         = $key.key
        }
    }
    $body = '{"keyCredentials":' + (ConvertTo-Json -InputObject @($remaining) -Depth 5 -Compress) + '}'
    Invoke-GraphRequest -Method PATCH -Uri ('applications/{0}' -f $Finding.ApplicationObjectId) -Body $body | Out-Null
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-CredentialHygieneRun {
    param(
        [Parameter(Mandatory = $true)][string]$SenderMailbox,
        [int]$WarnDays = 30,
        [bool]$RemoveExpired = $false,
        [int]$RemoveAfterDays = 30,
        [int]$MaxRemovalsPerRun = 25,
        [string]$ExcludedAppTag = 'NoCredentialHygiene',
        [string[]]$ExcludedAppNames = @(),
        [string]$FallbackRecipient = '',
        [string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [string]$ClientId = '',
        [string]$AccessToken = '',
        [DateTime]$Now = [DateTime]::UtcNow
    )

    $removalEnabled = ($RemoveExpired -and -not $DryRun)
    Write-RunLog -Level Info -Message ('Starting application credential hygiene. DryRun={0} RemoveExpired={1} WarnDays={2} RemoveAfterDays={3} MaxRemovalsPerRun={4} Sender={5}' -f $DryRun, $RemoveExpired, $WarnDays, $RemoveAfterDays, $MaxRemovalsPerRun, $SenderMailbox)
    if ($RemoveExpired -and $DryRun) { Write-RunLog -Level Info -Message 'RemoveExpired is set but DryRun is on; removals will be reported, not performed.' }

    Initialize-GraphSession -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken

    $applications = @(Invoke-GraphGetAll -Uri 'applications?$select=id,appId,displayName,tags,passwordCredentials,keyCredentials&$top=999')
    Write-RunLog -Level Info -Message ('Read {0} application registration(s).' -f $applications.Count)

    $assessment = Get-ApplicationFindings -Applications $applications -Now $Now -WarnDays $WarnDays -RemoveAfterDays $RemoveAfterDays -ExcludedAppTag $ExcludedAppTag -ExcludedAppNames $ExcludedAppNames
    $findings = @($assessment.Findings)
    $counters = $assessment.Counters
    Write-RunLog -Level Info -Message ('Classified: healthy={0} expiring={1} expired={2} removable={3} excludedApps={4}' -f $counters.Healthy, $counters.Expiring, $counters.Expired, $counters.Removable, $counters.Excluded)

    # Owners, one lookup per application with findings.
    $ownersByApp = @{}
    foreach ($appId in @($findings | ForEach-Object { $_.ApplicationObjectId } | Sort-Object -Unique)) {
        try { $ownersByApp[$appId] = @(Get-ApplicationOwnerAddresses -ApplicationObjectId $appId) }
        catch {
            Write-RunLog -Level Warn -Message ('Could not read owners of application {0}: {1}' -f $appId, $_.Exception.Message)
            $ownersByApp[$appId] = @()
        }
    }
    foreach ($f in $findings) { $f.Owners = @($ownersByApp[$f.ApplicationObjectId]) }

    # One digest per recipient.
    $byRecipient = @{}
    $ownerless = 0
    foreach ($f in $findings) {
        $recipients = @($f.Owners)
        if ($recipients.Count -eq 0) {
            $ownerless++
            if ([string]::IsNullOrWhiteSpace($FallbackRecipient)) {
                Write-RunLog -Level Warn -Message ('Application "{0}" has no owner with a mail address; {1} {2} credential {3} reported only in the log.' -f $f.ApplicationName, $f.State.ToLowerInvariant(), $f.Kind.ToLowerInvariant(), $f.KeyId)
                continue
            }
            $recipients = @($FallbackRecipient)
        }
        foreach ($r in $recipients) {
            if (-not $byRecipient.ContainsKey($r)) { $byRecipient[$r] = New-Object System.Collections.ArrayList }
            [void]$byRecipient[$r].Add($f)
        }
    }

    $digestsSent = 0
    $digestsPlanned = 0
    foreach ($recipient in ($byRecipient.Keys | Sort-Object)) {
        $rows = @($byRecipient[$recipient].ToArray())
        $digestsPlanned++
        $subject = ('Application credential hygiene: {0} item(s) need attention' -f $rows.Count)
        if ($DryRun) {
            Write-RunLog -Level Action -Message ('Would send digest to {0} with {1} finding(s).' -f $recipient, $rows.Count)
            continue
        }
        try {
            $html = New-OwnerDigestHtml -Recipient $recipient -Findings $rows -WarnDays $WarnDays -RemoveAfterDays $RemoveAfterDays -RemovalEnabled $removalEnabled
            Send-GraphMail -SenderMailbox $SenderMailbox -To @($recipient) -Subject $subject -HtmlBody $html
            $digestsSent++
            Write-RunLog -Level Action -Message ('Sent digest to {0} with {1} finding(s).' -f $recipient, $rows.Count)
        }
        catch {
            Write-RunLog -Level Error -Message ('Failed to send digest to {0}: {1}' -f $recipient, $_.Exception.Message)
        }
    }

    # Removals, oldest expiry first, capped.
    $removed = 0
    $deferred = 0
    $candidates = @($findings | Where-Object { $_.Removable } | Sort-Object -Property EndDate, ApplicationName, KeyId)
    if ($candidates.Count -gt $MaxRemovalsPerRun) {
        $deferred = $candidates.Count - $MaxRemovalsPerRun
        Write-RunLog -Level Warn -Message ('{0} removal candidate(s) exceed the cap of {1}; {2} left for the next run.' -f $candidates.Count, $MaxRemovalsPerRun, $deferred)
        $candidates = @($candidates | Select-Object -First $MaxRemovalsPerRun)
    }

    $keyCredentialsByApp = @{}
    foreach ($app in $applications) {
        $keys = @()
        $keysProp = $app.PSObject.Properties['keyCredentials']
        if ($keysProp) { $keys = @($keysProp.Value | Where-Object { $null -ne $_ }) }
        $keyCredentialsByApp[[string]$app.id] = $keys
    }

    foreach ($c in $candidates) {
        $label = ('{0} {1} on "{2}" (keyId {3}, expired {4})' -f $c.Kind.ToLowerInvariant(), $c.CredentialName, $c.ApplicationName, $c.KeyId, $c.EndDate)
        if (-not $removalEnabled) {
            Write-RunLog -Level Action -Message ('Would remove {0}.' -f $label)
            continue
        }
        try {
            Remove-ExpiredCredential -Finding $c -AllKeyCredentials @($keyCredentialsByApp[$c.ApplicationObjectId])
            $removed++
            Write-RunLog -Level Action -Message ('Removed {0}.' -f $label)
        }
        catch {
            Write-RunLog -Level Error -Message ('Failed to remove {0}: {1}' -f $label, $_.Exception.Message)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $directory = Split-Path -Path $ReportPath -Parent
        if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $findings | Select-Object ApplicationName, ApplicationClientId, ApplicationObjectId, Kind, CredentialName, KeyId, EndDate, State, DaysToExpiry, DaysExpired, Removable, @{ Name = 'Owners'; Expression = { ($_.Owners -join ';') } } |
            Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    $summary = [PSCustomObject]@{
        RunId               = $script:RunId
        Runbook             = 'Invoke-AppCredentialHygiene'
        DryRun              = $DryRun
        RemovalEnabled      = $removalEnabled
        Environment         = $Environment
        ApplicationsScanned = $counters.Applications
        ApplicationsExcluded = $counters.Excluded
        CredentialsHealthy  = $counters.Healthy
        CredentialsExpiring = $counters.Expiring
        CredentialsExpired  = $counters.Expired
        RemovalCandidates   = $counters.Removable
        Removed             = $removed
        RemovalsDeferred    = $deferred
        DigestsPlanned      = $digestsPlanned
        DigestsSent         = $digestsSent
        ApplicationsWithoutOwner = $ownerless
        Warnings            = (Get-RunLogCount -Level 'Warn')
        Errors              = (Get-RunLogCount -Level 'Error')
        ReportPath          = $ReportPath
        CompletedUtc        = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-RunLog -Level Info -Message ('Finished. removed={0} digestsSent={1} warnings={2} errors={3}' -f $summary.Removed, $summary.DigestsSent, $summary.Warnings, $summary.Errors)
    return $summary
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when the file is dot-sourced (tests load the functions
# that way); Azure Automation and a direct invocation run it.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CredentialHygieneRun -SenderMailbox $SenderMailbox -WarnDays $WarnDays -RemoveExpired ([bool]$RemoveExpired) `
        -RemoveAfterDays $RemoveAfterDays -MaxRemovalsPerRun $MaxRemovalsPerRun -ExcludedAppTag $ExcludedAppTag `
        -ExcludedAppNames $ExcludedAppNames -FallbackRecipient $FallbackRecipient -ReportPath $ReportPath `
        -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken
}
