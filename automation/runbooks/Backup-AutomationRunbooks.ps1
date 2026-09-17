<#
.SYNOPSIS
    Backs up the published source of every runbook in one or more Azure
    Automation accounts to blob storage, proves each backup restores, and
    prunes old backups under a strict prefix with a floor and a cap.

.DESCRIPTION
    Runs as an Azure Automation runbook on a user-assigned managed identity.
    For each Automation account named in AutomationAccountNames it:

      1. Lists the backups that already exist under
         <Prefix>/<account>/ in the container, which also gives the age of
         the newest one (reported on the summary as freshness, even when the
         rest of the run fails).
      2. Lists the account's runbooks through Azure Resource Manager and
         downloads the published content of every runbook that has a
         published version (state Published, or Edit, which is a published
         runbook with a draft open). Runbooks in state New have never been
         published and are skipped. Each source is written to a temporary
         folder as UTF-8 without a byte order mark, with the extension of its
         type (.ps1, .graphrunbook, .py).
      3. Writes manifest.json: every runbook's name, type, runtime version and
         runtime environment where known, state, lastModifiedTime, the
         Content-Type the service returned, byte length, and SHA-256.
      4. Runs the guards (below). A tripped guard aborts that account.
      5. Packages the folder as <Prefix>/<account>/<yyyyMMdd-HHmmss>Z.zip,
         extracts the package again and checks every hash (local verify).
      6. Uploads the package, downloads it again, extracts it to a second
         temporary folder, and recomputes every SHA-256 against the manifest
         (restore verify). Any difference fails the account.
      7. Only after a verified upload, and only when the run's delete cap
         holds, applies retention to that account's backups.

    Temporary folders are removed in a finally block, so a thrown error does
    not leave runbook source on the worker.

    Safety model.
      DryRun is the default. A dry run does steps 1 to 5 in full, including
      the local verify, then logs "Would upload" and "Would delete" for what a
      live run would do and writes nothing to storage. The summary lists the
      blobs that would be deleted.

      Empty export guard. An account that yields zero published runbooks is
      aborted before anything is written: a bad token, a wrong account name,
      or a scoping bug must never become the newest backup.

      Shrink guard. The manifest inside the newest existing backup is read
      (walking back up to three backups if the newest cannot be read). If the
      runbook count dropped by more than MaxShrinkPercent, the account is
      aborted. After a deliberate cleanup, raise MaxShrinkPercent for one run.
      If existing backups are present but none of their manifests can be read,
      the account is aborted too, because the guard cannot be evaluated.

      Retention never runs for an account whose new backup did not upload and
      verify, so a failing backup job never prunes the good copies it failed
      to replace. Retention lists blobs only under <Prefix>/<account>/,
      re-checks every returned name against that prefix and the exact
      <yyyyMMdd-HHmmss>Z.zip pattern, and never touches anything else in the
      container (other accounts, sibling prefixes, nested folders, notes).
      Blobs are sorted by name (the UTC stamp); the newest KeepAtLeast are
      always kept (KeepAtLeast is at least 1), and of the rest, those whose
      stamp is older than RetentionDays are deleted.

      Delete cap. The planned deletes of every account are added up before
      the first write of the run. When the total is more than
      MaxDeletesPerRun, the run records a DeleteCap failure and deletes
      nothing in any account, but it still uploads and verifies every new
      backup: the upload is a new, uniquely named blob sent with
      If-None-Match: *, so holding it back makes nothing safer and would
      turn a retention anomaly (old backups copied back into the prefix for
      an investigation, a clock problem) into a backup outage. The summary
      lists every blob the cap held back (BlobsToDelete, and DeleteBackup
      items with outcome Skipped), and the job still ends Failed. The cap
      stops all retention rather than truncating because a large number is
      a symptom, and a partial prune would hide it. MaxDeletesPerRun 0
      therefore means "never prune, and fail the job whenever a backup is
      due for deletion".

      Blob names are checked before any request. Every prefix segment, and
      every segment of a blob name this runbook uploads, downloads, or
      deletes, must start and end with a letter, digit, underscore, or
      hyphen (Assert-BackupBlobName). The library then checks the name again
      and parses each built URI back against the container and blob it was
      meant for. Windows PowerShell 5.1 silently drops a trailing dot from a
      path segment ("automation./" reaches "automation/"), which would make
      retention list one folder and delete in another; both checks refuse
      such a request before a token is sent. A delete that finds nothing
      (HTTP 404) is recorded as Skipped, "already gone", never as a delete.

      A backup never overwrites another blob: the upload sends
      If-None-Match: * and Content-MD5, so the storage service refuses to
      replace an existing blob and rejects a body damaged in transit.

      A run that recorded any failure (a guard, an upload, a verify, a
      delete, the delete cap) writes its summary object and then throws, so
      the Automation job ends Failed and the job alert fires. A backup job
      that "completes" without a backup is the failure mode this avoids. An
      error before the accounts are processed (a parameter, the subscription
      lookup) throws at once, without a summary.

      Recommended on the storage account, outside this runbook: blob soft
      delete and versioning (a wrong delete is recoverable), no public access,
      and a container dedicated to backups. A time-based immutability policy
      works only when its period is shorter than RetentionDays, or retention
      deletes will fail.

    Storage requests. Every request this runbook sends goes through the
    library's Invoke-HttpCore, the one Invoke-WebRequest call, so the
    automation/README.md rule holds without exception, and the tests mock
    Invoke-HttpCore and Start-Sleep and nothing else. The listing, the
    package downloads (Invoke-StorageRequest -Operation GetBlobToFile, which
    streams the body to a file without decoding it), and the deletes
    (-Operation DeleteBlob -AllowNotFound) use the library's storage helper.
    The upload is the one request built here: PutBlob sends its content as
    UTF-8 text and has no If-None-Match, Content-MD5, or metadata, so
    Send-BackupPackage sends the zip bytes itself through the library's
    Invoke-RunbookHttp (same retry rules, same error shape). A PUT is
    idempotent, so a 5xx or a lost response is retried; the retry meets
    If-None-Match: * and the restore verification decides.

    Why the content read does not use Invoke-CloudRequest. Runbook - Get
    Content returns the source as a string, and Invoke-CloudRequest parses
    any body that looks like JSON, which a graphical runbook is. The read
    therefore uses Invoke-RunbookHttp and decodes the body by runbook type:
    a text body is kept exactly; an application/json body that is a JSON
    string is decoded; an application/json object is kept as it is for a
    graphical runbook and refused for any other type. The Content-Type of
    every read is written to the manifest, because restore verification
    compares against the bytes this run downloaded and cannot catch a wrong
    decode.

    Endpoints (learn.microsoft.com). {api} is AutomationApiVersion, default
    2024-10-23; 2023-11-01 documents the same two operations.
      GET  {arm}/subscriptions?api-version=2022-12-01 (through Resolve-ArmScope)
      GET  {arm}/subscriptions/{id}/resourceGroups/{rg}/providers/Microsoft.Automation/automationAccounts/{account}/runbooks?api-version={api}
      GET  {arm}/subscriptions/{id}/resourceGroups/{rg}/providers/Microsoft.Automation/automationAccounts/{account}/runbooks/{name}/content?api-version={api}
      GET  https://{storage}.{blob suffix}/{container}?restype=container&comp=list&prefix=...
      PUT  https://{storage}.{blob suffix}/{container}/{blob}  x-ms-blob-type: BlockBlob, If-None-Match: *, Content-MD5
      GET  https://{storage}.{blob suffix}/{container}/{blob}
      DELETE https://{storage}.{blob suffix}/{container}/{blob}

    Permissions.
      Microsoft Graph application permissions: none.
      Azure RBAC for the managed identity:
        Reader on each Automation account (it includes
          Microsoft.Automation/automationAccounts/runbooks/read and
          Microsoft.Automation/automationAccounts/runbooks/content/read; the
          Automation Operator roles cannot read runbook content). A custom
          role with exactly those two actions is the tighter alternative.
        Storage Blob Data Contributor on the backup container (list, read,
          write, delete). A dry run needs only Storage Blob Data Reader.
        The subscription is found by name with GET /subscriptions, which
          lists only subscriptions where the identity holds a role. Pass the
          subscription id in SubscriptionName to skip that lookup.

    Recommended schedule. Daily, before anything else changes the account.
    The corp cell (tenants/azure/corp/azure-automation) runs it every day at
    02:00 UTC on its daily-0200-utc schedule, the first of the nightly jobs.
    Run it dry for a week and read the summaries, then set dry_run to
    false in the tenant cell. Before that, check the decoding once from a
    workstation, against an account that holds both a text runbook and a
    graphical runbook: dot-source this file (the entry point does not run),
    call Initialize-RunContext with -AccessToken, call
    Export-BackupRunbookSources with a -Destination folder of your own, and
    compare the files with a portal export of the same runbooks. The
    contentType of each entry it returns shows how each body was decoded.
    Retention is by age with a count floor, so a daily schedule and the
    defaults keep 30 days and never fewer than 7 backups. If the Automation
    api-version is not available in a cloud
    (HTTP 400 InvalidApiVersionParameter or NoRegisteredProviderFound), set
    automationapiversion = "2023-11-01" in the cell's parameters; a blank
    value means the default.

    Stack cell (stacks/azure-automation, runbooks map; keys lowercase). The
    stack adds clientid, environment, sendermailbox, and dryrun, and
    stack_parameters asks it for the values only it knows, so the cell never
    types the account, its resource group and subscription, or the backup
    storage names. subscription_id is passed as an id, which skips the
    subscription lookup. This is the corp cell's entry:

      runbook-backup = {
        name         = "Backup-AutomationRunbooks"
        file         = "Backup-AutomationRunbooks.ps1"
        library      = "Runbook.Common.ps1"
        schedule_key = "daily-0200-utc"
        parameters = {
          prefix           = "automation"
          retentiondays    = "30"
          keepatleast      = "7"
          maxdeletesperrun = "20"
          maxshrinkpercent = "25"
          # Only where the default api-version is missing:
          # automationapiversion = "2023-11-01"
        }
        stack_parameters = {
          automationaccountnames = "automation_account_names"
          resourcegroupname      = "resource_group_name"
          subscriptionname       = "subscription_id"
          storageaccountname     = "backup_storage_account_name"
          containername          = "backup_container_name"
        }
      }

    automation_account_names is the stack's own account, passed as a
    semicolon list. To back up more accounts in the same resource group,
    move automationaccountnames from stack_parameters to parameters (the
    stack refuses a key in both) with a value such as
    "aa-example-one;aa-example-two", and give the identity Reader on each
    of those accounts.

    Design rules shared by every runbook in this repository are in
    automation/README.md.

.PARAMETER AutomationAccountNames
    Automation accounts to back up, all in ResourceGroupName. One string, a
    semicolon-separated list such as aa-identity-prod;aa-identity-dev (commas
    also separate; spaces around a name are ignored). This is the form a job
    schedule passes; stack_parameters automation_account_names gives the
    stack's own account in it. An Automation account name cannot contain a
    semicolon or a comma. A JSON array such as ["aa-identity-prod"] is
    accepted for local runs only: the Automation service may parse
    JSON-looking schedule values before they are bound. Duplicates are
    dropped; names are matched case-insensitively and used in lower case in
    blob names.

.PARAMETER ResourceGroupName
    Resource group that holds the Automation accounts.

.PARAMETER SubscriptionName
    Display name of the subscription that holds the resource group, or the
    subscription id.

.PARAMETER StorageAccountName
    Storage account that receives the backups (3 to 24 lowercase letters and
    digits).

.PARAMETER ContainerName
    Blob container for the backups. Default runbook-backups. It must exist.

.PARAMETER Prefix
    Virtual folder under the container. Backups are written to
    <Prefix>/<account>/<yyyyMMdd-HHmmss>Z.zip and retention looks nowhere
    else. Segments of letters, digits, dot, underscore, and hyphen,
    separated by "/"; a segment may not start or end with a dot. Default
    automation.

.PARAMETER RetentionDays
    Backups whose stamp is older than this many days are deleted, except the
    newest KeepAtLeast. Default 30.

.PARAMETER KeepAtLeast
    The newest backups kept per account whatever their age, 1 or more.
    Default 7.

.PARAMETER MaxDeletesPerRun
    Circuit breaker. More planned deletes than this, across all accounts,
    skips retention for every account and fails the run; backups are still
    uploaded and verified. 0 never prunes and fails any run that has a
    backup due for deletion. Default 20.

.PARAMETER MaxShrinkPercent
    Shrink guard. An account whose published runbook count dropped by more
    than this percentage since the newest existing backup is aborted.
    Default 25.

.PARAMETER AutomationApiVersion
    api-version for the Automation runbook list and content calls, as
    yyyy-MM-dd or yyyy-MM-dd-preview. Default 2024-10-23; an empty value
    also means the default. Set 2023-11-01 (job schedule key
    automationapiversion) where the default is not available. The value
    used is logged, written to every manifest, and on the summary.

.PARAMETER ReportPath
    Optional path for a CSV with one row per account: status, counts, the
    backup blob, verification, freshness, and planned deletes.

.PARAMETER SenderMailbox
    Accepted and ignored. stacks/azure-automation passes it to every
    runbook, and this one sends no mail.

.PARAMETER DryRun
    Default $true. Exports, packages, and verifies locally; uploads and
    deletes nothing; logs every write as "Would". The delete cap is still
    evaluated, and a tripped cap still fails the run. Pass -DryRun:$false
    to act.

.PARAMETER Environment
    National cloud: Global (default) or USGov.

.PARAMETER ClientId
    Client id of the user-assigned managed identity.

.PARAMETER AccessToken
    Local runs only. A JSON object string with Arm and Storage tokens, for
    example {"Arm":"...","Storage":"..."}. Never logged.

.PARAMETER RunId
    Correlation id stamped on every log line, the summary, and the manifest.

.EXAMPLE
    $arm = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    $storage = az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv
    $tokens = @{ Arm = $arm; Storage = $storage } | ConvertTo-Json -Compress
    .\Backup-AutomationRunbooks.ps1 -AutomationAccountNames 'aa-identity-prod' -ResourceGroupName 'rg-identity-automation' -SubscriptionName 'Identity Production' -StorageAccountName 'stidentitybackups' -AccessToken $tokens -ReportPath .\out\runbook-backups.csv

    Dry run from a workstation: exports and verifies locally, reports what
    would be uploaded and deleted, and writes nothing.

.EXAMPLE
    .\Backup-AutomationRunbooks.ps1 -AutomationAccountNames 'aa-identity-prod;aa-identity-dev' -ResourceGroupName 'rg-identity-automation' -SubscriptionName '11111111-1111-1111-1111-111111111111' -StorageAccountName 'stidentitybackups' -DryRun:$false -ClientId <identity client id>

    The live form, as the job schedule runs it on the managed identity: a
    semicolon list of accounts and the subscription id, which skips the
    subscription lookup.

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    Uses System.IO.Compression for the package.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AutomationAccountNames,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    [ValidatePattern('^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$')]
    [string]$ContainerName = 'runbook-backups',

    [ValidateNotNullOrEmpty()]
    [string]$Prefix = 'automation',

    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 30,

    [ValidateRange(1, 1000)]
    [int]$KeepAtLeast = 7,

    [ValidateRange(0, 10000)]
    [int]$MaxDeletesPerRun = 20,

    [ValidateRange(0, 100)]
    [int]$MaxShrinkPercent = 25,

    [ValidatePattern('^(\d{4}-\d{2}-\d{2}(-preview)?)?$')]
    [string]$AutomationApiVersion = '2024-10-23',

    [string]$ReportPath = '',

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

$script:BackupRunbookName = 'Backup-AutomationRunbooks'
# Default only; the run uses the AutomationApiVersion parameter.
$script:BackupAutomationApiVersion = '2024-10-23'
$script:BackupApiVersionPattern = '^\d{4}-\d{2}-\d{2}(-preview)?$'
# A blob name segment. It may not start or end with a dot: a URI parser
# drops a trailing dot (Windows PowerShell 5.1) and collapses "." and "..".
$script:BackupSegmentPattern = '^[A-Za-z0-9_-]([A-Za-z0-9._-]*[A-Za-z0-9_-])?$'
$script:BackupStampFormat = 'yyyyMMdd-HHmmss'
$script:BackupManifestName = 'manifest.json'
$script:BackupSourceFolder = 'runbooks'
$script:BackupManifestLookback = 3
$script:BackupMaxEntryBytes = 52428800
$script:BackupMaxManifestBytes = 4194304
$script:BackupEntryPattern = '^(manifest\.json|runbooks/[A-Za-z][A-Za-z0-9_-]{0,127}\.(ps1|graphrunbook|py|txt))$'
$script:BackupRunbookNamePattern = '^[A-Za-z][A-Za-z0-9_-]{0,127}$'
$script:BackupAccountNamePattern = '^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$'

# ---------------------------------------------------------------------------
# Names, stamps, and small conversions. Pure.
# ---------------------------------------------------------------------------

function ConvertTo-BackupUtc {
    <#
    .SYNOPSIS
        A DateTime as UTC; an unspecified kind is taken to be UTC already.
    .PARAMETER Value
        The date.
    .EXAMPLE
        ConvertTo-BackupUtc -Value (Get-Date)
    #>
    param([Parameter(Mandatory = $true)][DateTime]$Value)

    if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
    return $Value.ToUniversalTime()
}

function ConvertTo-BackupIsoText {
    <#
    .SYNOPSIS
        An ARM date value as an ISO 8601 UTC string, or '' when empty.
    .DESCRIPTION
        Windows PowerShell 5.1 leaves JSON dates as strings and PowerShell 7
        turns them into DateTime values, so the manifest normalises both.
        A string that does not parse is kept as it is.
    .PARAMETER Value
        String, DateTime, DateTimeOffset, or $null.
    .EXAMPLE
        ConvertTo-BackupIsoText -Value '2017-03-28T21:32:25.81+00:00'
        2017-03-28T21:32:25.8100000Z
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return (ConvertTo-BackupUtc -Value $Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return '' }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $text
}

function ConvertTo-BackupPrefix {
    <#
    .SYNOPSIS
        The Prefix parameter without leading or trailing slashes, validated.
    .DESCRIPTION
        Segments may hold letters, digits, dot, underscore, and hyphen, and
        must start and end with something other than a dot. A URI parser
        collapses "." and "..", and Windows PowerShell 5.1 also drops a
        trailing dot ("automation." becomes "automation"), so such a segment
        would send the upload and the deletes to a different folder than the
        one the listing read.
    .PARAMETER Prefix
        The raw value.
    .EXAMPLE
        ConvertTo-BackupPrefix -Prefix '/automation/'
        automation
    #>
    param([AllowNull()][AllowEmptyString()][string]$Prefix)

    $text = ''
    if ($null -ne $Prefix) { $text = $Prefix.Trim().Trim('/') }
    if ($text.Length -eq 0) { throw 'Prefix must not be empty; backups need their own virtual folder in the container.' }
    foreach ($segment in $text.Split('/')) {
        if ($segment -cnotmatch $script:BackupSegmentPattern) {
            throw ('Prefix "{0}" is not valid. Use segments of letters, digits, dot, underscore, and hyphen, separated by "/", each starting and ending with a letter, digit, underscore, or hyphen.' -f $Prefix)
        }
    }
    return $text
}

function Assert-BackupBlobName {
    <#
    .SYNOPSIS
        Throws unless every segment of a blob name is a safe backup segment.
    .DESCRIPTION
        Stricter than the library's Assert-StorageBlobName, which every
        Invoke-StorageRequest call also applies: each "/" segment must start
        and end with a letter, digit, underscore, or hyphen and hold only
        those and dots. That rules out an empty segment, "." and "..", a
        leading or trailing dot, spaces, and anything a URI parser could
        rewrite. Called before any request that names a backup blob.
    .PARAMETER BlobName
        The blob name.
    .EXAMPLE
        Assert-BackupBlobName -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip'
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$BlobName)

    foreach ($segment in $BlobName.Split('/')) {
        if ($segment -cnotmatch $script:BackupSegmentPattern) {
            throw ('Refusing a storage request for blob "{0}": the segment "{1}" is not a safe blob name segment.' -f $BlobName, $segment)
        }
    }
}

function Assert-BackupBlobRequestUri {
    <#
    .SYNOPSIS
        Throws unless a blob request URI reaches exactly the container and
        blob it was built for.
    .DESCRIPTION
        Two checks, both before any token is sent. The blob name must pass
        Assert-BackupBlobName. Then the URI is parsed and its unescaped
        path must equal "/<container>/<blob>" exactly, so a parser that
        rewrites the path (collapsing dot segments, dropping a trailing dot)
        is caught whatever the name looked like.
    .PARAMETER Uri
        The absolute request URI.
    .PARAMETER ContainerName
        Container the request is meant for.
    .PARAMETER BlobName
        Blob the request is meant for.
    .EXAMPLE
        Assert-BackupBlobRequestUri -Uri $uri -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName
    )

    Assert-BackupBlobName -BlobName $BlobName
    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw ('Refusing a storage request for blob "{0}": the request URI does not parse.' -f $BlobName)
    }
    $expected = '/' + $ContainerName + '/' + $BlobName
    $actual = [Uri]::UnescapeDataString($parsed.AbsolutePath)
    if (-not ($actual -ceq $expected)) {
        throw ('Refusing a storage request for blob "{0}": the URI would reach "{1}" instead of "{2}".' -f $BlobName, $actual, $expected)
    }
}

function Get-BackupAccountPrefix {
    <#
    .SYNOPSIS
        The blob name prefix that holds one account's backups, with a
        trailing slash.
    .PARAMETER Prefix
        The Prefix parameter.
    .PARAMETER AccountName
        Automation account name; used in lower case.
    .EXAMPLE
        Get-BackupAccountPrefix -Prefix 'automation' -AccountName 'AA-Identity-Prod'
        automation/aa-identity-prod/
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$AccountName
    )

    $clean = ConvertTo-BackupPrefix -Prefix $Prefix
    if ($AccountName -notmatch $script:BackupAccountNamePattern) {
        throw ('Automation account name "{0}" is not valid (6 to 50 letters, digits, and hyphens, starting with a letter).' -f $AccountName)
    }
    return ('{0}/{1}/' -f $clean, $AccountName.ToLowerInvariant())
}

function New-BackupBlobName {
    <#
    .SYNOPSIS
        The blob name of the backup taken at Timestamp.
    .PARAMETER AccountPrefix
        From Get-BackupAccountPrefix.
    .PARAMETER Timestamp
        Backup time; converted to UTC.
    .EXAMPLE
        New-BackupBlobName -AccountPrefix 'automation/aa-identity-prod/' -Timestamp $now
        automation/aa-identity-prod/20260917-023000Z.zip
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountPrefix,
        [Parameter(Mandatory = $true)][DateTime]$Timestamp
    )

    $stamp = (ConvertTo-BackupUtc -Value $Timestamp).ToString($script:BackupStampFormat, [Globalization.CultureInfo]::InvariantCulture)
    return ('{0}{1}Z.zip' -f $AccountPrefix, $stamp)
}

function ConvertFrom-BackupBlobName {
    <#
    .SYNOPSIS
        The UTC stamp of a backup blob name, or $null when the name is not a
        backup directly under AccountPrefix.
    .DESCRIPTION
        The match is exact and case-sensitive: AccountPrefix, then
        yyyyMMdd-HHmmss, then Z.zip, and nothing else. A nested name, a
        sibling prefix, or an impossible date returns $null.
    .PARAMETER BlobName
        Name as listed.
    .PARAMETER AccountPrefix
        From Get-BackupAccountPrefix.
    .EXAMPLE
        ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -AccountPrefix 'automation/aa-identity-prod/'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$AccountPrefix
    )

    if ([string]::IsNullOrEmpty($BlobName)) { return $null }
    if (-not $BlobName.StartsWith($AccountPrefix, [StringComparison]::Ordinal)) { return $null }
    $rest = $BlobName.Substring($AccountPrefix.Length)
    $stampText = ''
    if ($rest -cmatch '^(\d{8}-\d{6})Z\.zip$') { $stampText = $Matches[1] }
    else { return $null }
    $parsed = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParseExact($stampText, $script:BackupStampFormat, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-RunbookFileExtension {
    <#
    .SYNOPSIS
        File extension for a runbook type.
    .DESCRIPTION
        PowerShell and PowerShell Workflow sources are .ps1, graphical
        runbooks .graphrunbook, Python .py (the import formats Azure
        Automation documents). An unknown type returns .txt so the source is
        still kept; the caller logs a warning.
    .PARAMETER RunbookType
        properties.runbookType.
    .EXAMPLE
        Get-RunbookFileExtension -RunbookType 'PowerShell72'
        Returns '.ps1'.
    #>
    param([AllowNull()][AllowEmptyString()][string]$RunbookType)

    $type = ''
    if ($null -ne $RunbookType) { $type = $RunbookType.Trim().ToLowerInvariant() }
    switch ($type) {
        'powershell' { return '.ps1' }
        'powershell7' { return '.ps1' }
        'powershell72' { return '.ps1' }
        'powershellworkflow' { return '.ps1' }
        'script' { return '.ps1' }
        'graph' { return '.graphrunbook' }
        'graphpowershell' { return '.graphrunbook' }
        'graphpowershellworkflow' { return '.graphrunbook' }
        'python' { return '.py' }
        'python2' { return '.py' }
        'python3' { return '.py' }
    }
    return '.txt'
}

function Get-RunbookRuntimeVersion {
    <#
    .SYNOPSIS
        The runtime version of a runbook when the API tells it, else ''.
    .DESCRIPTION
        A runtime environment name ending in a version (PowerShell-7.2,
        Python-3.10) gives that version. Without a runtime environment the
        version is read from the types that encode one: PowerShell72 is 7.2,
        PowerShell7 is 7.1, Python2 is 2.7, and the Windows PowerShell types
        are 5.1. Anything else is '' rather than a guess.
    .PARAMETER RunbookType
        properties.runbookType.
    .PARAMETER RuntimeEnvironment
        properties.runtimeEnvironment, when present.
    .EXAMPLE
        Get-RunbookRuntimeVersion -RunbookType 'PowerShell' -RuntimeEnvironment 'PowerShell-7.4'
        7.4
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$RunbookType,
        [AllowNull()][AllowEmptyString()][string]$RuntimeEnvironment
    )

    if (-not [string]::IsNullOrWhiteSpace($RuntimeEnvironment)) {
        if ($RuntimeEnvironment.Trim() -match '-(\d+(\.\d+)+)$') { return $Matches[1] }
        return ''
    }
    $type = ''
    if ($null -ne $RunbookType) { $type = $RunbookType.Trim().ToLowerInvariant() }
    switch ($type) {
        'powershell72' { return '7.2' }
        'powershell7' { return '7.1' }
        'python2' { return '2.7' }
        'powershell' { return '5.1' }
        'powershellworkflow' { return '5.1' }
        'graphpowershell' { return '5.1' }
        'graphpowershellworkflow' { return '5.1' }
    }
    return ''
}

function ConvertFrom-RunbookContentResponse {
    <#
    .SYNOPSIS
        The runbook source from a Get Content response body.
    .DESCRIPTION
        The operation documents a string response (text/plain and
        application/json in 2024-10-23, text/powershell in 2023-11-01). The
        decoding depends on the Content-Type and on the runbook type:

          text body                    kept exactly as returned
          JSON string literal body     decoded, for every runbook type
          JSON object body             kept exactly for a graphical runbook
                                       (type Graph*), whose source is itself
                                       JSON; refused for any other type

        Anything else under application/json is refused, because it is not a
        runbook source this code understands.
    .PARAMETER Content
        Response body.
    .PARAMETER ContentType
        Response Content-Type header.
    .PARAMETER RunbookType
        properties.runbookType of the runbook.
    .EXAMPLE
        ConvertFrom-RunbookContentResponse -Content 'param()' -ContentType 'text/plain' -RunbookType 'PowerShell72'
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Content,
        [AllowNull()][AllowEmptyString()][string]$ContentType,
        [AllowNull()][AllowEmptyString()][string]$RunbookType = ''
    )

    $text = ''
    if ($null -ne $Content) { $text = $Content }
    $type = ''
    if ($null -ne $ContentType) { $type = $ContentType.Trim().ToLowerInvariant() }
    if (-not $type.StartsWith('application/json')) { return $text }

    $trimmed = $text.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        $decoded = $null
        try { $decoded = ConvertFrom-Json -InputObject $trimmed }
        catch { throw 'Runbook content came back as a JSON string that does not parse.' }
        if (-not ($decoded -is [string])) { throw 'Runbook content came back as application/json but did not decode to text.' }
        return $decoded
    }

    $graphical = $false
    if ($null -ne $RunbookType) { $graphical = $RunbookType.Trim().ToLowerInvariant().StartsWith('graph') }
    if ($graphical -and $trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) { return $text }
    throw ('Runbook content of type "{0}" came back as application/json but is not a JSON string.' -f $RunbookType)
}

function Test-RunbookContentLooksQuoted {
    <#
    .SYNOPSIS
        $true when a text body looks like a whole JSON string literal.
    .DESCRIPTION
        The documented samples show the source as a quoted JSON string even
        under a text media type. Such a body is kept exactly (a PowerShell
        source can legitimately be one quoted string), and the caller logs a
        warning so a wrong decode is noticed rather than silently backed up.
        Only a quoted body that holds a backslash escape and parses as a JSON
        string counts; a multi-line source serialised as JSON always has one.
    .PARAMETER Text
        The body as kept.
    .EXAMPLE
        Test-RunbookContentLooksQuoted -Text '"param()\r\n"'
        True
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -lt 2 -or -not ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"'))) { return $false }
    if ($trimmed.IndexOf('\') -lt 0) { return $false }
    try { return ((ConvertFrom-Json -InputObject $trimmed) -is [string]) }
    catch { return $false }
}

function Select-BackupRunbooks {
    <#
    .SYNOPSIS
        Splits a runbook list into the ones with a published version and the
        ones without.
    .DESCRIPTION
        State Published has a published version; Edit is a published runbook
        with a draft open, and its published version is still the one that
        runs. New has never been published. Selected is sorted by name,
        ordinal. Skipped carries Name and Reason.
    .PARAMETER Runbooks
        Items from Runbook - List By Automation Account.
    .EXAMPLE
        (Select-BackupRunbooks -Runbooks $list).Selected
    #>
    param([AllowNull()][AllowEmptyCollection()][object[]]$Runbooks = @())

    $selected = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach ($runbook in @($Runbooks)) {
        if ($null -eq $runbook) { continue }
        $name = ''
        if ($runbook.PSObject.Properties['name']) { $name = [string]$runbook.name }
        $state = ''
        if ($runbook.PSObject.Properties['properties'] -and $null -ne $runbook.properties -and $runbook.properties.PSObject.Properties['state']) {
            $state = [string]$runbook.properties.state
        }
        if (@('published', 'edit') -contains $state.ToLowerInvariant()) { [void]$selected.Add($runbook) }
        elseif ([string]::IsNullOrEmpty($state)) { [void]$skipped.Add([PSCustomObject]@{ Name = $name; Reason = 'no state returned' }) }
        else { [void]$skipped.Add([PSCustomObject]@{ Name = $name; Reason = ('state {0}, never published' -f $state) }) }
    }

    # Sort keys are the name, a NUL (below every name character, so "abc"
    # sorts before "abcd"), and the list position (so equal names survive
    # until the export refuses them). List[string].Sort runs on the list
    # itself; [Array]::Sort on a PowerShell array can sort a converted copy.
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $byKey = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $position = 0
    foreach ($runbook in $selected) {
        $key = '{0}{1}{2:D6}' -f [string]$runbook.name, [char]0, $position
        $position++
        $keys.Add($key)
        $byKey[$key] = $runbook
    }
    $keys.Sort([StringComparer]::Ordinal)
    $sorted = New-Object System.Collections.ArrayList
    foreach ($key in $keys) { [void]$sorted.Add($byKey[$key]) }

    return [PSCustomObject]@{ Selected = $sorted.ToArray(); Skipped = $skipped.ToArray() }
}

function Get-BackupRetentionPlan {
    <#
    .SYNOPSIS
        Decides which backups of one account to keep and which to delete.
    .DESCRIPTION
        Only names that ConvertFrom-BackupBlobName accepts take part; other
        names under AccountPrefix are returned as Ignored, and names outside
        it are only counted (OutsidePrefix). With PendingBlobName (the backup
        this run is about to write) the pending backup is included as if it
        existed and is never deleted. Entries are sorted newest first by name
        (ordinal, which is chronological for the stamp format). The first
        KeepAtLeast are kept; of the rest, a backup whose stamp is before
        Now minus RetentionDays is deleted, and the others are kept.
        NewestExisting ignores the pending backup and is the freshness
        answer.
    .PARAMETER BlobNames
        Names as listed.
    .PARAMETER AccountPrefix
        From Get-BackupAccountPrefix.
    .PARAMETER Now
        The clock.
    .PARAMETER RetentionDays
        Age limit in days, 1 or more.
    .PARAMETER KeepAtLeast
        Floor, 1 or more.
    .PARAMETER PendingBlobName
        Optional name of the backup being written.
    .EXAMPLE
        $plan = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix 'automation/aa-identity-prod/' -Now $now -RetentionDays 30 -KeepAtLeast 7
        $plan.Delete | ForEach-Object { $_.Name }
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$BlobNames = @(),
        [Parameter(Mandatory = $true)][string]$AccountPrefix,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][ValidateRange(1, 100000)][int]$RetentionDays,
        [Parameter(Mandatory = $true)][ValidateRange(1, 100000)][int]$KeepAtLeast,
        [AllowEmptyString()][string]$PendingBlobName = ''
    )

    $nowUtc = ConvertTo-BackupUtc -Value $Now
    $cutoff = $nowUtc.AddDays(-$RetentionDays)
    $stamps = New-Object 'System.Collections.Generic.Dictionary[string,DateTime]' ([StringComparer]::Ordinal)
    $ignored = New-Object System.Collections.ArrayList
    $outside = 0
    foreach ($name in @($BlobNames)) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        if (-not $name.StartsWith($AccountPrefix, [StringComparison]::Ordinal)) { $outside++; continue }
        $stamp = ConvertFrom-BackupBlobName -BlobName $name -AccountPrefix $AccountPrefix
        if ($null -eq $stamp) { [void]$ignored.Add($name); continue }
        if (-not $stamps.ContainsKey($name)) { $stamps[$name] = $stamp }
    }

    $existing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $stamps.Keys) { $existing.Add($key) }
    $existing.Sort([StringComparer]::Ordinal)
    $existing.Reverse()
    $newestExisting = ''
    $newestExistingUtc = $null
    if ($existing.Count -gt 0) {
        $newestExisting = $existing[0]
        $newestExistingUtc = $stamps[$newestExisting]
    }

    $pendingKnown = $false
    if (-not [string]::IsNullOrEmpty($PendingBlobName)) {
        $pendingStamp = ConvertFrom-BackupBlobName -BlobName $PendingBlobName -AccountPrefix $AccountPrefix
        if ($null -eq $pendingStamp) { throw ('Pending backup name "{0}" is not a backup name under {1}.' -f $PendingBlobName, $AccountPrefix) }
        if ($stamps.ContainsKey($PendingBlobName)) { $pendingKnown = $true }
        else { $stamps[$PendingBlobName] = $pendingStamp }
    }

    $ordered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $stamps.Keys) { $ordered.Add($key) }
    $ordered.Sort([StringComparer]::Ordinal)
    $ordered.Reverse()

    $entries = New-Object System.Collections.ArrayList
    $keep = New-Object System.Collections.ArrayList
    $delete = New-Object System.Collections.ArrayList
    $position = 0
    foreach ($name in $ordered) {
        $stamp = $stamps[$name]
        $ageDays = [Math]::Round(($nowUtc - $stamp).TotalDays, 2)
        $isPending = ($name -ceq $PendingBlobName)
        $decision = 'Keep'
        $reason = ''
        if ($isPending) { $reason = 'the backup this run writes' }
        elseif ($position -lt $KeepAtLeast) { $reason = ('one of the newest {0}' -f $KeepAtLeast) }
        elseif ($stamp -lt $cutoff) { $decision = 'Delete'; $reason = ('older than {0} day(s)' -f $RetentionDays) }
        else { $reason = ('within {0} day(s)' -f $RetentionDays) }
        $position++

        $entry = [PSCustomObject]@{
            Name      = $name
            StampUtc  = $stamp
            AgeDays   = $ageDays
            Pending   = $isPending
            Decision  = $decision
            Reason    = $reason
        }
        [void]$entries.Add($entry)
        if ($decision -eq 'Delete') { [void]$delete.Add($entry) } else { [void]$keep.Add($entry) }
    }

    return [PSCustomObject]@{
        AccountPrefix      = $AccountPrefix
        Entries            = $entries.ToArray()
        Keep               = $keep.ToArray()
        Delete             = $delete.ToArray()
        Ignored            = $ignored.ToArray()
        OutsidePrefix      = $outside
        ExistingNewestFirst = $existing.ToArray()
        NewestExisting     = $newestExisting
        NewestExistingUtc  = $newestExistingUtc
        PendingExists      = $pendingKnown
    }
}

function Test-BackupShrink {
    <#
    .SYNOPSIS
        The shrink guard: did the runbook count drop by more than the limit?
    .DESCRIPTION
        Passed is $false when (Previous - Current) / Previous exceeds
        MaxShrinkPercent. Exactly at the limit passes. Growth, no change, and
        a previous count of zero pass. Integer arithmetic, so no rounding
        decides the boundary.
    .PARAMETER PreviousCount
        Runbook count in the newest existing backup.
    .PARAMETER CurrentCount
        Runbook count exported now.
    .PARAMETER MaxShrinkPercent
        0 to 100.
    .EXAMPLE
        (Test-BackupShrink -PreviousCount 20 -CurrentCount 15 -MaxShrinkPercent 25).Passed
        True
    #>
    param(
        [Parameter(Mandatory = $true)][int]$PreviousCount,
        [Parameter(Mandatory = $true)][int]$CurrentCount,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$MaxShrinkPercent
    )

    $drop = $PreviousCount - $CurrentCount
    if ($PreviousCount -le 0 -or $drop -le 0) {
        return [PSCustomObject]@{ Passed = $true; PreviousCount = $PreviousCount; CurrentCount = $CurrentCount; DropPercent = 0; Reason = 'no drop' }
    }
    $percent = [Math]::Round(100.0 * $drop / $PreviousCount, 1)
    $passed = -not (([long]$drop * 100) -gt ([long]$MaxShrinkPercent * $PreviousCount))
    $reason = ('{0} runbook(s) now, {1} in the newest backup: a drop of {2}%, limit {3}%' -f $CurrentCount, $PreviousCount, $percent, $MaxShrinkPercent)
    return [PSCustomObject]@{ Passed = $passed; PreviousCount = $PreviousCount; CurrentCount = $CurrentCount; DropPercent = $percent; Reason = $reason }
}

function Compare-BackupManifest {
    <#
    .SYNOPSIS
        Differences between a manifest and the files found in a package.
    .DESCRIPTION
        Returns one problem string per difference: a manifest.json whose
        SHA-256 is not the expected one, a runbook file that is missing or has
        another length or hash, a file that the manifest does not list, or a
        runbookCount that does not match the list. No output means the
        package matches.
    .PARAMETER Manifest
        Parsed manifest (runbookCount, runbooks[].path, byteLength, sha256).
    .PARAMETER ActualFiles
        Hashtable keyed by relative path, values with Sha256 and Length.
    .PARAMETER ExpectedManifestSha256
        SHA-256 of the manifest file this run wrote.
    .EXAMPLE
        $problems = @(Compare-BackupManifest -Manifest $m -ActualFiles $files -ExpectedManifestSha256 $sha)
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ActualFiles,
        [Parameter(Mandatory = $true)][string]$ExpectedManifestSha256
    )

    $problems = New-Object System.Collections.ArrayList
    $manifestName = $script:BackupManifestName
    if (-not $ActualFiles.Contains($manifestName)) {
        [void]$problems.Add('manifest.json is missing from the package')
    }
    elseif (-not ([string]$ActualFiles[$manifestName].Sha256).Equals($ExpectedManifestSha256, [StringComparison]::OrdinalIgnoreCase)) {
        [void]$problems.Add('manifest.json in the package is not the manifest this run wrote')
    }

    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entries = @()
    if ($Manifest.PSObject.Properties['runbooks'] -and $null -ne $Manifest.runbooks) { $entries = @($Manifest.runbooks) }
    $declared = -1
    if ($Manifest.PSObject.Properties['runbookCount']) { $declared = [int]$Manifest.runbookCount }
    if ($declared -ne $entries.Count) {
        [void]$problems.Add(('manifest declares {0} runbook(s) but lists {1}' -f $declared, $entries.Count))
    }

    foreach ($entry in $entries) {
        $path = [string]$entry.path
        [void]$listed.Add($path)
        if (-not $ActualFiles.Contains($path)) {
            [void]$problems.Add(('{0} is listed in the manifest but missing from the package' -f $path))
            continue
        }
        $actual = $ActualFiles[$path]
        if ([long]$actual.Length -ne [long]$entry.byteLength) {
            [void]$problems.Add(('{0} is {1} byte(s), manifest says {2}' -f $path, $actual.Length, $entry.byteLength))
        }
        if (-not ([string]$actual.Sha256).Equals([string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$problems.Add(('{0} has SHA-256 {1}, manifest says {2}' -f $path, $actual.Sha256, $entry.sha256))
        }
    }

    foreach ($key in $ActualFiles.Keys) {
        $name = [string]$key
        if ($name -ceq $manifestName) { continue }
        if (-not $listed.Contains($name)) { [void]$problems.Add(('{0} is in the package but not in the manifest' -f $name)) }
    }
    return $problems.ToArray()
}

function Get-BackupRunFailureMessage {
    <#
    .SYNOPSIS
        The message the entry point throws after emitting the summary, or ''
        when the run recorded no failure.
    .PARAMETER Summary
        The object from Complete-RunSummary.
    .EXAMPLE
        $message = Get-BackupRunFailureMessage -Summary $result
    #>
    param([Parameter(Mandatory = $true)][object]$Summary)

    $count = 0
    if ($Summary.PSObject.Properties['FailureCount']) { $count = [int]$Summary.FailureCount }
    if ($count -le 0) { return '' }
    $targets = @()
    if ($Summary.PSObject.Properties['Failures']) {
        $targets = @(@($Summary.Failures) | ForEach-Object { '{0} {1}' -f $_.Action, $_.Target } | Select-Object -First 10)
    }
    return ('{0} recorded {1} failure(s): {2}. The summary above and the error stream of run {3} have the details.' -f $script:BackupRunbookName, $count, ($targets -join '; '), $Summary.RunId)
}

# ---------------------------------------------------------------------------
# Files, hashes, and the package. System.IO.Compression only, so the same
# code runs on Windows PowerShell 5.1 and PowerShell 7.
# ---------------------------------------------------------------------------

function Initialize-BackupZipSupport {
    <#
    .SYNOPSIS
        Loads System.IO.Compression when the session does not have it.
    .EXAMPLE
        Initialize-BackupZipSupport
    #>
    if ($null -eq ('System.IO.Compression.ZipArchive' -as [type])) {
        Add-Type -AssemblyName 'System.IO.Compression'
    }
}

function ConvertTo-BackupHex {
    <#
    .SYNOPSIS
        Lower-case hexadecimal text of a byte array.
    .PARAMETER Bytes
        The bytes.
    .EXAMPLE
        ConvertTo-BackupHex -Bytes $hash
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-BackupSha256 {
    <#
    .SYNOPSIS
        SHA-256 of a byte array or a file, as lower-case hex.
    .DESCRIPTION
        Uses the CryptoServiceProvider implementation first, which stays
        available when a Windows FIPS policy blocks the managed one.
    .PARAMETER Bytes
        Bytes to hash.
    .PARAMETER Path
        File to hash instead.
    .EXAMPLE
        Get-BackupSha256 -Path .\manifest.json
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][byte[]]$Bytes = $null,
        [AllowEmptyString()][string]$Path = ''
    )

    $algorithm = $null
    try { $algorithm = New-Object -TypeName System.Security.Cryptography.SHA256CryptoServiceProvider }
    catch { $algorithm = [System.Security.Cryptography.SHA256]::Create() }
    try {
        if (-not [string]::IsNullOrEmpty($Path)) {
            $stream = [System.IO.File]::OpenRead($Path)
            try { return (ConvertTo-BackupHex -Bytes $algorithm.ComputeHash($stream)) }
            finally { $stream.Dispose() }
        }
        if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }
        return (ConvertTo-BackupHex -Bytes $algorithm.ComputeHash($Bytes))
    }
    finally { $algorithm.Dispose() }
}

function Get-BackupContentMd5 {
    <#
    .SYNOPSIS
        Base64 MD5 of a file for the Content-MD5 header, or '' when MD5 is
        not available (a FIPS policy).
    .DESCRIPTION
        MD5 is only a transport check that the storage service performs; the
        restore verification uses SHA-256 and does not depend on it.
    .PARAMETER Path
        The file.
    .EXAMPLE
        Get-BackupContentMd5 -Path .\20260917-023000Z.zip
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = $null
    try { $algorithm = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider }
    catch { return '' }
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return [Convert]::ToBase64String($algorithm.ComputeHash($stream)) }
        finally { $stream.Dispose() }
    }
    catch { return '' }
    finally { $algorithm.Dispose() }
}

function Write-BackupFile {
    <#
    .SYNOPSIS
        Writes bytes to a path under Root, creating folders, refusing a path
        that leaves Root.
    .PARAMETER Root
        Folder the file must stay inside.
    .PARAMETER RelativePath
        Path with "/" separators.
    .PARAMETER Bytes
        Content.
    .EXAMPLE
        Write-BackupFile -Root $folder -RelativePath 'runbooks/Invoke-Thing.ps1' -Bytes $bytes
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $target = [System.IO.Path]::GetFullPath((Join-Path -Path $rootFull -ChildPath ($RelativePath.Replace('/', [string][System.IO.Path]::DirectorySeparatorChar))))
    if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing to write "{0}": it resolves outside the work folder.' -f $RelativePath)
    }
    $directory = [System.IO.Path]::GetDirectoryName($target)
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    [System.IO.File]::WriteAllBytes($target, $Bytes)
    return $target
}

function New-BackupPackage {
    <#
    .SYNOPSIS
        Creates the zip from files under SourceFolder.
    .DESCRIPTION
        Entry names are the relative paths with "/" separators, so the
        package opens the same way on any platform. The target must not
        exist.
    .PARAMETER SourceFolder
        Export folder.
    .PARAMETER RelativePaths
        Files to add, manifest.json included.
    .PARAMETER ZipPath
        Package to create.
    .EXAMPLE
        New-BackupPackage -SourceFolder $export -RelativePaths @('manifest.json', 'runbooks/a.ps1') -ZipPath $zip
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceFolder,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )

    Initialize-BackupZipSupport
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ZipPath))
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $stream = $null
    $archive = $null
    try {
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @($ZipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($relative in $RelativePaths) {
            if ($relative -cnotmatch $script:BackupEntryPattern) { throw ('"{0}" is not a valid package entry name.' -f $relative) }
            $full = Join-Path -Path $SourceFolder -ChildPath ($relative.Replace('/', [string][System.IO.Path]::DirectorySeparatorChar))
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try { $entryStream.Write($bytes, 0, $bytes.Length) }
            finally { $entryStream.Dispose() }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-BackupZipEntryBytes {
    <#
    .SYNOPSIS
        The bytes of one zip entry, refusing more than MaxBytes.
    .PARAMETER Entry
        A ZipArchiveEntry.
    .PARAMETER MaxBytes
        Upper bound, so a hostile package cannot fill the worker's disk or
        memory.
    .EXAMPLE
        Read-BackupZipEntryBytes -Entry $entry -MaxBytes 1048576
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][long]$MaxBytes
    )

    if ([long]$Entry.Length -gt $MaxBytes) { throw ('Package entry {0} is {1} byte(s), over the {2} byte limit.' -f $Entry.FullName, $Entry.Length, $MaxBytes) }
    $source = $Entry.Open()
    $buffer = New-Object -TypeName System.IO.MemoryStream
    try {
        $chunk = New-Object byte[] 65536
        $total = [long]0
        while ($true) {
            $read = $source.Read($chunk, 0, $chunk.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $MaxBytes) { throw ('Package entry {0} expands past the {1} byte limit.' -f $Entry.FullName, $MaxBytes) }
            $buffer.Write($chunk, 0, $read)
        }
        return , $buffer.ToArray()
    }
    finally {
        $source.Dispose()
        $buffer.Dispose()
    }
}

function Expand-BackupPackage {
    <#
    .SYNOPSIS
        Extracts a package to Destination and returns the SHA-256 and length
        of every extracted file, keyed by entry name.
    .DESCRIPTION
        Only entry names of the backup format are accepted (manifest.json and
        runbooks/<name>.<ext>), which also rules out path traversal. A
        duplicate entry, an unexpected entry, or an oversized entry throws.
        Hashes are computed from the files on disk after extraction.
    .PARAMETER ZipPath
        Package.
    .PARAMETER Destination
        Empty folder to extract into.
    .EXAMPLE
        $files = Expand-BackupPackage -ZipPath $zip -Destination $verifyFolder
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Initialize-BackupZipSupport
    if (-not [System.IO.Directory]::Exists($Destination)) { [void][System.IO.Directory]::CreateDirectory($Destination) }
    $written = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = $null
    $archive = $null
    try {
        $stream = [System.IO.File]::OpenRead($ZipPath)
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        foreach ($entry in @($archive.Entries)) {
            $name = [string]$entry.FullName
            if ($name -cnotmatch $script:BackupEntryPattern) { throw ('Package holds an unexpected entry "{0}".' -f $name) }
            if (-not $seen.Add($name)) { throw ('Package holds entry "{0}" more than once.' -f $name) }
            $bytes = Read-BackupZipEntryBytes -Entry $entry -MaxBytes $script:BackupMaxEntryBytes
            $path = Write-BackupFile -Root $Destination -RelativePath $name -Bytes $bytes
            [void]$written.Add(@{ Name = $name; Path = $path })
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $files = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($item in $written) {
        $info = New-Object -TypeName System.IO.FileInfo -ArgumentList $item.Path
        $files[$item.Name] = [PSCustomObject]@{ Sha256 = (Get-BackupSha256 -Path $item.Path); Length = [long]$info.Length }
    }
    return $files
}

function Read-BackupPackageManifest {
    <#
    .SYNOPSIS
        The parsed manifest.json of a package, read without extracting the
        rest.
    .DESCRIPTION
        Throws when the file is not a zip, has no manifest.json, or the
        manifest has no runbookCount or a runbooks list of another length.
    .PARAMETER ZipPath
        Package.
    .EXAMPLE
        (Read-BackupPackageManifest -ZipPath $previous).runbookCount
    #>
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Initialize-BackupZipSupport
    $stream = $null
    $archive = $null
    $bytes = $null
    try {
        $stream = [System.IO.File]::OpenRead($ZipPath)
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        $entry = $archive.GetEntry($script:BackupManifestName)
        if ($null -eq $entry) { throw 'the package has no manifest.json' }
        $bytes = Read-BackupZipEntryBytes -Entry $entry -MaxBytes $script:BackupMaxManifestBytes
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $text = (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false).GetString($bytes).TrimStart([char]0xFEFF)
    $manifest = $null
    try { $manifest = ConvertFrom-Json -InputObject $text }
    catch { throw 'manifest.json is not valid JSON' }
    if ($null -eq $manifest -or -not $manifest.PSObject.Properties['runbookCount']) { throw 'manifest.json has no runbookCount' }
    $count = 0
    if (-not [int]::TryParse([string]$manifest.runbookCount, [ref]$count)) { throw 'manifest.json runbookCount is not a number' }
    $listed = 0
    if ($manifest.PSObject.Properties['runbooks'] -and $null -ne $manifest.runbooks) { $listed = @($manifest.runbooks).Count }
    if ($listed -ne $count) { throw ('manifest.json declares {0} runbook(s) but lists {1}' -f $count, $listed) }
    return $manifest
}

function Test-BackupPackage {
    <#
    .SYNOPSIS
        Extracts a package and checks it against the manifest this run wrote.
    .DESCRIPTION
        Returns Verified, Problems, and FileCount. An extraction error is a
        problem, not an exception, so the caller decides what fails.
    .PARAMETER ZipPath
        Package to check.
    .PARAMETER Manifest
        Parsed manifest this run wrote.
    .PARAMETER ManifestSha256
        SHA-256 of that manifest file.
    .PARAMETER Destination
        Empty folder to extract into.
    .EXAMPLE
        $check = Test-BackupPackage -ZipPath $downloaded -Manifest $manifest -ManifestSha256 $sha -Destination $folder
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $problems = New-Object System.Collections.ArrayList
    $count = 0
    try {
        $files = Expand-BackupPackage -ZipPath $ZipPath -Destination $Destination
        $count = $files.Count
        foreach ($problem in @(Compare-BackupManifest -Manifest $Manifest -ActualFiles $files -ExpectedManifestSha256 $ManifestSha256)) {
            [void]$problems.Add([string]$problem)
        }
    }
    catch {
        [void]$problems.Add(('the package could not be extracted: {0}' -f (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300)))
    }
    return [PSCustomObject]@{ Verified = ($problems.Count -eq 0); Problems = $problems.ToArray(); FileCount = $count }
}

function New-BackupWorkFolder {
    <#
    .SYNOPSIS
        Creates this run's private temporary folder and returns its full
        path.
    .DESCRIPTION
        A relative WorkRoot is resolved against the PowerShell location, and
        the result is a full file system path, because the library's
        download (Invoke-StorageRequest -Operation GetBlobToFile) accepts
        only a rooted target.
    .PARAMETER WorkRoot
        Parent folder; the system temporary folder when empty.
    .EXAMPLE
        $folder = New-BackupWorkFolder -WorkRoot ''
    #>
    param([AllowEmptyString()][string]$WorkRoot = '')

    $root = $WorkRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    else { $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($root) }
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($root), ('runbook-backup-' + [Guid]::NewGuid().ToString('N')))
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-BackupWorkFolder {
    <#
    .SYNOPSIS
        Deletes this run's temporary folder; a failure is logged, not thrown,
        so it never hides the error that is already on its way out.
    .PARAMETER Path
        Folder from New-BackupWorkFolder.
    .EXAMPLE
        Remove-BackupWorkFolder -Path $folder
    #>
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $true) }
        Write-RunLog -Level Info -Message 'Removed the temporary work folder.'
    }
    catch {
        Write-RunLog -Level Warn -Message ('Could not remove the temporary work folder {0}: {1}' -f $Path, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
    }
}

# ---------------------------------------------------------------------------
# Azure Resource Manager: runbook list and content.
# ---------------------------------------------------------------------------

function Get-BackupRunbookContent {
    <#
    .SYNOPSIS
        The published source of one runbook, exactly as the service returns
        it.
    .DESCRIPTION
        GET <account>/runbooks/{name}/content through the library's
        Invoke-RunbookHttp (retries, scrubbed errors), not Invoke-CloudRequest,
        which would parse a body that looks like JSON (a graphical runbook).
        The body is decoded with ConvertFrom-RunbookContentResponse. Returns
        Text (the source) and ContentType (the response header, '' when the
        service sent none).
    .PARAMETER AccountId
        ARM id of the Automation account.
    .PARAMETER RunbookName
        Runbook name.
    .PARAMETER RunbookType
        properties.runbookType, which decides how a JSON body is decoded.
    .PARAMETER ApiVersion
        Automation api-version. Default 2024-10-23.
    .EXAMPLE
        (Get-BackupRunbookContent -AccountId $accountId -RunbookName 'Invoke-GuestLifecycle' -RunbookType 'PowerShell72').Text
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$RunbookName,
        [AllowEmptyString()][string]$RunbookType = '',
        [ValidateNotNullOrEmpty()][string]$ApiVersion = $script:BackupAutomationApiVersion
    )

    $relative = '{0}/runbooks/{1}/content' -f $AccountId.TrimStart('/'), [Uri]::EscapeDataString($RunbookName)
    $uri = Resolve-CloudRequestUri -Api Arm -Uri $relative -ApiVersion $ApiVersion -Environment (Get-RunContext).Environment
    $token = Get-RunbookAccessToken -Resource Arm
    $headers = @{ Authorization = 'Bearer ' + $token; Accept = 'text/plain, text/powershell, application/json' }
    $response = Invoke-RunbookHttp -Api 'Arm' -Method GET -Uri $uri -Headers $headers
    $contentType = ''
    if ($null -ne $response.Headers -and $response.Headers.ContainsKey('Content-Type')) { $contentType = [string]$response.Headers['Content-Type'] }
    $text = ConvertFrom-RunbookContentResponse -Content ([string]$response.Content) -ContentType $contentType -RunbookType $RunbookType
    return [PSCustomObject]@{ Text = [string]$text; ContentType = $contentType }
}

function Get-BackupApiVersionHint {
    <#
    .SYNOPSIS
        A sentence telling the operator to change AutomationApiVersion when
        an error says the api-version is not available, else ''.
    .PARAMETER ErrorRecord
        The error from an Automation call.
    .PARAMETER ApiVersion
        The api-version that was sent.
    .EXAMPLE
        $hint = Get-BackupApiVersionHint -ErrorRecord $_ -ApiVersion '2024-10-23'
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )

    if ((Get-CloudErrorStatus -ErrorRecord $ErrorRecord) -ne 400) { return '' }
    $text = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $text = [string]$ErrorRecord.Exception.Message }
    elseif ($ErrorRecord -is [Exception]) { $text = [string]$ErrorRecord.Message }
    if ($text -notmatch 'InvalidApiVersionParameter|NoRegisteredProviderFound|InvalidResourceType') { return '' }
    return (' api-version {0} is not available for Microsoft.Automation here; set AutomationApiVersion (for example 2023-11-01) in the job schedule parameters.' -f $ApiVersion)
}

function Export-BackupRunbookSources {
    <#
    .SYNOPSIS
        Writes every published runbook of one account to Destination and
        returns the manifest entries.
    .DESCRIPTION
        Lists the runbooks (all pages), keeps the ones with a published
        version, downloads each source, and writes it under runbooks/ as
        UTF-8 without a byte order mark. A runbook name outside the documented
        pattern, or two names that differ only by case, fail the export rather
        than produce a file with a surprising name. Returns Entries (ordered
        dictionaries for manifest.json, including the Content-Type of each
        read), Listed, and Skipped.
    .PARAMETER AccountId
        ARM id of the Automation account.
    .PARAMETER AccountName
        Name, for log lines.
    .PARAMETER Destination
        Export folder.
    .PARAMETER ApiVersion
        Automation api-version. Default 2024-10-23.
    .EXAMPLE
        $export = Export-BackupRunbookSources -AccountId $accountId -AccountName 'aa-identity-prod' -Destination $folder
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$AccountName,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateNotNullOrEmpty()][string]$ApiVersion = $script:BackupAutomationApiVersion
    )

    $listed = @()
    try {
        $listed = @(Invoke-CloudRequest -Api Arm -Uri ('{0}/runbooks' -f $AccountId.TrimStart('/')) -ApiVersion $ApiVersion -AllPages)
    }
    catch {
        $hint = Get-BackupApiVersionHint -ErrorRecord $_ -ApiVersion $ApiVersion
        if ([string]::IsNullOrEmpty($hint)) { throw }
        throw (New-Object -TypeName System.InvalidOperationException -ArgumentList @(($_.Exception.Message + $hint), $_.Exception))
    }
    $selection = Select-BackupRunbooks -Runbooks $listed
    foreach ($skip in @($selection.Skipped)) {
        Write-RunLog -Level Info -Message ('{0}: not backing up runbook {1} ({2}).' -f $AccountName, $skip.Name, $skip.Reason)
    }

    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries = New-Object System.Collections.ArrayList
    foreach ($runbook in @($selection.Selected)) {
        $name = [string]$runbook.name
        if ($name -cnotmatch $script:BackupRunbookNamePattern) { throw ('Runbook name "{0}" in {1} is outside the documented pattern; refusing to write it to a file.' -f $name, $AccountName) }
        if (-not $names.Add($name)) { throw ('Runbook name "{0}" appears twice in {1} (names differ only by case).' -f $name, $AccountName) }

        $properties = $runbook.properties
        $type = ''
        if ($properties.PSObject.Properties['runbookType']) { $type = [string]$properties.runbookType }
        $runtimeEnvironment = ''
        if ($properties.PSObject.Properties['runtimeEnvironment'] -and $null -ne $properties.runtimeEnvironment) { $runtimeEnvironment = [string]$properties.runtimeEnvironment }
        $lastModified = ''
        if ($properties.PSObject.Properties['lastModifiedTime']) { $lastModified = ConvertTo-BackupIsoText -Value $properties.lastModifiedTime }
        $extension = Get-RunbookFileExtension -RunbookType $type
        if ($extension -eq '.txt') {
            Write-RunLog -Level Warn -Message ('{0}: runbook {1} has type "{2}", which this runbook does not know; saving it as .txt.' -f $AccountName, $name, $type)
        }

        $read = Get-BackupRunbookContent -AccountId $AccountId -RunbookName $name -RunbookType $type -ApiVersion $ApiVersion
        if (Test-RunbookContentLooksQuoted -Text $read.Text) {
            Write-RunLog -Level Warn -Message ('{0}: runbook {1} came back as "{2}" with a body that looks like a quoted JSON string; it is kept exactly as returned. Compare it with a portal export.' -f $AccountName, $name, $read.ContentType)
        }
        $bytes = $utf8.GetBytes($read.Text)
        $relative = '{0}/{1}{2}' -f $script:BackupSourceFolder, $name, $extension
        [void](Write-BackupFile -Root $Destination -RelativePath $relative -Bytes $bytes)

        [void]$entries.Add([ordered]@{
                name               = $name
                runbookType        = $type
                runtimeVersion     = (Get-RunbookRuntimeVersion -RunbookType $type -RuntimeEnvironment $runtimeEnvironment)
                runtimeEnvironment = $runtimeEnvironment
                state              = [string]$properties.state
                lastModifiedTime   = $lastModified
                contentType        = $read.ContentType
                path               = $relative
                byteLength         = [long]$bytes.Length
                sha256             = (Get-BackupSha256 -Bytes $bytes)
            })
    }

    return [PSCustomObject]@{ Entries = $entries.ToArray(); Listed = $listed.Count; Skipped = @($selection.Skipped).Count }
}

function Write-BackupManifest {
    <#
    .SYNOPSIS
        Writes manifest.json to the export folder and returns the parsed file
        and its SHA-256.
    .DESCRIPTION
        The manifest is read back from disk so the object compared later is
        exactly what is in the package, whichever PowerShell wrote it.
    .PARAMETER Destination
        Export folder.
    .PARAMETER Header
        Ordered dictionary of run and account facts.
    .PARAMETER Entries
        From Export-BackupRunbookSources.
    .EXAMPLE
        $written = Write-BackupManifest -Destination $folder -Header $header -Entries $export.Entries
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Header,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries
    )

    $document = [ordered]@{}
    foreach ($key in $Header.Keys) { $document[[string]$key] = $Header[$key] }
    $document['runbookCount'] = $Entries.Count
    $document['runbooks'] = @($Entries)
    $json = ConvertTo-Json -InputObject $document -Depth 6
    $bytes = (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false).GetBytes($json)
    $path = Write-BackupFile -Root $Destination -RelativePath $script:BackupManifestName -Bytes $bytes
    $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
    return [PSCustomObject]@{ Path = $path; Manifest = $manifest; Sha256 = (Get-BackupSha256 -Path $path) }
}

# ---------------------------------------------------------------------------
# Blob storage for the package. Every request goes through the library's
# Invoke-HttpCore: the listing, the downloads, and the deletes through
# Invoke-StorageRequest, the upload through Invoke-RunbookHttp.
# ---------------------------------------------------------------------------

function Get-BackupBlobUri {
    <#
    .SYNOPSIS
        https://<account>.<blob suffix>/<container>/<blob> for the run's cloud.
    .DESCRIPTION
        Used by the upload, the one blob request this runbook builds itself.
        The name and the built URI are checked with
        Assert-BackupBlobRequestUri before the URI is returned.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER BlobName
        Blob name.
    .EXAMPLE
        Get-BackupBlobUri -StorageAccountName 'stidentitybackups' -ContainerName 'runbook-backups' -BlobName $name
    #>
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$')][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName
    )

    $endpoints = Get-CloudEndpoints -Environment (Get-RunContext).Environment
    $uri = 'https://{0}.{1}/{2}/{3}' -f $StorageAccountName, $endpoints.BlobSuffix, $ContainerName, (ConvertTo-BlobPath -BlobName $BlobName)
    Assert-BackupBlobRequestUri -Uri $uri -ContainerName $ContainerName -BlobName $BlobName
    return $uri
}

function Remove-BackupBlob {
    <#
    .SYNOPSIS
        Deletes one backup blob. Returns $true when it was deleted and $false
        when it was already gone (HTTP 404).
    .DESCRIPTION
        Assert-BackupBlobName first, then the library's
        Invoke-StorageRequest -Operation DeleteBlob -AllowNotFound, which
        checks the name again and the built URI before the token is sent,
        and retries a 429 or a 5xx (DELETE is idempotent). Any status other
        than 2xx or 404 throws.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER BlobName
        Blob name.
    .EXAMPLE
        $removed = Remove-BackupBlob -StorageAccountName 'stidentitybackups' -ContainerName 'runbook-backups' -BlobName $name
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName
    )

    Assert-BackupBlobName -BlobName $BlobName
    $removed = Invoke-StorageRequest -Operation DeleteBlob -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $BlobName -AllowNotFound
    return [bool]$removed
}

function Send-BackupPackage {
    <#
    .SYNOPSIS
        Uploads the package as a block blob that must not already exist.
    .DESCRIPTION
        PUT with x-ms-blob-type BlockBlob, Content-Type application/zip,
        If-None-Match: * (never overwrite), Content-MD5 when available (the
        service rejects a damaged body with 400), and x-ms-meta values. The
        headers come from the library's New-StorageRequestHeaders and the
        bytes go through its Invoke-RunbookHttp. A 409 BlobAlreadyExists or
        a 412 is returned as AlreadyExisted rather than thrown: a PUT retried
        after a lost response meets its own blob, and the restore
        verification that follows decides whether the blob is this run's
        package.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER BlobName
        Blob name.
    .PARAMETER Path
        Package file.
    .PARAMETER ContentMd5
        Base64 MD5, or '' to omit the header.
    .PARAMETER Metadata
        Name and value pairs; names must be C# identifiers, values ASCII.
    .EXAMPLE
        Send-BackupPackage -StorageAccountName 'stidentitybackups' -ContainerName 'runbook-backups' -BlobName $name -Path $zip -ContentMd5 $md5
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$ContentMd5 = '',
        [System.Collections.IDictionary]$Metadata = @{}
    )

    $uri = Get-BackupBlobUri -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $BlobName
    foreach ($key in $Metadata.Keys) {
        $metaName = [string]$key
        $metaValue = [string]$Metadata[$key]
        if ($metaName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw ('Metadata name "{0}" is not a valid identifier.' -f $metaName) }
        if ($metaValue -notmatch '^[\x20-\x7E]*$') { throw ('Metadata value for "{0}" must be printable ASCII.' -f $metaName) }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $headers = New-StorageRequestHeaders -StorageVersion ([string]$script:RunbookApiVersions['Storage'])
    $headers['x-ms-blob-type'] = 'BlockBlob'
    $headers['If-None-Match'] = '*'
    if (-not [string]::IsNullOrEmpty($ContentMd5)) { $headers['Content-MD5'] = $ContentMd5 }
    foreach ($key in $Metadata.Keys) { $headers['x-ms-meta-' + [string]$key] = [string]$Metadata[$key] }

    $response = Invoke-RunbookHttp -Api 'Storage' -Method PUT -Uri $uri -Headers $headers -Body $bytes -ContentType 'application/zip' -AllowedStatus @(409, 412)
    $status = [int]$response.StatusCode
    if ($status -eq 409) {
        $detail = Get-ServiceErrorText -Content ([string]$response.Content)
        if ($detail.Code -ne 'BlobAlreadyExists') {
            throw (New-CloudRequestError -Api 'Storage' -Method 'PUT' -Uri $uri -StatusCode $status -Attempts 1 -Content ([string]$response.Content))
        }
    }
    $etag = ''
    $md5 = ''
    if ($null -ne $response.Headers) {
        if ($response.Headers.ContainsKey('ETag')) { $etag = [string]$response.Headers['ETag'] }
        if ($response.Headers.ContainsKey('Content-MD5')) { $md5 = [string]$response.Headers['Content-MD5'] }
    }
    return [PSCustomObject]@{ StatusCode = $status; AlreadyExisted = ($status -eq 409 -or $status -eq 412); ETag = $etag; ContentMd5 = $md5; Bytes = [long]$bytes.Length }
}

function Receive-BackupBlob {
    <#
    .SYNOPSIS
        Downloads a backup blob to a file.
    .DESCRIPTION
        Assert-BackupBlobName first, then the library's
        Invoke-StorageRequest -Operation GetBlobToFile, which streams the
        body to OutFile without decoding it, retries a 429, a 5xx, or a lost
        response, and leaves no file behind when it fails. Any status other
        than 2xx throws New-CloudRequestError, so Get-CloudErrorStatus reads
        a 404. A relative OutFile is resolved against the PowerShell
        location. Returns the library's result: Name, Path, Length,
        ContentMd5 (as the service reported it, or ''), ETag, LastModified,
        and StatusCode.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER BlobName
        Blob name.
    .PARAMETER OutFile
        Destination file; replaced. Its folder is created.
    .PARAMETER MaxAttempts
        Default 5.
    .EXAMPLE
        Receive-BackupBlob -StorageAccountName 'stidentitybackups' -ContainerName 'runbook-backups' -BlobName $name -OutFile $path
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5
    )

    Assert-BackupBlobName -BlobName $BlobName
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    return (Invoke-StorageRequest -Operation GetBlobToFile -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $BlobName -OutFile $target -MaxAttempts $MaxAttempts)
}

function Get-PreviousBackupManifest {
    <#
    .SYNOPSIS
        The manifest of the newest existing backup that can be read.
    .DESCRIPTION
        Tries the candidates newest first, at most Lookback of them. A
        download or manifest error is logged as a warning and the next older
        backup is tried. Returns Found, BlobName, Manifest, and Tried.
    .PARAMETER CandidateNames
        Existing backup names, newest first.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER WorkFolder
        Folder for the downloaded packages; each is removed after reading.
    .PARAMETER Lookback
        Default 3.
    .EXAMPLE
        $previous = Get-PreviousBackupManifest -CandidateNames $plan.ExistingNewestFirst -StorageAccountName $sa -ContainerName $c -WorkFolder $folder
    #>
    param(
        [AllowEmptyCollection()][string[]]$CandidateNames = @(),
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$WorkFolder,
        [ValidateRange(1, 100)][int]$Lookback = 3
    )

    $tried = 0
    foreach ($name in @($CandidateNames)) {
        if ($tried -ge $Lookback) { break }
        $tried++
        $file = Join-Path -Path $WorkFolder -ChildPath ('previous-{0}.zip' -f $tried)
        try {
            [void](Receive-BackupBlob -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $name -OutFile $file)
            $manifest = Read-BackupPackageManifest -ZipPath $file
            return [PSCustomObject]@{ Found = $true; BlobName = $name; Manifest = $manifest; Tried = $tried }
        }
        catch {
            Write-RunLog -Level Warn -Message ('Could not read the manifest of existing backup {0}: {1}' -f $name, (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300))
        }
        finally {
            try { if ([System.IO.File]::Exists($file)) { [System.IO.File]::Delete($file) } } catch { }
        }
    }
    return [PSCustomObject]@{ Found = $false; BlobName = ''; Manifest = $null; Tried = $tried }
}

# ---------------------------------------------------------------------------
# One account: prepare (read-only) and publish (writes).
# ---------------------------------------------------------------------------

function New-BackupAccountState {
    <#
    .SYNOPSIS
        The mutable record of one account's progress through the run.
    .PARAMETER AccountName
        Automation account name.
    .PARAMETER Prefix
        Prefix parameter.
    .PARAMETER Now
        Run clock.
    .PARAMETER Folder
        This account's work folder.
    .EXAMPLE
        $state = New-BackupAccountState -AccountName 'aa-identity-prod' -Prefix 'automation' -Now $now -Folder $folder
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AccountName,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][DateTime]$Now,
        [Parameter(Mandatory = $true)][string]$Folder
    )

    $accountPrefix = Get-BackupAccountPrefix -Prefix $Prefix -AccountName $AccountName
    return [PSCustomObject]@{
        AccountName     = $AccountName
        AccountPrefix   = $accountPrefix
        BackupBlob      = (New-BackupBlobName -AccountPrefix $accountPrefix -Timestamp $Now)
        Folder          = $Folder
        Status          = 'Pending'
        Detail          = ''
        Listed          = 0
        RunbookCount    = 0
        PreviousBackup  = ''
        PreviousCount   = $null
        DropPercent     = $null
        PackagePath     = ''
        PackageBytes    = [long]0
        PackageSha256   = ''
        PackageMd5      = ''
        Manifest        = $null
        ManifestSha256  = ''
        LocalVerified   = $false
        Uploaded        = $false
        RemoteVerified  = $false
        Plan            = $null
        NewestExisting  = ''
        NewestExistingUtc = $null
        RetentionHeld   = $false
        Deleted         = 0
        DeleteSkipped   = 0
        DeleteFailed    = 0
    }
}

function Invoke-BackupAccountPreparation {
    <#
    .SYNOPSIS
        Everything for one account that reads: existing backups, export,
        manifest, guards, package, local verify, retention plan.
    .DESCRIPTION
        Throws with the reason when a guard trips or a step fails; the caller
        records it and carries on with the next account. Writes nothing
        outside the work folder.
    .PARAMETER State
        From New-BackupAccountState.
    .PARAMETER ResourceGroupScope
        /subscriptions/<id>/resourceGroups/<name>.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER RetentionDays
        Retention age.
    .PARAMETER KeepAtLeast
        Retention floor.
    .PARAMETER MaxShrinkPercent
        Shrink guard limit.
    .PARAMETER AutomationApiVersion
        api-version for the Automation calls; recorded in the manifest.
    .PARAMETER Now
        Run clock.
    .EXAMPLE
        Invoke-BackupAccountPreparation -State $state -ResourceGroupScope $scope -StorageAccountName $sa -ContainerName $c -RetentionDays 30 -KeepAtLeast 7 -MaxShrinkPercent 25 -Now $now
    #>
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ResourceGroupScope,
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][int]$RetentionDays,
        [Parameter(Mandatory = $true)][int]$KeepAtLeast,
        [Parameter(Mandatory = $true)][int]$MaxShrinkPercent,
        [ValidateNotNullOrEmpty()][string]$AutomationApiVersion = $script:BackupAutomationApiVersion,
        [Parameter(Mandatory = $true)][DateTime]$Now
    )

    $account = [string]$State.AccountName
    $exportFolder = Join-Path -Path $State.Folder -ChildPath 'export'
    $packageFolder = Join-Path -Path $State.Folder -ChildPath 'package'
    [void][System.IO.Directory]::CreateDirectory($exportFolder)
    [void][System.IO.Directory]::CreateDirectory($packageFolder)

    # 1. Existing backups first, so freshness is known even if the export fails.
    $listedBlobs = @(Invoke-StorageRequest -Operation ListBlobs -StorageAccountName $StorageAccountName -ContainerName $ContainerName -Prefix $State.AccountPrefix)
    $names = @($listedBlobs | ForEach-Object { [string]$_.Name })
    $existing = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix $State.AccountPrefix -Now $Now -RetentionDays $RetentionDays -KeepAtLeast $KeepAtLeast
    $State.NewestExisting = $existing.NewestExisting
    $State.NewestExistingUtc = $existing.NewestExistingUtc
    if ($existing.OutsidePrefix -gt 0) {
        Write-RunLog -Level Warn -Message ('{0}: the listing returned {1} blob(s) outside {2}; they are ignored.' -f $account, $existing.OutsidePrefix, $State.AccountPrefix)
    }
    foreach ($ignored in @($existing.Ignored)) {
        Write-RunLog -Level Info -Message ('{0}: blob {1} is not a backup name; retention leaves it alone.' -f $account, $ignored)
    }
    Write-RunLog -Level Info -Message ('{0}: {1} existing backup(s) under {2}; newest {3}.' -f $account, @($existing.ExistingNewestFirst).Count, $State.AccountPrefix, $(if ($existing.NewestExisting) { $existing.NewestExisting } else { 'none' }))
    if (@($existing.ExistingNewestFirst) -ccontains $State.BackupBlob) {
        throw ('Backup blob {0} already exists; another run wrote a backup in the same second. Nothing was uploaded.' -f $State.BackupBlob)
    }

    # 2. Export.
    $accountId = '{0}/providers/Microsoft.Automation/automationAccounts/{1}' -f $ResourceGroupScope.TrimEnd('/'), $account
    $export = Export-BackupRunbookSources -AccountId $accountId -AccountName $account -Destination $exportFolder -ApiVersion $AutomationApiVersion
    $State.Listed = $export.Listed
    $State.RunbookCount = @($export.Entries).Count
    if ($State.RunbookCount -eq 0) {
        throw ('Empty export guard: {0} listed {1} runbook(s) and none has a published version. Nothing was uploaded and no backup was deleted. Check the account name and the identity''s Reader role on the account.' -f $account, $export.Listed)
    }
    Write-RunLog -Level Info -Message ('{0}: exported {1} published runbook(s) of {2} listed.' -f $account, $State.RunbookCount, $export.Listed)

    # 3. Manifest.
    $context = Get-RunContext
    $scopeParts = $ResourceGroupScope.Trim('/').Split('/')
    $header = [ordered]@{
        schemaVersion         = 1
        createdBy             = $script:BackupRunbookName
        runId                 = $context.RunId
        createdUtc            = (ConvertTo-BackupUtc -Value $Now).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        environment           = $context.Environment
        subscriptionId        = $scopeParts[1]
        resourceGroupName     = $scopeParts[3]
        automationAccountName = $account
        automationApiVersion  = $AutomationApiVersion
        blobName              = $State.BackupBlob
    }
    $written = Write-BackupManifest -Destination $exportFolder -Header $header -Entries @($export.Entries)
    $State.Manifest = $written.Manifest
    $State.ManifestSha256 = $written.Sha256

    # 4. Shrink guard against the newest readable existing backup.
    $candidates = @($existing.ExistingNewestFirst)
    if ($candidates.Count -gt 0) {
        $previous = Get-PreviousBackupManifest -CandidateNames $candidates -StorageAccountName $StorageAccountName -ContainerName $ContainerName -WorkFolder $packageFolder -Lookback $script:BackupManifestLookback
        if (-not $previous.Found) {
            throw ('Shrink guard: none of the newest {0} existing backup(s) under {1} has a readable manifest, so the runbook count cannot be compared. Nothing was uploaded. Inspect those blobs.' -f $previous.Tried, $State.AccountPrefix)
        }
        $previousCount = [int]$previous.Manifest.runbookCount
        $shrink = Test-BackupShrink -PreviousCount $previousCount -CurrentCount $State.RunbookCount -MaxShrinkPercent $MaxShrinkPercent
        $State.PreviousBackup = $previous.BlobName
        $State.PreviousCount = $previousCount
        $State.DropPercent = $shrink.DropPercent
        if (-not $shrink.Passed) {
            throw ('Shrink guard: {0}: {1} (compared with {2}). Nothing was uploaded and no backup was deleted. If runbooks were removed on purpose, run once with a higher MaxShrinkPercent.' -f $account, $shrink.Reason, $previous.BlobName)
        }
        Write-RunLog -Level Info -Message ('{0}: shrink guard passed ({1} now, {2} in {3}).' -f $account, $State.RunbookCount, $previousCount, $previous.BlobName)
    }
    else {
        Write-RunLog -Level Info -Message ('{0}: no existing backup; this is the first one, so there is no count to compare.' -f $account)
    }

    # 5. Package.
    $relativePaths = @($script:BackupManifestName) + @($export.Entries | ForEach-Object { [string]$_['path'] })
    $zipPath = Join-Path -Path $packageFolder -ChildPath ([System.IO.Path]::GetFileName($State.BackupBlob))
    New-BackupPackage -SourceFolder $exportFolder -RelativePaths $relativePaths -ZipPath $zipPath
    $State.PackagePath = $zipPath
    $State.PackageBytes = [long](New-Object -TypeName System.IO.FileInfo -ArgumentList $zipPath).Length
    $State.PackageSha256 = Get-BackupSha256 -Path $zipPath
    $State.PackageMd5 = Get-BackupContentMd5 -Path $zipPath

    # 6. Local verify: the package on disk restores to exactly the manifest.
    $local = Test-BackupPackage -ZipPath $zipPath -Manifest $State.Manifest -ManifestSha256 $State.ManifestSha256 -Destination (Join-Path -Path $State.Folder -ChildPath 'verify-local')
    if (-not $local.Verified) {
        throw ('Local verification of the package failed: {0}' -f (@($local.Problems) -join '; '))
    }
    $State.LocalVerified = $true
    Write-RunLog -Level Info -Message ('{0}: packaged {1} file(s), {2} byte(s), sha256 {3}; local restore verified.' -f $account, $local.FileCount, $State.PackageBytes, $State.PackageSha256)

    # 7. Retention plan, counting the backup this run is about to write.
    $State.Plan = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix $State.AccountPrefix -Now $Now -RetentionDays $RetentionDays -KeepAtLeast $KeepAtLeast -PendingBlobName $State.BackupBlob
    Write-RunLog -Level Info -Message ('{0}: retention plan keeps {1} and deletes {2} backup(s) (RetentionDays={3}, KeepAtLeast={4}).' -f $account, @($State.Plan.Keep).Count, @($State.Plan.Delete).Count, $RetentionDays, $KeepAtLeast)
}

function Set-BackupSummaryItemSkipped {
    <#
    .SYNOPSIS
        Turns the newest Done item for an action and target into Skipped.
    .DESCRIPTION
        Invoke-RunbookAction records Done whenever its script block returns,
        and a delete that met HTTP 404 returns normally. This moves that one
        item, and its count, from Done to Skipped with the reason, so the
        summary never counts a delete that did not happen. Returns $true when
        an item was changed; otherwise logs a warning and returns $false.
    .PARAMETER Summary
        The object from New-RunSummary.
    .PARAMETER Action
        Action name of the item.
    .PARAMETER Target
        Target of the item.
    .PARAMETER Detail
        Reason, for the item.
    .EXAMPLE
        Set-BackupSummaryItemSkipped -Summary $summary -Action 'DeleteBackup' -Target $name -Detail 'already gone'
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Target,
        [AllowEmptyString()][string]$Detail = ''
    )

    $items = $Summary.Items
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        $item = $items[$i]
        if ([string]$item.Action -ceq $Action -and [string]$item.Target -ceq $Target -and [string]$item.Outcome -eq 'Done') {
            $item.Outcome = 'Skipped'
            $item.Detail = Protect-RunbookText -Text $Detail -MaxLength 1000
            $row = $Summary.Counts[$Action]
            $row['Done'] = [int]$row['Done'] - 1
            $row['Skipped'] = [int]$row['Skipped'] + 1
            return $true
        }
    }
    Write-RunLog -Level Warn -Message ('No Done item for {0} {1} to mark as Skipped; the summary counts may include it as Done.' -f $Action, $Target)
    return $false
}

function Invoke-BackupAccountPublish {
    <#
    .SYNOPSIS
        Everything for one prepared account that writes: upload, restore
        verify, retention.
    .DESCRIPTION
        The upload and each delete go through Invoke-RunbookAction, so a dry
        run logs "Would" and records Planned. Live, the uploaded blob is
        downloaded, extracted, and checked against the manifest; retention
        runs only when that passes. With RetentionHoldReason (the delete cap
        tripped) no delete is attempted or planned: each is logged and
        recorded as Skipped with the reason. A delete that finds the blob
        already gone (HTTP 404) is recorded as Skipped, not Done. Sets
        State.Status to DryRun, BackedUp, Unverified, or Failed.
    .PARAMETER State
        A prepared state.
    .PARAMETER Summary
        Run summary.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ContainerName
        Container.
    .PARAMETER RetentionHoldReason
        Why retention must not run for this account in this run; '' to apply
        it.
    .EXAMPLE
        Invoke-BackupAccountPublish -State $state -Summary $summary -StorageAccountName $sa -ContainerName $c
    #>
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [AllowEmptyString()][string]$RetentionHoldReason = ''
    )

    $account = [string]$State.AccountName
    $blobName = [string]$State.BackupBlob
    $uploadState = @{ AlreadyExisted = $false }
    $metadata = [ordered]@{ runid = [string](Get-RunContext).RunId; runbookcount = [string]$State.RunbookCount; sha256 = [string]$State.PackageSha256 }
    $uploadText = 'upload {0} ({1} runbook(s), {2} byte(s)) to {3}/{4}' -f $blobName, $State.RunbookCount, $State.PackageBytes, $StorageAccountName, $ContainerName
    $outcome = Invoke-RunbookAction -Summary $Summary -Action 'UploadBackup' -Target $blobName -Description $uploadText -PassThru -ScriptBlock {
        $sent = Send-BackupPackage -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $blobName -Path $State.PackagePath -ContentMd5 $State.PackageMd5 -Metadata $metadata
        if ($sent.AlreadyExisted) { $uploadState.AlreadyExisted = $true }
    }

    if ($outcome -eq 'Failed') {
        $State.Status = 'Failed'
        $State.Detail = 'upload failed; retention skipped'
        Write-RunLog -Level Warn -Message ('{0}: retention skipped because the upload failed.' -f $account)
        return
    }

    if ($outcome -eq 'Done') {
        $State.Uploaded = $true
        if ($uploadState.AlreadyExisted) {
            Write-RunLog -Level Warn -Message ('{0}: {1} already existed when the upload ran (a retried request or a concurrent run); verifying what is stored.' -f $account, $blobName)
        }
        $problems = New-Object System.Collections.ArrayList
        try {
            $downloadPath = Join-Path -Path $State.Folder -ChildPath 'downloaded.zip'
            $downloaded = Receive-BackupBlob -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $blobName -OutFile $downloadPath
            $downloadedSha = Get-BackupSha256 -Path $downloaded.Path
            if ($downloadedSha -ne $State.PackageSha256) {
                [void]$problems.Add(('the stored blob has SHA-256 {0}, the package has {1}' -f $downloadedSha, $State.PackageSha256))
            }
            if (-not [string]::IsNullOrEmpty($downloaded.ContentMd5) -and -not [string]::IsNullOrEmpty($State.PackageMd5) -and $downloaded.ContentMd5 -ne $State.PackageMd5) {
                [void]$problems.Add('the Content-MD5 the service reports is not the package''s')
            }
            $remote = Test-BackupPackage -ZipPath $downloaded.Path -Manifest $State.Manifest -ManifestSha256 $State.ManifestSha256 -Destination (Join-Path -Path $State.Folder -ChildPath 'verify-remote')
            foreach ($problem in @($remote.Problems)) { [void]$problems.Add([string]$problem) }
        }
        catch {
            [void]$problems.Add(('the uploaded blob could not be downloaded: {0}' -f (Protect-RunbookText -Text $_.Exception.Message -MaxLength 300)))
        }

        if ($problems.Count -gt 0) {
            $detail = (@($problems) -join '; ')
            $State.Status = 'Unverified'
            $State.Detail = $detail
            Write-RunLog -Level Error -Message ('{0}: restore verification of {1} failed: {2}. The blob is kept for inspection; retention skipped.' -f $account, $blobName, $detail)
            Add-RunSummaryItem -Summary $Summary -Action 'VerifyBackup' -Target $blobName -Outcome Failed -Detail $detail
            return
        }
        $State.RemoteVerified = $true
        $State.Status = 'BackedUp'
        Write-RunLog -Level Info -Message ('Verified: {0} downloads and restores to the {1} runbook(s) in its manifest.' -f $blobName, $State.RunbookCount)
        Add-RunSummaryItem -Summary $Summary -Action 'VerifyBackup' -Target $blobName -Outcome Done -Detail ('sha256 ' + $State.PackageSha256)
    }
    else {
        $State.Status = 'DryRun'
    }

    $planned = @($State.Plan.Delete)
    if (-not [string]::IsNullOrEmpty($RetentionHoldReason)) {
        $State.RetentionHeld = $true
        if ($planned.Count -gt 0) {
            $State.Detail = ('retention held for {0} backup(s): {1}' -f $planned.Count, $RetentionHoldReason)
        }
        foreach ($entry in $planned) {
            $heldName = [string]$entry.Name
            Write-RunLog -Level Info -Message ('{0}: not deleting {1} ({2} day(s) old): {3}.' -f $account, $heldName, $entry.AgeDays, $RetentionHoldReason)
            Add-RunSummaryItem -Summary $Summary -Action 'DeleteBackup' -Target $heldName -Outcome Skipped -Detail $RetentionHoldReason
            $State.DeleteSkipped++
        }
        return
    }

    foreach ($entry in $planned) {
        $deleteName = [string]$entry.Name
        $deleteText = 'delete backup blob {0} (stamp {1}, {2} day(s) old, {3})' -f $deleteName, $entry.StampUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture), $entry.AgeDays, $entry.Reason
        $deleteState = @{ Removed = $false }
        $deleteOutcome = Invoke-RunbookAction -Summary $Summary -Action 'DeleteBackup' -Target $deleteName -Description $deleteText -PassThru -ScriptBlock {
            $deleteState.Removed = [bool](Remove-BackupBlob -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $deleteName)
        }
        if ($deleteOutcome -eq 'Done' -and -not $deleteState.Removed) {
            [void](Set-BackupSummaryItemSkipped -Summary $Summary -Action 'DeleteBackup' -Target $deleteName -Detail 'already gone (HTTP 404); nothing was deleted')
            Write-RunLog -Level Warn -Message ('{0}: {1} was already gone when the delete ran (HTTP 404); recorded as Skipped, not as a delete.' -f $account, $deleteName)
            $State.DeleteSkipped++
        }
        elseif ($deleteOutcome -eq 'Done') { $State.Deleted++ }
        elseif ($deleteOutcome -eq 'Failed') { $State.DeleteFailed++ }
    }
}

function ConvertTo-BackupReportRow {
    <#
    .SYNOPSIS
        One flat report row for an account, for the CSV and the summary.
    .PARAMETER State
        Account state after the run.
    .PARAMETER Now
        Run clock, for freshness.
    .EXAMPLE
        ConvertTo-BackupReportRow -State $state -Now $now
    #>
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][DateTime]$Now
    )

    $newest = [string]$State.NewestExisting
    $newestUtc = $State.NewestExistingUtc
    if ($State.RemoteVerified) {
        $newest = [string]$State.BackupBlob
        $newestUtc = ConvertFrom-BackupBlobName -BlobName $State.BackupBlob -AccountPrefix $State.AccountPrefix
    }
    $newestText = ''
    $ageHours = $null
    if ($null -ne $newestUtc) {
        $newestText = ([DateTime]$newestUtc).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $ageHours = [Math]::Round(((ConvertTo-BackupUtc -Value $Now) - [DateTime]$newestUtc).TotalHours, 1)
    }
    # Only a dry run or a verified backup gets as far as retention; for any
    # other status the plan was never acted on and is not reported. When the
    # delete cap held retention back, the list is what would have been
    # deleted (RetentionHeld says so).
    $deletes = @()
    if ($null -ne $State.Plan -and @('DryRun', 'BackedUp') -contains [string]$State.Status) {
        $deletes = @(@($State.Plan.Delete) | ForEach-Object { [string]$_.Name })
    }

    return [PSCustomObject]@{
        AutomationAccount = [string]$State.AccountName
        Status            = [string]$State.Status
        RunbooksListed    = [int]$State.Listed
        RunbooksExported  = [int]$State.RunbookCount
        PreviousBackup    = [string]$State.PreviousBackup
        PreviousCount     = $State.PreviousCount
        DropPercent       = $State.DropPercent
        BackupBlob        = [string]$State.BackupBlob
        PackageBytes      = [long]$State.PackageBytes
        PackageSha256     = [string]$State.PackageSha256
        LocalVerified     = [bool]$State.LocalVerified
        Uploaded          = [bool]$State.Uploaded
        RemoteVerified    = [bool]$State.RemoteVerified
        NewestBackup      = $newest
        NewestBackupUtc   = $newestText
        NewestAgeHours    = $ageHours
        DeletesPlanned    = $deletes.Count
        RetentionHeld     = [bool]$State.RetentionHeld
        Deleted           = [int]$State.Deleted
        DeleteSkipped     = [int]$State.DeleteSkipped
        DeleteFailed      = [int]$State.DeleteFailed
        DeleteBlobs       = ($deletes -join ';')
        Detail            = [string]$State.Detail
    }
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-BackupAutomationRunbooksRun {
    <#
    .SYNOPSIS
        The whole run; returns the summary object.
    .DESCRIPTION
        Phase 1 prepares every account (read-only; a failure aborts only that
        account). Phase 2 adds up the planned deletes and applies the delete
        cap before any write; a tripped cap records a DeleteCap failure and
        holds retention back for every account. Phase 3 uploads, verifies,
        and (unless held) prunes each prepared account. The work folder is
        removed in a finally block. The summary is returned in every case
        that reaches Phase 1; the entry point throws after emitting it when
        it holds a failure. The parameters are the script's, plus Now and
        WorkRoot for tests.
    .PARAMETER AutomationAccountNames
        Semicolon (or comma) separated list; a JSON array for local runs.
    .PARAMETER ResourceGroupName
        Resource group of the accounts.
    .PARAMETER SubscriptionName
        Subscription display name or id.
    .PARAMETER StorageAccountName
        Backup storage account.
    .PARAMETER ContainerName
        Backup container.
    .PARAMETER Prefix
        Virtual folder for backups.
    .PARAMETER RetentionDays
        Retention age.
    .PARAMETER KeepAtLeast
        Retention floor.
    .PARAMETER MaxDeletesPerRun
        Delete cap.
    .PARAMETER MaxShrinkPercent
        Shrink guard limit.
    .PARAMETER AutomationApiVersion
        api-version for the Automation calls; empty means 2024-10-23.
    .PARAMETER ReportPath
        Optional CSV path.
    .PARAMETER DryRun
        Default $true.
    .PARAMETER Environment
        Global or USGov.
    .PARAMETER ClientId
        Managed identity client id.
    .PARAMETER AccessToken
        Local runs only.
    .PARAMETER RunId
        Correlation id.
    .PARAMETER Now
        Clock, for tests. Default now (UTC).
    .PARAMETER WorkRoot
        Parent of the temporary folder. Default the system temporary folder.
    .EXAMPLE
        Invoke-BackupAutomationRunbooksRun -AutomationAccountNames 'aa-identity-prod' -ResourceGroupName 'rg-identity-automation' -SubscriptionName 'Identity Production' -StorageAccountName 'stidentitybackups' -AccessToken $tokens
    #>
    param(
        [AllowEmptyString()][string]$AutomationAccountNames = '',
        [AllowEmptyString()][string]$ResourceGroupName = '',
        [AllowEmptyString()][string]$SubscriptionName = '',
        [AllowEmptyString()][string]$StorageAccountName = '',
        [string]$ContainerName = 'runbook-backups',
        [string]$Prefix = 'automation',
        [int]$RetentionDays = 30,
        [int]$KeepAtLeast = 7,
        [int]$MaxDeletesPerRun = 20,
        [int]$MaxShrinkPercent = 25,
        [AllowEmptyString()][string]$AutomationApiVersion = '2024-10-23',
        [AllowEmptyString()][string]$ReportPath = '',
        [bool]$DryRun = $true,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [AllowEmptyString()][string]$ClientId = '',
        [AllowEmptyString()][string]$AccessToken = '',
        [AllowEmptyString()][string]$RunId = '',
        [DateTime]$Now = [DateTime]::UtcNow,
        [AllowEmptyString()][string]$WorkRoot = ''
    )

    Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $RunId -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -DryRun $DryRun
    $summary = New-RunSummary
    $nowUtc = ConvertTo-BackupUtc -Value $Now

    # Parameters. The script's param block validates the same things; this
    # function is also called directly by the tests.
    $requested = @(ConvertTo-StringList -Value $AutomationAccountNames -Label 'AutomationAccountNames')
    $accountNames = New-Object System.Collections.ArrayList
    $seenAccounts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $requested) {
        if ($candidate -notmatch $script:BackupAccountNamePattern) { throw ('AutomationAccountNames: "{0}" is not a valid Automation account name.' -f $candidate) }
        if ($seenAccounts.Add($candidate)) { [void]$accountNames.Add($candidate) }
    }
    if ($accountNames.Count -eq 0) { throw 'AutomationAccountNames is empty; name at least one Automation account.' }
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { throw 'ResourceGroupName is required.' }
    if ([string]::IsNullOrWhiteSpace($SubscriptionName)) { throw 'SubscriptionName is required.' }
    if ($StorageAccountName -notmatch '^[a-z0-9]{3,24}$') { throw ('StorageAccountName "{0}" is not a valid storage account name.' -f $StorageAccountName) }
    if ($ContainerName -notmatch '^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]$') { throw ('ContainerName "{0}" is not a valid container name.' -f $ContainerName) }
    $cleanPrefix = ConvertTo-BackupPrefix -Prefix $Prefix
    if ($RetentionDays -lt 1) { throw 'RetentionDays must be 1 or more.' }
    if ($KeepAtLeast -lt 1) { throw 'KeepAtLeast must be 1 or more; a backup job never deletes its newest backup.' }
    if ($MaxDeletesPerRun -lt 0) { throw 'MaxDeletesPerRun must be 0 or more.' }
    if ($MaxShrinkPercent -lt 0 -or $MaxShrinkPercent -gt 100) { throw 'MaxShrinkPercent must be between 0 and 100.' }
    $apiVersion = ''
    if ($null -ne $AutomationApiVersion) { $apiVersion = $AutomationApiVersion.Trim() }
    if ($apiVersion.Length -eq 0) { $apiVersion = $script:BackupAutomationApiVersion }
    if ($apiVersion -cnotmatch $script:BackupApiVersionPattern) { throw ('AutomationApiVersion "{0}" is not an api-version (yyyy-MM-dd, optionally -preview).' -f $AutomationApiVersion) }

    Write-RunLog -Level Info -Message ('Backing up {0} account(s) in {1} to {2}/{3}/{4}/. RetentionDays={5} KeepAtLeast={6} MaxDeletesPerRun={7} MaxShrinkPercent={8} AutomationApiVersion={9}' -f $accountNames.Count, $ResourceGroupName, $StorageAccountName, $ContainerName, $cleanPrefix, $RetentionDays, $KeepAtLeast, $MaxDeletesPerRun, $MaxShrinkPercent, $apiVersion)

    # The manifest and every Automation URI are built from this scope.
    # Resolve-ArmScope refuses a lookup entry without a GUID subscription id
    # and an invalid resource group name, so a bad scope stops the run here,
    # before any Automation or storage request.
    $subscriptionText = $SubscriptionName.Trim()
    if ($subscriptionText -match $script:RunbookGuidPattern) {
        $scope = Resolve-ArmScope -SubscriptionId $subscriptionText -ResourceGroupName $ResourceGroupName.Trim()
    }
    else {
        $scope = Resolve-ArmScope -SubscriptionName $subscriptionText -ResourceGroupName $ResourceGroupName.Trim()
    }
    Write-RunLog -Level Info -Message ('Resource group scope: {0}.' -f $scope)

    $states = New-Object System.Collections.ArrayList
    $runFolder = New-BackupWorkFolder -WorkRoot $WorkRoot
    try {
        # Phase 1: read-only preparation, one account at a time.
        $index = 0
        foreach ($name in $accountNames) {
            $index++
            $folder = Join-Path -Path $runFolder -ChildPath ('{0:D2}-{1}' -f $index, $name.ToLowerInvariant())
            [void][System.IO.Directory]::CreateDirectory($folder)
            $state = New-BackupAccountState -AccountName $name -Prefix $cleanPrefix -Now $nowUtc -Folder $folder
            [void]$states.Add($state)
            try {
                Invoke-BackupAccountPreparation -State $state -ResourceGroupScope $scope -StorageAccountName $StorageAccountName -ContainerName $ContainerName -RetentionDays $RetentionDays -KeepAtLeast $KeepAtLeast -MaxShrinkPercent $MaxShrinkPercent -AutomationApiVersion $apiVersion -Now $nowUtc
                $state.Status = 'Ready'
            }
            catch {
                $reason = Protect-RunbookText -Text $_.Exception.Message -MaxLength 600
                $state.Status = 'Failed'
                $state.Detail = $reason
                Write-RunLog -Level Error -Message ('{0}: backup aborted before any write: {1}' -f $name, $reason)
                Add-RunSummaryItem -Summary $summary -Action 'BackupAccount' -Target $name -Outcome Failed -Detail $reason
            }
        }

        # Phase 2: the delete cap, across accounts, before the first write. A
        # trip holds retention back everywhere and fails the run, but the
        # uploads still happen: a new, uniquely named blob cannot hurt.
        $ready = @($states | Where-Object { $_.Status -eq 'Ready' })
        $plannedDeletes = 0
        foreach ($state in $ready) { $plannedDeletes += @($state.Plan.Delete).Count }
        $holdReason = ''
        try {
            Test-CircuitBreaker -Planned $plannedDeletes -Cap $MaxDeletesPerRun -Label 'backup blob deletes'
        }
        catch {
            if (-not ([string]$_.Exception.Message).StartsWith('Circuit breaker tripped', [StringComparison]::Ordinal)) { throw }
            $capText = ('Delete cap tripped: {0} backup blob delete(s) planned across {1} account(s), MaxDeletesPerRun is {2}. No backup is deleted in this run; new backups are still uploaded and verified. Review BlobsToDelete, then raise MaxDeletesPerRun for one run or fix the cause.' -f $plannedDeletes, $ready.Count, $MaxDeletesPerRun)
            $holdReason = ('delete cap tripped ({0} planned, cap {1})' -f $plannedDeletes, $MaxDeletesPerRun)
            Write-RunLog -Level Error -Message $capText
            Add-RunSummaryItem -Summary $summary -Action 'DeleteCap' -Target ('{0} planned, cap {1}' -f $plannedDeletes, $MaxDeletesPerRun) -Outcome Failed -Detail $capText
        }

        # Phase 3: writes.
        foreach ($state in $ready) {
            Invoke-BackupAccountPublish -State $state -Summary $summary -StorageAccountName $StorageAccountName -ContainerName $ContainerName -RetentionHoldReason $holdReason
        }
    }
    finally {
        Remove-BackupWorkFolder -Path $runFolder
    }

    $rows = @($states | ForEach-Object { ConvertTo-BackupReportRow -State $_ -Now $nowUtc })
    foreach ($row in $rows) {
        if ($null -ne $row.NewestAgeHours) {
            Write-RunLog -Level Info -Message ('Freshness: {0} newest backup {1} is {2} hour(s) old.' -f $row.AutomationAccount, $row.NewestBackup, $row.NewestAgeHours)
        }
        else {
            Write-RunLog -Level Warn -Message ('Freshness: {0} has no backup that this run could see.' -f $row.AutomationAccount)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $directory = Split-Path -Path $ReportPath -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
        $rows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
        Write-RunLog -Level Info -Message ('Wrote report to {0}.' -f $ReportPath)
    }

    $deleteNames = @($rows | ForEach-Object { if ($_.DeleteBlobs) { $_.DeleteBlobs.Split(';') } } | Where-Object { $_ })
    $freshness = @($rows | ForEach-Object {
            [PSCustomObject]@{ AutomationAccount = $_.AutomationAccount; NewestBackup = $_.NewestBackup; NewestBackupUtc = $_.NewestBackupUtc; AgeHours = $_.NewestAgeHours }
        })
    $extra = [ordered]@{
        StorageAccount     = $StorageAccountName
        Container          = $ContainerName
        Prefix             = $cleanPrefix
        RetentionDays      = $RetentionDays
        KeepAtLeast        = $KeepAtLeast
        MaxDeletesPerRun   = $MaxDeletesPerRun
        DeleteCapTripped   = (-not [string]::IsNullOrEmpty($holdReason))
        AutomationApiVersion = $apiVersion
        AccountsRequested  = $accountNames.Count
        AccountsBackedUp   = @($rows | Where-Object { $_.Status -eq 'BackedUp' }).Count
        AccountsDryRun     = @($rows | Where-Object { $_.Status -eq 'DryRun' }).Count
        AccountsFailed     = @($rows | Where-Object { @('Failed', 'Unverified') -contains $_.Status }).Count
        RunbooksExported   = [int](($rows | Measure-Object -Property RunbooksExported -Sum).Sum)
        DeletesPlanned     = $deleteNames.Count
        BlobsToDelete      = $deleteNames
        Freshness          = $freshness
        Accounts           = $rows
        ReportPath         = $ReportPath
    }
    return (Complete-RunSummary -Summary $summary -Extra $extra)
}

# ---------------------------------------------------------------------------
# Entry point. Skipped when dot-sourced by the tests. A run with failures
# still emits its summary, then throws so the job ends Failed.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-BackupAutomationRunbooksRun -AutomationAccountNames $AutomationAccountNames -ResourceGroupName $ResourceGroupName `
        -SubscriptionName $SubscriptionName -StorageAccountName $StorageAccountName -ContainerName $ContainerName -Prefix $Prefix `
        -RetentionDays $RetentionDays -KeepAtLeast $KeepAtLeast -MaxDeletesPerRun $MaxDeletesPerRun -MaxShrinkPercent $MaxShrinkPercent `
        -AutomationApiVersion $AutomationApiVersion -ReportPath $ReportPath -DryRun ([bool]$DryRun) -Environment $Environment -ClientId $ClientId -AccessToken $AccessToken -RunId $RunId
    $result
    $failureMessage = Get-BackupRunFailureMessage -Summary $result
    if (-not [string]::IsNullOrEmpty($failureMessage)) { throw $failureMessage }
}
