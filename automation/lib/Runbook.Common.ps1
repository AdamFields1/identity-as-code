# Runbook.Common.ps1
#
# The logging, identity, transport, and lookup helpers shared by the runbooks
# in automation/runbooks that name this file as their library. It is the
# second library under automation/lib and the first whose purpose is plumbing
# rather than domain logic: the first three runbooks each carry their own copy
# of these helpers (see automation/README.md, "Runbooks are self-contained
# files"), and six more copies would be six places for a retry or a token bug
# to hide. Shared here, the helpers are versioned once, tested once, and still
# published as part of one self-contained file.
#
# How it reaches Azure Automation. A runbook carries two marker lines with a
# dot-source of this file between them. On a workstation and in the tests the
# dot-source loads this file from disk; at plan time
# modules/azure/automation-runbooks replaces the whole block with this file's
# content (library_path, or library = "Runbook.Common.ps1" in a
# stacks/azure-automation cell), so the published runbook is one file and the
# tested code and the deployed code are the same text. This file therefore:
#
#   - has no param block, no #Requires line, and no use of $PSScriptRoot or
#     $MyInvocation, because once inlined it is the middle of another script;
#   - never contains either marker string itself;
#   - is ASCII with no byte order mark, because Terraform's file() would carry
#     a BOM into the middle of the published runbook.
#
# Contract with the host runbook:
#
#   1. Declare [bool]$DryRun = $true, [string]$Environment, [string]$ClientId,
#      [string]$AccessToken, and [string]$RunId in the param block, set
#      $ErrorActionPreference = 'Stop' and $VerbosePreference = 'Continue',
#      then carry the marker block.
#   2. Define no function with a name this file defines.
#   3. Call Initialize-RunContext first in the run function, New-RunSummary
#      next, and emit Complete-RunSummary as the last output.
#   4. Put every write behind DryRun (Invoke-RunbookAction does it for you).
#   5. Every function here that returns a list writes the items to the
#      pipeline, so wrap the call in @() to get an array even for one item:
#      $ids = @(Get-TransitiveGroupMemberIds -GroupId $id).
#   6. Keep schedule-bound parameters to [bool], [int], and [string], pass
#      lists in the semicolon form (ConvertTo-StringList), and read
#      structured configuration from an Automation string variable
#      (Get-AutomationStringVariable), not from JSON text in a parameter.
#   7. Let the library do every web request. POST and PATCH are not
#      repeated after a server error unless the call says -RetryNonIdempotent;
#      a blob download goes through Invoke-StorageRequest -Operation
#      GetBlobToFile rather than a second Invoke-WebRequest call.
#
# Nothing in this file writes an access token, a request header, or the
# identity endpoint secret to any stream. Error text that came from a service
# is scrubbed of anything shaped like a token before it is logged or thrown.
#
# Windows PowerShell 5.1 and PowerShell 7: no ternary, no null-coalescing or
# null-conditional operators, and the one Invoke-WebRequest call handles both
# editions' error shapes. A parsed JSON object is recognised with
# Test-RunbookJsonObject, never with "-is [PSCustomObject]": that accelerator
# names System.Management.Automation.PSObject, so on either edition any
# PSObject-wrapped value (a JSON array returned by ConvertFrom-Json on 5.1, a
# string written to the pipeline) passes it.

# ---------------------------------------------------------------------------
# Run state. Reset by Initialize-RunContext; the defaults below make every
# function usable before it is called (tests, ad hoc use).
# ---------------------------------------------------------------------------

$script:RunbookCommonVersion = '1.1.0'
if (-not (Get-Variable -Name 'RunId' -Scope Script -ErrorAction SilentlyContinue) -or [string]::IsNullOrWhiteSpace([string]$script:RunId)) {
    $script:RunId = [Guid]::NewGuid().ToString()
}
$script:RunLog = New-Object System.Collections.ArrayList
$script:RunbookContext = @{
    RunbookName = 'runbook'
    Environment = 'Global'
    ClientId    = ''
    AccessToken = $null
    DryRun      = $true
    StartedUtc  = [DateTime]::UtcNow
}
$script:RunbookTokenCache = @{}
$script:RunbookTokenSourceLogged = @{}
$script:RunbookSecretValues = New-Object System.Collections.ArrayList
$script:RunbookLookupCache = @{}
$script:RunbookApiVersions = @{
    Subscriptions    = '2022-12-01'
    ManagementGroups = '2020-05-01'
    Storage          = '2023-11-03'
}
$script:RunbookGuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Test hook for Get-AutomationStringVariable: a hashtable of variable name to
# value that stands in for the Automation sandbox. Kept across a second
# dot-source and never reset by Initialize-RunContext, so a test can set it
# before it runs a runbook. $null (the default) means "not set".
if (-not (Get-Variable -Name 'RunbookAutomationVariables' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RunbookAutomationVariables = $null
}
# Which optional ConvertFrom-Json parameters this edition has; filled on first
# use by ConvertFrom-RunbookJsonText.
$script:RunbookJsonParameters = $null

# ---------------------------------------------------------------------------
# Logging.
#
# Info and Action go to the verbose stream, not the output stream. That is a
# deliberate choice over Write-Output: anything a function writes to the
# output stream becomes part of that function's return value, so a retry
# warning or a "Would remove" line written with Write-Output inside a helper
# would end up inside the caller's result array, and the runbook's final
# output would no longer be one summary object. The verbose stream is kept
# with the job because modules/azure/automation-runbooks publishes every
# runbook with log_verbose = true, and the host sets
# $VerbosePreference = 'Continue'. Warn and Error use their own streams so a
# job stream filter or the SIEM finds them without parsing text.
# ---------------------------------------------------------------------------

function Write-RunLog {
    <#
    .SYNOPSIS
        Writes one structured log line: UTC timestamp, level, run id, message.
    .DESCRIPTION
        The line format is "2026-09-16T06:00:12Z [ACTION] run=<RunId> <Message>".
        Info and Action go to the verbose stream, Warn to the warning stream,
        Error to the error stream as a non-terminating error. Every entry is
        also kept in memory so Complete-RunSummary can count warnings and
        errors. The message is scrubbed of token-shaped text first. An Action
        line that starts with "Would" is a dry run; without it, a write that
        happened.
    .PARAMETER Level
        Info, Action, Warn, or Error.
    .PARAMETER Message
        The text. May be empty.
    .EXAMPLE
        Write-RunLog -Level Action -Message 'Would remove user@corp.example.com from "Contoso Admins".'
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Info', 'Action', 'Warn', 'Error')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    $safe = Protect-RunbookText -Text $Message -MaxLength 0
    $entry = [PSCustomObject]@{
        Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Level     = $Level
        RunId     = [string]$script:RunId
        Message   = $safe
    }
    if ($null -eq $script:RunLog) { $script:RunLog = New-Object System.Collections.ArrayList }
    [void]$script:RunLog.Add($entry)

    $line = '{0} [{1}] run={2} {3}' -f $entry.Timestamp, $Level.ToUpperInvariant(), $entry.RunId, $safe
    switch ($Level) {
        'Warn' { Write-Warning -Message $line }
        'Error' {
            # Local override: the host runs with Stop, and a logged error must
            # not end the run by itself.
            $ErrorActionPreference = 'Continue'
            Write-Error -Message $line
        }
        default { Write-Verbose -Message $line }
    }
}

function Get-RunLogCount {
    <#
    .SYNOPSIS
        Number of log entries at one level in this run.
    .PARAMETER Level
        Info, Action, Warn, or Error.
    .EXAMPLE
        Get-RunLogCount -Level Warn
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('Info', 'Action', 'Warn', 'Error')][string]$Level)

    if ($null -eq $script:RunLog) { return 0 }
    return @($script:RunLog | Where-Object { $_.Level -eq $Level }).Count
}

function Get-RunLogEntries {
    <#
    .SYNOPSIS
        The log entries of this run (Timestamp, Level, RunId, Message).
    .DESCRIPTION
        Writes the entries to the pipeline, oldest first, optionally only one
        level. Useful for a digest of warnings and errors. Wrap in @().
    .PARAMETER Level
        Optional level filter.
    .EXAMPLE
        $problems = @(Get-RunLogEntries -Level Error)
    #>
    param([ValidateSet('', 'Info', 'Action', 'Warn', 'Error')][string]$Level = '')

    if ($null -eq $script:RunLog) { return }
    foreach ($entry in $script:RunLog) {
        if ([string]::IsNullOrEmpty($Level) -or $entry.Level -eq $Level) { $entry }
    }
}

function Protect-RunbookText {
    <#
    .SYNOPSIS
        Removes anything token-shaped from a piece of text.
    .DESCRIPTION
        Replaces every token value this run has seen (supplied or acquired),
        JSON Web Tokens, bearer credentials, SAS signatures, and
        access_token, refresh_token, or client_secret values with a
        placeholder. With MaxLength above zero, also collapses whitespace and
        truncates, which is how service error bodies are shortened for an
        exception message.
    .PARAMETER Text
        The text to scrub. Null becomes an empty string.
    .PARAMETER MaxLength
        0 (default) keeps the length and the whitespace; otherwise the result
        is collapsed to one line and cut at this many characters.
    .EXAMPLE
        Protect-RunbookText -Text $response.Content -MaxLength 400
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateRange(0, 100000)][int]$MaxLength = 0
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $result = $Text
    if ($null -ne $script:RunbookSecretValues) {
        foreach ($secret in $script:RunbookSecretValues) {
            $value = [string]$secret
            if ($value.Length -ge 8) { $result = $result.Replace($value, '[redacted]') }
        }
    }
    $result = $result -replace 'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*', '[redacted-jwt]'
    $result = $result -replace '(?i)\bbearer\s+[A-Za-z0-9\-\._~\+/]+=*', 'Bearer [redacted]'
    $result = $result -replace '(?i)([?&]sig=)[^&\s"''<]+', '$1[redacted]'
    $result = $result -replace '(?i)("?\b(access_token|refresh_token|client_secret|x-identity-header)"?\s*[:=]\s*"?)[^"&\s,}]+', '$1[redacted]'
    if ($MaxLength -gt 0) {
        $result = ($result -replace '\s+', ' ').Trim()
        if ($result.Length -gt $MaxLength) { $result = $result.Substring(0, $MaxLength) + '...' }
    }
    return $result
}

function Add-RunbookSecret {
    <#
    .SYNOPSIS
        Registers a value that must never appear in a log line or an error.
    .DESCRIPTION
        Internal. Get-RunbookAccessToken and Initialize-RunContext call it for
        every token they hold, so Protect-RunbookText can remove the literal
        value even when a service echoes it back in an error body.
    .PARAMETER Value
        The secret. Values shorter than eight characters are ignored.
    .EXAMPLE
        Add-RunbookSecret -Value $token
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -lt 8) { return }
    if ($null -eq $script:RunbookSecretValues) { $script:RunbookSecretValues = New-Object System.Collections.ArrayList }
    if (-not $script:RunbookSecretValues.Contains($Value)) { [void]$script:RunbookSecretValues.Add($Value) }
}

# ---------------------------------------------------------------------------
# JSON. The two editions disagree on what ConvertFrom-Json returns: Windows
# PowerShell 5.1 writes a top-level array as one object, PowerShell 7 writes
# its elements one by one unless -NoEnumerate is given, and PowerShell 7
# turns strings shaped like timestamps into [datetime] unless 7.5's
# -DateKind String is given. ConvertFrom-RunbookJsonText gives both editions
# the 5.1 shape and keeps strings as strings where the edition allows it.
#
# The [PSCustomObject] type accelerator is System.Management.Automation.PSObject,
# not System.Management.Automation.PSCustomObject, so "-is [PSCustomObject]"
# is true for any value that happens to be wrapped in a PSObject: a JSON
# array from ConvertFrom-Json on 5.1, a string that went through the
# pipeline, an element of an array built from pipeline output. Only the full
# type name tests for a parsed JSON object.
# ---------------------------------------------------------------------------

function Test-RunbookJsonObject {
    <#
    .SYNOPSIS
        True only for a JSON object as ConvertFrom-Json returns it (a
        PSCustomObject), never for an array, a string, or a hashtable.
    .DESCRIPTION
        Uses the exact type System.Management.Automation.PSCustomObject. The
        [PSCustomObject] accelerator must not be used for this test: it is
        PSObject, and every PSObject-wrapped value passes it.
    .PARAMETER Value
        Anything, including $null.
    .EXAMPLE
        Test-RunbookJsonObject -Value (ConvertFrom-RunbookJsonText -Json '[1,2]')
        False
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

function ConvertFrom-RunbookJsonText {
    <#
    .SYNOPSIS
        ConvertFrom-Json with the same result shape on Windows PowerShell 5.1
        and PowerShell 7.
    .DESCRIPTION
        Internal. A top-level JSON array comes back as one array object (the
        5.1 behaviour; -NoEnumerate on PowerShell 7), so a one-element array
        and a nested array keep their shape. On PowerShell 7.5 and later,
        -DateKind String keeps timestamp-shaped strings as strings. Throws
        what ConvertFrom-Json throws for text that is not JSON.
    .PARAMETER Json
        The JSON text.
    .EXAMPLE
        $parsed = ConvertFrom-RunbookJsonText -Json '["only one"]'
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json)

    if ($null -eq $script:RunbookJsonParameters) {
        $names = @{}
        try {
            $command = Get-Command -Name 'ConvertFrom-Json' -CommandType Cmdlet -ErrorAction Stop
            foreach ($name in $command.Parameters.Keys) { $names[[string]$name] = $true }
        }
        catch { $names = @{} }
        $script:RunbookJsonParameters = $names
    }
    $convert = @{ InputObject = $Json; ErrorAction = 'Stop' }
    if ($script:RunbookJsonParameters.ContainsKey('NoEnumerate')) { $convert.NoEnumerate = $true }
    if ($script:RunbookJsonParameters.ContainsKey('DateKind')) { $convert.DateKind = 'String' }
    # The unary comma stops the return statement from unrolling an array.
    return , (ConvertFrom-Json @convert)
}

# ---------------------------------------------------------------------------
# Run context.
# ---------------------------------------------------------------------------

function Initialize-RunContext {
    <#
    .SYNOPSIS
        Starts a run: sets the run id, cloud, identity, and dry-run flag, and
        clears every per-run cache.
    .DESCRIPTION
        Call once, first, from the runbook's run function with the values of
        its own parameters. Get-RunbookAccessToken, Invoke-CloudRequest,
        Invoke-StorageRequest, and New-RunSummary read these values unless a
        call passes its own. The access token, when supplied, is registered
        for scrubbing and never logged; the log line says only which source
        will be used.
    .PARAMETER RunbookName
        Name that appears on the summary, for example Invoke-GroupOwnerReview.
    .PARAMETER RunId
        Correlation id. A new GUID when empty.
    .PARAMETER Environment
        Global (default) or USGov.
    .PARAMETER ClientId
        Client id of the user-assigned managed identity. Empty uses the
        account's default identity.
    .PARAMETER AccessToken
        Local runs and tests only. One string used for every resource, a
        hashtable keyed Graph, Arm, Storage, or a string holding a JSON object
        with those keys.
    .PARAMETER DryRun
        Default $true.
    .EXAMPLE
        Initialize-RunContext -RunbookName 'Invoke-GroupOwnerReview' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$RunbookName,
        [AllowEmptyString()][string]$RunId = '',
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowNull()][object]$AccessToken = $null,
        [bool]$DryRun = $true
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [Guid]::NewGuid().ToString() }
    $script:RunId = $RunId
    $script:RunLog = New-Object System.Collections.ArrayList
    $script:RunbookTokenCache = @{}
    $script:RunbookTokenSourceLogged = @{}
    $script:RunbookSecretValues = New-Object System.Collections.ArrayList
    $script:RunbookLookupCache = @{}
    $script:RunbookContext = @{
        RunbookName = $RunbookName
        Environment = $Environment
        ClientId    = $ClientId
        AccessToken = $AccessToken
        DryRun      = $DryRun
        StartedUtc  = [DateTime]::UtcNow
    }

    $supplied = $false
    foreach ($value in @(Get-SuppliedTokenValues -AccessToken $AccessToken)) {
        Add-RunbookSecret -Value $value
        $supplied = $true
    }
    if ($env:IDENTITY_HEADER) { Add-RunbookSecret -Value $env:IDENTITY_HEADER }

    $source = 'managed identity'
    if ($supplied) { $source = 'caller-supplied token (local mode)' }
    $clientText = 'default'
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $clientText = $ClientId }
    Write-RunLog -Level Info -Message ('Starting {0}. DryRun={1} Environment={2} ClientId={3} Credential={4} Library=Runbook.Common {5}' -f $RunbookName, $DryRun, $Environment, $clientText, $source, $script:RunbookCommonVersion)
}

function Get-RunContext {
    <#
    .SYNOPSIS
        The current run settings, without the access token.
    .DESCRIPTION
        Returns RunId, RunbookName, Environment, ClientId, DryRun, StartedUtc,
        and HasSuppliedToken. The token itself is never returned.
    .EXAMPLE
        $endpoints = Get-CloudEndpoints -Environment (Get-RunContext).Environment
    #>
    $context = $script:RunbookContext
    return [PSCustomObject]@{
        RunId            = [string]$script:RunId
        RunbookName      = [string]$context.RunbookName
        Environment      = [string]$context.Environment
        ClientId         = [string]$context.ClientId
        DryRun           = [bool]$context.DryRun
        StartedUtc       = $context.StartedUtc
        HasSuppliedToken = (@(Get-SuppliedTokenValues -AccessToken $context.AccessToken).Count -gt 0)
    }
}

# ---------------------------------------------------------------------------
# Clouds.
#
# Values from learn.microsoft.com: "Microsoft Graph national cloud
# deployments" (graph.microsoft.us for US Government L4, GCC High),
# "Compare Azure Government and global Azure" (management.usgovcloudapi.net,
# login.microsoftonline.us, blob.core.usgovcloudapi.net), and "Authorize
# Blob Access with Microsoft Entra ID", which gives https://storage.azure.com/
# as the any-account resource id for Azure Global, Azure Government, and
# Azure China alike. The DoD Graph endpoint (dod-graph.microsoft.us) is not
# covered; a DoD tenant needs a third Environment value.
# ---------------------------------------------------------------------------

function Get-CloudEndpoints {
    <#
    .SYNOPSIS
        Base URLs, storage suffix, and token resources for one cloud.
    .DESCRIPTION
        Returns a hashtable with Environment, Graph (base URL), Arm (base
        URL), Login (authority host), BlobSuffix, GraphResource, ArmResource,
        and StorageResource. Graph and Arm have no trailing slash; the
        resources are the values the Automation identity endpoint and
        Get-AzAccessToken take.
    .PARAMETER Environment
        Global or USGov.
    .EXAMPLE
        (Get-CloudEndpoints -Environment USGov).Graph
        https://graph.microsoft.us
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('Global', 'USGov')][string]$Environment)

    if ($Environment -eq 'USGov') {
        return @{
            Environment     = 'USGov'
            Graph           = 'https://graph.microsoft.us'
            Arm             = 'https://management.usgovcloudapi.net'
            Login           = 'https://login.microsoftonline.us'
            BlobSuffix      = 'blob.core.usgovcloudapi.net'
            GraphResource   = 'https://graph.microsoft.us'
            ArmResource     = 'https://management.usgovcloudapi.net/'
            StorageResource = 'https://storage.azure.com/'
        }
    }
    return @{
        Environment     = 'Global'
        Graph           = 'https://graph.microsoft.com'
        Arm             = 'https://management.azure.com'
        Login           = 'https://login.microsoftonline.com'
        BlobSuffix      = 'blob.core.windows.net'
        GraphResource   = 'https://graph.microsoft.com'
        ArmResource     = 'https://management.azure.com/'
        StorageResource = 'https://storage.azure.com/'
    }
}

# ---------------------------------------------------------------------------
# Identity. Three sources, in order: a caller-supplied token (local runs and
# tests), the Azure Automation identity endpoint (production), and
# Az.Accounts when it is available. Tokens are cached per cloud, resource,
# and client id for the run and refreshed five minutes before they expire.
# ---------------------------------------------------------------------------

function ConvertFrom-RunbookSecureString {
    <#
    .SYNOPSIS
        Plain text of a SecureString, for the Az.Accounts token shape.
    .PARAMETER Value
        The secure string.
    .EXAMPLE
        ConvertFrom-RunbookSecureString -Value $result.Token
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Value)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function ConvertTo-SuppliedTokenTable {
    <#
    .SYNOPSIS
        Normalises the AccessToken argument into $null, a string, or a
        hashtable keyed by resource name.
    .DESCRIPTION
        Internal. A string that starts with "{" is read as a JSON object with
        Graph, Arm, and Storage keys, so a runbook's [string] parameter can
        carry more than one token. A parse failure never echoes the value.
    .PARAMETER AccessToken
        What the caller passed.
    .EXAMPLE
        ConvertTo-SuppliedTokenTable -AccessToken '{"Graph":"...","Arm":"..."}'
    #>
    param([AllowNull()][object]$AccessToken)

    if ($null -eq $AccessToken) { return $null }
    if ($AccessToken -is [System.Security.SecureString]) { return (ConvertFrom-RunbookSecureString -Value $AccessToken) }
    if ($AccessToken -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $AccessToken.Keys) {
            $value = $AccessToken[$key]
            if ($value -is [System.Security.SecureString]) { $value = ConvertFrom-RunbookSecureString -Value $value }
            $table[[string]$key] = [string]$value
        }
        return $table
    }

    $text = ([string]$AccessToken).Trim()
    if ($text.Length -eq 0) { return $null }
    if (-not $text.StartsWith('{')) { return $text }

    # An unterminated object is refused on both editions; PowerShell 7 would
    # otherwise read what it could of it.
    $parsed = $null
    if ($text.EndsWith('}')) {
        try { $parsed = ConvertFrom-RunbookJsonText -Json $text }
        catch { $parsed = $null }
    }
    if (-not (Test-RunbookJsonObject -Value $parsed)) {
        throw 'AccessToken starts with "{" but is not a JSON object with Graph, Arm, or Storage keys. The value is not shown.'
    }
    $table = @{}
    foreach ($property in $parsed.PSObject.Properties) { $table[[string]$property.Name] = [string]$property.Value }
    return $table
}

function Get-SuppliedTokenValues {
    <#
    .SYNOPSIS
        Every non-empty token value inside an AccessToken argument.
    .DESCRIPTION
        Internal. Used to register supplied tokens for scrubbing and to tell
        whether the run is in local mode. Writes the values to the pipeline.
    .PARAMETER AccessToken
        What the caller passed.
    .EXAMPLE
        @(Get-SuppliedTokenValues -AccessToken $AccessToken).Count
    #>
    param([AllowNull()][object]$AccessToken)

    $normalised = ConvertTo-SuppliedTokenTable -AccessToken $AccessToken
    if ($null -eq $normalised) { return }
    if ($normalised -is [hashtable]) {
        foreach ($value in $normalised.Values) { if (-not [string]::IsNullOrWhiteSpace([string]$value)) { [string]$value } }
        return
    }
    [string]$normalised
}

function Get-SuppliedTokenForResource {
    <#
    .SYNOPSIS
        The supplied token for one resource, or $null when none was supplied.
    .DESCRIPTION
        Internal. A single string is used for every resource. A table must
        name the resource (Graph, Arm, Storage, case-insensitive); a table
        that has entries but not this one is an error rather than a silent
        fallback to the managed identity. An empty table counts as not
        supplied.
    .PARAMETER AccessToken
        What the caller passed.
    .PARAMETER Resource
        Graph, Arm, or Storage.
    .EXAMPLE
        Get-SuppliedTokenForResource -AccessToken @{ Graph = $g } -Resource Graph
    #>
    param(
        [AllowNull()][object]$AccessToken,
        [Parameter(Mandatory = $true)][ValidateSet('Graph', 'Arm', 'Storage')][string]$Resource
    )

    $normalised = ConvertTo-SuppliedTokenTable -AccessToken $AccessToken
    if ($null -eq $normalised) { return $null }
    if (-not ($normalised -is [hashtable])) { return [string]$normalised }
    if ($normalised.Count -eq 0) { return $null }

    foreach ($key in $normalised.Keys) {
        if ([string]$key -eq $Resource -and -not [string]::IsNullOrWhiteSpace([string]$normalised[$key])) {
            return [string]$normalised[$key]
        }
    }
    throw ('AccessToken was supplied as a table but has no entry for {0}. Add {0} = <token>, or omit AccessToken to use the managed identity.' -f $Resource)
}

function ConvertFrom-TokenExpiry {
    <#
    .SYNOPSIS
        UTC expiry of a token response, or $null when it cannot be read.
    .DESCRIPTION
        Internal. Accepts expires_on as Unix seconds (the current identity
        endpoint shape) or as a date string (the older shape), and falls back
        to expires_in seconds from Now.
    .PARAMETER ExpiresOn
        The expires_on value.
    .PARAMETER ExpiresIn
        The expires_in value.
    .PARAMETER Now
        The clock, for tests.
    .EXAMPLE
        ConvertFrom-TokenExpiry -ExpiresOn '1790000000'
    #>
    param(
        [AllowNull()][object]$ExpiresOn,
        [AllowNull()][object]$ExpiresIn,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    $text = ''
    if ($null -ne $ExpiresOn) { $text = ([string]$ExpiresOn).Trim() }
    if ($text -match '^\d{9,11}$') {
        $epoch = New-Object -TypeName DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        return $epoch.AddSeconds([double]$text)
    }
    if ($text.Length -gt 0) {
        $parsed = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed.UtcDateTime
        }
    }
    $seconds = 0
    if ($null -ne $ExpiresIn -and [int]::TryParse(([string]$ExpiresIn).Trim(), [ref]$seconds) -and $seconds -gt 0) {
        return $Now.AddSeconds($seconds)
    }
    return $null
}

function Test-AzAccountsAvailable {
    <#
    .SYNOPSIS
        True when Get-AzAccessToken can be called in this session.
    .DESCRIPTION
        Internal, and a separate function so tests can decide the answer.
    .EXAMPLE
        if (Test-AzAccountsAvailable) { 'Az.Accounts fallback available' }
    #>
    return [bool](Get-Command -Name 'Get-AzAccessToken' -ErrorAction SilentlyContinue)
}

function Clear-RunbookTokenCache {
    <#
    .SYNOPSIS
        Forgets every cached token so the next call acquires a new one.
    .EXAMPLE
        Clear-RunbookTokenCache
    #>
    $script:RunbookTokenCache = @{}
}

function Get-RunbookAccessToken {
    <#
    .SYNOPSIS
        An access token for Microsoft Graph, Azure Resource Manager, or Azure
        Storage in the run's cloud.
    .DESCRIPTION
        Sources, in order:

          1. AccessToken supplied by the caller (local runs and tests). A
             string is used for every resource; a hashtable (or a string
             holding a JSON object) is keyed Graph, Arm, Storage.
          2. The Azure Automation identity endpoint, when IDENTITY_ENDPOINT
             and IDENTITY_HEADER are set: GET with resource=<audience> and,
             for a user-assigned identity, client_id=<ClientId>, headers
             X-IDENTITY-HEADER and Metadata: True.
          3. Az.Accounts Get-AzAccessToken, connecting with
             Connect-AzAccount -Identity when there is no context.

        Tokens from sources 2 and 3 are cached per cloud, resource, and client
        id for the run and reused until five minutes before expiry. The token
        is returned to the caller and registered for scrubbing; it is never
        written to any stream. The first acquisition per resource logs which
        source was used.
    .PARAMETER Resource
        Graph, Arm, or Storage.
    .PARAMETER Environment
        Global or USGov. Defaults to the run context.
    .PARAMETER ClientId
        User-assigned identity client id. Defaults to the run context.
    .PARAMETER AccessToken
        Supplied token(s). Defaults to the run context.
    .PARAMETER ForceRefresh
        Ignore the cache.
    .EXAMPLE
        $token = Get-RunbookAccessToken -Resource Arm
    .EXAMPLE
        Get-RunbookAccessToken -Resource Graph -Environment USGov -AccessToken @{ Graph = $graphToken; Arm = $armToken }
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Graph', 'Arm', 'Storage')][string]$Resource,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowNull()][object]$AccessToken = $null,
        [switch]$ForceRefresh
    )

    if (-not $PSBoundParameters.ContainsKey('Environment')) { $Environment = [string]$script:RunbookContext.Environment }
    if (-not $PSBoundParameters.ContainsKey('ClientId')) { $ClientId = [string]$script:RunbookContext.ClientId }
    if (-not $PSBoundParameters.ContainsKey('AccessToken')) { $AccessToken = $script:RunbookContext.AccessToken }

    $endpoints = Get-CloudEndpoints -Environment $Environment
    $audience = [string]$endpoints[$Resource + 'Resource']
    $logKey = '{0}|{1}' -f $Environment, $Resource

    # 1. Supplied by the caller. Never cached, so a different value passed
    #    explicitly is always honoured.
    $supplied = Get-SuppliedTokenForResource -AccessToken $AccessToken -Resource $Resource
    if (-not [string]::IsNullOrWhiteSpace($supplied)) {
        Add-RunbookSecret -Value $supplied
        if (-not $script:RunbookTokenSourceLogged.ContainsKey($logKey)) {
            $script:RunbookTokenSourceLogged[$logKey] = $true
            Write-RunLog -Level Info -Message ('Token for {0} ({1}): supplied by the caller (local mode).' -f $Resource, $audience)
        }
        return $supplied
    }

    $cacheKey = '{0}|{1}|{2}' -f $Environment, $Resource, $ClientId.ToLowerInvariant()
    if (-not $ForceRefresh -and $script:RunbookTokenCache.ContainsKey($cacheKey)) {
        $cached = $script:RunbookTokenCache[$cacheKey]
        if ($null -eq $cached.ExpiresOnUtc -or $cached.ExpiresOnUtc -gt [DateTime]::UtcNow.AddMinutes(5)) { return [string]$cached.Token }
    }

    $clientText = 'default'
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $clientText = $ClientId }
    $token = $null
    $expiresOn = $null
    $source = ''

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        # 2. Azure Automation identity endpoint.
        Add-RunbookSecret -Value $env:IDENTITY_HEADER
        $separator = '?'
        if ($env:IDENTITY_ENDPOINT.Contains('?')) { $separator = '&' }
        $uri = '{0}{1}resource={2}' -f $env:IDENTITY_ENDPOINT, $separator, [Uri]::EscapeDataString($audience)
        if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $uri += '&client_id=' + [Uri]::EscapeDataString($ClientId) }
        $identityHeaders = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }

        $response = $null
        try {
            $response = Invoke-RunbookHttp -Api 'Identity' -Method GET -Uri $uri -Headers $identityHeaders -MaxAttempts 3
        }
        catch {
            throw ('Could not get a {0} token from the Automation identity endpoint (client_id {1}): {2}' -f $Resource, $clientText, $_.Exception.Message)
        }
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject ([string]$response.Content) } catch { $parsed = $null }
        if ($null -eq $parsed -or -not $parsed.PSObject.Properties['access_token'] -or [string]::IsNullOrWhiteSpace([string]$parsed.access_token)) {
            throw ('The Automation identity endpoint returned no access_token for {0} (client_id {1}).' -f $Resource, $clientText)
        }
        $token = [string]$parsed.access_token
        $expiresOnValue = $null
        $expiresInValue = $null
        if ($parsed.PSObject.Properties['expires_on']) { $expiresOnValue = $parsed.expires_on }
        if ($parsed.PSObject.Properties['expires_in']) { $expiresInValue = $parsed.expires_in }
        $expiresOn = ConvertFrom-TokenExpiry -ExpiresOn $expiresOnValue -ExpiresIn $expiresInValue
        $source = 'Automation identity endpoint, client_id ' + $clientText
    }
    elseif (Test-AzAccountsAvailable) {
        # 3. Az.Accounts.
        $context = $null
        try { $context = Get-AzContext -ErrorAction SilentlyContinue } catch { $context = $null }
        if ($null -eq $context) {
            $connect = @{ Identity = $true; ErrorAction = 'Stop' }
            if ($Environment -eq 'USGov') { $connect.Environment = 'AzureUSGovernment' }
            if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $connect.AccountId = $ClientId }
            try { Connect-AzAccount @connect | Out-Null }
            catch { throw ('Connect-AzAccount -Identity failed (client_id {0}): {1}' -f $clientText, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 400)) }
        }
        $result = $null
        try { $result = Get-AzAccessToken -ResourceUrl $audience -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { throw ('Get-AzAccessToken failed for {0}: {1}' -f $Resource, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 400)) }
        if ($null -eq $result) { throw ('Get-AzAccessToken returned nothing for {0}.' -f $Resource) }
        $raw = $result.Token
        if ($raw -is [System.Security.SecureString]) { $raw = ConvertFrom-RunbookSecureString -Value $raw }
        $token = [string]$raw
        if ([string]::IsNullOrWhiteSpace($token)) { throw ('Get-AzAccessToken returned an empty token for {0}.' -f $Resource) }
        if ($result.PSObject.Properties['ExpiresOn'] -and $null -ne $result.ExpiresOn) {
            if ($result.ExpiresOn -is [DateTimeOffset]) { $expiresOn = $result.ExpiresOn.UtcDateTime }
            elseif ($result.ExpiresOn -is [DateTime]) { $expiresOn = $result.ExpiresOn.ToUniversalTime() }
            else { $expiresOn = ConvertFrom-TokenExpiry -ExpiresOn $result.ExpiresOn -ExpiresIn $null }
        }
        $source = 'Az.Accounts'
    }
    else {
        throw 'No credential source. Run inside Azure Automation with a managed identity, load Az.Accounts, or pass -AccessToken for a local run.'
    }

    Add-RunbookSecret -Value $token
    $script:RunbookTokenCache[$cacheKey] = @{ Token = $token; ExpiresOnUtc = $expiresOn; Source = $source }
    if (-not $script:RunbookTokenSourceLogged.ContainsKey($logKey)) {
        $script:RunbookTokenSourceLogged[$logKey] = $true
        Write-RunLog -Level Info -Message ('Token for {0} ({1}): {2}.' -f $Resource, $audience, $source)
    }
    return $token
}

# ---------------------------------------------------------------------------
# Transport. Invoke-HttpCore is the only place Invoke-WebRequest is called,
# so tests mock exactly one function and both PowerShell editions are
# handled in one spot. It never throws on an HTTP status. Invoke-RunbookHttp
# owns retries; Invoke-CloudRequest and Invoke-StorageRequest build requests
# and read responses.
# ---------------------------------------------------------------------------

function Read-HttpCoreErrorFile {
    <#
    .SYNOPSIS
        The first 64 KB of a downloaded error body, decoded as UTF-8, or ''.
    .DESCRIPTION
        Internal to Invoke-HttpCore -OutFile. On PowerShell 7 an error
        response is written to the target file like any other body; a
        service error body is small, so only its start is read.
    .PARAMETER Path
        The file Invoke-WebRequest wrote.
    .EXAMPLE
        $content = Read-HttpCoreErrorFile -Path $OutFile
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return '' }
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $buffer = New-Object -TypeName byte[] -ArgumentList 65536
        $total = 0
        while ($total -lt $buffer.Length) {
            $read = $stream.Read($buffer, $total, $buffer.Length - $total)
            if ($read -le 0) { break }
            $total += $read
        }
        return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $total)
    }
    catch { return '' }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Remove-HttpCoreOutFile {
    <#
    .SYNOPSIS
        Deletes a download target after a failed request, best effort.
    .DESCRIPTION
        Internal to Invoke-HttpCore -OutFile, so a failed or partial
        download never leaves a file a caller could mistake for the blob.
    .PARAMETER Path
        The download target.
    .EXAMPLE
        Remove-HttpCoreOutFile -Path $OutFile
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    try { if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) } } catch { }
}

function Invoke-HttpCore {
    <#
    .SYNOPSIS
        One HTTP request. Returns @{ StatusCode; Content; Headers } for every
        HTTP status and throws only when there is no HTTP response at all.
    .DESCRIPTION
        Internal; the single seam the tests mock. The body is sent as UTF-8
        bytes. The response body is decoded as UTF-8 from the raw stream
        (Windows PowerShell 5.1 otherwise decodes a response without a
        charset as ISO-8859-1) and a leading byte order mark is removed.
        Header names in the returned table are case-insensitive. On
        PowerShell 7 -SkipHttpErrorCheck keeps error responses on the normal
        path; on 5.1 the WebException response is read instead.

        With -OutFile (GET only) the body is streamed to that file by
        Invoke-WebRequest -OutFile -PassThru and never decoded, so binary
        content survives; Content is then empty for a 2xx. Any file already
        at OutFile is removed first. For any other status, or when there is
        no response at all, no file is left behind: on PowerShell 7 the
        service's error body lands in the file (-SkipHttpErrorCheck), so it
        is read back into Content before the file is removed.
    .PARAMETER Method
        GET, POST, PUT, PATCH, DELETE, or HEAD.
    .PARAMETER Uri
        Absolute URI.
    .PARAMETER Headers
        Request headers, including Authorization. Never logged.
    .PARAMETER Body
        String or byte array, or $null.
    .PARAMETER ContentType
        Content-Type for the body.
    .PARAMETER TimeoutSec
        Request timeout. Default 100.
    .PARAMETER OutFile
        GET only: a full file system path to stream the body to. Empty
        (default) returns the body as text instead.
    .EXAMPLE
        Invoke-HttpCore -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' -Headers @{ Authorization = 'Bearer ...' }
    .EXAMPLE
        Invoke-HttpCore -Method GET -Uri $blobUri -Headers $headers -OutFile 'C:\Temp\package.zip'
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [AllowNull()][object]$Body = $null,
        [AllowEmptyString()][string]$ContentType = '',
        [ValidateRange(1, 3600)][int]$TimeoutSec = 100,
        [AllowEmptyString()][string]$OutFile = ''
    )

    $toFile = -not [string]::IsNullOrEmpty($OutFile)
    if ($toFile) {
        if ($Method -ne 'GET') { throw ('Invoke-HttpCore -OutFile is only valid with GET, not {0}.' -f $Method) }
        if ($null -ne $Body) { throw 'Invoke-HttpCore -OutFile cannot send a body.' }
        if ([System.IO.File]::Exists($OutFile)) { [System.IO.File]::Delete($OutFile) }
    }

    $ProgressPreference = 'SilentlyContinue'
    $request = @{ Method = $Method; Uri = $Uri; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        if ($Body -is [byte[]]) { $request.Body = $Body }
        else { $request.Body = [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
        if (-not [string]::IsNullOrEmpty($ContentType)) { $request.ContentType = $ContentType }
    }
    if ($toFile) {
        $request.OutFile = $OutFile
        $request.PassThru = $true
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) { $request.SkipHttpErrorCheck = $true }

    $response = $null
    $errorRecord = $null
    try { $response = Invoke-WebRequest @request }
    catch { $errorRecord = $_ }

    if ($null -ne $response) {
        $responseHeaders = @{}
        try { foreach ($key in $response.Headers.Keys) { $responseHeaders[[string]$key] = [string]($response.Headers[$key] -join ',') } } catch { }
        $status = [int]$response.StatusCode
        if ($toFile) {
            $text = ''
            if ($status -lt 200 -or $status -ge 300) {
                $text = Read-HttpCoreErrorFile -Path $OutFile
                Remove-HttpCoreOutFile -Path $OutFile
            }
            return @{ StatusCode = $status; Content = $text.TrimStart([char]0xFEFF); Headers = $responseHeaders }
        }
        $text = ''
        $stream = $null
        try { $stream = $response.RawContentStream } catch { $stream = $null }
        if ($null -ne $stream -and $stream -is [System.IO.MemoryStream]) {
            $text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        }
        elseif ($response.Content -is [byte[]]) {
            $text = [System.Text.Encoding]::UTF8.GetString($response.Content)
        }
        else {
            $text = [string]$response.Content
        }
        return @{ StatusCode = $status; Content = $text.TrimStart([char]0xFEFF); Headers = $responseHeaders }
    }

    if ($toFile) { Remove-HttpCoreOutFile -Path $OutFile }
    $errorResponse = $null
    try { $errorResponse = $errorRecord.Exception.Response } catch { $errorResponse = $null }
    if ($null -eq $errorResponse) { throw $errorRecord }

    $status = 0
    try { $status = [int]$errorResponse.StatusCode } catch { $status = 0 }

    $content = ''
    if ($errorRecord.ErrorDetails -and $errorRecord.ErrorDetails.Message) { $content = [string]$errorRecord.ErrorDetails.Message }
    elseif ($errorResponse.PSObject.Methods['GetResponseStream']) {
        try {
            $reader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $content = $reader.ReadToEnd()
        }
        catch { $content = '' }
    }

    $errorHeaders = @{}
    try {
        if ($errorResponse.Headers.PSObject.Properties['AllKeys']) {
            foreach ($key in $errorResponse.Headers.AllKeys) { $errorHeaders[[string]$key] = [string]$errorResponse.Headers[$key] }
        }
        else {
            foreach ($pair in $errorResponse.Headers) { $errorHeaders[[string]$pair.Key] = [string]($pair.Value -join ',') }
        }
    }
    catch { }

    return @{ StatusCode = $status; Content = ([string]$content).TrimStart([char]0xFEFF); Headers = $errorHeaders }
}

function Get-RetryDelaySeconds {
    <#
    .SYNOPSIS
        Seconds to wait before retry number Attempt.
    .DESCRIPTION
        Retry-After is honoured when present, as delta seconds or as an HTTP
        date, and clamped to 1 to 60 seconds. Without it the wait is
        exponential: 2, 4, 8, 16, 32, then 60 seconds.
    .PARAMETER Attempt
        The attempt that just failed, starting at 1.
    .PARAMETER RetryAfter
        The Retry-After header value, if any.
    .PARAMETER MaxSeconds
        Upper bound. Default 60.
    .PARAMETER Now
        The clock, for an HTTP-date Retry-After.
    .EXAMPLE
        Get-RetryDelaySeconds -Attempt 2 -RetryAfter '120'
        60
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 100)][int]$Attempt,
        [AllowNull()][AllowEmptyString()][string]$RetryAfter = '',
        [ValidateRange(1, 3600)][int]$MaxSeconds = 60,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    if (-not [string]::IsNullOrWhiteSpace($RetryAfter)) {
        $text = $RetryAfter.Trim()
        $seconds = 0
        if ([int]::TryParse($text, [ref]$seconds)) {
            return [int][Math]::Max(1, [Math]::Min($MaxSeconds, $seconds))
        }
        $date = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$date)) {
            $delta = [int][Math]::Ceiling(($date.UtcDateTime - $Now.ToUniversalTime()).TotalSeconds)
            return [int][Math]::Max(1, [Math]::Min($MaxSeconds, $delta))
        }
    }
    return [int][Math]::Min($MaxSeconds, [Math]::Pow(2, $Attempt))
}

function ConvertTo-SafeRequestPath {
    <#
    .SYNOPSIS
        Path and query of a URI for a log line or an error, with continuation
        tokens and signatures redacted.
    .PARAMETER Uri
        Absolute URI.
    .EXAMPLE
        ConvertTo-SafeRequestPath -Uri 'https://graph.microsoft.com/v1.0/users?$skiptoken=abc'
        /v1.0/users?$skiptoken=[redacted]
    #>
    param([Parameter(Mandatory = $true)][string]$Uri)

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) { return (Protect-RunbookText -Text $Uri -MaxLength 300) }
    $path = $parsed.AbsolutePath
    $query = $parsed.Query
    if (-not [string]::IsNullOrEmpty($query)) {
        $parts = @()
        foreach ($pair in $query.TrimStart('?').Split('&')) {
            $name = $pair
            $index = $pair.IndexOf('=')
            if ($index -ge 0) { $name = $pair.Substring(0, $index) }
            $plainName = [Uri]::UnescapeDataString($name).TrimStart('$').ToLowerInvariant()
            if (@('sig', 'skiptoken', 'code', 'token', 'access_token', 'client_secret') -contains $plainName) { $parts += ($name + '=[redacted]') }
            else { $parts += $pair }
        }
        $path = $path + '?' + ($parts -join '&')
    }
    return (Protect-RunbookText -Text $path -MaxLength 300)
}

function Get-ServiceErrorText {
    <#
    .SYNOPSIS
        A short, scrubbed description of a service error body.
    .DESCRIPTION
        Internal. Reads error.code and error.message from a Graph or ARM JSON
        body, or Code and Message from a Storage XML body, and falls back to
        the collapsed body text. Returns @{ Code; Text }.
    .PARAMETER Content
        The response body.
    .EXAMPLE
        (Get-ServiceErrorText -Content '{"error":{"code":"Forbidden","message":"No."}}').Text
        Forbidden: No.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return @{ Code = ''; Text = '(no body)' } }
    $code = ''
    $message = ''
    $trimmed = $Content.Trim()
    if ($trimmed.StartsWith('{')) {
        try {
            $json = ConvertFrom-Json -InputObject $trimmed
            if ($json.PSObject.Properties['error'] -and $null -ne $json.error) {
                if ($json.error -is [string]) { $message = [string]$json.error }
                else {
                    if ($json.error.PSObject.Properties['code']) { $code = [string]$json.error.code }
                    if ($json.error.PSObject.Properties['message']) { $message = [string]$json.error.message }
                }
            }
            if (-not $message -and $json.PSObject.Properties['error_description']) { $message = [string]$json.error_description }
        }
        catch { $message = '' }
    }
    elseif ($trimmed.StartsWith('<')) {
        if ($trimmed -match '<Code>([^<]*)</Code>') { $code = $Matches[1] }
        if ($trimmed -match '<Message>([^<]*)</Message>') { $message = $Matches[1] }
    }

    $text = $trimmed
    if ($message) {
        $text = $message
        if ($code) { $text = $code + ': ' + $message }
    }
    elseif ($code) { $text = $code }
    return @{ Code = (Protect-RunbookText -Text $code -MaxLength 100); Text = (Protect-RunbookText -Text $text -MaxLength 400) }
}

function New-CloudRequestError {
    <#
    .SYNOPSIS
        The exception every failed request throws.
    .DESCRIPTION
        Internal. The message is "<Api> <METHOD> <path> failed with HTTP
        <status> after <n> attempt(s): <code>: <message>", scrubbed. The
        exception's Data carries Api, Method, Path, Host, HttpStatus,
        Attempts, ErrorCode, and MayHaveBeenApplied, which
        Get-CloudErrorStatus and callers read.
    .PARAMETER Api
        Graph, Arm, Storage, or Identity.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Uri
        Absolute URI.
    .PARAMETER StatusCode
        HTTP status, or 0 when there was no response.
    .PARAMETER Attempts
        Attempts made.
    .PARAMETER Content
        Response body, or the transport error text when StatusCode is 0.
    .PARAMETER MayHaveBeenApplied
        The request was not repeated because it is not idempotent and may
        already have taken effect. Adds a sentence saying so and sets
        Data['MayHaveBeenApplied'].
    .EXAMPLE
        throw (New-CloudRequestError -Api Graph -Method GET -Uri $uri -StatusCode 403 -Attempts 1 -Content $body)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Api,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][int]$Attempts,
        [AllowNull()][AllowEmptyString()][string]$Content = '',
        [switch]$MayHaveBeenApplied
    )

    $path = ConvertTo-SafeRequestPath -Uri $Uri
    $hostName = ''
    $parsed = $null
    if ([Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) { $hostName = $parsed.Host }
    $detail = Get-ServiceErrorText -Content $Content
    if ($StatusCode -gt 0) {
        $message = '{0} {1} {2} failed with HTTP {3} after {4} attempt(s): {5}' -f $Api, $Method, $path, $StatusCode, $Attempts, $detail.Text
    }
    else {
        $message = '{0} {1} {2} failed without an HTTP response after {3} attempt(s): {4}' -f $Api, $Method, $path, $Attempts, $detail.Text
    }
    if ($MayHaveBeenApplied) {
        $message += (' {0} is not repeated automatically after a server error or a lost response because it may already have been applied; check the target before sending it again.' -f $Method)
    }
    $exception = New-Object System.InvalidOperationException($message)
    $exception.Data['Api'] = $Api
    $exception.Data['Method'] = $Method
    $exception.Data['Path'] = $path
    $exception.Data['Host'] = $hostName
    $exception.Data['HttpStatus'] = $StatusCode
    $exception.Data['Attempts'] = $Attempts
    $exception.Data['ErrorCode'] = $detail.Code
    $exception.Data['MayHaveBeenApplied'] = [bool]$MayHaveBeenApplied
    return $exception
}

function Get-CloudErrorStatus {
    <#
    .SYNOPSIS
        The HTTP status carried by an error from this library, or 0.
    .PARAMETER ErrorRecord
        $_ in a catch block, or the exception itself.
    .EXAMPLE
        try { Invoke-CloudRequest -Api Graph -Uri "users/$id" } catch { if ((Get-CloudErrorStatus -ErrorRecord $_) -eq 404) { 'gone' } else { throw } }
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][object]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return 0 }
    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
    while ($null -ne $exception) {
        if ($exception -is [Exception] -and $exception.Data.Contains('HttpStatus')) { return [int]$exception.Data['HttpStatus'] }
        if ($exception -is [Exception]) { $exception = $exception.InnerException } else { $exception = $null }
    }
    return 0
}

function Invoke-RunbookHttp {
    <#
    .SYNOPSIS
        One logical request with retries. Returns the Invoke-HttpCore result
        for a 2xx (or an allowed) status and throws New-CloudRequestError
        otherwise.
    .DESCRIPTION
        Internal. Retries wait Get-RetryDelaySeconds (Retry-After honoured,
        capped at 60 seconds) and stop at MaxAttempts.

          429          Retried for every method. The service refused the
                       request without processing it (Microsoft Graph
                       throttling guidance: the request fails and a
                       Retry-After is suggested; without one, back off
                       exponentially), so repeating it cannot apply it twice.
          5xx          Retried for GET, HEAD, PUT, and DELETE, which are
                       idempotent (RFC 9110). A POST or PATCH that got a 500,
                       502, 503, or 504 may have been applied behind the
                       error, so it fails at once unless the caller passes
                       -RetryNonIdempotent.
          no response  Same rule as 5xx: a POST or PATCH that timed out may
                       have been applied.
          other 4xx    Fails at once.

        A POST or PATCH that fails for one of those reasons while attempts
        remain carries MayHaveBeenApplied in its error and says so in the
        message. Pass -RetryNonIdempotent only when repeating the request is
        harmless, for example a PATCH that sets a whole value. A request that
        sends mail, creates an object, or starts an operation must not opt
        in.
    .PARAMETER Api
        Label for messages: Graph, Arm, Storage, Identity.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Uri
        Absolute URI.
    .PARAMETER Headers
        Request headers.
    .PARAMETER Body
        String, byte array, or $null.
    .PARAMETER ContentType
        Content-Type for the body.
    .PARAMETER MaxAttempts
        Default 5.
    .PARAMETER AllowedStatus
        Non-2xx statuses returned instead of thrown, for example 404.
    .PARAMETER RetryNonIdempotent
        Also retry POST and PATCH after a 5xx or a lost response. Off by
        default; see the description.
    .PARAMETER OutFile
        GET only: stream the body to this file (see Invoke-HttpCore).
    .EXAMPLE
        Invoke-RunbookHttp -Api Graph -Method GET -Uri $uri -Headers $headers
    .EXAMPLE
        Invoke-RunbookHttp -Api Arm -Method PATCH -Uri $uri -Headers $headers -Body $json -ContentType 'application/json' -RetryNonIdempotent
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Api,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [AllowNull()][object]$Body = $null,
        [AllowEmptyString()][string]$ContentType = '',
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [int[]]$AllowedStatus = @(),
        [switch]$RetryNonIdempotent,
        [AllowEmptyString()][string]$OutFile = ''
    )

    $idempotent = @('GET', 'HEAD', 'PUT', 'DELETE') -contains $Method
    $repeatable = $idempotent -or [bool]$RetryNonIdempotent
    $core = @{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = $ContentType }
    if (-not [string]::IsNullOrEmpty($OutFile)) { $core.OutFile = $OutFile }
    $attempt = 0
    while ($true) {
        $attempt++
        $response = $null
        try {
            $response = Invoke-HttpCore @core
        }
        catch {
            $transportText = Protect-RunbookText -Text $_.Exception.Message -MaxLength 400
            if ($attempt -lt $MaxAttempts) {
                if ($repeatable) {
                    $wait = Get-RetryDelaySeconds -Attempt $attempt
                    Write-RunLog -Level Warn -Message ('{0} {1} {2} got no response ({3}); retrying in {4}s (attempt {5} of {6}).' -f $Api, $Method, (ConvertTo-SafeRequestPath -Uri $Uri), $transportText, $wait, $attempt, $MaxAttempts)
                    Start-Sleep -Seconds $wait
                    continue
                }
                throw (New-CloudRequestError -Api $Api -Method $Method -Uri $Uri -StatusCode 0 -Attempts $attempt -Content $transportText -MayHaveBeenApplied)
            }
            throw (New-CloudRequestError -Api $Api -Method $Method -Uri $Uri -StatusCode 0 -Attempts $attempt -Content $transportText)
        }

        $status = [int]$response.StatusCode
        if (($status -ge 200 -and $status -lt 300) -or ($AllowedStatus -contains $status)) { return $response }

        $throttled = ($status -eq 429)
        $serverError = ($status -ge 500 -and $status -le 599)
        if ($attempt -lt $MaxAttempts -and ($throttled -or ($serverError -and $repeatable))) {
            $retryAfter = ''
            if ($null -ne $response.Headers -and $response.Headers.ContainsKey('Retry-After')) { $retryAfter = [string]$response.Headers['Retry-After'] }
            $wait = Get-RetryDelaySeconds -Attempt $attempt -RetryAfter $retryAfter
            Write-RunLog -Level Warn -Message ('{0} {1} {2} returned HTTP {3}; retrying in {4}s (attempt {5} of {6}).' -f $Api, $Method, (ConvertTo-SafeRequestPath -Uri $Uri), $status, $wait, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $wait
            continue
        }

        $withheld = $serverError -and -not $repeatable -and $attempt -lt $MaxAttempts
        throw (New-CloudRequestError -Api $Api -Method $Method -Uri $Uri -StatusCode $status -Attempts $attempt -Content ([string]$response.Content) -MayHaveBeenApplied:$withheld)
    }
}

function Resolve-CloudRequestUri {
    <#
    .SYNOPSIS
        The absolute URI for a Graph or ARM request in the run's cloud.
    .DESCRIPTION
        Internal. Graph: a relative URI is resolved against /v1.0/ unless it
        starts with v1.0/ or beta/. ARM: a relative URI is resolved against
        the ARM root and api-version is appended when the URI does not carry
        one. An absolute URI (a nextLink) must be https and on the same host
        as the cloud's endpoint for that API; anything else is refused, so a
        bearer token is never sent to a host this library did not choose.
    .PARAMETER Api
        Graph or Arm.
    .PARAMETER Uri
        Relative or absolute.
    .PARAMETER ApiVersion
        ARM api-version.
    .PARAMETER Environment
        Global or USGov.
    .EXAMPLE
        Resolve-CloudRequestUri -Api Arm -Uri 'subscriptions' -ApiVersion '2022-12-01' -Environment Global
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Graph', 'Arm')][string]$Api,
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowEmptyString()][string]$ApiVersion = '',
        [Parameter(Mandatory = $true)][ValidateSet('Global', 'USGov')][string]$Environment
    )

    $endpoints = Get-CloudEndpoints -Environment $Environment
    $base = [string]$endpoints[$Api]
    $text = $Uri.Trim()

    if ($text -match '^[A-Za-z][A-Za-z0-9+.\-]*://') {
        $parsed = $null
        if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$parsed)) { throw ('{0} request URI is not a valid absolute URI.' -f $Api) }
        $expectedHost = ([Uri]$base).Host
        if ($parsed.Scheme -ne 'https' -or -not $parsed.Host.Equals($expectedHost, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('Refusing to send a {0} token to {1}://{2}; {0} requests in {3} must go to https://{4}.' -f $Api, $parsed.Scheme, $parsed.Host, $Environment, $expectedHost)
        }
        $full = $text
    }
    else {
        $relative = $text.TrimStart('/')
        if ($Api -eq 'Graph') {
            if ($relative -match '^(v1\.0|beta)/') { $full = '{0}/{1}' -f $base, $relative }
            else { $full = '{0}/v1.0/{1}' -f $base, $relative }
        }
        else {
            $full = '{0}/{1}' -f $base, $relative
        }
    }

    if ($Api -eq 'Arm' -and $full -notmatch '[?&]api-version=') {
        if ([string]::IsNullOrWhiteSpace($ApiVersion)) {
            throw ('ARM request {0} has no api-version. Pass -ApiVersion.' -f (ConvertTo-SafeRequestPath -Uri $full))
        }
        $separator = '?'
        if ($full.Contains('?')) { $separator = '&' }
        $full = '{0}{1}api-version={2}' -f $full, $separator, [Uri]::EscapeDataString($ApiVersion.Trim())
    }
    return $full
}

function Get-NextPageLink {
    <#
    .SYNOPSIS
        The next-page URL of a Graph or ARM list response, or $null.
    .DESCRIPTION
        Internal. Graph uses @odata.nextLink; ARM uses nextLink (the
        management groups list documents @nextLink).
    .PARAMETER Page
        The parsed response.
    .EXAMPLE
        Get-NextPageLink -Page $page
    #>
    param([AllowNull()][object]$Page)

    if (-not (Test-RunbookJsonObject -Value $Page)) { return $null }
    foreach ($name in @('@odata.nextLink', 'nextLink', '@nextLink')) {
        $property = $Page.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return [string]$property.Value }
    }
    return $null
}

function Invoke-CloudRequest {
    <#
    .SYNOPSIS
        One Microsoft Graph or Azure Resource Manager call, JSON in and out,
        with retries and optional paging.
    .DESCRIPTION
        Gets a token for the API from Get-RunbookAccessToken (cached), builds
        the URI for the run's cloud (see Resolve-CloudRequestUri), serialises
        Body to JSON unless it is already a string, and parses the response
        JSON. Retries follow Invoke-RunbookHttp: 429 is retried for every
        method, 5xx and a lost response only for GET, PUT, and DELETE unless
        -RetryNonIdempotent is given, with backoff (Retry-After honoured,
        capped at 60 seconds); any other 4xx fails at once. A failure throws
        an exception whose message carries the method, path, HTTP status,
        and a scrubbed service message, and whose Data Get-CloudErrorStatus
        reads (Data['MayHaveBeenApplied'] is true for a POST or PATCH that
        was not repeated).

        Without -AllPages the parsed body is returned ($null for an empty
        body, the raw text when the body is not JSON). With -AllPages the
        request must be a GET: @odata.nextLink (Graph) or nextLink (ARM) is
        followed to the end and the items of every page's value array are
        written to the pipeline, so wrap the call in @().
    .PARAMETER Api
        Graph or Arm.
    .PARAMETER Method
        GET (default), POST, PUT, PATCH, DELETE.
    .PARAMETER Uri
        Relative ("groups?$filter=...", "v1.0/...", "beta/...",
        "subscriptions/...") or an absolute URI on the cloud's own host.
    .PARAMETER Body
        Hashtable or object (serialised with depth 20) or a JSON string.
    .PARAMETER AllPages
        Follow next links and return the combined value items.
    .PARAMETER ApiVersion
        ARM api-version, appended when the URI has none. Ignored for Graph.
    .PARAMETER Headers
        Extra request headers, for example @{ ConsistencyLevel = 'eventual' }.
        Authorization cannot be overridden.
    .PARAMETER MaxAttempts
        Attempts per request, 1 to 10. Default 5.
    .PARAMETER MaxPages
        Safety stop for -AllPages. Default 5000.
    .PARAMETER RetryNonIdempotent
        Also retry a POST or PATCH after a 5xx or a lost response. Only for a
        request that is harmless to repeat, such as a PATCH that sets a whole
        value; never for sendMail, a create, or an action.
    .EXAMPLE
        $groups = @(Invoke-CloudRequest -Api Graph -Uri 'groups?$select=id,displayName&$top=999' -AllPages)
    .EXAMPLE
        Invoke-CloudRequest -Api Arm -Uri "$scope/providers/Microsoft.Authorization/roleAssignments" -ApiVersion '2022-04-01' -AllPages
    .EXAMPLE
        Invoke-CloudRequest -Api Graph -Method PATCH -Uri "users/$id" -Body @{ accountEnabled = $false } -RetryNonIdempotent
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Graph', 'Arm')][string]$Api,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Uri,
        [AllowNull()][object]$Body = $null,
        [switch]$AllPages,
        [AllowEmptyString()][string]$ApiVersion = '',
        [hashtable]$Headers = @{},
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [ValidateRange(1, 1000000)][int]$MaxPages = 5000,
        [switch]$RetryNonIdempotent
    )

    if ($AllPages -and $Method -ne 'GET') { throw ('-AllPages is only valid with GET, not {0}.' -f $Method) }
    $environment = [string]$script:RunbookContext.Environment
    $fullUri = Resolve-CloudRequestUri -Api $Api -Uri $Uri -ApiVersion $ApiVersion -Environment $environment
    $token = Get-RunbookAccessToken -Resource $Api

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) {
        if ([string]$key -eq 'Authorization') { continue }
        $requestHeaders[[string]$key] = [string]$Headers[$key]
    }
    $requestHeaders['Authorization'] = 'Bearer ' + $token
    if (-not $requestHeaders.ContainsKey('Accept')) { $requestHeaders['Accept'] = 'application/json' }

    $json = $null
    $contentType = ''
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body }
        else { $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
        $contentType = 'application/json; charset=utf-8'
    }

    if (-not $AllPages) {
        $response = Invoke-RunbookHttp -Api $Api -Method $Method -Uri $fullUri -Headers $requestHeaders -Body $json -ContentType $contentType -MaxAttempts $MaxAttempts -RetryNonIdempotent:$RetryNonIdempotent
        return (ConvertFrom-CloudResponse -Content ([string]$response.Content))
    }

    $items = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $next = $fullUri
    $pages = 0
    while ($next) {
        $pages++
        if ($pages -gt $MaxPages) { throw ('{0} GET {1} returned more than {2} pages; stopping.' -f $Api, (ConvertTo-SafeRequestPath -Uri $fullUri), $MaxPages) }
        if (-not $seen.Add($next)) { throw ('{0} GET {1} returned a next link it had already returned; stopping to avoid a loop.' -f $Api, (ConvertTo-SafeRequestPath -Uri $fullUri)) }
        if ($pages -gt 1) { $next = Resolve-CloudRequestUri -Api $Api -Uri $next -ApiVersion $ApiVersion -Environment $environment }

        $response = Invoke-RunbookHttp -Api $Api -Method GET -Uri $next -Headers $requestHeaders -MaxAttempts $MaxAttempts
        $page = ConvertFrom-CloudResponse -Content ([string]$response.Content)
        if ($null -eq $page) { break }
        if (-not (Test-RunbookJsonObject -Value $page)) {
            foreach ($item in @($page)) { if ($null -ne $item) { [void]$items.Add($item) } }
            break
        }
        $valueProperty = $page.PSObject.Properties['value']
        if ($null -ne $valueProperty) {
            foreach ($item in @($valueProperty.Value)) { if ($null -ne $item) { [void]$items.Add($item) } }
        }
        else {
            [void]$items.Add($page)
        }
        $next = Get-NextPageLink -Page $page
    }
    return $items.ToArray()
}

function ConvertFrom-CloudResponse {
    <#
    .SYNOPSIS
        Parsed JSON of a response body, $null for an empty body, or the text
        itself when it is not JSON.
    .DESCRIPTION
        Internal. A JSON array at the top level is returned as one array
        object, which Invoke-CloudRequest writes to the pipeline item by item.
    .PARAMETER Content
        Response body.
    .EXAMPLE
        ConvertFrom-CloudResponse -Content '{"id":"1"}'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    $trimmed = $Content.Trim()
    if (-not ($trimmed.StartsWith('{') -or $trimmed.StartsWith('['))) { return $Content }
    try { return (ConvertFrom-Json -InputObject $trimmed) }
    catch { return $Content }
}

# ---------------------------------------------------------------------------
# Blob storage. OAuth bearer requests need x-ms-version 2017-11-09 or later
# (learn.microsoft.com, "Authorize with Microsoft Entra ID"); the default
# below is a long-deployed version, older than what the current SDKs send,
# so it is available in every region including Azure Government.
# ---------------------------------------------------------------------------

function ConvertTo-BlobPath {
    <#
    .SYNOPSIS
        A blob name escaped segment by segment, keeping "/" as the virtual
        directory separator.
    .PARAMETER BlobName
        Blob name such as "reports/2026/09/run.json".
    .EXAMPLE
        ConvertTo-BlobPath -BlobName 'reports/a b.json'
        reports/a%20b.json
    #>
    param([Parameter(Mandatory = $true)][string]$BlobName)

    $segments = @()
    foreach ($segment in $BlobName.Split('/')) { $segments += [Uri]::EscapeDataString($segment) }
    return ($segments -join '/')
}

function Assert-StorageBlobName {
    <#
    .SYNOPSIS
        Throws unless a blob name is safe to put in a request path.
    .DESCRIPTION
        The rules come from "Naming and Referencing Containers, Blobs, and
        Metadata" (learn.microsoft.com) plus what System.Uri does to a path:
        1 to 1024 characters, at most 254 "/" segments, no control
        characters, no backslash, no empty segment (a leading, trailing, or
        doubled "/"), no "." or ".." segment, and no segment that ends with
        a dot. The last three matter beyond the service's advice: .NET
        removes dot segments and, on .NET Framework, a segment's trailing
        dots when it parses the URI, so such a name would reach a different
        blob than the one named. Invoke-StorageRequest calls this before it
        builds a URI or asks for a token.
    .PARAMETER BlobName
        The name to check.
    .EXAMPLE
        Assert-StorageBlobName -BlobName 'reviews/2026/state.json'
    #>
    param([AllowNull()][AllowEmptyString()][string]$BlobName)

    $problem = ''
    if ([string]::IsNullOrEmpty($BlobName)) { $problem = 'it is empty' }
    elseif ($BlobName.Length -gt 1024) { $problem = 'it is longer than 1024 characters' }
    elseif ($BlobName -match '[\x00-\x1F\x7F-\x9F]') { $problem = 'it contains a control character' }
    elseif ($BlobName.Contains('\')) { $problem = 'it contains a backslash; use "/" between virtual directories' }
    else {
        $segments = $BlobName.Split('/')
        if ($segments.Length -gt 254) { $problem = 'it has more than 254 path segments' }
        else {
            foreach ($segment in $segments) {
                if ($segment.Length -eq 0) { $problem = 'it has an empty path segment (a leading, trailing, or doubled "/")'; break }
                if ($segment -eq '.' -or $segment -eq '..') { $problem = 'it has a "." or ".." path segment'; break }
                if ($segment.EndsWith('.')) { $problem = 'a path segment ends with a dot'; break }
            }
        }
    }
    if ($problem) {
        $shown = ''
        if ($null -ne $BlobName) { $shown = Protect-RunbookText -Text ($BlobName -replace '[\x00-\x1F\x7F-\x9F]', '?') -MaxLength 200 }
        throw ('Refusing blob name "{0}": {1}.' -f $shown, $problem)
    }
}

function Assert-StorageRequestUri {
    <#
    .SYNOPSIS
        Throws unless a built blob URI addresses exactly the named blob.
    .DESCRIPTION
        Parses the URI the way the request will and compares the unescaped
        path with "/<container>/<blob>", case-sensitively. A second line of
        defence behind Assert-StorageBlobName: anything System.Uri would
        rewrite on this edition is refused before a token is attached.
    .PARAMETER Uri
        The absolute blob URI.
    .PARAMETER ContainerName
        Container name.
    .PARAMETER BlobName
        Blob name.
    .EXAMPLE
        Assert-StorageRequestUri -Uri $uri -ContainerName 'state' -BlobName 'a.json'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName
    )

    $parsed = $null
    $expected = '/' + $ContainerName + '/' + $BlobName
    $actual = ''
    if ([Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) { $actual = [Uri]::UnescapeDataString($parsed.AbsolutePath) }
    if (-not [string]::Equals($actual, $expected, [StringComparison]::Ordinal)) {
        throw ('Refusing a storage request: the URI for blob "{0}" in container {1} resolves to a different path.' -f (Protect-RunbookText -Text $BlobName -MaxLength 200), $ContainerName)
    }
}

function Resolve-RunbookOutFile {
    <#
    .SYNOPSIS
        A download target as a full path, with its folder created.
    .DESCRIPTION
        Internal. The path must be rooted (a relative path would resolve
        against a different folder in PowerShell and in .NET), must not
        contain wildcard characters (Invoke-WebRequest -OutFile is not a
        literal path on every edition), and must not name a folder.
    .PARAMETER Path
        The requested path.
    .EXAMPLE
        $target = Resolve-RunbookOutFile -Path 'C:\Temp\restore\package.zip'
    #>
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A download needs -OutFile, a full file path.' }
    if ($Path.IndexOfAny([char[]]@('*', '?', '[', ']')) -ge 0) { throw ('OutFile "{0}" contains a wildcard character (* ? [ ]); choose a plain file path.' -f $Path) }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { throw ('OutFile "{0}" is not a full path.' -f $Path) }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Directory]::Exists($full)) { throw ('OutFile "{0}" is a folder; name the file to write.' -f $full) }
    $folder = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrEmpty($folder)) { throw ('OutFile "{0}" has no parent folder.' -f $full) }
    if (-not [System.IO.Directory]::Exists($folder)) { [void][System.IO.Directory]::CreateDirectory($folder) }
    return $full
}

function New-StorageRequestHeaders {
    <#
    .SYNOPSIS
        The headers of one Blob REST request: bearer token, x-ms-version,
        and a fresh x-ms-date.
    .DESCRIPTION
        Internal. Called per request so a long listing gets a current date
        and a token Get-RunbookAccessToken has refreshed when needed.
    .PARAMETER StorageVersion
        x-ms-version.
    .EXAMPLE
        $headers = New-StorageRequestHeaders -StorageVersion '2023-11-03'
    #>
    param([Parameter(Mandatory = $true)][string]$StorageVersion)

    $token = Get-RunbookAccessToken -Resource Storage
    return @{
        'Authorization' = 'Bearer ' + $token
        'x-ms-version'  = $StorageVersion
        'x-ms-date'     = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Invoke-StorageRequest {
    <#
    .SYNOPSIS
        Blob REST with a bearer token: put a block blob, get as text or to a
        file, delete, or list with a prefix.
    .DESCRIPTION
        Sends x-ms-version, x-ms-date, and an OAuth bearer token for the
        Storage resource of the run's cloud to
        https://<account>.<blob suffix>/<container>/<blob>, with the same
        retry rules as Invoke-CloudRequest (every request here is a GET, PUT,
        or DELETE, so a 5xx is retried). The identity needs a Storage Blob
        Data role on the container (Reader for GetBlob, GetBlobToFile, and
        ListBlobs; Contributor for PutBlob and DeleteBlob).

        Before any URI is built or any token is requested, the blob name is
        checked with Assert-StorageBlobName (no empty, ".", "..", or
        trailing-dot segment, no backslash, no control character, at most
        1024 characters). After the URI is built, Assert-StorageRequestUri
        confirms that it still addresses exactly that blob.

          PutBlob       PUT, x-ms-blob-type BlockBlob, Content as UTF-8.
                        Returns Name, ETag, LastModified, StatusCode.
          GetBlob       GET. Returns the blob text (UTF-8), or $null for a
                        missing blob with -AllowNotFound.
          GetBlobToFile GET streamed to -OutFile without decoding, so binary
                        blobs (a zip) survive. The file is replaced; its
                        folder is created. Returns Name, Path, Length,
                        ContentMd5 (as the service reported it, or ''), ETag,
                        LastModified, StatusCode. A missing blob with
                        -AllowNotFound returns $null. After any failure no
                        file is left at OutFile.
          DeleteBlob    DELETE. Returns $true, or $false for a missing blob
                        with -AllowNotFound.
          ListBlobs     GET ?restype=container&comp=list&prefix=...&maxresults=...
                        following NextMarker until it is empty. Writes one
                        object per blob (Name, LastModified, ContentLength,
                        ETag, ContentType) to the pipeline; wrap in @().
    .PARAMETER Operation
        PutBlob, GetBlob, GetBlobToFile, DeleteBlob, ListBlobs.
    .PARAMETER StorageAccountName
        Account name (3 to 24 lowercase letters and digits).
    .PARAMETER ContainerName
        Container name.
    .PARAMETER BlobName
        Blob name; required except for ListBlobs.
    .PARAMETER OutFile
        GetBlobToFile: full path of the file to write.
    .PARAMETER Content
        PutBlob body text.
    .PARAMETER ContentType
        PutBlob content type. Default application/json; charset=utf-8.
    .PARAMETER Prefix
        ListBlobs name prefix.
    .PARAMETER MaxResults
        ListBlobs page size, 1 to 5000.
    .PARAMETER AllowNotFound
        GetBlob, GetBlobToFile, and DeleteBlob treat 404 as a normal result.
    .PARAMETER MaxAttempts
        Attempts per request, 1 to 10. Default 5.
    .PARAMETER StorageVersion
        x-ms-version. Default 2023-11-03.
    .EXAMPLE
        Invoke-StorageRequest -Operation PutBlob -StorageAccountName 'stexampleiam' -ContainerName 'runbook-state' -BlobName 'access-review/last-run.json' -Content ($state | ConvertTo-Json -Depth 5)
    .EXAMPLE
        $blobs = @(Invoke-StorageRequest -Operation ListBlobs -StorageAccountName 'stexampleiam' -ContainerName 'runbook-state' -Prefix 'access-review/')
    .EXAMPLE
        $file = Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName 'stexampleiam' -ContainerName 'runbook-backups' -BlobName 'automation/package.zip' -OutFile 'C:\Temp\restore\package.zip'
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PutBlob', 'GetBlob', 'GetBlobToFile', 'DeleteBlob', 'ListBlobs')][string]$Operation,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][ValidatePattern('^(\$root|\$logs|\$web|[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9])$')][string]$ContainerName,
        [AllowEmptyString()][string]$BlobName = '',
        [AllowEmptyString()][string]$OutFile = '',
        [AllowNull()][AllowEmptyString()][string]$Content = '',
        [ValidateNotNullOrEmpty()][string]$ContentType = 'application/json; charset=utf-8',
        [AllowEmptyString()][string]$Prefix = '',
        [ValidateRange(1, 5000)][int]$MaxResults = 5000,
        [switch]$AllowNotFound,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5,
        [AllowEmptyString()][string]$StorageVersion = ''
    )

    # Everything about the names is checked before a URI or a token exists.
    if ([string]::IsNullOrWhiteSpace($StorageVersion)) { $StorageVersion = [string]$script:RunbookApiVersions.Storage }
    if ($Operation -ne 'ListBlobs') {
        if ([string]::IsNullOrWhiteSpace($BlobName)) { throw ('Invoke-StorageRequest -Operation {0} needs -BlobName.' -f $Operation) }
        Assert-StorageBlobName -BlobName $BlobName
    }
    if ($Operation -eq 'GetBlobToFile') { $OutFile = Resolve-RunbookOutFile -Path $OutFile }
    elseif (-not [string]::IsNullOrEmpty($OutFile)) { throw ('-OutFile is only valid with -Operation GetBlobToFile, not {0}.' -f $Operation) }

    $endpoints = Get-CloudEndpoints -Environment ([string]$script:RunbookContext.Environment)
    $root = 'https://{0}.{1}/{2}' -f $StorageAccountName, $endpoints.BlobSuffix, $ContainerName
    $uri = ''
    if ($Operation -ne 'ListBlobs') {
        $uri = '{0}/{1}' -f $root, (ConvertTo-BlobPath -BlobName $BlobName)
        Assert-StorageRequestUri -Uri $uri -ContainerName $ContainerName -BlobName $BlobName
    }
    $allowed = @()
    if ($AllowNotFound) { $allowed = @(404) }

    switch ($Operation) {
        'PutBlob' {
            $headers = New-StorageRequestHeaders -StorageVersion $StorageVersion
            $headers['x-ms-blob-type'] = 'BlockBlob'
            $text = ''
            if ($null -ne $Content) { $text = $Content }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $response = Invoke-RunbookHttp -Api 'Storage' -Method PUT -Uri $uri -Headers $headers -Body $bytes -ContentType $ContentType -MaxAttempts $MaxAttempts
            $etag = ''
            $lastModified = ''
            if ($response.Headers.ContainsKey('ETag')) { $etag = [string]$response.Headers['ETag'] }
            if ($response.Headers.ContainsKey('Last-Modified')) { $lastModified = [string]$response.Headers['Last-Modified'] }
            return [PSCustomObject]@{ Name = $BlobName; ETag = $etag; LastModified = $lastModified; StatusCode = [int]$response.StatusCode }
        }
        'GetBlob' {
            $headers = New-StorageRequestHeaders -StorageVersion $StorageVersion
            $response = Invoke-RunbookHttp -Api 'Storage' -Method GET -Uri $uri -Headers $headers -MaxAttempts $MaxAttempts -AllowedStatus $allowed
            if ([int]$response.StatusCode -eq 404) { return $null }
            return [string]$response.Content
        }
        'GetBlobToFile' {
            $headers = New-StorageRequestHeaders -StorageVersion $StorageVersion
            $response = Invoke-RunbookHttp -Api 'Storage' -Method GET -Uri $uri -Headers $headers -MaxAttempts $MaxAttempts -AllowedStatus $allowed -OutFile $OutFile
            $status = [int]$response.StatusCode
            if ($status -eq 404) {
                Remove-HttpCoreOutFile -Path $OutFile
                return $null
            }
            if (-not [System.IO.File]::Exists($OutFile)) {
                throw ('Storage GET {0} returned HTTP {1} but wrote no file.' -f (ConvertTo-SafeRequestPath -Uri $uri), $status)
            }
            $responseHeaders = @{}
            if ($null -ne $response.Headers) { $responseHeaders = $response.Headers }
            $values = @{ 'Content-MD5' = ''; 'ETag' = ''; 'Last-Modified' = '' }
            foreach ($name in @('Content-MD5', 'ETag', 'Last-Modified')) {
                if ($responseHeaders.ContainsKey($name)) { $values[$name] = [string]$responseHeaders[$name] }
            }
            $info = New-Object -TypeName System.IO.FileInfo -ArgumentList $OutFile
            return [PSCustomObject]@{
                Name         = $BlobName
                Path         = $OutFile
                Length       = [long]$info.Length
                ContentMd5   = $values['Content-MD5']
                ETag         = $values['ETag']
                LastModified = $values['Last-Modified']
                StatusCode   = $status
            }
        }
        'DeleteBlob' {
            $headers = New-StorageRequestHeaders -StorageVersion $StorageVersion
            $response = Invoke-RunbookHttp -Api 'Storage' -Method DELETE -Uri $uri -Headers $headers -MaxAttempts $MaxAttempts -AllowedStatus $allowed
            return ([int]$response.StatusCode -ne 404)
        }
        'ListBlobs' {
            $blobs = New-Object System.Collections.ArrayList
            $marker = ''
            $pages = 0
            do {
                $pages++
                if ($pages -gt 100000) { throw 'Storage ListBlobs returned more than 100000 pages; stopping.' }
                $uri = '{0}?restype=container&comp=list&maxresults={1}' -f $root, $MaxResults
                if (-not [string]::IsNullOrEmpty($Prefix)) { $uri += '&prefix=' + [Uri]::EscapeDataString($Prefix) }
                if (-not [string]::IsNullOrEmpty($marker)) { $uri += '&marker=' + [Uri]::EscapeDataString($marker) }
                $headers = New-StorageRequestHeaders -StorageVersion $StorageVersion
                $response = Invoke-RunbookHttp -Api 'Storage' -Method GET -Uri $uri -Headers $headers -MaxAttempts $MaxAttempts

                $document = New-Object System.Xml.XmlDocument
                try { $document.LoadXml(([string]$response.Content).TrimStart([char]0xFEFF)) }
                catch { throw ('Storage ListBlobs for container {0} returned a body that is not XML.' -f $ContainerName) }
                foreach ($node in @($document.SelectNodes('/EnumerationResults/Blobs/Blob'))) {
                    if ($null -eq $node) { continue }
                    $lengthNode = $node.SelectSingleNode('Properties/Content-Length')
                    $length = [long]0
                    if ($null -ne $lengthNode) { [void][long]::TryParse($lengthNode.InnerText, [ref]$length) }
                    $modified = $null
                    $modifiedNode = $node.SelectSingleNode('Properties/Last-Modified')
                    if ($null -ne $modifiedNode -and $modifiedNode.InnerText) {
                        $parsedDate = [DateTimeOffset]::MinValue
                        if ([DateTimeOffset]::TryParse($modifiedNode.InnerText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedDate)) { $modified = $parsedDate.UtcDateTime }
                    }
                    $etagNode = $node.SelectSingleNode('Properties/Etag')
                    $typeNode = $node.SelectSingleNode('Properties/Content-Type')
                    $nameNode = $node.SelectSingleNode('Name')
                    [void]$blobs.Add([PSCustomObject]@{
                            Name          = $(if ($null -ne $nameNode) { $nameNode.InnerText } else { '' })
                            LastModified  = $modified
                            ContentLength = $length
                            ETag          = $(if ($null -ne $etagNode) { $etagNode.InnerText } else { '' })
                            ContentType   = $(if ($null -ne $typeNode) { $typeNode.InnerText } else { '' })
                        })
                }
                $marker = ''
                $markerNode = $document.SelectSingleNode('/EnumerationResults/NextMarker')
                if ($null -ne $markerNode) { $marker = $markerNode.InnerText }
            } while (-not [string]::IsNullOrEmpty($marker))
            return $blobs.ToArray()
        }
    }
}

# ---------------------------------------------------------------------------
# Parameters, HTML, mail, and the circuit breaker.
# ---------------------------------------------------------------------------

function ConvertTo-StringList {
    <#
    .SYNOPSIS
        Turns a list parameter into trimmed strings.
    .DESCRIPTION
        A schedule-bound list parameter is one [string]: the job schedule
        can only carry [bool], [int], and [string] values safely. Write such
        a list in the semicolon form, "Group A;Group B" (commas also
        separate). Do not put a JSON array in a schedule parameter: the
        Automation service gives JSON-looking parameter values special
        handling ("Start a runbook in Azure Automation", "Work with runbook
        parameters", on learn.microsoft.com) and may parse the text before it
        is bound, so a [string] parameter can receive something other than
        the text that was set (an array bound to [string] becomes the
        elements joined by spaces). On PowerShell 7 before 7.5 a
        timestamp-shaped element would also be turned into a date. Structured
        configuration belongs in an Automation string variable instead (see
        Get-AutomationStringVariable).

        The JSON array form, ["a","b"], is still accepted for local runs and
        tests, where the text reaches the runbook unchanged; it lets an
        element contain a comma or a semicolon. A value that starts with "["
        must end with "]" and parse as a JSON array of scalars, or the call
        throws naming the parameter (PowerShell 7 would otherwise read an
        unterminated array as its elements). A string array (a local call)
        is accepted too, each element parsed the same way. Blank entries are
        dropped and order is
        kept.

        The JSON is parsed with ConvertFrom-RunbookJsonText, so both editions
        see the whole array as one value, and elements are tested with
        Test-RunbookJsonObject, so a PSObject-wrapped string element is not
        mistaken for an object. The strings are written to the pipeline;
        wrap the call in @() to get an array for a single value.
    .PARAMETER Value
        The raw value: string, string array, or $null.
    .PARAMETER Label
        Parameter name for error messages. Default Value.
    .EXAMPLE
        @(ConvertTo-StringList -Value 'Group A; Group B,Group C').Count
        3
    .EXAMPLE
        $recipients = @(ConvertTo-StringList -Value 'iam@corp.example.com;secops@corp.example.com' -Label Recipients)
    .EXAMPLE
        # Local run only: a JSON array keeps a comma inside an element.
        @(ConvertTo-StringList -Value '["Doe, Jane","Roe, Rick"]' -Label Owners).Count
        2
    #>
    param(
        [AllowNull()][AllowEmptyString()][object]$Value,
        [ValidateNotNullOrEmpty()][string]$Label = 'Value'
    )

    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        # A hashtable enumerates as itself, which would recurse until the call
        # depth overflows; say what the contract is instead.
        throw ('{0} must be a string or a string array, not a hashtable.' -f $Label)
    }
    if (-not ($Value -is [string]) -and $Value -is [System.Collections.IEnumerable]) {
        foreach ($element in $Value) { ConvertTo-StringList -Value $element -Label $Label }
        return
    }

    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return }

    $items = New-Object System.Collections.ArrayList
    if ($text.StartsWith('"') -and $text.EndsWith('"') -and $text.Length -ge 2) {
        # A JSON string literal, as some callers wrap schedule values.
        try { $text = ([string](ConvertFrom-RunbookJsonText -Json $text)).Trim() }
        catch { throw ('{0} looks like a quoted JSON string but does not parse.' -f $Label) }
    }

    if ($text.StartsWith('[')) {
        # PowerShell 7 reads an array whose closing bracket is missing after a
        # complete last element, such as ["a" or [1,2 with nothing after it,
        # as its elements without an error, where Windows PowerShell throws;
        # the check is made here so both editions refuse it.
        if (-not $text.EndsWith(']')) {
            throw ('{0} looks like a JSON array but does not parse: it does not end with "]".' -f $Label)
        }
        $parsed = $null
        try { $parsed = ConvertFrom-RunbookJsonText -Json $text }
        catch { throw ('{0} looks like a JSON array but does not parse: {1}' -f $Label, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 200)) }
        foreach ($element in $parsed) {
            if ($null -eq $element) { continue }
            if ((Test-RunbookJsonObject -Value $element) -or $element -is [System.Collections.IDictionary] -or ($element -is [System.Collections.IEnumerable] -and -not ($element -is [string]))) {
                throw ('{0} must be a JSON array of strings; it contains an object or a nested array.' -f $Label)
            }
            [void]$items.Add([string]$element)
        }
    }
    else {
        foreach ($part in ($text -split '[,;]')) { [void]$items.Add($part) }
    }

    foreach ($item in $items) {
        $trimmed = ([string]$item).Trim()
        if ($trimmed.Length -gt 0) { $trimmed }
    }
}

function Get-AutomationStringVariable {
    <#
    .SYNOPSIS
        The value of an Azure Automation string variable.
    .DESCRIPTION
        Why variables carry structured configuration. A job schedule binds
        its parameter values to the runbook's param block, and only [bool],
        [int], and [string] survive that reliably. The Automation service
        gives JSON-looking values special handling (arrays and objects, see
        "Start a runbook in Azure Automation" on learn.microsoft.com) and
        may parse a value before it is bound, so JSON text placed in a
        [string] schedule parameter can arrive changed: an array bound to
        [string] is joined with spaces, and quoting and key order are not
        guaranteed. A string variable is returned exactly as it was stored,
        so a runbook takes the variable's name as a plain [string]
        parameter and reads the JSON here. Lists of plain names can stay in
        a parameter in the semicolon form (ConvertTo-StringList).

        Sources, in order:

          1. -LocalValues, when given: a hashtable of variable name to value
             for a workstation run. A name it does not hold is an error.
          2. $script:RunbookAutomationVariables, when set: the same shape,
             the hook tests use to stand in for the sandbox.
          3. Get-AutomationVariable, the internal cmdlet that exists only in
             the Azure Automation sandbox and on a Hybrid Runbook Worker
             (module Orchestrator.AssetManagement.Cmdlets). It also returns
             the plain value of an encrypted variable.

        Anywhere else the call throws and says how to supply the value. A
        missing variable, a value that is not a string, or an empty value
        (unless -AllowEmpty) throws. The value is never logged; register it
        with -Sensitive when the variable is encrypted so a service echo of
        it is scrubbed.
    .PARAMETER Name
        Variable name: 1 to 128 characters, none of < > * % & : \ ? . + /
        and no control character, not ending with a space (the Azure naming
        rules for automationAccounts/variables).
    .PARAMETER LocalValues
        Workstation stand-in for the Automation account's variables.
    .PARAMETER AllowEmpty
        Return '' for an empty or whitespace-only value instead of throwing.
    .PARAMETER Sensitive
        Register the value with the scrubber (Protect-RunbookText).
    .EXAMPLE
        $baselineJson = Get-AutomationStringVariable -Name $BaselineVariableName
    .EXAMPLE
        Get-AutomationStringVariable -Name 'PimBaseline' -LocalValues @{ PimBaseline = (Get-Content -Raw .\baseline.json) }
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [AllowNull()][System.Collections.IDictionary]$LocalValues = $null,
        [switch]$AllowEmpty,
        [switch]$Sensitive
    )

    if ([string]::IsNullOrEmpty($Name) -or $Name.Length -gt 128 -or $Name -match '[<>*%&:\\?.+/\x00-\x1F\x7F]' -or $Name.EndsWith(' ')) {
        throw ('"{0}" is not a valid Automation variable name: use 1 to 128 characters, none of < > * % & : \ ? . + / or control characters, and no trailing space.' -f ($Name -replace '[\x00-\x1F\x7F]', '?'))
    }

    $table = $null
    $source = ''
    if ($null -ne $LocalValues) {
        $table = $LocalValues
        $source = 'the -LocalValues table'
    }
    elseif ($null -ne $script:RunbookAutomationVariables) {
        if (-not ($script:RunbookAutomationVariables -is [System.Collections.IDictionary])) {
            throw 'The test hook $script:RunbookAutomationVariables must be a hashtable of variable name to value.'
        }
        $table = $script:RunbookAutomationVariables
        $source = 'the local variable table ($script:RunbookAutomationVariables)'
    }

    $value = $null
    if ($null -ne $table) {
        $found = $false
        foreach ($key in $table.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                $value = $table[$key]
                $found = $true
                break
            }
        }
        if (-not $found) { throw ('Automation variable "{0}" is not in {1}.' -f $Name, $source) }
    }
    else {
        $command = Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw ('Automation variable "{0}" can only be read inside Azure Automation, where Get-AutomationVariable exists. For a local run pass -LocalValues @{{ ''{0}'' = ''<value>'' }} to Get-AutomationStringVariable, or the runbook''s own local-file parameter.' -f $Name)
        }
        try {
            $ErrorActionPreference = 'Stop'
            $value = Get-AutomationVariable -Name $Name
        }
        catch {
            throw ('Automation variable "{0}" could not be read: {1}' -f $Name, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
        }
    }

    if ($null -eq $value) { throw ('Automation variable "{0}" has no value.' -f $Name) }
    if ($value -is [System.Security.SecureString]) { $value = ConvertFrom-RunbookSecureString -Value $value }
    if (-not ($value -is [string])) {
        throw ('Automation variable "{0}" holds a {1}, not a string. Store the configuration as a string variable.' -f $Name, $value.GetType().Name)
    }
    $text = [string]$value
    if ($Sensitive) { Add-RunbookSecret -Value $text }
    if ([string]::IsNullOrWhiteSpace($text) -and -not $AllowEmpty) {
        throw ('Automation variable "{0}" is empty.' -f $Name)
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    return $text
}

function ConvertTo-HtmlSafe {
    <#
    .SYNOPSIS
        HTML-encodes text for a mail body.
    .DESCRIPTION
        Encodes &, <, >, double and single quotes. $null becomes an empty
        string.
    .PARAMETER Value
        The text.
    .EXAMPLE
        ConvertTo-HtmlSafe -Value 'R&D <admins>'
        R&amp;D &lt;admins&gt;
    #>
    param([AllowNull()][AllowEmptyString()][object]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Send-RunbookMail {
    <#
    .SYNOPSIS
        Sends one HTML mail through Graph users/{sender}/sendMail.
    .DESCRIPTION
        POST users/{SenderMailbox}/sendMail with saveToSentItems false. Graph
        answers 202 Accepted with no body. The identity needs Mail.Send,
        restricted to the sender mailbox by an Exchange application access
        policy (automation/README.md). This function always sends: the
        caller decides about DryRun (Invoke-RunbookAction does).
        Each To and Cc entry may itself be a comma or semicolon list.

        The POST is deliberately not sent with -RetryNonIdempotent: a 429 is
        retried (Graph did not accept the mail), but a 5xx or a lost
        response fails at once, because Graph may already have queued the
        message and a retry would deliver it twice.
    .PARAMETER SenderMailbox
        Mailbox the mail is sent from, as a user principal name.
    .PARAMETER To
        Recipient addresses.
    .PARAMETER Cc
        Optional copy addresses.
    .PARAMETER Subject
        Subject line.
    .PARAMETER HtmlBody
        HTML body. Encode data with ConvertTo-HtmlSafe.
    .EXAMPLE
        Send-RunbookMail -SenderMailbox 'iam-noreply@corp.example.com' -To @('iam@corp.example.com') -Subject 'Weekly review' -HtmlBody $html
    #>
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string]$SenderMailbox,
        [Parameter(Mandatory = $true)][string[]]$To,
        [string[]]$Cc = @(),
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Subject,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HtmlBody
    )

    $toList = @(ConvertTo-StringList -Value $To -Label 'To')
    $ccList = @(ConvertTo-StringList -Value $Cc -Label 'Cc')
    if ($toList.Count -eq 0) { throw 'Send-RunbookMail needs at least one To address.' }
    foreach ($address in ($toList + $ccList)) {
        if ($address -notmatch '^[^@\s]+@[^@\s]+$') { throw ('Send-RunbookMail: "{0}" is not a mail address.' -f $address) }
    }

    $toRecipients = @()
    foreach ($address in $toList) { $toRecipients += @{ emailAddress = @{ address = $address } } }
    $message = @{
        subject      = $Subject
        body         = @{ contentType = 'HTML'; content = $HtmlBody }
        toRecipients = $toRecipients
    }
    if ($ccList.Count -gt 0) {
        $ccRecipients = @()
        foreach ($address in $ccList) { $ccRecipients += @{ emailAddress = @{ address = $address } } }
        $message.ccRecipients = $ccRecipients
    }
    $payload = @{ message = $message; saveToSentItems = $false }
    Invoke-CloudRequest -Api Graph -Method POST -Uri ('users/{0}/sendMail' -f [Uri]::EscapeDataString($SenderMailbox)) -Body $payload | Out-Null
}

function Test-CircuitBreaker {
    <#
    .SYNOPSIS
        Throws when a planned count exceeds its cap.
    .DESCRIPTION
        Call before the first write, in dry runs too, so a dry run shows that
        the live run would refuse. A tripped breaker means nothing was
        written: the number is a symptom (a bad clock, a bulk import, a
        broken filter) and the right response is a person looking, not a
        partial run. Planned equal to Cap passes.
    .PARAMETER Planned
        Number of actions the run intends to take.
    .PARAMETER Cap
        Largest acceptable number, 0 or more.
    .PARAMETER Label
        What is being counted, for the message, for example "guest disables".
    .EXAMPLE
        Test-CircuitBreaker -Planned $toRemove.Count -Cap $MaxRemovalsPerRun -Label 'role assignment removals'
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Planned,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2147483647)][int]$Cap,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Label
    )

    if ($Planned -gt $Cap) {
        throw ('Circuit breaker tripped: {0}: {1} planned, cap is {2}. Nothing was changed. Review the run output, then raise the cap for one run or narrow the scope.' -f $Label, $Planned, $Cap)
    }
}

# ---------------------------------------------------------------------------
# Directory lookups. Names are resolved with an exact eq filter and must match
# exactly one object; results are cached for the run.
# ---------------------------------------------------------------------------

function ConvertTo-ODataLiteral {
    <#
    .SYNOPSIS
        A quoted OData string literal with single quotes doubled.
    .PARAMETER Value
        The raw string.
    .EXAMPLE
        ConvertTo-ODataLiteral -Value "O'Brien"
        'O''Brien'
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Resolve-GroupIdByName {
    <#
    .SYNOPSIS
        Object id of the one group with this display name.
    .DESCRIPTION
        GET groups?$filter=displayName eq '<name>'. Zero matches or more than
        one throws; a name that is not unique cannot be used as a key.
    .PARAMETER DisplayName
        Exact display name.
    .EXAMPLE
        $groupId = Resolve-GroupIdByName -DisplayName 'SEC Break Glass Accounts'
    #>
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DisplayName)

    $cacheKey = 'group:' + $DisplayName.ToLowerInvariant()
    if ($script:RunbookLookupCache.ContainsKey($cacheKey)) { return [string]$script:RunbookLookupCache[$cacheKey] }

    $filter = [Uri]::EscapeDataString('displayName eq ' + (ConvertTo-ODataLiteral -Value $DisplayName))
    $found = @(Invoke-CloudRequest -Api Graph -Uri ('groups?$filter={0}&$select=id,displayName' -f $filter) -AllPages)
    if ($found.Count -eq 0) { throw ('Group "{0}" was not found by display name.' -f $DisplayName) }
    if ($found.Count -gt 1) {
        throw ('Group "{0}" is not unique: {1} groups have that display name ({2}). Rename them so the lookup by name is unambiguous.' -f $DisplayName, $found.Count, ((@($found | ForEach-Object { [string]$_.id })) -join ', '))
    }
    $id = [string]$found[0].id
    $script:RunbookLookupCache[$cacheKey] = $id
    return $id
}

function Resolve-UserIdByUpn {
    <#
    .SYNOPSIS
        Object id of the user with this user principal name.
    .DESCRIPTION
        GET users?$filter=userPrincipalName eq '<upn>'. Guest UPNs with
        #EXT# are escaped. Zero matches or more than one throws.
    .PARAMETER UserPrincipalName
        The UPN.
    .EXAMPLE
        $userId = Resolve-UserIdByUpn -UserPrincipalName 'alex@corp.example.com'
    #>
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$UserPrincipalName)

    $cacheKey = 'user:' + $UserPrincipalName.ToLowerInvariant()
    if ($script:RunbookLookupCache.ContainsKey($cacheKey)) { return [string]$script:RunbookLookupCache[$cacheKey] }

    $filter = [Uri]::EscapeDataString('userPrincipalName eq ' + (ConvertTo-ODataLiteral -Value $UserPrincipalName))
    $found = @(Invoke-CloudRequest -Api Graph -Uri ('users?$filter={0}&$select=id,userPrincipalName' -f $filter) -AllPages)
    if ($found.Count -eq 0) { throw ('User "{0}" was not found.' -f $UserPrincipalName) }
    if ($found.Count -gt 1) { throw ('User principal name "{0}" matched {1} users.' -f $UserPrincipalName, $found.Count) }
    $id = [string]$found[0].id
    $script:RunbookLookupCache[$cacheKey] = $id
    return $id
}

function Get-TransitiveGroupMemberIds {
    <#
    .SYNOPSIS
        Object ids of every direct and nested member of a group.
    .DESCRIPTION
        GET groups/{id}/transitiveMembers[/microsoft.graph.<type>] with
        $select=id, $top=999, $count=true and ConsistencyLevel: eventual
        (the documented advanced query form for the cast and $select). Ids
        are unique and written to the pipeline; wrap in @(), or use
        -AsHashSet for a case-insensitive set.
    .PARAMETER GroupId
        Group object id.
    .PARAMETER MemberType
        All (default), User, Group, Device, or ServicePrincipal.
    .PARAMETER AsHashSet
        Return one HashSet[string] instead of the ids.
    .EXAMPLE
        $members = Get-TransitiveGroupMemberIds -GroupId $groupId -MemberType User -AsHashSet
        $members.Contains($userId)
    #>
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$GroupId,
        [ValidateSet('All', 'User', 'Group', 'Device', 'ServicePrincipal')][string]$MemberType = 'All',
        [switch]$AsHashSet
    )

    $cast = ''
    switch ($MemberType) {
        'User' { $cast = '/microsoft.graph.user' }
        'Group' { $cast = '/microsoft.graph.group' }
        'Device' { $cast = '/microsoft.graph.device' }
        'ServicePrincipal' { $cast = '/microsoft.graph.servicePrincipal' }
    }
    $uri = 'groups/{0}/transitiveMembers{1}?$select=id&$top=999&$count=true' -f $GroupId, $cast
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.ArrayList
    foreach ($member in @(Invoke-CloudRequest -Api Graph -Uri $uri -AllPages -Headers @{ ConsistencyLevel = 'eventual' })) {
        $id = ''
        if ($member.PSObject.Properties['id']) { $id = [string]$member.id }
        if ($id -and $set.Add($id)) { [void]$ordered.Add($id) }
    }
    if ($AsHashSet) { return , $set }
    return [string[]]$ordered.ToArray()
}

# ---------------------------------------------------------------------------
# ARM scopes.
# ---------------------------------------------------------------------------

function Resolve-ArmScope {
    <#
    .SYNOPSIS
        ARM scope path for a management group or a subscription given by name.
    .DESCRIPTION
        ManagementGroupName: lists the management groups the identity can
        read and matches the group id (the ARM name) first, then the display
        name; returns /providers/Microsoft.Management/managementGroups/<id>.
        SubscriptionName: lists /subscriptions and matches displayName;
        returns /subscriptions/<id>. SubscriptionId: returns
        /subscriptions/<id> without a call. Zero matches or a duplicate name
        throws. ResourceGroupName appends /resourceGroups/<name> to a
        subscription scope.

        What ARM returns is checked before it becomes a scope: the matched
        subscription's subscriptionId must be a GUID, and the matched
        management group's name must be a valid group id (1 to 90 letters,
        digits, "-", "_", ".", "(", ")", not ending with "."). Otherwise the
        call throws rather than return a scope such as
        "/subscriptions//resourceGroups/rg" that would address something
        else. Nothing invalid is cached.
    .PARAMETER ManagementGroupName
        Management group id or display name.
    .PARAMETER SubscriptionName
        Subscription display name.
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER ResourceGroupName
        Optional resource group under the subscription.
    .EXAMPLE
        Resolve-ArmScope -ManagementGroupName 'Platform'
        /providers/Microsoft.Management/managementGroups/mg-platform
    .EXAMPLE
        Resolve-ArmScope -SubscriptionName 'Identity Production' -ResourceGroupName 'rg-identity'
    #>
    [CmdletBinding(DefaultParameterSetName = 'ManagementGroup')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ManagementGroup')][ValidateNotNullOrEmpty()][string]$ManagementGroupName,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionName')][ValidateNotNullOrEmpty()][string]$SubscriptionName,
        [Parameter(Mandatory = $true, ParameterSetName = 'SubscriptionId')][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$SubscriptionId,
        [Parameter(ParameterSetName = 'SubscriptionName')][Parameter(ParameterSetName = 'SubscriptionId')][AllowEmptyString()][string]$ResourceGroupName = ''
    )

    if ($PSCmdlet.ParameterSetName -eq 'ManagementGroup') {
        $cacheKey = 'mg:' + $ManagementGroupName.ToLowerInvariant()
        if ($script:RunbookLookupCache.ContainsKey($cacheKey)) { return [string]$script:RunbookLookupCache[$cacheKey] }

        $groups = @(Invoke-CloudRequest -Api Arm -Uri 'providers/Microsoft.Management/managementGroups' -ApiVersion $script:RunbookApiVersions.ManagementGroups -AllPages)
        $byName = @($groups | Where-Object { ([string]$_.name).Equals($ManagementGroupName, [StringComparison]::OrdinalIgnoreCase) })
        $match = $null
        if ($byName.Count -eq 1) { $match = $byName[0] }
        else {
            $byDisplay = @($groups | Where-Object { $_.PSObject.Properties['properties'] -and $null -ne $_.properties -and ([string]$_.properties.displayName).Equals($ManagementGroupName, [StringComparison]::OrdinalIgnoreCase) })
            if ($byDisplay.Count -gt 1) {
                throw ('Management group display name "{0}" is not unique ({1} matches: {2}). Use the group id.' -f $ManagementGroupName, $byDisplay.Count, ((@($byDisplay | ForEach-Object { [string]$_.name })) -join ', '))
            }
            if ($byDisplay.Count -eq 1) { $match = $byDisplay[0] }
        }
        if ($null -eq $match) {
            throw ('Management group "{0}" was not found by id or display name among the {1} management group(s) the identity can read.' -f $ManagementGroupName, $groups.Count)
        }
        $groupId = [string]$match.name
        if ($groupId -notmatch '^[\w\-\.\(\)]{1,90}$' -or $groupId.EndsWith('.')) {
            throw ('Management group "{0}" matched an entry whose id "{1}" is not a valid management group id; refusing to build a scope from it.' -f $ManagementGroupName, (Protect-RunbookText -Text $groupId -MaxLength 100))
        }
        $scope = '/providers/Microsoft.Management/managementGroups/' + $groupId
        $script:RunbookLookupCache[$cacheKey] = $scope
        return $scope
    }

    if ($PSCmdlet.ParameterSetName -eq 'SubscriptionId') {
        $scope = '/subscriptions/' + $SubscriptionId.ToLowerInvariant()
    }
    else {
        $cacheKey = 'sub:' + $SubscriptionName.ToLowerInvariant()
        if ($script:RunbookLookupCache.ContainsKey($cacheKey)) { $scope = [string]$script:RunbookLookupCache[$cacheKey] }
        else {
            $subscriptions = @(Invoke-CloudRequest -Api Arm -Uri 'subscriptions' -ApiVersion $script:RunbookApiVersions.Subscriptions -AllPages)
            $nameMatches = @($subscriptions | Where-Object { ([string]$_.displayName).Equals($SubscriptionName, [StringComparison]::OrdinalIgnoreCase) })
            if ($nameMatches.Count -eq 0) {
                throw ('Subscription "{0}" was not found among the {1} subscription(s) the identity can read.' -f $SubscriptionName, $subscriptions.Count)
            }
            if ($nameMatches.Count -gt 1) {
                throw ('Subscription name "{0}" is not unique ({1} matches: {2}). Rename one, or pass the subscription id.' -f $SubscriptionName, $nameMatches.Count, ((@($nameMatches | ForEach-Object { [string]$_.subscriptionId })) -join ', '))
            }
            $matchedId = [string]$nameMatches[0].subscriptionId
            if ($matchedId -notmatch $script:RunbookGuidPattern) {
                $shownId = '(empty)'
                if (-not [string]::IsNullOrWhiteSpace($matchedId)) { $shownId = '"' + (Protect-RunbookText -Text $matchedId -MaxLength 100) + '"' }
                throw ('Subscription "{0}" has no usable subscription id: the lookup matched an entry whose subscriptionId {1} is not a GUID; refusing to build a scope from it.' -f $SubscriptionName, $shownId)
            }
            $scope = '/subscriptions/' + $matchedId
            $script:RunbookLookupCache[$cacheKey] = $scope
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        if ($ResourceGroupName -notmatch '^[-\w\._\(\)]{1,90}$') { throw ('Resource group name "{0}" is not valid.' -f $ResourceGroupName) }
        $scope = '{0}/resourceGroups/{1}' -f $scope, $ResourceGroupName
    }
    return $scope
}

function Get-ManagementGroupDescendantSubscriptions {
    <#
    .SYNOPSIS
        Every subscription under a management group, at any depth.
    .DESCRIPTION
        Resolves the group with Resolve-ArmScope (id or display name), then
        GET <scope>/descendants and keeps the entries whose type ends in
        /subscriptions. Writes one object per subscription, sorted by display
        name: SubscriptionId, DisplayName, ParentId, Scope. Wrap in @(). A
        subscription entry whose name is not a GUID throws rather than
        produce a malformed scope.
    .PARAMETER ManagementGroupName
        Management group id or display name.
    .EXAMPLE
        foreach ($sub in @(Get-ManagementGroupDescendantSubscriptions -ManagementGroupName 'Platform')) { $sub.Scope }
    #>
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ManagementGroupName)

    $scope = Resolve-ArmScope -ManagementGroupName $ManagementGroupName
    $descendants = @(Invoke-CloudRequest -Api Arm -Uri ($scope.TrimStart('/') + '/descendants') -ApiVersion $script:RunbookApiVersions.ManagementGroups -AllPages)
    $subscriptions = New-Object System.Collections.ArrayList
    foreach ($entry in $descendants) {
        if (-not ([string]$entry.type).EndsWith('/subscriptions', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $displayName = ''
        $parentId = ''
        if ($entry.PSObject.Properties['properties'] -and $null -ne $entry.properties) {
            if ($entry.properties.PSObject.Properties['displayName']) { $displayName = [string]$entry.properties.displayName }
            if ($entry.properties.PSObject.Properties['parent'] -and $null -ne $entry.properties.parent) { $parentId = [string]$entry.properties.parent.id }
        }
        $id = [string]$entry.name
        if ($id -notmatch $script:RunbookGuidPattern) {
            throw ('Management group "{0}" listed a subscription whose name "{1}" is not a GUID; refusing to build a scope from it.' -f $ManagementGroupName, (Protect-RunbookText -Text $id -MaxLength 100))
        }
        $entryScope = '/subscriptions/' + $id
        if ($entry.PSObject.Properties['id'] -and ([string]$entry.id) -match '^/subscriptions/[^/]+$') { $entryScope = [string]$entry.id }
        [void]$subscriptions.Add([PSCustomObject]@{
                SubscriptionId = $id
                DisplayName    = $displayName
                ParentId       = $parentId
                Scope          = $entryScope
            })
    }
    return @($subscriptions | Sort-Object -Property DisplayName, SubscriptionId)
}

# ---------------------------------------------------------------------------
# Run summary. One structured object, emitted as the runbook's last output:
# counts per action and outcome, the items, the failures, the dry-run flag,
# the run id, and the duration. The SIEM keys a ticket on RunId.
# ---------------------------------------------------------------------------

function New-RunSummary {
    <#
    .SYNOPSIS
        Starts the structured summary for this run.
    .DESCRIPTION
        Returns a mutable object that Add-RunSummaryItem and
        Invoke-RunbookAction record into and Complete-RunSummary turns into
        the final output. RunbookName, DryRun, Environment, and RunId default
        to the run context.
    .PARAMETER RunbookName
        Name on the summary.
    .PARAMETER DryRun
        Dry-run flag on the summary.
    .PARAMETER RunId
        Correlation id.
    .PARAMETER Environment
        Global or USGov.
    .PARAMETER StartedUtc
        Start time. Default now.
    .EXAMPLE
        $summary = New-RunSummary
    #>
    param(
        [AllowEmptyString()][string]$RunbookName = '',
        [bool]$DryRun = $true,
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$Environment = '',
        [DateTime]$StartedUtc = [DateTime]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($RunbookName)) { $RunbookName = [string]$script:RunbookContext.RunbookName }
    if (-not $PSBoundParameters.ContainsKey('DryRun')) { $DryRun = [bool]$script:RunbookContext.DryRun }
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [string]$script:RunId }
    if ([string]::IsNullOrWhiteSpace($Environment)) { $Environment = [string]$script:RunbookContext.Environment }

    return [PSCustomObject]@{
        RunId       = $RunId
        Runbook     = $RunbookName
        DryRun      = $DryRun
        Environment = $Environment
        StartedUtc  = $StartedUtc.ToUniversalTime()
        Counts      = [ordered]@{}
        Items       = (New-Object System.Collections.ArrayList)
        Failures    = (New-Object System.Collections.ArrayList)
    }
}

function Add-RunSummaryItem {
    <#
    .SYNOPSIS
        Records one action and its outcome on the summary.
    .DESCRIPTION
        Outcome defaults to Planned in a dry run and Done otherwise. Failed
        items are also added to the failure list. Writes nothing to the
        pipeline and nothing to the log; log with Write-RunLog, or use
        Invoke-RunbookAction, which does both.
    .PARAMETER Summary
        The object from New-RunSummary.
    .PARAMETER Action
        Short verb-noun for grouping, for example RemoveMember.
    .PARAMETER Target
        What the action applies to.
    .PARAMETER Outcome
        Planned, Done, Failed, or Skipped.
    .PARAMETER Detail
        Free text, such as the reason or the error message.
    .EXAMPLE
        Add-RunSummaryItem -Summary $summary -Action 'DisableUser' -Target $upn -Outcome Skipped -Detail 'exempt'
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [ValidateSet('Planned', 'Done', 'Failed', 'Skipped')][string]$Outcome = 'Done',
        [AllowEmptyString()][string]$Detail = ''
    )

    if (-not $PSBoundParameters.ContainsKey('Outcome')) {
        if ([bool]$Summary.DryRun) { $Outcome = 'Planned' } else { $Outcome = 'Done' }
    }
    if (-not $Summary.Counts.Contains($Action)) {
        $Summary.Counts[$Action] = [ordered]@{ Planned = 0; Done = 0; Failed = 0; Skipped = 0 }
    }
    $Summary.Counts[$Action][$Outcome] = [int]$Summary.Counts[$Action][$Outcome] + 1

    $item = [PSCustomObject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Action       = $Action
        Target       = $Target
        Outcome      = $Outcome
        Detail       = (Protect-RunbookText -Text $Detail -MaxLength 1000)
    }
    [void]$Summary.Items.Add($item)
    if ($Outcome -eq 'Failed') { [void]$Summary.Failures.Add($item) }
}

function ConvertTo-RunbookObject {
    <#
    .SYNOPSIS
        A PSCustomObject with the dictionary's keys as properties, in order.
    .PARAMETER Table
        Ordered dictionary or hashtable.
    .EXAMPLE
        ConvertTo-RunbookObject -Table ([ordered]@{ A = 1; B = 2 })
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Table)

    $object = New-Object -TypeName PSObject
    foreach ($key in $Table.Keys) {
        $object | Add-Member -MemberType NoteProperty -Name ([string]$key) -Value $Table[$key]
    }
    return $object
}

function Complete-RunSummary {
    <#
    .SYNOPSIS
        Finishes the summary and returns the object the runbook emits last.
    .DESCRIPTION
        Adds CompletedUtc, DurationSeconds, totals per outcome, warning and
        error counts from the run log, and the items (at most MaxItems, with
        ItemsTruncated set when more were recorded). Extra adds
        runbook-specific values after the standard ones; a key that would
        replace a standard one is ignored with a warning. Writes one closing
        Info line.
    .PARAMETER Summary
        The object from New-RunSummary.
    .PARAMETER Extra
        Runbook-specific values, for example @{ GroupsScanned = 12 }.
    .PARAMETER MaxItems
        Items and failures kept on the output. Default 500.
    .PARAMETER CompletedUtc
        End time. Default now.
    .EXAMPLE
        return (Complete-RunSummary -Summary $summary -Extra ([ordered]@{ AssignmentsScanned = $assignments.Count }))
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [AllowNull()][System.Collections.IDictionary]$Extra = $null,
        [ValidateRange(0, 1000000)][int]$MaxItems = 500,
        [DateTime]$CompletedUtc = [DateTime]::UtcNow
    )

    $completed = $CompletedUtc.ToUniversalTime()
    $totals = [ordered]@{ Planned = 0; Done = 0; Failed = 0; Skipped = 0 }
    $counts = [ordered]@{}
    foreach ($action in $Summary.Counts.Keys) {
        $row = $Summary.Counts[$action]
        foreach ($outcome in @('Planned', 'Done', 'Failed', 'Skipped')) { $totals[$outcome] = $totals[$outcome] + [int]$row[$outcome] }
        $counts[[string]$action] = ConvertTo-RunbookObject -Table $row
    }

    $items = @($Summary.Items.ToArray())
    $failures = @($Summary.Failures.ToArray())
    $duration = [Math]::Round(($completed - ([DateTime]$Summary.StartedUtc)).TotalSeconds, 1)
    if ($duration -lt 0) { $duration = 0 }

    $table = [ordered]@{
        RunId           = [string]$Summary.RunId
        Runbook         = [string]$Summary.Runbook
        DryRun          = [bool]$Summary.DryRun
        Environment     = [string]$Summary.Environment
        StartedUtc      = ([DateTime]$Summary.StartedUtc).ToString('yyyy-MM-ddTHH:mm:ssZ')
        CompletedUtc    = $completed.ToString('yyyy-MM-ddTHH:mm:ssZ')
        DurationSeconds = $duration
        Counts          = (ConvertTo-RunbookObject -Table $counts)
        Planned         = $totals.Planned
        Done            = $totals.Done
        Failed          = $totals.Failed
        Skipped         = $totals.Skipped
        ItemCount       = $items.Count
        FailureCount    = $failures.Count
        Items           = @($items | Select-Object -First $MaxItems)
        ItemsTruncated  = ($items.Count -gt $MaxItems)
        Failures        = @($failures | Select-Object -First $MaxItems)
        Warnings        = (Get-RunLogCount -Level Warn)
        Errors          = (Get-RunLogCount -Level Error)
    }
    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $name = [string]$key
            if ($table.Contains($name)) {
                Write-RunLog -Level Warn -Message ('Summary value "{0}" from the runbook was ignored; the name is reserved.' -f $name)
                continue
            }
            $table[$name] = $Extra[$key]
        }
        $table['Warnings'] = Get-RunLogCount -Level Warn
    }

    Write-RunLog -Level Info -Message ('Finished {0}. DryRun={1} planned={2} done={3} failed={4} skipped={5} warnings={6} errors={7} duration={8}s' -f $table.Runbook, $table.DryRun, $table.Planned, $table.Done, $table.Failed, $table.Skipped, $table.Warnings, $table.Errors, $table.DurationSeconds)
    return (ConvertTo-RunbookObject -Table $table)
}

function Invoke-RunbookAction {
    <#
    .SYNOPSIS
        Performs one write, or logs that it would, and records the outcome.
    .DESCRIPTION
        The dry-run rule in one place. When the summary is a dry run, logs
        "Would <Description>." at Action level, records Planned, and does not
        run the script block. Otherwise runs the script block, logs
        "Done: <Description>." and records Done; if the block throws, logs
        "Failed: <Description>: <error>" at Error level, records Failed, and
        carries on (or rethrows with -StopOnError). Output of the script
        block is discarded. With -PassThru the outcome string is returned.

        The script block runs in a child scope of this function, so it sees
        the caller's variables except any named Summary, Action, Target,
        Description, ScriptBlock, StopOnError, or PassThru, which are this
        function's parameters. Use other names inside the block, or
        .GetNewClosure().
    .PARAMETER Summary
        The object from New-RunSummary; its DryRun decides.
    .PARAMETER Action
        Short verb-noun for grouping, for example RemoveMember.
    .PARAMETER Target
        What the action applies to.
    .PARAMETER Description
        Lower-case verb phrase, for example 'remove alex@corp.example.com from "Contoso Admins"'.
    .PARAMETER ScriptBlock
        The write.
    .PARAMETER StopOnError
        Rethrow after recording a failure.
    .PARAMETER PassThru
        Return Planned, Done, or Failed.
    .EXAMPLE
        Invoke-RunbookAction -Summary $summary -Action 'RemoveMember' -Target $upn -Description ('remove {0} from "{1}"' -f $upn, $groupName) -ScriptBlock {
            Invoke-CloudRequest -Api Graph -Method DELETE -Uri ('groups/{0}/members/{1}/$ref' -f $groupId, $memberId)
        }
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [switch]$StopOnError,
        [switch]$PassThru
    )

    if ([bool]$Summary.DryRun) {
        Write-RunLog -Level Action -Message ('Would {0}.' -f $Description)
        Add-RunSummaryItem -Summary $Summary -Action $Action -Target $Target -Outcome Planned
        if ($PassThru) { return 'Planned' }
        return
    }

    try {
        & $ScriptBlock | Out-Null
    }
    catch {
        $failure = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
        Write-RunLog -Level Error -Message ('Failed: {0}: {1}' -f $Description, $failure)
        Add-RunSummaryItem -Summary $Summary -Action $Action -Target $Target -Outcome Failed -Detail $failure
        if ($StopOnError) { throw }
        if ($PassThru) { return 'Failed' }
        return
    }

    Write-RunLog -Level Action -Message ('Done: {0}.' -f $Description)
    Add-RunSummaryItem -Summary $Summary -Action $Action -Target $Target -Outcome Done
    if ($PassThru) { return 'Done' }
}
