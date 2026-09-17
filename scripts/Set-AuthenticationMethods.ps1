<#
.SYNOPSIS
    Compares the Entra authentication methods policy with the desired state in
    policies/entra/authentication-methods and, when explicitly allowed, patches
    the tenant to match.

.DESCRIPTION
    The authentication methods policy (which methods are enabled, for whom, with
    what settings, plus the registration campaign, report-suspicious-activity,
    and system-preferred MFA settings) has no Terraform resource: the azuread
    provider does not model it, and the objects are patch-only singletons that
    cannot be created, destroyed, or imported. This script is the desired-state
    tool for it. It reads a folder of JSON (one file per method configuration,
    one for the policy-level settings; see the folder README for the contract),
    resolves every group display name to an object ID, reads the live policy
    with one GET, computes a field-level drift list, prints it as a table and
    as JSON, and with -DryRun:$false sends one PATCH per drifted method and one
    for the policy object.

    Two guards the script applies on its own. It refuses to plan a change that
    would leave the tenant with no enabled method configuration, because a
    tenant in that state cannot register MFA at all. And it never sends
    policyMigrationState unless -AllowMigrationStateChange $true, because
    migrationComplete switches off the legacy per-user MFA and SSPR settings
    for the whole tenant in one write; a difference in that field is reported
    and held.

    -Export reverses the flow for adopting an existing tenant: the live policy
    is written into the folder layout with group IDs replaced by display names,
    so the first real run can show zero drift before anything is patched.

    The diff, plan, apply, and export logic lives in
    automation/lib/AuthenticationMethods.Common.ps1, dot-sourced here and
    inlined into the Automation runbook that runs the same comparison weekly.
    Everything else (identity, transport with retries, logging) follows the
    runbook rules in automation/README.md.

.PARAMETER DesiredStatePath
    Folder holding policy.json and methods/*.json. With -Export it is where the
    files are written.

.PARAMETER DryRun
    Default $true. The policy is read and compared and every PATCH is logged
    as "Would". Pass -DryRun:$false to patch.

.PARAMETER FailOnDrift
    Default $false. When $true the script exits with code 2 if any drift was
    found, for a pull request check that must go red.

.PARAMETER Export
    Default $false. Write the live policy into -DesiredStatePath instead of
    comparing. Never patches. policyMigrationState is logged, not written.

.PARAMETER AllowMigrationStateChange
    Default $false. Permit policyMigrationState in policy.json to be sent.
    Read the folder README before setting this.

.PARAMETER ReportPath
    Optional path for a JSON report (drift list plus summary). When empty the
    JSON is printed after the table.

.PARAMETER Environment
    National cloud: Global (default) or USGov. Selects the Graph base URL and
    the token resource.

.PARAMETER ClientId
    Client ID of a user-assigned managed identity, for a run inside Azure
    Automation or on a VM with the identity endpoint. Unused on a workstation.

.PARAMETER AccessToken
    A Graph access token obtained by the caller (the pipeline passes the one
    az account get-access-token returns). Never logged. When empty the script
    tries the identity endpoint, Az.Accounts, then the Azure CLI.

.PARAMETER RunId
    Correlation ID stamped on every log line and on the summary.

.EXAMPLE
    # Report drift from a workstation, no writes.
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Set-AuthenticationMethods.ps1 -DesiredStatePath ..\policies\entra\authentication-methods -AccessToken $token

.EXAMPLE
    # Pull request gate: red on drift, no writes.
    .\Set-AuthenticationMethods.ps1 -DesiredStatePath ..\policies\entra\authentication-methods -DryRun:$true -FailOnDrift:$true -AccessToken $token

.EXAMPLE
    # Release train: enforce.
    .\Set-AuthenticationMethods.ps1 -DesiredStatePath ..\policies\entra\authentication-methods -DryRun:$false -AccessToken $token -ReportPath .\out\auth-methods.json

.EXAMPLE
    # Adopt an existing tenant: write the live policy as files, then trim them.
    .\Set-AuthenticationMethods.ps1 -DesiredStatePath ..\policies\entra\authentication-methods -Export $true -AccessToken $token

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Graph permissions: Policy.Read.AuthenticationMethod and Group.Read.All for a
    dry run or export; Policy.ReadWrite.AuthenticationMethod to patch. The
    delegated caller needs the Authentication Policy Administrator role.
    Exit codes: 0 no drift or drift patched, 1 an error was logged, 2 drift
    found with -FailOnDrift $true.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DesiredStatePath,

    [bool]$DryRun = $true,

    [bool]$FailOnDrift = $false,

    [bool]$Export = $false,

    [bool]$AllowMigrationStateChange = $false,

    [string]$ReportPath = '',

    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',

    [string]$ClientId = '',

    [string]$AccessToken = '',

    [string]$RunId = ([Guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Logging. Same shape as the runbooks; Info goes to the console because this
# is a workstation and pipeline script. No line ever contains a token.
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
        default { Write-Host $line }
    }
}

function Get-RunLogCount {
    param([Parameter(Mandatory = $true)][string]$Level)
    return @($script:RunLog | Where-Object { $_.Level -eq $Level }).Count
}

# ---------------------------------------------------------------------------
# Identity. Four sources, tried in order: a caller-supplied token (the
# pipeline and local testing), the Azure Automation identity endpoint, Az.Accounts
# when it happens to be loaded, and the Azure CLI, which is how a workstation
# is signed in. The token value is held in a script variable and is never
# written to any stream.
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
        if ($context) {
            $result = Get-AzAccessToken -ResourceUrl $Resource
            $token = $result.Token
            if ($token -is [System.Security.SecureString]) { $token = ConvertFrom-SecureStringToPlain -Value $token }
            Write-RunLog -Level Info -Message 'Token source: Az.Accounts.'
            return [string]$token
        }
    }

    # Workstation and pipeline runner: az login is the identity.
    if (Get-Command -Name az -ErrorAction SilentlyContinue) {
        $token = & az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($token | Out-String))) {
            Write-RunLog -Level Info -Message 'Token source: Azure CLI.'
            return ([string]($token | Select-Object -First 1)).Trim()
        }
    }

    throw 'No credential source. Pass -AccessToken, run az login or Connect-AzAccount, or run where a managed identity endpoint exists.'
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
       against the v1.0 endpoint of the selected cloud unless they start with
       an explicit "v1.0/" or "beta/" segment (the authentication methods
       policy singleton exposes two of its settings only on beta); absolute
       URIs (nextLink) are used as given. Returns the parsed JSON body, or
       $null for 204. #>
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowNull()][object]$Body = $null,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5
    )

    if ($Uri -match '^https://') { $fullUri = $Uri }
    elseif ($Uri -match '^(v1\.0|beta)/') { $fullUri = '{0}/{1}' -f $script:GraphBaseUri, $Uri }
    else { $fullUri = '{0}/v1.0/{1}' -f $script:GraphBaseUri, $Uri.TrimStart('/') }
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
# Shared logic: normalize, diff, plan, apply, export. The runbook carries the
# same file inlined by Terraform; here it is dot-sourced from the repository.
# ---------------------------------------------------------------------------

. (Join-Path -Path $PSScriptRoot -ChildPath '..\automation\lib\AuthenticationMethods.Common.ps1')

# ---------------------------------------------------------------------------
# Report and run.
# ---------------------------------------------------------------------------

function Write-DriftReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Drift,
        [Parameter(Mandatory = $true)][PSCustomObject]$Summary,
        [AllowEmptyString()][string]$ReportPath = ''
    )

    Write-Host ''
    Write-Host (Format-AuthMethodsDriftTable -Drift $Drift)
    Write-Host ''

    $report = [ordered]@{ Summary = $Summary; Drift = @($Drift) }
    $json = ConvertTo-AuthMethodsJson -Value $report
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-Host $json
        return
    }
    $directory = Split-Path -Path $ReportPath -Parent
    if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ReportPath, $json + "`n", $utf8NoBom)
    Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
}

function Invoke-AuthenticationMethodsRun {
    param(
        [Parameter(Mandatory = $true)][string]$DesiredStatePath,
        [bool]$DryRun = $true,
        [bool]$FailOnDrift = $false,
        [bool]$Export = $false,
        [bool]$AllowMigrationStateChange = $false,
        [string]$ReportPath = '',
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [string]$ClientId = '',
        [string]$AccessToken = ''
    )

    Write-RunLog -Level Info -Message ('Starting authentication methods policy run. DryRun={0} FailOnDrift={1} Export={2} AllowMigrationStateChange={3} Path={4}' -f $DryRun, $FailOnDrift, $Export, $AllowMigrationStateChange, $DesiredStatePath)
    Initialize-GraphSession -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken

    $live = Get-AuthMethodsLivePolicy
    Write-RunLog -Level Info -Message ('Read the live policy: {0} method configuration(s), policyMigrationState={1}.' -f $live.Methods.Count, $(if ($live.Policy.Contains('policyMigrationState')) { $live.Policy['policyMigrationState'] } else { '(absent)' }))

    if ($Export) {
        $files = @(Export-AuthMethodsDesiredState -Live $live -Path $DesiredStatePath)
        foreach ($file in $files) { Write-RunLog -Level Action -Message ('Wrote {0}.' -f $file) }
        $summary = [PSCustomObject]@{
            RunId            = $script:RunId
            Script           = 'Set-AuthenticationMethods'
            Mode             = 'Export'
            DryRun           = $true
            Environment      = $Environment
            DesiredStatePath = $DesiredStatePath
            FilesWritten     = $files.Count
            MethodsLive      = $live.Methods.Count
            DriftCount       = 0
            Warnings         = (Get-RunLogCount -Level 'Warn')
            Errors           = (Get-RunLogCount -Level 'Error')
            CompletedUtc     = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        Write-RunLog -Level Info -Message ('Finished export. files={0} warnings={1} errors={2}' -f $summary.FilesWritten, $summary.Warnings, $summary.Errors)
        return $summary
    }

    $desired = Import-AuthMethodsDesiredState -Path $DesiredStatePath
    Write-RunLog -Level Info -Message ('Desired state: {0} method file(s){1}.' -f $desired.Methods.Count, $(if ($null -ne $desired.Policy) { ' and policy.json' } else { '' }))

    $plan = Get-AuthMethodsPlan -Desired $desired -Live $live -AllowMigrationStateChange $AllowMigrationStateChange
    $drift = @($plan.Drift)
    $enforceable = @($drift | Where-Object { -not $_.Guarded })
    Write-RunLog -Level Info -Message ('Drift: {0} field difference(s) across {1} method(s){2}; {3} held by the migration state guard.' -f $drift.Count, $plan.MethodPatches.Count, $(if ($null -ne $plan.PolicyPatch) { ' plus the policy object' } else { '' }), ($drift.Count - $enforceable.Count))

    $apply = Invoke-AuthMethodsApply -Plan $plan -DryRun $DryRun

    $summary = [PSCustomObject]@{
        RunId                     = $script:RunId
        Script                    = 'Set-AuthenticationMethods'
        Mode                      = $(if ($DryRun) { 'Report' } else { 'Enforce' })
        DryRun                    = $DryRun
        FailOnDrift               = $FailOnDrift
        AllowMigrationStateChange = $AllowMigrationStateChange
        Environment               = $Environment
        DesiredStatePath          = $DesiredStatePath
        MethodsDesired            = $desired.Methods.Count
        MethodsLive               = $live.Methods.Count
        DriftCount                = $drift.Count
        MethodsDrifted            = $plan.MethodPatches.Count
        PolicyDrifted             = ($null -ne $plan.PolicyPatch)
        MigrationStateHeld        = $plan.MigrationStateHeld
        PatchesPlanned            = $apply.Planned
        PatchesApplied            = $apply.Patched
        PatchesFailed             = $apply.Failed
        Warnings                  = (Get-RunLogCount -Level 'Warn')
        Errors                    = (Get-RunLogCount -Level 'Error')
        ReportPath                = $ReportPath
        CompletedUtc              = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    Write-DriftReport -Drift $drift -Summary $summary -ReportPath $ReportPath
    Write-RunLog -Level Info -Message ('Finished. drift={0} patched={1} failed={2} warnings={3} errors={4}' -f $summary.DriftCount, $summary.PatchesApplied, $summary.PatchesFailed, $summary.Warnings, $summary.Errors)
    return $summary
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when the file is dot-sourced (tests load the functions
# that way); a direct invocation runs it and sets the exit code.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-AuthenticationMethodsRun -DesiredStatePath $DesiredStatePath -DryRun ([bool]$DryRun) -FailOnDrift ([bool]$FailOnDrift) `
        -Export ([bool]$Export) -AllowMigrationStateChange ([bool]$AllowMigrationStateChange) -ReportPath $ReportPath `
        -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken
    $result
    if ($result.Errors -gt 0) { exit 1 }
    if ($FailOnDrift -and $result.DriftCount -gt 0) {
        Write-RunLog -Level Warn -Message ('FailOnDrift is set and {0} difference(s) were found; exiting 2.' -f $result.DriftCount)
        exit 2
    }
    exit 0
}
