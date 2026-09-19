<#
.SYNOPSIS
    Compares the tenant's Entra authentication methods policy with the desired
    state held in Automation variables, mails a drift digest when they differ,
    and, when explicitly allowed, patches the tenant to match.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity.
    The desired state is the same set of JSON files that scripts/Set-AuthenticationMethods.ps1
    reads from policies/entra/authentication-methods, published by
    stacks/azure-automation as one Automation string variable per file
    (AuthMethods_Policy for policy.json, AuthMethods_<Id> for methods/<Id>.json).
    The runbook reads those variables, resolves group display names to object
    IDs, reads the live policy with one GET, and computes the same field-level
    drift list the script does, because both load the same library.

    Why a weekly runbook when the release train already enforces on merge.
    The pipeline runs when the repository changes; this runs when the tenant
    changes. An administrator who enables SMS from the portal on a Tuesday is
    not caught by a workflow that last ran on Monday's merge, and is caught
    here on Sunday, with a digest naming the field, the live value, and the
    value the repository holds. Dry by default, the runbook is a detector; with
    DryRun false it is the same enforcement the pipeline performs, on the
    schedule the cell declares.

    The two guards are the library's: the run refuses to plan a change that
    would leave no enabled method, and policyMigrationState is never sent
    unless -AllowMigrationStateChange $true.

    Design rules shared by every runbook in this repository are in
    automation/README.md: managed identity only, DryRun on by default, a
    national cloud switch, and structured logging. This runbook differs from
    the other two in one respect, explained in
    modules/azure/automation-runbooks/README.md: the block between the two
    INLINE_LIBRARY markers below is replaced at deploy time with
    automation/lib/AuthenticationMethods.Common.ps1, so the shared logic is
    versioned once and the deployed file is still one file.

.PARAMETER SenderMailbox
    Shared mailbox the digest is sent from, as a user principal name. The
    managed identity needs Mail.Send and an Exchange application access policy
    that restricts it to this mailbox (see automation/README.md).

.PARAMETER Recipients
    Mail addresses that receive the drift digest, as one string: a JSON array
    such as ["iam@corp.example.com"] or a list separated by commas or
    semicolons. It is a string rather than a string array because Azure
    Automation passes job schedule parameters as strings, and a plain string
    binds the same way from a schedule, the portal, and a local call.

.PARAMETER VariablePrefix
    Prefix of the Automation variables that hold the desired state. Default
    AuthMethods_, so policy.json is AuthMethods_Policy and methods/Fido2.json
    is AuthMethods_Fido2.

.PARAMETER MethodIds
    Method configuration ids to manage, as one string separated by
    semicolons (commas separate too). Default: the eight the folder ships.
    A missing variable for a listed id is an error, never a silent skip, and
    an empty list is refused for the same reason. It is a string rather than
    a string array for the reason Recipients is; a local run may pass a JSON
    array.

.PARAMETER DesiredStatePath
    Workstation only: read the desired state from this folder instead of
    Automation variables, for a local dry run against a tenant.

.PARAMETER AllowMigrationStateChange
    Default $false. Permit policyMigrationState to be sent. Read
    policies/entra/authentication-methods/README.md before setting this.

.PARAMETER ReportPath
    Optional path for a JSON report of the drift list. On an Automation
    worker use a path under $env:TEMP.

.PARAMETER DryRun
    Default $true. The policy is compared and the digest is logged as
    "would send"; nothing is patched and nothing is mailed. Pass -DryRun:$false
    to mail the digest and patch the drift.

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
    # Dry run on a workstation from the repository files, with a CLI token.
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    .\Invoke-AuthenticationMethodsDrift.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients iam@corp.example.com -DesiredStatePath ..\..\policies\entra\authentication-methods -AccessToken $token

.EXAMPLE
    # Live run from Azure Automation: parameters come from the job schedule.
    .\Invoke-AuthenticationMethodsDrift.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients '["iam@corp.example.com"]' -DryRun:$false -ClientId <identity client id>

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Graph application permissions: Policy.ReadWrite.AuthenticationMethod
    (Policy.Read.AuthenticationMethod is enough for a dry run), Group.Read.All
    to resolve names, Mail.Send for the digest.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox,

    [Parameter(Mandatory = $true)]
    [string]$Recipients,

    [string]$VariablePrefix = 'AuthMethods_',

    [string]$MethodIds = 'Fido2;MicrosoftAuthenticator;TemporaryAccessPass;Sms;Voice;Email;SoftwareOath;X509Certificate',

    [string]$DesiredStatePath = '',

    [bool]$AllowMigrationStateChange = $false,

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
# Shared logic. Between the two marker lines, stacks/azure-automation inlines
# automation/lib/AuthenticationMethods.Common.ps1 at deploy time (see
# modules/azure/automation-runbooks, library_path), so the published runbook
# is one file. On a workstation and in the tests the block dot-sources the
# same file from disk, so both paths run identical code. Do not edit the
# marker lines; Terraform splits on them.
# ---------------------------------------------------------------------------

# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\AuthenticationMethods.Common.ps1')
# INLINE_LIBRARY_END

# ---------------------------------------------------------------------------
# Desired state from Automation variables. One variable per file, read with
# Get-AutomationVariable, which exists only inside the sandbox; a workstation
# run passes -DesiredStatePath instead. A listed method whose variable is
# missing is an error: the stack did not publish it, and managing fewer
# methods than the cell declares would be a silent gap.
# ---------------------------------------------------------------------------

function Get-DesiredStateJson {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        throw ('Automation variable {0} cannot be read outside Azure Automation. Pass -DesiredStatePath for a workstation run.' -f $Name)
    }
    $value = Get-AutomationVariable -Name $Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        throw ('Automation variable {0} is missing or empty. stacks/azure-automation publishes it from desired_state_files.' -f $Name)
    }
    return [string]$value
}

function Get-DesiredStateFromVariables {
    param(
        [Parameter(Mandatory = $true)][string]$VariablePrefix,
        [Parameter(Mandatory = $true)][string[]]$MethodIds
    )

    $policyJson = ''
    try { $policyJson = Get-DesiredStateJson -Name ($VariablePrefix + 'Policy') }
    catch {
        Write-RunLog -Level Warn -Message ('No policy-level desired state: {0}' -f $_.Exception.Message)
        $policyJson = ''
    }

    $methodJson = @{}
    foreach ($id in $MethodIds) { $methodJson[$id] = Get-DesiredStateJson -Name ($VariablePrefix + $id) }

    return Import-AuthMethodsDesiredStateFromJson -PolicyJson $policyJson -MethodJson $methodJson
}

# ---------------------------------------------------------------------------
# Digest.
# ---------------------------------------------------------------------------

function ConvertTo-HtmlText {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '' }
    return $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-DriftDigestHtml {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Drift,
        [Parameter(Mandatory = $true)][bool]$Enforced
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">')
    [void]$sb.Append(('<p>The Entra authentication methods policy differs from the desired state in the identity-as-code repository in {0} field(s).</p>' -f $Drift.Count))
    if ($Enforced) {
        [void]$sb.Append('<p>The differences below were patched back to the desired state by the runbook. The Entra audit log records each write under the runbook identity.</p>')
    }
    else {
        [void]$sb.Append('<p>This run was a report only. Either the tenant was changed outside the repository (revert it, or change the repository if the new value is intended), or a merged change has not been released yet.</p>')
    }
    [void]$sb.Append('<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse">')
    [void]$sb.Append('<tr><th>Scope</th><th>Configuration</th><th>Field</th><th>Kind</th><th>Desired</th><th>Live</th><th>Held</th></tr>')

    foreach ($row in ($Drift | Sort-Object -Property Scope, Id, Path)) {
        [void]$sb.Append('<tr>')
        foreach ($value in @($row.Scope, $row.Id, $row.Path, $row.Kind, $row.Desired, $row.Live, $(if ($row.Guarded) { 'yes' } else { '' }))) {
            [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText -Value ([string]$value))))
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</table>')
    [void]$sb.Append(('<p style="color:#666">Sent by the authentication methods drift runbook (run {0}). This mailbox is not monitored.</p>' -f (ConvertTo-HtmlText -Value $script:RunId)))
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

function Invoke-AuthenticationMethodsDriftRun {
    param(
        [Parameter(Mandatory = $true)][string]$SenderMailbox,
        [Parameter(Mandatory = $true)][string[]]$Recipients,
        [string]$VariablePrefix = 'AuthMethods_',
        [string[]]$MethodIds = @('Fido2', 'MicrosoftAuthenticator', 'TemporaryAccessPass', 'Sms', 'Voice', 'Email', 'SoftwareOath', 'X509Certificate'),
        [string]$DesiredStatePath = '',
        [bool]$AllowMigrationStateChange = $false,
        [string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [string]$ClientId = '',
        [string]$AccessToken = ''
    )

    Write-RunLog -Level Info -Message ('Starting authentication methods drift. DryRun={0} AllowMigrationStateChange={1} Sender={2} Recipients={3} Source={4}' -f $DryRun, $AllowMigrationStateChange, $SenderMailbox, ($Recipients -join ';'), $(if ($DesiredStatePath) { $DesiredStatePath } else { 'Automation variables ' + $VariablePrefix + '*' }))

    if ([string]::IsNullOrWhiteSpace($DesiredStatePath)) { $desired = Get-DesiredStateFromVariables -VariablePrefix $VariablePrefix -MethodIds $MethodIds }
    else { $desired = Import-AuthMethodsDesiredState -Path $DesiredStatePath }
    Write-RunLog -Level Info -Message ('Desired state: {0} method(s){1}.' -f $desired.Methods.Count, $(if ($null -ne $desired.Policy) { ' and the policy object' } else { '' }))

    Initialize-GraphSession -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken

    $live = Get-AuthMethodsLivePolicy
    Write-RunLog -Level Info -Message ('Read the live policy: {0} method configuration(s).' -f $live.Methods.Count)

    $plan = Get-AuthMethodsPlan -Desired $desired -Live $live -AllowMigrationStateChange $AllowMigrationStateChange
    $drift = @($plan.Drift)
    Write-RunLog -Level Info -Message ('Drift: {0} field difference(s) across {1} method(s){2}.' -f $drift.Count, $plan.MethodPatches.Count, $(if ($null -ne $plan.PolicyPatch) { ' plus the policy object' } else { '' }))
    foreach ($row in $drift) {
        Write-RunLog -Level Info -Message ('  {0} {1} {2}: {3} desired={4} live={5}{6}' -f $row.Scope, $row.Id, $row.Path, $row.Kind, $row.Desired, $row.Live, $(if ($row.Guarded) { ' (held)' } else { '' }))
    }

    $apply = Invoke-AuthMethodsApply -Plan $plan -DryRun $DryRun

    $digestSent = $false
    if ($drift.Count -gt 0) {
        $subject = ('Authentication methods policy drift: {0} field(s) differ' -f $drift.Count)
        if ($DryRun) {
            Write-RunLog -Level Action -Message ('Would send drift digest to {0}.' -f ($Recipients -join ';'))
        }
        else {
            try {
                $html = New-DriftDigestHtml -Drift $drift -Enforced ($apply.Patched -gt 0)
                Send-GraphMail -SenderMailbox $SenderMailbox -To $Recipients -Subject $subject -HtmlBody $html
                $digestSent = $true
                Write-RunLog -Level Action -Message ('Sent drift digest to {0}.' -f ($Recipients -join ';'))
            }
            catch {
                Write-RunLog -Level Error -Message ('Failed to send drift digest: {0}' -f $_.Exception.Message)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $directory = Split-Path -Path $ReportPath -Parent
        if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ReportPath, (ConvertTo-AuthMethodsJson -Value @($drift)) + "`n", $utf8NoBom)
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    $summary = [PSCustomObject]@{
        RunId                     = $script:RunId
        Runbook                   = 'Invoke-AuthenticationMethodsDrift'
        DryRun                    = $DryRun
        AllowMigrationStateChange = $AllowMigrationStateChange
        Environment               = $Environment
        MethodsDesired            = $desired.Methods.Count
        MethodsLive               = $live.Methods.Count
        DriftCount                = $drift.Count
        MethodsDrifted            = $plan.MethodPatches.Count
        PolicyDrifted             = ($null -ne $plan.PolicyPatch)
        MigrationStateHeld        = $plan.MigrationStateHeld
        PatchesPlanned            = $apply.Planned
        PatchesApplied            = $apply.Patched
        PatchesFailed             = $apply.Failed
        DigestSent                = $digestSent
        Warnings                  = (Get-RunLogCount -Level 'Warn')
        Errors                    = (Get-RunLogCount -Level 'Error')
        ReportPath                = $ReportPath
        CompletedUtc              = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-RunLog -Level Info -Message ('Finished. drift={0} patched={1} digestSent={2} warnings={3} errors={4}' -f $summary.DriftCount, $summary.PatchesApplied, $summary.DigestSent, $summary.Warnings, $summary.Errors)
    return $summary
}

function ConvertTo-RecipientList {
    <# Turns the Recipients string into an array of addresses. Accepts a JSON
       array or a comma or semicolon separated list, trims blanks, and rejects
       anything that is not shaped like a mail address. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $text = $Value.Trim()
    $items = @()
    if ($text.StartsWith('[')) {
        # PowerShell 7 reads an unterminated array without an error; refuse it on both editions.
        if (-not $text.EndsWith(']')) { throw 'Recipients looks like a JSON array but does not parse: it does not end with "]".' }
        try { $parsed = ConvertFrom-Json -InputObject $text }
        catch { throw ('Recipients looks like a JSON array but does not parse: {0}' -f $_.Exception.Message) }
        # Windows PowerShell 5.1 emits a parsed JSON array as one object, so
        # enumerate it explicitly rather than trusting @() to unroll it.
        foreach ($element in $parsed) { $items += $element }
    }
    else {
        $items = @($text -split '[,;]')
    }
    $list = @()
    foreach ($item in $items) {
        $address = ([string]$item).Trim()
        if ($address.Length -eq 0) { continue }
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Recipients contains a value that is not a mail address: "{0}"' -f $address) }
        $list += $address
    }
    if ($list.Count -eq 0) { throw 'Recipients is empty. Supply at least one mail address.' }
    return ,$list
}

function ConvertTo-MethodIdList {
    <# Turns the MethodIds string into an array of method configuration ids.
       Accepts a JSON array or a comma or semicolon separated list, trims
       blanks, and refuses an empty result: a runbook told to manage no
       method would report zero drift for the wrong reason. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $text = $Value.Trim()
    $items = @()
    if ($text.StartsWith('[')) {
        # PowerShell 7 reads an unterminated array without an error; refuse it on both editions.
        if (-not $text.EndsWith(']')) { throw 'MethodIds looks like a JSON array but does not parse: it does not end with "]".' }
        try { $parsed = ConvertFrom-Json -InputObject $text }
        catch { throw ('MethodIds looks like a JSON array but does not parse: {0}' -f $_.Exception.Message) }
        foreach ($element in $parsed) { $items += $element }
    }
    else {
        $items = @($text -split '[,;]')
    }
    $list = @()
    foreach ($item in $items) {
        $id = ([string]$item).Trim()
        if ($id.Length -eq 0) { continue }
        if ($id -notmatch '^[A-Za-z0-9]+$') { throw ('MethodIds contains a value that is not a method configuration id: "{0}"' -f $id) }
        $list += $id
    }
    if ($list.Count -eq 0) { throw 'MethodIds is empty. Supply at least one method configuration id.' }
    return ,$list
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when the file is dot-sourced (tests load the functions
# that way); Azure Automation and a direct invocation run it.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AuthenticationMethodsDriftRun -SenderMailbox $SenderMailbox -Recipients (ConvertTo-RecipientList -Value $Recipients) -VariablePrefix $VariablePrefix `
        -MethodIds (ConvertTo-MethodIdList -Value $MethodIds) -DesiredStatePath $DesiredStatePath -AllowMigrationStateChange ([bool]$AllowMigrationStateChange) `
        -ReportPath $ReportPath -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken
}
