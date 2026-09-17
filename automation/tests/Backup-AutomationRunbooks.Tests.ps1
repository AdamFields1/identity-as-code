# Pester tests for automation/runbooks/Backup-AutomationRunbooks.ps1.
#
# Pester 3/4 assertion syntax ("Should Be") because Windows PowerShell 5.1
# ships Pester 3.4.0. The runbook is dot-sourced, which dot-sources
# automation/lib/Runbook.Common.ps1 through its INLINE_LIBRARY block, so the
# functions load and the entry point does not run. Nothing leaves the machine:
# Invoke-HttpCore, the library's one Invoke-WebRequest call and so every ARM
# and storage request the runbook sends, is mocked with an in-memory
# Automation account and blob container shaped like the documented
# responses, and Start-Sleep is mocked so retries do not wait. Nothing else is
# mocked. The mock writes a download to the -OutFile it is given, as the real
# core does, refuses a storage PUT body that is not a byte array, and echoes
# the Authorization header in its error bodies so the token tests can fail.
# The clock is a parameter. Work folders live under $TestDrive, and every run
# test checks that the runbook removed its own. Run tests silence the error
# stream unless they capture it.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$automationRoot = Split-Path -Parent $here
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Backup-AutomationRunbooks.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$dotSourceArgs = @{
    AutomationAccountNames = 'aa-identity-prod'
    ResourceGroupName      = 'rg-identity-automation'
    SubscriptionName       = 'Identity Automation'
    StorageAccountName     = 'stbackupexample'
    AccessToken            = 'dot-source-token-0000'
}

Describe 'Backup-AutomationRunbooks' {
    . $runbook @dotSourceArgs
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    # Fake values only. The GUIDs are all-same-digit on purpose.
    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 2, 30, 0, ([DateTimeKind]::Utc)
    $runId = '00000000-0000-0000-0000-000000000000'
    $subscriptionId = '33333333-3333-3333-3333-333333333333'
    $armToken = 'eyJ0eXAiOiJKV1QifQ.armpayload00000000000.armsignature00000'
    $storageToken = 'eyJ0eXAiOiJKV1QifQ.storagepayload0000000.storagesig0000000'
    $tokens = ConvertTo-Json -InputObject @{ Arm = $armToken; Storage = $storageToken } -Compress
    $accountA = 'aa-identity-prod'
    $accountB = 'aa-identity-dev'
    $prefixA = 'automation/aa-identity-prod/'
    $prefixB = 'automation/aa-identity-dev/'
    $graphJson = '{"schemaVersion":"1.10","runbookDefinition":"AAAABBBB"}'
    $eAcute = [string][char]0x00E9
    $runArgs = @{
        AutomationAccountNames = $accountA
        ResourceGroupName      = 'rg-identity-automation'
        SubscriptionName       = 'Identity Automation'
        StorageAccountName     = 'stbackupexample'
        AccessToken            = $tokens
        RunId                  = $runId
        Now                    = $now
    }

    # Names that share the container but are not this account's backups.
    # Every one is old enough that sloppy retention would delete it.
    $foreignNames = @(
        'automation/aa-identity-prod-old/20250101-000000Z.zip',
        'automation-archive/aa-identity-prod/20250101-000000Z.zip',
        'automation/aa-identity-prod/manual/20250101-000000Z.zip',
        'automation/aa-identity-prod/README.txt',
        'automation/AA-Identity-Prod/20250101-000000Z.zip',
        'automation/aa-identity-prod/20250101-000000Z.zip.bak',
        'aa-identity-prod/20250101-000000Z.zip'
    )

    function New-TestRunbook {
        param([string]$Name, [string]$Type = 'PowerShell72', [string]$State = 'Published', [string]$RuntimeEnvironment = '')
        $properties = [ordered]@{
            creationTime     = '2026-01-05T10:00:00.00+00:00'
            lastModifiedTime = '2026-09-01T10:00:00.00+00:00'
            runbookType      = $Type
            state            = $State
            logVerbose       = $true
        }
        if ($RuntimeEnvironment) { $properties['runtimeEnvironment'] = $RuntimeEnvironment }
        return [PSCustomObject]@{
            name       = $Name
            type       = 'Microsoft.Automation/AutomationAccounts/Runbooks'
            id         = ('/subscriptions/{0}/resourceGroups/rg-identity-automation/providers/Microsoft.Automation/automationAccounts/x/runbooks/{1}' -f $subscriptionId, $Name)
            location   = 'eastus'
            properties = [PSCustomObject]$properties
        }
    }

    function Reset-TestWorld {
        $work = Join-Path -Path $TestDrive -ChildPath ('work-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        $global:BarWorld = @{
            Runbooks      = @{}
            Content       = @{}
            ContentTypes  = @{}
            ContentStatus = @{}
            ListError     = @{}
            Blobs         = (New-Object 'System.Collections.Generic.Dictionary[string,byte[]]' ([StringComparer]::Ordinal))
            # Content-MD5 sent with each PUT, returned by a later GET, as
            # the service does for a blob uploaded in one Put Blob.
            BlobMd5       = @{}
            Md5OnGet      = ''
            GoneOnDelete  = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
            DenyDelete    = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
            Requests      = (New-Object System.Collections.ArrayList)
            Downloads     = (New-Object System.Collections.ArrayList)
            Tamper        = $null
            PageSize      = 0
            WorkRoot      = $work
            # The mock body cannot see Describe variables, so the id it
            # returns from GET /subscriptions travels in the world.
            SubscriptionId = $subscriptionId
        }
    }

    function Set-TestAccount {
        param([string]$Account, [object[]]$Runbooks = @(), [hashtable]$Content = @{}, [hashtable]$ContentTypes = @{})
        $global:BarWorld.Runbooks[$Account] = @($Runbooks)
        foreach ($item in @($Runbooks)) {
            $key = '{0}/{1}' -f $Account, $item.name
            if ($Content.ContainsKey($item.name)) { $global:BarWorld.Content[$key] = $Content[$item.name] }
            else { $global:BarWorld.Content[$key] = ('param()' + "`r`n" + 'Write-Output "{0}"' -f $item.name) }
            if ($ContentTypes.ContainsKey($item.name)) { $global:BarWorld.ContentTypes[$key] = $ContentTypes[$item.name] }
        }
    }

    # The graphical runbook comes back the way the service may send it: as
    # application/json with the JSON source as the body, not a quoted string.
    function Set-StandardAccount {
        param([string]$Account = 'aa-identity-prod')
        Set-TestAccount -Account $Account -Runbooks @(
            (New-TestRunbook -Name 'Invoke-GuestLifecycle' -Type 'PowerShell72'),
            (New-TestRunbook -Name 'Draw-Diagram' -Type 'GraphPowerShell' -State 'Edit'),
            (New-TestRunbook -Name 'Sync-Things' -Type 'PowerShell' -RuntimeEnvironment 'PowerShell-7.4'),
            (New-TestRunbook -Name 'New-Draft' -Type 'PowerShell' -State 'New')
        ) -Content @{ 'Draw-Diagram' = $graphJson } -ContentTypes @{ 'Draw-Diagram' = 'application/json; charset=utf-8' }
    }

    # A second account with three old backups past retention (45, 55, and
    # 65 days) behind a readable newest backup and six recent ones.
    function Add-SecondAccountBlobs {
        Add-TestBlob -Name (Get-TestBlobName -Prefix $prefixB -DaysAgo 1) -Bytes (New-TestBackupBytes -Count 3)
        foreach ($days in @(2, 3, 4, 5, 6, 7, 45, 55, 65)) { Add-TestBlob -Name (Get-TestBlobName -Prefix $prefixB -DaysAgo $days) }
    }

    # Runs the run function with every stream on and captured. Returns the
    # summary and the text of every verbose, warning, and error record.
    function Invoke-CapturedTestRun {
        param([hashtable]$Overrides = @{})
        $records = @(& {
                $VerbosePreference = 'Continue'
                $WarningPreference = 'Continue'
                Invoke-TestRun -Overrides $Overrides -KeepErrorStream
            } 4>&1 3>&1 2>&1)
        $summary = $null
        $lines = New-Object System.Collections.ArrayList
        foreach ($record in $records) {
            if ($record -is [System.Management.Automation.ErrorRecord]) { [void]$lines.Add([string]$record.Exception.Message) }
            elseif ($record -is [System.Management.Automation.InformationalRecord]) { [void]$lines.Add([string]$record.Message) }
            elseif ($null -ne $record -and $record.PSObject.Properties['Accounts'] -and $record.PSObject.Properties['RunId']) { $summary = $record }
            else { [void]$lines.Add(($record | Out-String)) }
        }
        return [PSCustomObject]@{ Summary = $summary; Text = ($lines -join "`n"); RecordCount = $records.Count }
    }

    function New-TestBackupBytes {
        param([int]$Count)
        $folder = Join-Path -Path $TestDrive -ChildPath ('fixture-' + [Guid]::NewGuid().ToString('N'))
        $entries = New-Object System.Collections.ArrayList
        for ($i = 1; $i -le $Count; $i++) {
            $relative = 'runbooks/Old-Runbook{0}.ps1' -f $i
            $bytes = [System.Text.Encoding]::ASCII.GetBytes(('Write-Output {0}' -f $i))
            [void](Write-BackupFile -Root $folder -RelativePath $relative -Bytes $bytes)
            [void]$entries.Add([ordered]@{ name = ('Old-Runbook{0}' -f $i); runbookType = 'PowerShell72'; path = $relative; byteLength = [long]$bytes.Length; sha256 = (Get-BackupSha256 -Bytes $bytes) })
        }
        [void](Write-BackupManifest -Destination $folder -Header ([ordered]@{ schemaVersion = 1 }) -Entries $entries.ToArray())
        $zip = Join-Path -Path $folder -ChildPath 'package.zip'
        $paths = @('manifest.json') + @($entries | ForEach-Object { [string]$_['path'] })
        New-BackupPackage -SourceFolder $folder -RelativePaths $paths -ZipPath $zip
        return , [System.IO.File]::ReadAllBytes($zip)
    }

    function New-TestZip {
        param([System.Collections.IDictionary]$Entries)
        Initialize-BackupZipSupport
        $stream = New-Object -TypeName System.IO.MemoryStream
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($key in $Entries.Keys) {
                $entry = $archive.CreateEntry([string]$key)
                $writer = $entry.Open()
                try {
                    $data = [System.Text.Encoding]::UTF8.GetBytes([string]$Entries[$key])
                    $writer.Write($data, 0, $data.Length)
                }
                finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        return , $stream.ToArray()
    }

    function Edit-TestZipEntry {
        param([byte[]]$Bytes, [string]$EntryName, [string]$Text)
        Initialize-BackupZipSupport
        $stream = New-Object -TypeName System.IO.MemoryStream
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Position = 0
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @($stream, [System.IO.Compression.ZipArchiveMode]::Update, $true)
        try {
            $old = $archive.GetEntry($EntryName)
            if ($null -ne $old) { $old.Delete() }
            $entry = $archive.CreateEntry($EntryName)
            $writer = $entry.Open()
            try {
                $data = [System.Text.Encoding]::UTF8.GetBytes($Text)
                $writer.Write($data, 0, $data.Length)
            }
            finally { $writer.Dispose() }
        }
        finally { $archive.Dispose() }
        return , $stream.ToArray()
    }

    function Add-TestBlob {
        param([string]$Name, [byte[]]$Bytes = $null)
        if ($null -eq $Bytes) { $Bytes = [System.Text.Encoding]::ASCII.GetBytes('not a zip') }
        $global:BarWorld.Blobs[$Name] = $Bytes
    }

    function Get-TestBlobName {
        param([string]$Prefix = 'automation/aa-identity-prod/', [double]$DaysAgo)
        return (New-BackupBlobName -AccountPrefix $Prefix -Timestamp $now.AddDays(-$DaysAgo))
    }

    # Newest existing backup is a real package with three runbooks; the rest
    # are placeholders. With a new backup today, KeepAtLeast 7 and
    # RetentionDays 30, exactly the 40, 50, and 60 day old ones are deleted.
    function Add-StandardBlobs {
        param([int]$NewestCount = 3)
        Add-TestBlob -Name (Get-TestBlobName -DaysAgo 1) -Bytes (New-TestBackupBytes -Count $NewestCount)
        foreach ($days in @(2, 3, 4, 5, 6, 7, 40, 50, 60)) { Add-TestBlob -Name (Get-TestBlobName -DaysAgo $days) }
        foreach ($name in $foreignNames) { Add-TestBlob -Name $name }
    }

    # A thrown error still reaches the caller when the error stream is
    # silenced; only the logged, non-terminating Error lines are dropped.
    function Invoke-TestRun {
        param([hashtable]$Overrides = @{}, [switch]$KeepErrorStream)
        $params = $runArgs.Clone()
        $params['WorkRoot'] = $global:BarWorld.WorkRoot
        foreach ($key in $Overrides.Keys) { $params[$key] = $Overrides[$key] }
        if ($KeepErrorStream) { return (Invoke-BackupAutomationRunbooksRun @params) }
        return (Invoke-BackupAutomationRunbooksRun @params 2>$null)
    }

    function Get-TestRequests {
        param([string]$Method)
        return @($global:BarWorld.Requests | Where-Object { $_.Method -eq $Method })
    }

    function Get-WorkRootItemCount {
        return @(Get-ChildItem -LiteralPath $global:BarWorld.WorkRoot -Force).Count
    }

    Mock Invoke-HttpCore {
        $world = $global:BarWorld
        [void]$world.Requests.Add(@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = $ContentType; OutFile = $OutFile })
        $parsed = [Uri]$Uri
        $path = $parsed.AbsolutePath

        if ($parsed.Host -like 'management.*') {
            if ($path -eq '/subscriptions') {
                $subscriptions = @{ value = @(@{ subscriptionId = $world.SubscriptionId; displayName = 'Identity Automation'; state = 'Enabled' }) }
                return @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Content = (ConvertTo-Json -InputObject $subscriptions -Depth 5 -Compress) }
            }
            if ($path -match '/automationAccounts/([^/]+)/runbooks$') {
                $account = $Matches[1]
                if ($world.ListError.ContainsKey($account)) {
                    $listError = $world.ListError[$account]
                    return @{ StatusCode = [int]$listError.Status; Headers = @{}; Content = ('{{"error":{{"code":"{0}","message":"The resource type runbooks does not support this api-version."}}}}' -f $listError.Code) }
                }
                if (-not $world.Runbooks.ContainsKey($account)) {
                    return @{ StatusCode = 404; Headers = @{}; Content = '{"error":{"code":"ResourceNotFound","message":"The Resource was not found."}}' }
                }
                $all = @($world.Runbooks[$account])
                $skip = 0
                if ($parsed.Query -match 'skiptoken=(\d+)') { $skip = [int]$Matches[1] }
                $requestedVersion = ''
                if ($parsed.Query -match 'api-version=([^&]+)') { $requestedVersion = $Matches[1] }
                $page = $all
                $listBody = [ordered]@{}
                if ($world.PageSize -gt 0) {
                    $page = @($all | Select-Object -Skip $skip -First $world.PageSize)
                    if (($skip + $world.PageSize) -lt $all.Count) {
                        $listBody['nextLink'] = ('https://{0}{1}?api-version={2}&$skiptoken={3}' -f $parsed.Host, $path, $requestedVersion, ($skip + $world.PageSize))
                    }
                }
                $listBody['value'] = @($page)
                return @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/json' }; Content = (ConvertTo-Json -InputObject $listBody -Depth 10 -Compress) }
            }
            if ($path -match '/automationAccounts/([^/]+)/runbooks/([^/]+)/content$') {
                $key = '{0}/{1}' -f $Matches[1], [Uri]::UnescapeDataString($Matches[2])
                if ($world.ContentStatus.ContainsKey($key)) {
                    # The error body echoes the Authorization header, the worst
                    # thing a service could do, so the token tests can fail.
                    return @{ StatusCode = [int]$world.ContentStatus[$key]; Headers = @{}; Content = ('{{"error":{{"code":"AuthorizationFailed","message":"The client presenting {0} does not have authorization to perform this action."}}}}' -f [string]$Headers['Authorization']) }
                }
                if (-not $world.Content.ContainsKey($key)) {
                    return @{ StatusCode = 404; Headers = @{}; Content = '{"error":{"code":"NotFound","message":"Runbook not found."}}' }
                }
                $contentType = 'text/plain'
                if ($world.ContentTypes.ContainsKey($key)) { $contentType = [string]$world.ContentTypes[$key] }
                return @{ StatusCode = 200; Headers = @{ 'Content-Type' = $contentType }; Content = [string]$world.Content[$key] }
            }
            throw ('Unexpected ARM request: {0} {1}' -f $Method, $path)
        }

        if ($parsed.Host -like 'stbackupexample.blob.*') {
            if ($Method -eq 'GET' -and $parsed.Query -like '*comp=list*') {
                # The prefix in the query is ignored on purpose: the runbook
                # must filter again and never act on a name outside its prefix.
                $xml = New-Object -TypeName System.Text.StringBuilder
                [void]$xml.Append('<?xml version="1.0" encoding="utf-8"?><EnumerationResults ContainerName="runbook-backups"><Blobs>')
                foreach ($name in $world.Blobs.Keys) {
                    [void]$xml.Append(('<Blob><Name>{0}</Name><Properties><Content-Length>{1}</Content-Length><Content-Type>application/zip</Content-Type></Properties></Blob>' -f [System.Security.SecurityElement]::Escape($name), $world.Blobs[$name].Length))
                }
                [void]$xml.Append('</Blobs><NextMarker /></EnumerationResults>')
                return @{ StatusCode = 200; Headers = @{ 'Content-Type' = 'application/xml' }; Content = $xml.ToString() }
            }
            $blobName = [Uri]::UnescapeDataString($path.Substring('/runbook-backups/'.Length))
            if ($Method -eq 'GET' -and -not [string]::IsNullOrEmpty($OutFile)) {
                # The real core streams the body to OutFile, removes any file
                # that was there first, and leaves none behind on an error.
                if ($null -ne $Body) { throw 'A download must not send a body.' }
                if ([System.IO.File]::Exists($OutFile)) { [System.IO.File]::Delete($OutFile) }
                [void]$world.Downloads.Add($blobName)
                if (-not $world.Blobs.ContainsKey($blobName)) {
                    return @{ StatusCode = 404; Headers = @{ 'x-ms-error-code' = 'BlobNotFound' }; Content = '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>' }
                }
                $bytes = $world.Blobs[$blobName]
                if ($null -ne $world.Tamper) { $bytes = & $world.Tamper $blobName $bytes }
                [System.IO.File]::WriteAllBytes($OutFile, [byte[]]$bytes)
                $downloadHeaders = @{ 'Content-Type' = 'application/zip'; 'Content-Length' = [string]$bytes.Length }
                $md5 = ''
                if ($world.Md5OnGet) { $md5 = [string]$world.Md5OnGet }
                elseif ($world.BlobMd5.ContainsKey($blobName)) { $md5 = [string]$world.BlobMd5[$blobName] }
                if ($md5) { $downloadHeaders['Content-MD5'] = $md5 }
                return @{ StatusCode = 200; Headers = $downloadHeaders; Content = '' }
            }
            if ($Method -eq 'PUT') {
                # The real Invoke-HttpCore sends anything but a byte array as
                # text, so a package that is not byte[] here is a defect.
                if (-not ($Body -is [byte[]])) { throw ('Storage PUT body is {0}, not byte[].' -f $(if ($null -eq $Body) { 'null' } else { $Body.GetType().FullName })) }
                if ($world.Blobs.ContainsKey($blobName) -and [string]$Headers['If-None-Match'] -eq '*') {
                    return @{ StatusCode = 409; Headers = @{}; Content = '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobAlreadyExists</Code><Message>The specified blob already exists.</Message></Error>' }
                }
                $world.Blobs[$blobName] = $Body
                $world.BlobMd5[$blobName] = [string]$Headers['Content-MD5']
                return @{ StatusCode = 201; Headers = @{ ETag = '"0x8D0000000000001"'; 'Content-MD5' = [string]$Headers['Content-MD5'] }; Content = '' }
            }
            if ($Method -eq 'DELETE') {
                if ($world.DenyDelete.Contains($blobName)) {
                    return @{ StatusCode = 403; Headers = @{}; Content = ('<?xml version="1.0" encoding="utf-8"?><Error><Code>AuthorizationPermissionMismatch</Code><Message>This request presenting {0} is not authorized to perform this operation.</Message></Error>' -f [string]$Headers['Authorization']) }
                }
                # Another actor removed the blob between the listing and the delete.
                if ($world.GoneOnDelete.Contains($blobName)) { [void]$world.Blobs.Remove($blobName) }
                if ($world.Blobs.Remove($blobName)) { return @{ StatusCode = 202; Headers = @{}; Content = '' } }
                return @{ StatusCode = 404; Headers = @{}; Content = '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>' }
            }
        }
        throw ('Unexpected request: {0} {1}' -f $Method, $Uri)
    }

    Mock Start-Sleep { }

    Context 'blob names and stamps' {
        It 'builds the account prefix in lower case without stray slashes' {
            Get-BackupAccountPrefix -Prefix '/automation/' -AccountName 'AA-Identity-Prod' | Should Be 'automation/aa-identity-prod/'
            Get-BackupAccountPrefix -Prefix 'backups/automation' -AccountName $accountA | Should Be 'backups/automation/aa-identity-prod/'
        }

        It 'refuses an empty prefix, a dot segment, and a bad account name' {
            { ConvertTo-BackupPrefix -Prefix ' / ' } | Should Throw 'must not be empty'
            { ConvertTo-BackupPrefix -Prefix 'automation/../other' } | Should Throw 'is not valid'
            { ConvertTo-BackupPrefix -Prefix 'automation/./x' } | Should Throw 'is not valid'
            { ConvertTo-BackupPrefix -Prefix 'auto mation' } | Should Throw 'is not valid'
            { ConvertTo-BackupPrefix -Prefix 'automation//x' } | Should Throw 'is not valid'
            { Get-BackupAccountPrefix -Prefix 'automation' -AccountName 'aa' } | Should Throw 'is not valid'
            { Get-BackupAccountPrefix -Prefix 'automation' -AccountName 'aa/identity-prod' } | Should Throw 'is not valid'
        }

        # Windows PowerShell 5.1 drops a trailing dot from a URI path segment,
        # so "automation./" would be listed but written and deleted under
        # "automation/". Any segment that starts or ends with a dot is refused.
        It 'refuses a prefix segment that starts or ends with a dot' {
            foreach ($bad in @('automation.', 'backups/...', 'backups/automation.', '.automation', 'backups/.hidden/x', 'a..')) {
                { ConvertTo-BackupPrefix -Prefix $bad } | Should Throw 'is not valid'
            }
            ConvertTo-BackupPrefix -Prefix 'backups.v2/automation_1/-' | Should Be 'backups.v2/automation_1/-'
            ConvertTo-BackupPrefix -Prefix 'a' | Should Be 'a'
        }

        It 'names a backup by its UTC stamp' {
            New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now | Should Be 'automation/aa-identity-prod/20260917-023000Z.zip'
            $local = [DateTime]::SpecifyKind($now, [DateTimeKind]::Utc).ToLocalTime()
            New-BackupBlobName -AccountPrefix $prefixA -Timestamp $local | Should Be 'automation/aa-identity-prod/20260917-023000Z.zip'
        }

        It 'reads a stamp only from an exact backup name under the prefix' {
            (ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -AccountPrefix $prefixA).ToString('o') | Should Be '2026-09-17T02:30:00.0000000Z'
            ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod-old/20260917-023000Z.zip' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/manual/20260917-023000Z.zip' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName 'automation/AA-Identity-Prod/20260917-023000Z.zip' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/20260917-023000z.zip' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip.bak' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName 'automation/aa-identity-prod/20261399-023000Z.zip' -AccountPrefix $prefixA | Should BeNullOrEmpty
            ConvertFrom-BackupBlobName -BlobName '' -AccountPrefix $prefixA | Should BeNullOrEmpty
        }
    }

    Context 'runbook types, runtime, and content' {
        It 'maps runbook types to the documented import extensions' {
            Get-RunbookFileExtension -RunbookType 'PowerShell72' | Should Be '.ps1'
            Get-RunbookFileExtension -RunbookType 'PowerShell' | Should Be '.ps1'
            Get-RunbookFileExtension -RunbookType 'PowerShellWorkflow' | Should Be '.ps1'
            Get-RunbookFileExtension -RunbookType 'GraphPowerShell' | Should Be '.graphrunbook'
            Get-RunbookFileExtension -RunbookType 'GraphPowerShellWorkflow' | Should Be '.graphrunbook'
            Get-RunbookFileExtension -RunbookType 'Python3' | Should Be '.py'
            Get-RunbookFileExtension -RunbookType 'Python' | Should Be '.py'
            Get-RunbookFileExtension -RunbookType 'SomethingNew' | Should Be '.txt'
            Get-RunbookFileExtension -RunbookType '' | Should Be '.txt'
        }

        It 'reports a runtime version only when the API gives one' {
            Get-RunbookRuntimeVersion -RunbookType 'PowerShell' -RuntimeEnvironment 'PowerShell-7.4' | Should Be '7.4'
            Get-RunbookRuntimeVersion -RunbookType 'Python' -RuntimeEnvironment 'Python-3.10' | Should Be '3.10'
            Get-RunbookRuntimeVersion -RunbookType 'PowerShell' -RuntimeEnvironment 'custom-env' | Should Be ''
            Get-RunbookRuntimeVersion -RunbookType 'PowerShell72' -RuntimeEnvironment '' | Should Be '7.2'
            Get-RunbookRuntimeVersion -RunbookType 'PowerShell' | Should Be '5.1'
            Get-RunbookRuntimeVersion -RunbookType 'Python2' | Should Be '2.7'
            Get-RunbookRuntimeVersion -RunbookType 'Python3' | Should Be ''
        }

        It 'keeps a text body exactly, even when it looks like JSON' {
            ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'text/plain' -RunbookType 'GraphPowerShell' | Should BeExactly $graphJson
            ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'text/plain' -RunbookType 'PowerShell' | Should BeExactly $graphJson
            ConvertFrom-RunbookContentResponse -Content "[CmdletBinding()]`r`nparam()" -ContentType 'text/powershell' | Should BeExactly "[CmdletBinding()]`r`nparam()"
            ConvertFrom-RunbookContentResponse -Content '"param()\r\n"' -ContentType 'text/plain' -RunbookType 'PowerShell72' | Should BeExactly '"param()\r\n"'
            ConvertFrom-RunbookContentResponse -Content $null -ContentType '' | Should BeExactly ''
        }

        It 'decodes a JSON string body for every runbook type' {
            ConvertFrom-RunbookContentResponse -Content '"param()\r\nWrite-Output \"hi\""' -ContentType 'application/json; charset=utf-8' -RunbookType 'PowerShell72' | Should BeExactly ("param()`r`nWrite-Output " + '"hi"')
            ConvertFrom-RunbookContentResponse -Content ' "{\"schemaVersion\":\"1.10\"}" ' -ContentType 'application/json' -RunbookType 'GraphPowerShell' | Should BeExactly '{"schemaVersion":"1.10"}'
            { ConvertFrom-RunbookContentResponse -Content '"unterminated' -ContentType 'application/json' -RunbookType 'PowerShell' } | Should Throw
        }

        It 'keeps a JSON object body for a graphical runbook and refuses it for any other type' {
            ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'application/json; charset=utf-8' -RunbookType 'GraphPowerShell' | Should BeExactly $graphJson
            ConvertFrom-RunbookContentResponse -Content ($graphJson + "`r`n") -ContentType 'application/json' -RunbookType 'GraphPowerShellWorkflow' | Should BeExactly ($graphJson + "`r`n")
            ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'application/json' -RunbookType 'Graph' | Should BeExactly $graphJson
            { ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'application/json' -RunbookType 'PowerShell72' } | Should Throw 'of type "PowerShell72" came back as application/json but is not a JSON string'
            { ConvertFrom-RunbookContentResponse -Content $graphJson -ContentType 'application/json' } | Should Throw 'not a JSON string'
            { ConvertFrom-RunbookContentResponse -Content '[1,2]' -ContentType 'application/json' -RunbookType 'GraphPowerShell' } | Should Throw 'not a JSON string'
            { ConvertFrom-RunbookContentResponse -Content '42' -ContentType 'application/json' -RunbookType 'GraphPowerShell' } | Should Throw 'not a JSON string'
        }

        It 'spots a text body that looks like a quoted JSON string' {
            Test-RunbookContentLooksQuoted -Text '"param()\r\nWrite-Output 1"' | Should Be $true
            Test-RunbookContentLooksQuoted -Text "param()`r`nWrite-Output 1" | Should Be $false
            Test-RunbookContentLooksQuoted -Text '"hello"' | Should Be $false
            Test-RunbookContentLooksQuoted -Text $graphJson | Should Be $false
            Test-RunbookContentLooksQuoted -Text '"a\q"' | Should Be $false
            Test-RunbookContentLooksQuoted -Text '' | Should Be $false
        }

        It 'selects published and edited runbooks, skips new ones, and sorts by name' {
            $list = @(
                (New-TestRunbook -Name 'abcd'),
                (New-TestRunbook -Name 'abc' -State 'Edit'),
                (New-TestRunbook -Name 'B-Runbook'),
                (New-TestRunbook -Name 'draft' -State 'New'),
                [PSCustomObject]@{ name = 'stateless'; properties = [PSCustomObject]@{ runbookType = 'PowerShell' } }
            )
            $selection = Select-BackupRunbooks -Runbooks $list
            (@($selection.Selected | ForEach-Object { $_.name }) -join ',') | Should Be 'B-Runbook,abc,abcd'
            @($selection.Skipped).Count | Should Be 2
            ((@($selection.Skipped) | Where-Object { $_.Name -eq 'draft' }).Reason) | Should Match 'never published'
            @((Select-BackupRunbooks -Runbooks @()).Selected).Count | Should Be 0
        }
    }

    Context 'retention plan' {
        $names = @(foreach ($d in @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)) { New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now.AddDays(-100 - $d) })

        It 'keeps the newest KeepAtLeast even when every backup is past retention' {
            $plan = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix $prefixA -Now $now -RetentionDays 30 -KeepAtLeast 7
            @($plan.Keep).Count | Should Be 7
            @($plan.Delete).Count | Should Be 3
            (@($plan.Delete | ForEach-Object { $_.Name }) -join ',') | Should Be (($names[7], $names[8], $names[9]) -join ',')
            $plan.NewestExisting | Should Be $names[0]
        }

        It 'counts the pending backup toward the floor and never deletes it' {
            $pending = New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now
            $plan = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix $prefixA -Now $now -RetentionDays 30 -KeepAtLeast 7 -PendingBlobName $pending
            @($plan.Keep).Count | Should Be 7
            @($plan.Delete).Count | Should Be 4
            (@($plan.Keep | Where-Object { $_.Pending }).Count) | Should Be 1
            (@($plan.Delete | ForEach-Object { $_.Name }) -contains $pending) | Should Be $false
            $plan.NewestExisting | Should Be $names[0]
            $plan.PendingExists | Should Be $false

            $one = Get-BackupRetentionPlan -BlobNames $names -AccountPrefix $prefixA -Now $now -RetentionDays 1 -KeepAtLeast 1 -PendingBlobName $pending
            @($one.Keep).Count | Should Be 1
            @($one.Keep)[0].Name | Should Be $pending
            @($one.Delete).Count | Should Be 10
        }

        It 'deletes only past RetentionDays, keeping a backup exactly at the limit' {
            $mixed = @(
                (New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now.AddDays(-1)),
                (New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now.AddDays(-30)),
                (New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now.AddDays(-30).AddSeconds(-1)),
                (New-BackupBlobName -AccountPrefix $prefixA -Timestamp $now.AddDays(-90))
            )
            $plan = Get-BackupRetentionPlan -BlobNames $mixed -AccountPrefix $prefixA -Now $now -RetentionDays 30 -KeepAtLeast 1
            (@($plan.Delete | ForEach-Object { $_.Name }) -join ',') | Should Be (($mixed[2], $mixed[3]) -join ',')
            @($plan.Keep).Count | Should Be 2
        }

        It 'never plans a delete outside the prefix or for a name that is not a backup' {
            $all = @($names) + $foreignNames + @('automation/aa-identity-dev/20200101-000000Z.zip')
            $plan = Get-BackupRetentionPlan -BlobNames $all -AccountPrefix $prefixA -Now $now -RetentionDays 1 -KeepAtLeast 1
            foreach ($entry in @($plan.Delete)) { $entry.Name.StartsWith($prefixA, [StringComparison]::Ordinal) | Should Be $true }
            foreach ($foreign in $foreignNames) { (@($plan.Delete | ForEach-Object { $_.Name }) -contains $foreign) | Should Be $false }
            @($plan.Delete).Count | Should Be 9
            (@($plan.Ignored) -join ',') | Should Be 'automation/aa-identity-prod/manual/20250101-000000Z.zip,automation/aa-identity-prod/README.txt,automation/aa-identity-prod/20250101-000000Z.zip.bak'
            $plan.OutsidePrefix | Should Be 5
        }

        It 'handles an empty listing and refuses a pending name outside the prefix' {
            $empty = Get-BackupRetentionPlan -BlobNames @() -AccountPrefix $prefixA -Now $now -RetentionDays 30 -KeepAtLeast 7
            @($empty.Entries).Count | Should Be 0
            $empty.NewestExisting | Should Be ''
            $empty.NewestExistingUtc | Should BeNullOrEmpty
            { Get-BackupRetentionPlan -BlobNames @() -AccountPrefix $prefixA -Now $now -RetentionDays 30 -KeepAtLeast 7 -PendingBlobName 'automation/other/20260917-023000Z.zip' } | Should Throw 'is not a backup name'
        }
    }

    Context 'shrink guard' {
        It 'passes exactly at the limit and trips one runbook past it' {
            (Test-BackupShrink -PreviousCount 20 -CurrentCount 15 -MaxShrinkPercent 25).Passed | Should Be $true
            $tripped = Test-BackupShrink -PreviousCount 20 -CurrentCount 14 -MaxShrinkPercent 25
            $tripped.Passed | Should Be $false
            $tripped.DropPercent | Should Be 30
            $tripped.Reason | Should Match 'limit 25%'
        }

        It 'passes on growth, no change, and a first backup' {
            (Test-BackupShrink -PreviousCount 5 -CurrentCount 9 -MaxShrinkPercent 0).Passed | Should Be $true
            (Test-BackupShrink -PreviousCount 5 -CurrentCount 5 -MaxShrinkPercent 0).Passed | Should Be $true
            (Test-BackupShrink -PreviousCount 0 -CurrentCount 1 -MaxShrinkPercent 0).Passed | Should Be $true
        }

        It 'trips on any drop at 0 and never at 100' {
            (Test-BackupShrink -PreviousCount 100 -CurrentCount 99 -MaxShrinkPercent 0).Passed | Should Be $false
            (Test-BackupShrink -PreviousCount 100 -CurrentCount 0 -MaxShrinkPercent 100).Passed | Should Be $true
        }
    }

    Context 'manifest comparison' {
        $manifest = [PSCustomObject]@{
            runbookCount = 2
            runbooks     = @(
                [PSCustomObject]@{ path = 'runbooks/A.ps1'; byteLength = 3; sha256 = 'aaaa' },
                [PSCustomObject]@{ path = 'runbooks/B.py'; byteLength = 4; sha256 = 'bbbb' }
            )
        }

        function New-TestFiles {
            $files = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
            $files['manifest.json'] = [PSCustomObject]@{ Sha256 = 'MMMM'; Length = 10 }
            $files['runbooks/A.ps1'] = [PSCustomObject]@{ Sha256 = 'AAAA'; Length = 3 }
            $files['runbooks/B.py'] = [PSCustomObject]@{ Sha256 = 'bbbb'; Length = 4 }
            return $files
        }

        It 'finds nothing when the package matches' {
            @(Compare-BackupManifest -Manifest $manifest -ActualFiles (New-TestFiles) -ExpectedManifestSha256 'mmmm').Count | Should Be 0
        }

        It 'reports a hash mismatch' {
            $files = New-TestFiles
            $files['runbooks/B.py'] = [PSCustomObject]@{ Sha256 = 'cccc'; Length = 4 }
            $problems = @(Compare-BackupManifest -Manifest $manifest -ActualFiles $files -ExpectedManifestSha256 'mmmm')
            $problems.Count | Should Be 1
            $problems[0] | Should Match 'runbooks/B.py has SHA-256 cccc, manifest says bbbb'
        }

        It 'reports missing, extra, resized, and foreign-manifest differences' {
            $files = New-TestFiles
            $files.Remove('runbooks/A.ps1')
            $files['runbooks/C.ps1'] = [PSCustomObject]@{ Sha256 = 'dddd'; Length = 1 }
            $files['runbooks/B.py'] = [PSCustomObject]@{ Sha256 = 'bbbb'; Length = 5 }
            $problems = @(Compare-BackupManifest -Manifest $manifest -ActualFiles $files -ExpectedManifestSha256 'nnnn')
            $problems.Count | Should Be 4
            ($problems -join '|') | Should Match 'not the manifest this run wrote'
            ($problems -join '|') | Should Match 'runbooks/A.ps1 is listed in the manifest but missing'
            ($problems -join '|') | Should Match 'runbooks/C.ps1 is in the package but not in the manifest'
            ($problems -join '|') | Should Match 'runbooks/B.py is 5 byte'
        }

        It 'reports a missing manifest and a count that does not match the list' {
            $files = New-TestFiles
            $files.Remove('manifest.json')
            $bad = [PSCustomObject]@{ runbookCount = 3; runbooks = $manifest.runbooks }
            $problems = @(Compare-BackupManifest -Manifest $bad -ActualFiles $files -ExpectedManifestSha256 'mmmm')
            ($problems -join '|') | Should Match 'manifest.json is missing'
            ($problems -join '|') | Should Match 'declares 3 runbook'
        }
    }

    Context 'package round trip' {
        It 'packages, extracts, and verifies UTF-8 sources without a byte order mark' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'roundtrip'
            $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
            $text = 'Write-Output "caf' + $eAcute + '"'
            $bytes = $utf8.GetBytes($text)
            [void](Write-BackupFile -Root $folder -RelativePath 'runbooks/Say-Cafe.ps1' -Bytes $bytes)
            $entries = @([ordered]@{ name = 'Say-Cafe'; path = 'runbooks/Say-Cafe.ps1'; byteLength = [long]$bytes.Length; sha256 = (Get-BackupSha256 -Bytes $bytes) })
            $written = Write-BackupManifest -Destination $folder -Header ([ordered]@{ schemaVersion = 1 }) -Entries $entries
            $zip = Join-Path -Path $TestDrive -ChildPath 'roundtrip.zip'
            New-BackupPackage -SourceFolder $folder -RelativePaths @('manifest.json', 'runbooks/Say-Cafe.ps1') -ZipPath $zip

            $check = Test-BackupPackage -ZipPath $zip -Manifest $written.Manifest -ManifestSha256 $written.Sha256 -Destination (Join-Path -Path $TestDrive -ChildPath 'roundtrip-verify')
            $check.Verified | Should Be $true
            $check.FileCount | Should Be 2
            $restored = [System.IO.File]::ReadAllBytes((Join-Path -Path $TestDrive -ChildPath 'roundtrip-verify\runbooks\Say-Cafe.ps1'))
            ($restored[0] -eq 0xEF) | Should Be $false
            $utf8.GetString($restored) | Should BeExactly $text
            (Read-BackupPackageManifest -ZipPath $zip).runbookCount | Should Be 1
            $bytes.Length | Should Be ($text.Length + 1)
        }

        # The library's download takes only a rooted target, so the work
        # folder is always a full path, even from a relative root.
        It 'creates the work folder as a full path, also from a relative root' {
            Push-Location -LiteralPath $TestDrive
            try { $folder = New-BackupWorkFolder -WorkRoot 'relative-root' }
            finally { Pop-Location }
            [System.IO.Path]::IsPathRooted($folder) | Should Be $true
            $expectedParent = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'relative-root')) + [System.IO.Path]::DirectorySeparatorChar
            $folder.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) | Should Be $true
            [System.IO.Directory]::Exists($folder) | Should Be $true
            $temp = New-BackupWorkFolder -WorkRoot ''
            try { $temp.StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) | Should Be $true }
            finally { [System.IO.Directory]::Delete($temp, $true) }
        }

        It 'hashes bytes and files the same way' {
            $path = Join-Path -Path $TestDrive -ChildPath 'hash.txt'
            [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes('abc'))
            Get-BackupSha256 -Path $path | Should Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            Get-BackupSha256 -Bytes ([System.Text.Encoding]::ASCII.GetBytes('abc')) | Should Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }

        It 'refuses an entry that could escape the extraction folder' {
            $zip = Join-Path -Path $TestDrive -ChildPath 'evil.zip'
            [System.IO.File]::WriteAllBytes($zip, (New-TestZip -Entries ([ordered]@{ 'manifest.json' = '{}'; '../evil.ps1' = 'x' })))
            $destination = Join-Path -Path $TestDrive -ChildPath 'evil-out'
            { Expand-BackupPackage -ZipPath $zip -Destination $destination } | Should Throw 'unexpected entry'
            Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'evil.ps1') | Should Be $false
            { Write-BackupFile -Root $destination -RelativePath '../outside.txt' -Bytes ([byte[]](1)) } | Should Throw 'outside the work folder'
        }

        It 'reports an unreadable package as a problem rather than throwing' {
            $zip = Join-Path -Path $TestDrive -ChildPath 'junk.zip'
            [System.IO.File]::WriteAllBytes($zip, [System.Text.Encoding]::ASCII.GetBytes('not a zip'))
            $check = Test-BackupPackage -ZipPath $zip -Manifest ([PSCustomObject]@{ runbookCount = 0; runbooks = @() }) -ManifestSha256 'x' -Destination (Join-Path -Path $TestDrive -ChildPath 'junk-out')
            $check.Verified | Should Be $false
            (@($check.Problems) -join '|') | Should Match 'could not be extracted'
            { Read-BackupPackageManifest -ZipPath $zip } | Should Throw
        }

        It 'refuses a package without a manifest or with an inconsistent one' {
            $noManifest = Join-Path -Path $TestDrive -ChildPath 'nomanifest.zip'
            [System.IO.File]::WriteAllBytes($noManifest, (New-TestZip -Entries ([ordered]@{ 'runbooks/A.ps1' = 'x' })))
            { Read-BackupPackageManifest -ZipPath $noManifest } | Should Throw 'no manifest.json'
            $inconsistent = Join-Path -Path $TestDrive -ChildPath 'inconsistent.zip'
            [System.IO.File]::WriteAllBytes($inconsistent, (New-TestZip -Entries ([ordered]@{ 'manifest.json' = '{"runbookCount":2,"runbooks":[{"path":"runbooks/A.ps1"}]}' })))
            { Read-BackupPackageManifest -ZipPath $inconsistent } | Should Throw 'declares 2 runbook'
        }
    }

    Context 'storage helpers' {
        It 'uploads with BlockBlob, If-None-Match, Content-MD5, and metadata' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens -DryRun $false
            $zip = Join-Path -Path $TestDrive -ChildPath 'upload.zip'
            $fileBytes = [byte[]](0x50, 0x4B, 0x05, 0x06, 0x00, 0xFF, 0x80, 0xC3, 0x28, 0x0A)
            [System.IO.File]::WriteAllBytes($zip, $fileBytes)
            $sent = Send-BackupPackage -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -Path $zip -ContentMd5 'q83vEjRWeJA=' -Metadata ([ordered]@{ runid = $runId })
            $sent.StatusCode | Should Be 201
            $sent.AlreadyExisted | Should Be $false
            $request = @(Get-TestRequests -Method 'PUT')[0]
            $request.Uri | Should Be 'https://stbackupexample.blob.core.windows.net/runbook-backups/automation/aa-identity-prod/20260917-023000Z.zip'
            $request.Headers['x-ms-blob-type'] | Should Be 'BlockBlob'
            $request.Headers['If-None-Match'] | Should Be '*'
            $request.Headers['Content-MD5'] | Should Be 'q83vEjRWeJA='
            $request.Headers['x-ms-meta-runid'] | Should Be $runId
            $request.Headers['x-ms-version'] | Should Be '2023-11-03'
            $request.Headers['Authorization'] | Should Be ('Bearer ' + $storageToken)
            $request.ContentType | Should Be 'application/zip'
            # No cast: an object[] of numbers would pass a cast and then be
            # sent as text by the real Invoke-HttpCore.
            ($request.Body -is [byte[]]) | Should Be $true
            $request.Body.Length | Should Be $fileBytes.Length
            for ($i = 0; $i -lt $fileBytes.Length; $i++) { $request.Body[$i] | Should Be $fileBytes[$i] }
            $stored = $global:BarWorld.Blobs['automation/aa-identity-prod/20260917-023000Z.zip']
            ([BitConverter]::ToString($stored)) | Should Be ([BitConverter]::ToString($fileBytes))
        }

        It 'refuses a storage PUT body that is not a byte array (the mock guard itself)' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens -DryRun $false
            $uri = 'https://stbackupexample.blob.core.windows.net/runbook-backups/automation/aa-identity-prod/20260917-023000Z.zip'
            { Invoke-HttpCore -Method PUT -Uri $uri -Headers @{} -Body @(1, 2, 3) -ContentType 'application/zip' } | Should Throw 'not byte[]'
            $global:BarWorld.Blobs.Count | Should Be 0
        }

        It 'checks every blob request URI before a token is sent' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens -DryRun $false
            Get-BackupBlobUri -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'backups.v2/aa-identity-prod/20260917-023000Z.zip' | Should Be 'https://stbackupexample.blob.core.windows.net/runbook-backups/backups.v2/aa-identity-prod/20260917-023000Z.zip'
            foreach ($bad in @('automation./aa-identity-prod/20260101-000000Z.zip', 'backups/.../aa-identity-prod/20260101-000000Z.zip', 'automation/../aa-identity-prod/20260101-000000Z.zip', 'automation//20260101-000000Z.zip', 'automation/a b.zip')) {
                { Get-BackupBlobUri -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName $bad } | Should Throw 'Refusing a storage request'
                { Remove-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName $bad } | Should Throw 'Refusing a storage request'
                { Send-BackupPackage -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName $bad -Path $runbook } | Should Throw 'Refusing a storage request'
                { Receive-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName $bad -OutFile (Join-Path -Path $TestDrive -ChildPath 'refused.zip') } | Should Throw 'Refusing a storage request'
            }
            @($global:BarWorld.Requests).Count | Should Be 0
            @($global:BarWorld.Downloads).Count | Should Be 0
        }

        It 'compares the parsed request path with the container and blob it was built for' {
            $name = 'automation/aa-identity-prod/20260101-000000Z.zip'
            $base = 'https://stbackupexample.blob.core.windows.net/'
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/' + $name) -ContainerName 'runbook-backups' -BlobName $name } | Should Not Throw
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/automation/aa-identity-dev/20260101-000000Z.zip') -ContainerName 'runbook-backups' -BlobName $name } | Should Throw 'would reach "/runbook-backups/automation/aa-identity-dev/20260101-000000Z.zip"'
            { Assert-BackupBlobRequestUri -Uri ($base + 'other/' + $name) -ContainerName 'runbook-backups' -BlobName $name } | Should Throw 'instead of "/runbook-backups/automation/aa-identity-prod/20260101-000000Z.zip"'
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/Automation/aa-identity-prod/20260101-000000Z.zip') -ContainerName 'runbook-backups' -BlobName $name } | Should Throw 'would reach'
            # The text starts with the right path, but the parser removes the
            # last segment: only a comparison of the parsed path catches it.
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/' + $name + '/..') -ContainerName 'runbook-backups' -BlobName $name } | Should Throw 'would reach "/runbook-backups/automation/aa-identity-prod/"'
            # A dot segment that resolves back to the named blob is harmless.
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/automation/aa-identity-prod/./20260101-000000Z.zip') -ContainerName 'runbook-backups' -BlobName $name } | Should Not Throw
            { Assert-BackupBlobRequestUri -Uri 'not a uri' -ContainerName 'runbook-backups' -BlobName $name } | Should Throw 'does not parse'
            { Assert-BackupBlobRequestUri -Uri ($base + 'runbook-backups/automation./x.zip') -ContainerName 'runbook-backups' -BlobName 'automation./x.zip' } | Should Throw 'not a safe blob name segment'
        }

        It 'deletes a blob, and reports a blob that is already gone as $false' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens -DryRun $false
            Add-TestBlob -Name 'automation/aa-identity-prod/20250101-000000Z.zip'
            Remove-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20250101-000000Z.zip' | Should Be $true
            Remove-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20250101-000000Z.zip' | Should Be $false
            $deletes = @(Get-TestRequests -Method 'DELETE')
            $deletes.Count | Should Be 2
            $deletes[0].Uri | Should Be 'https://stbackupexample.blob.core.windows.net/runbook-backups/automation/aa-identity-prod/20250101-000000Z.zip'
            $deletes[0].Headers['Authorization'] | Should Be ('Bearer ' + $storageToken)
            $deletes[0].Headers['x-ms-version'] | Should Be '2023-11-03'
            [void]$global:BarWorld.DenyDelete.Add('automation/aa-identity-prod/20250102-000000Z.zip')
            { Remove-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20250102-000000Z.zip' } | Should Throw 'HTTP 403'
        }

        It 'downloads a package byte for byte through the library core' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            $name = 'automation/aa-identity-prod/20260916-023000Z.zip'
            $fileBytes = [byte[]](0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x80, 0xC3, 0x28, 0x0A)
            Add-TestBlob -Name $name -Bytes $fileBytes
            $global:BarWorld.BlobMd5[$name] = 'bWQ1dmFsdWU='
            $out = Join-Path -Path $TestDrive -ChildPath 'dl\bytes.zip'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force)
            [System.IO.File]::WriteAllBytes($out, [byte[]](1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1))

            $result = Receive-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName $name -OutFile $out
            $result.Path | Should Be $out
            $result.Length | Should Be $fileBytes.Length
            $result.ContentMd5 | Should Be 'bWQ1dmFsdWU='
            $result.StatusCode | Should Be 200
            ([BitConverter]::ToString([System.IO.File]::ReadAllBytes($out))) | Should Be ([BitConverter]::ToString($fileBytes))
            @($global:BarWorld.Requests).Count | Should Be 1
            $request = @($global:BarWorld.Requests)[0]
            $request.Method | Should Be 'GET'
            $request.OutFile | Should Be $out
            $request.Body | Should BeNullOrEmpty
            $request.Uri | Should Be ('https://stbackupexample.blob.core.windows.net/runbook-backups/' + $name)
            $request.Headers['Authorization'] | Should Be ('Bearer ' + $storageToken)
            $request.Headers['x-ms-version'] | Should Be '2023-11-03'
            $request.Headers.ContainsKey('x-ms-date') | Should Be $true
        }

        It 'throws a 404 that Get-CloudErrorStatus reads, without retrying or leaving a file' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            $out = Join-Path -Path $TestDrive -ChildPath 'missing.zip'
            [System.IO.File]::WriteAllBytes($out, [byte[]](1, 2, 3))
            $status = 0
            $message = ''
            try { [void](Receive-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/missing.zip' -OutFile $out) }
            catch {
                $status = Get-CloudErrorStatus -ErrorRecord $_
                $message = $_.Exception.Message
            }
            $status | Should Be 404
            $message | Should Match 'Storage GET /runbook-backups/automation/missing.zip failed with HTTP 404 after 1 attempt'
            $message | Should Match 'BlobNotFound'
            Test-Path -LiteralPath $out | Should Be $false
            @($global:BarWorld.Downloads).Count | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
        }

        It 'reads runbook content raw through ARM with the default or the given api-version' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            Set-StandardAccount
            $accountId = '/subscriptions/{0}/resourceGroups/rg-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-identity-prod' -f $subscriptionId
            $read = Get-BackupRunbookContent -AccountId $accountId -RunbookName 'Draw-Diagram' -RunbookType 'GraphPowerShell'
            $read.Text | Should BeExactly $graphJson
            $read.ContentType | Should Be 'application/json; charset=utf-8'
            $request = @(Get-TestRequests -Method 'GET')[0]
            $request.Uri | Should Be ('https://management.azure.com/subscriptions/{0}/resourceGroups/rg-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-identity-prod/runbooks/Draw-Diagram/content?api-version=2024-10-23' -f $subscriptionId)
            $request.Headers['Accept'] | Should Match 'text/plain'
            $request.Headers['Accept'] | Should Match 'text/powershell'
            $request.Headers['Authorization'] | Should Be ('Bearer ' + $armToken)

            { Get-BackupRunbookContent -AccountId $accountId -RunbookName 'Draw-Diagram' -RunbookType 'PowerShell' } | Should Throw 'not a JSON string'
            $older = Get-BackupRunbookContent -AccountId $accountId -RunbookName 'Sync-Things' -RunbookType 'PowerShell' -ApiVersion '2023-11-01'
            $older.ContentType | Should Be 'text/plain'
            @(Get-TestRequests -Method 'GET')[-1].Uri | Should Match 'Sync-Things/content\?api-version=2023-11-01$'
        }

        It 'adds an api-version hint to a 400 that names the api-version' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            $global:BarWorld.ListError['aa-identity-prod'] = @{ Status = 400; Code = 'InvalidApiVersionParameter' }
            $accountId = '/subscriptions/{0}/resourceGroups/rg-identity-automation/providers/Microsoft.Automation/automationAccounts/aa-identity-prod' -f $subscriptionId
            $caught = $null
            try { [void](Export-BackupRunbookSources -AccountId $accountId -AccountName 'aa-identity-prod' -Destination (Join-Path -Path $TestDrive -ChildPath 'hint') -ApiVersion '2024-10-23') }
            catch { $caught = $_ }
            $caught.Exception.Message | Should Match 'HTTP 400'
            $caught.Exception.Message | Should Match 'set AutomationApiVersion \(for example 2023-11-01\)'
            Get-CloudErrorStatus -ErrorRecord $caught | Should Be 400

            $global:BarWorld.ListError['aa-identity-prod'] = @{ Status = 403; Code = 'AuthorizationFailed' }
            $caught = $null
            try { [void](Export-BackupRunbookSources -AccountId $accountId -AccountName 'aa-identity-prod' -Destination (Join-Path -Path $TestDrive -ChildPath 'hint') -ApiVersion '2024-10-23') }
            catch { $caught = $_ }
            $caught.Exception.Message | Should Match 'HTTP 403'
            $caught.Exception.Message | Should Not Match 'AutomationApiVersion'
        }
    }

    # Pester 3.4 keeps a mock declared inside an It until the end of its
    # Context, so each test that replaces a Describe-level mock has its own.
    Context 'storage helpers: a blob that already exists' {
        It 'reports an existing blob instead of overwriting it, and throws on any other conflict' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens -DryRun $false
            Add-TestBlob -Name 'automation/aa-identity-prod/20260917-023000Z.zip'
            $zip = Join-Path -Path $TestDrive -ChildPath 'upload2.zip'
            [System.IO.File]::WriteAllBytes($zip, [byte[]](1, 2, 3))
            $sent = Send-BackupPackage -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -Path $zip
            $sent.AlreadyExisted | Should Be $true
            [System.Text.Encoding]::ASCII.GetString($global:BarWorld.Blobs['automation/aa-identity-prod/20260917-023000Z.zip']) | Should Be 'not a zip'

            Mock Invoke-HttpCore { return @{ StatusCode = 409; Headers = @{}; Content = '<?xml version="1.0" encoding="utf-8"?><Error><Code>ContainerBeingDeleted</Code><Message>The specified container is being deleted.</Message></Error>' } }
            { Send-BackupPackage -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/x.zip' -Path $zip } | Should Throw 'HTTP 409'
        }
    }

    Context 'storage helpers: a busy download' {
        It 'retries a busy download through the library, to a path relative to the location' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            $global:BarDownloadCalls = 0
            Mock Invoke-HttpCore {
                $global:BarDownloadCalls++
                if ([string]::IsNullOrEmpty($OutFile)) { throw 'Expected a download to a file.' }
                if ($global:BarDownloadCalls -eq 1) { return @{ StatusCode = 503; Headers = @{ 'Retry-After' = '2' }; Content = '<Error><Code>ServerBusy</Code></Error>' } }
                [System.IO.File]::WriteAllBytes($OutFile, [byte[]](9, 8, 7))
                return @{ StatusCode = 200; Headers = @{ 'Content-MD5' = 'abc=' }; Content = '' }
            }
            $expected = [System.IO.Path]::GetFullPath((Join-Path -Path $TestDrive -ChildPath 'dl-relative\busy.zip'))
            Push-Location -LiteralPath $TestDrive
            try { $result = Receive-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -OutFile 'dl-relative\busy.zip' }
            finally { Pop-Location }
            $result.Path | Should Be $expected
            $result.Length | Should Be 3
            $result.ContentMd5 | Should Be 'abc='
            Test-Path -LiteralPath $expected | Should Be $true
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 2 }
            Assert-MockCalled Invoke-HttpCore -Exactly 2 -Scope It -ParameterFilter { $Method -eq 'GET' -and $OutFile -like '*\dl-relative\busy.zip' -and $Headers['Authorization'] -like 'Bearer eyJ*' -and $Headers['x-ms-version'] -eq '2023-11-03' }
        }

        It 'gives up after the attempts it is given' {
            Reset-TestWorld
            Initialize-RunContext -RunbookName 'Backup-AutomationRunbooks' -RunId $runId -AccessToken $tokens
            Mock Invoke-HttpCore { return @{ StatusCode = 500; Headers = @{}; Content = '<Error><Code>InternalError</Code></Error>' } }
            $out = Join-Path -Path $TestDrive -ChildPath 'dl\down.zip'
            { Receive-BackupBlob -StorageAccountName 'stbackupexample' -ContainerName 'runbook-backups' -BlobName 'automation/aa-identity-prod/20260917-023000Z.zip' -OutFile $out -MaxAttempts 2 } | Should Throw 'failed with HTTP 500 after 2 attempt'
            Assert-MockCalled Invoke-HttpCore -Exactly 2 -Scope It
            Test-Path -LiteralPath $out | Should Be $false
        }
    }

    Context 'run with a mocked Automation account and container' {
        It 'makes no storage write in a dry run and reports what it would delete' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $before = $global:BarWorld.Blobs.Count
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true }

            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $global:BarWorld.Blobs.Count | Should Be $before
            $summary.DryRun | Should Be $true
            $summary.Runbook | Should Be 'Backup-AutomationRunbooks'
            $summary.RunId | Should Be $runId
            $summary.Planned | Should Be 4
            $summary.Done | Should Be 0
            $summary.Failed | Should Be 0
            $summary.Counts.UploadBackup.Planned | Should Be 1
            $summary.Counts.DeleteBackup.Planned | Should Be 3
            $summary.DeletesPlanned | Should Be 3
            $expected = @((Get-TestBlobName -DaysAgo 40), (Get-TestBlobName -DaysAgo 50), (Get-TestBlobName -DaysAgo 60))
            (@($summary.BlobsToDelete) -join ',') | Should Be ($expected -join ',')
            $row = @($summary.Accounts)[0]
            $row.Status | Should Be 'DryRun'
            $row.RunbooksListed | Should Be 4
            $row.RunbooksExported | Should Be 3
            $row.LocalVerified | Should Be $true
            $row.Uploaded | Should Be $false
            $row.PreviousCount | Should Be 3
            $row.BackupBlob | Should Be 'automation/aa-identity-prod/20260917-023000Z.zip'
            $fresh = @($summary.Freshness)[0]
            $fresh.NewestBackup | Should Be (Get-TestBlobName -DaysAgo 1)
            $fresh.AgeHours | Should Be 24
            (Get-BackupRunFailureMessage -Summary $summary) | Should Be ''
            @($global:BarWorld.Downloads).Count | Should Be 1
            Get-WorkRootItemCount | Should Be 0
        }

        It 'uploads, restore-verifies, and prunes only its own old backups when live' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }

            $puts = @(Get-TestRequests -Method 'PUT')
            $puts.Count | Should Be 1
            $puts[0].Uri | Should Be 'https://stbackupexample.blob.core.windows.net/runbook-backups/automation/aa-identity-prod/20260917-023000Z.zip'
            $puts[0].Headers['If-None-Match'] | Should Be '*'
            $puts[0].Headers['x-ms-blob-type'] | Should Be 'BlockBlob'
            $puts[0].Headers['x-ms-meta-runbookcount'] | Should Be '3'
            $puts[0].ContentType | Should Be 'application/zip'

            $deleted = @(Get-TestRequests -Method 'DELETE' | ForEach-Object { [Uri]::UnescapeDataString(([Uri]$_.Uri).AbsolutePath.Substring('/runbook-backups/'.Length)) })
            (($deleted | Sort-Object) -join ',') | Should Be ((@((Get-TestBlobName -DaysAgo 40), (Get-TestBlobName -DaysAgo 50), (Get-TestBlobName -DaysAgo 60)) | Sort-Object) -join ',')
            foreach ($foreign in $foreignNames) { $global:BarWorld.Blobs.ContainsKey($foreign) | Should Be $true }
            foreach ($days in @(1, 2, 3, 4, 5, 6, 7)) { $global:BarWorld.Blobs.ContainsKey((Get-TestBlobName -DaysAgo $days)) | Should Be $true }

            ($global:BarWorld.Downloads -contains 'automation/aa-identity-prod/20260917-023000Z.zip') | Should Be $true
            $summary.DryRun | Should Be $false
            $summary.Done | Should Be 5
            $summary.Failed | Should Be 0
            $summary.Counts.VerifyBackup.Done | Should Be 1
            $row = @($summary.Accounts)[0]
            $row.Status | Should Be 'BackedUp'
            $row.RemoteVerified | Should Be $true
            $row.Deleted | Should Be 3
            @($summary.Freshness)[0].NewestBackup | Should Be 'automation/aa-identity-prod/20260917-023000Z.zip'
            @($summary.Freshness)[0].AgeHours | Should Be 0
            (Get-BackupRunFailureMessage -Summary $summary) | Should Be ''
            Get-WorkRootItemCount | Should Be 0

            # The stored package restores to the sources as the service returned them.
            $stored = Join-Path -Path $TestDrive -ChildPath 'stored.zip'
            [System.IO.File]::WriteAllBytes($stored, $global:BarWorld.Blobs['automation/aa-identity-prod/20260917-023000Z.zip'])
            $manifest = Read-BackupPackageManifest -ZipPath $stored
            $manifest.runbookCount | Should Be 3
            (@($manifest.runbooks | ForEach-Object { $_.path }) -join ',') | Should Be 'runbooks/Draw-Diagram.graphrunbook,runbooks/Invoke-GuestLifecycle.ps1,runbooks/Sync-Things.ps1'
            $sync = @($manifest.runbooks | Where-Object { $_.name -eq 'Sync-Things' })[0]
            $sync.runtimeVersion | Should Be '7.4'
            $sync.runtimeEnvironment | Should Be 'PowerShell-7.4'
            $sync.contentType | Should Be 'text/plain'
            @($manifest.runbooks | Where-Object { $_.name -eq 'Draw-Diagram' })[0].contentType | Should Be 'application/json; charset=utf-8'
            $manifest.runId | Should Be $runId
            $manifest.subscriptionId | Should Be $subscriptionId
            $manifest.resourceGroupName | Should Be 'rg-identity-automation'
            $manifest.automationApiVersion | Should Be '2024-10-23'
            foreach ($request in @($global:BarWorld.Requests | Where-Object { $_.Uri -like '*/Microsoft.Automation/*' })) {
                $request.Uri | Should Match ('^https://management\.azure\.com/subscriptions/{0}/resourceGroups/rg-identity-automation/providers/Microsoft\.Automation/automationAccounts/aa-identity-prod/runbooks' -f $subscriptionId)
            }
            $summary.AutomationApiVersion | Should Be '2024-10-23'
            $summary.DeleteCapTripped | Should Be $false
            $files = Expand-BackupPackage -ZipPath $stored -Destination (Join-Path -Path $TestDrive -ChildPath 'stored-out')
            # The graphical runbook came back as an application/json object
            # and is stored byte for byte as the service sent it.
            [System.IO.File]::ReadAllText((Join-Path -Path $TestDrive -ChildPath 'stored-out\runbooks\Draw-Diagram.graphrunbook')) | Should BeExactly $graphJson
            $files.Count | Should Be 4
            # The mock lists the whole container, so the only expected warning
            # is the one about names outside the prefix.
            (@(Get-RunLogEntries -Level Warn) | Where-Object { $_.Message -notlike '*blob(s) outside automation/aa-identity-prod/; they are ignored.' } | ForEach-Object { $_.Message }) -join "`n" | Should Be ''
        }

        It 'stops before any Automation or storage request when the subscription lookup has no id' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $global:BarWorld.SubscriptionId = ''
            # Resolve-ArmScope refuses the entry before a scope exists.
            { Invoke-TestRun -Overrides @{ DryRun = $false } } | Should Throw 'has no usable subscription id'
            $global:BarWorld.SubscriptionId = 'not-a-guid'
            { Invoke-TestRun -Overrides @{ DryRun = $false } } | Should Throw 'refusing to build a scope'
            # One subscription lookup per run, and nothing else.
            @($global:BarWorld.Requests).Count | Should Be 2
            foreach ($request in @($global:BarWorld.Requests)) { ([Uri]$request.Uri).AbsolutePath | Should Be '/subscriptions' }
            Get-WorkRootItemCount | Should Be 0
        }

        It 'records a delete that finds nothing as Skipped, not as a delete' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $gone = Get-TestBlobName -DaysAgo 50
            [void]$global:BarWorld.GoneOnDelete.Add($gone)
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }

            @(Get-TestRequests -Method 'DELETE').Count | Should Be 3
            $summary.Counts.DeleteBackup.Done | Should Be 2
            $summary.Counts.DeleteBackup.Skipped | Should Be 1
            $summary.Done | Should Be 4
            $summary.Skipped | Should Be 1
            $summary.FailureCount | Should Be 0
            $item = @($summary.Items | Where-Object { $_.Action -eq 'DeleteBackup' -and $_.Target -eq $gone })
            $item.Count | Should Be 1
            $item[0].Outcome | Should Be 'Skipped'
            $item[0].Detail | Should Match 'already gone \(HTTP 404\)'
            $row = @($summary.Accounts)[0]
            $row.Deleted | Should Be 2
            $row.DeleteSkipped | Should Be 1
            $row.DeleteFailed | Should Be 0
            $logText = (@(Get-RunLogEntries -Level Warn) | ForEach-Object { $_.Message }) -join "`n"
            $logText | Should Match ([regex]::Escape($gone) + ' was already gone')
            (Get-BackupRunFailureMessage -Summary $summary) | Should Be ''
        }

        It 'refuses a prefix that a URI parser would rewrite before any request' {
            foreach ($bad in @('automation.', 'backups/...', 'backups/automation.')) {
                Reset-TestWorld
                Set-StandardAccount
                Add-StandardBlobs
                $before = $global:BarWorld.Blobs.Count
                { Invoke-TestRun -Overrides @{ DryRun = $false; Prefix = $bad } } | Should Throw 'is not valid'
                @($global:BarWorld.Requests).Count | Should Be 0
                $global:BarWorld.Blobs.Count | Should Be $before
                Get-WorkRootItemCount | Should Be 0
            }
        }

        It 'backs up with the api-version it is given and records it' {
            Reset-TestWorld
            Set-TestAccount -Account $accountA -Runbooks @(
                (New-TestRunbook -Name 'Runbook-A'), (New-TestRunbook -Name 'Runbook-B'), (New-TestRunbook -Name 'Runbook-C')
            )
            $global:BarWorld.PageSize = 2
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false; AutomationApiVersion = '2023-11-01' }
            $summary.FailureCount | Should Be 0
            $summary.AutomationApiVersion | Should Be '2023-11-01'
            $armAutomation = @($global:BarWorld.Requests | Where-Object { $_.Uri -like '*/Microsoft.Automation/*' })
            $armAutomation.Count | Should Be 5
            foreach ($request in $armAutomation) { ([Uri]$request.Uri).Query | Should Match 'api-version=2023-11-01' }
            $stored = Join-Path -Path $TestDrive -ChildPath 'stored-api.zip'
            [System.IO.File]::WriteAllBytes($stored, $global:BarWorld.Blobs['automation/aa-identity-prod/20260917-023000Z.zip'])
            (Read-BackupPackageManifest -ZipPath $stored).automationApiVersion | Should Be '2023-11-01'
        }

        It 'fails the account with a hint when the api-version is not available' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $global:BarWorld.ListError['aa-identity-prod'] = @{ Status = 400; Code = 'NoRegisteredProviderFound' }
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false; Environment = 'USGov' }
            $summary.FailureCount | Should Be 1
            @($summary.Failures)[0].Action | Should Be 'BackupAccount'
            @($summary.Failures)[0].Detail | Should Match 'NoRegisteredProviderFound'
            @($summary.Failures)[0].Detail | Should Match 'set AutomationApiVersion'
            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
        }

        It 'warns when a text body looks like a quoted JSON string and keeps it as sent' {
            Reset-TestWorld
            $quoted = '"param()\r\nWrite-Output \"quoted\""'
            Set-TestAccount -Account $accountA -Runbooks @((New-TestRunbook -Name 'Quoted-Source' -Type 'PowerShell72')) -Content @{ 'Quoted-Source' = $quoted }
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }
            $summary.FailureCount | Should Be 0
            $warnings = @(Get-RunLogEntries -Level Warn | ForEach-Object { $_.Message })
            $warnings.Count | Should Be 1
            $warnings[0] | Should Match 'Quoted-Source came back as "text/plain" with a body that looks like a quoted JSON string'
            $stored = Join-Path -Path $TestDrive -ChildPath 'stored-quoted.zip'
            [System.IO.File]::WriteAllBytes($stored, $global:BarWorld.Blobs['automation/aa-identity-prod/20260917-023000Z.zip'])
            [void](Expand-BackupPackage -ZipPath $stored -Destination (Join-Path -Path $TestDrive -ChildPath 'stored-quoted-out'))
            [System.IO.File]::ReadAllText((Join-Path -Path $TestDrive -ChildPath 'stored-quoted-out\runbooks\Quoted-Source.ps1')) | Should BeExactly $quoted
        }

        It 'aborts an empty export before any write' {
            Reset-TestWorld
            Set-TestAccount -Account $accountA -Runbooks @((New-TestRunbook -Name 'New-Draft' -State 'New'))
            Add-StandardBlobs
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }

            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $summary.FailureCount | Should Be 1
            @($summary.Failures)[0].Action | Should Be 'BackupAccount'
            @($summary.Failures)[0].Detail | Should Match 'Empty export guard'
            @($summary.Accounts)[0].Status | Should Be 'Failed'
            $summary.DeletesPlanned | Should Be 0
            @($summary.Freshness)[0].NewestBackup | Should Be (Get-TestBlobName -DaysAgo 1)
            (Get-BackupRunFailureMessage -Summary $summary) | Should Match 'BackupAccount aa-identity-prod'
            Get-WorkRootItemCount | Should Be 0

            Reset-TestWorld
            Set-TestAccount -Account $accountA -Runbooks @()
            $again = Invoke-TestRun -Overrides @{ DryRun = $false }
            $again.FailureCount | Should Be 1
            @($again.Failures)[0].Detail | Should Match 'listed 0 runbook'
            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
        }

        It 'aborts when the runbook count shrank past the limit, and passes with a raised limit' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs -NewestCount 10
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }

            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $summary.FailureCount | Should Be 1
            @($summary.Failures)[0].Detail | Should Match 'Shrink guard'
            @($summary.Failures)[0].Detail | Should Match 'a drop of 70%, limit 25%'
            $row = @($summary.Accounts)[0]
            $row.Status | Should Be 'Failed'
            $row.PreviousCount | Should Be 10
            $row.DropPercent | Should Be 70
            Get-WorkRootItemCount | Should Be 0

            $global:BarWorld.Requests.Clear()
            $raised = Invoke-TestRun -Overrides @{ DryRun = $false; MaxShrinkPercent = 70 }
            $raised.FailureCount | Should Be 0
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
        }

        It 'walks back past an unreadable newest backup, and fails closed when none is readable' {
            Reset-TestWorld
            Set-StandardAccount
            Add-TestBlob -Name (Get-TestBlobName -DaysAgo 1)
            Add-TestBlob -Name (Get-TestBlobName -DaysAgo 2) -Bytes (New-TestBackupBytes -Count 3)
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true }
            $summary.FailureCount | Should Be 0
            @($summary.Accounts)[0].PreviousBackup | Should Be (Get-TestBlobName -DaysAgo 2)
            $summary.Warnings | Should BeGreaterThan 0

            Reset-TestWorld
            Set-StandardAccount
            foreach ($days in @(1, 2, 3, 4)) { Add-TestBlob -Name (Get-TestBlobName -DaysAgo $days) }
            $closed = Invoke-TestRun -Overrides @{ DryRun = $false }
            $closed.FailureCount | Should Be 1
            @($closed.Failures)[0].Detail | Should Match 'none of the newest 3 existing backup'
            @($global:BarWorld.Downloads).Count | Should Be 3
            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            Get-WorkRootItemCount | Should Be 0
        }

        It 'holds every delete back when the cap trips, still uploads and verifies, and fails the run' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $before = @($global:BarWorld.Blobs.Keys)
            $expected = @((Get-TestBlobName -DaysAgo 40), (Get-TestBlobName -DaysAgo 50), (Get-TestBlobName -DaysAgo 60))
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false; MaxDeletesPerRun = 2 }

            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            foreach ($name in $before) { $global:BarWorld.Blobs.ContainsKey($name) | Should Be $true }
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            $global:BarWorld.Blobs.ContainsKey('automation/aa-identity-prod/20260917-023000Z.zip') | Should Be $true
            $summary.Counts.VerifyBackup.Done | Should Be 1
            $summary.DeleteCapTripped | Should Be $true
            $summary.MaxDeletesPerRun | Should Be 2
            $summary.FailureCount | Should Be 1
            @($summary.Failures)[0].Action | Should Be 'DeleteCap'
            @($summary.Failures)[0].Target | Should Be '3 planned, cap 2'
            @($summary.Failures)[0].Detail | Should Match 'Delete cap tripped: 3 backup blob delete\(s\) planned across 1 account\(s\), MaxDeletesPerRun is 2'
            $summary.Counts.DeleteBackup.Skipped | Should Be 3
            $summary.Counts.DeleteBackup.Done | Should Be 0
            (@($summary.BlobsToDelete) -join ',') | Should Be ($expected -join ',')
            $summary.DeletesPlanned | Should Be 3
            $row = @($summary.Accounts)[0]
            $row.Status | Should Be 'BackedUp'
            $row.RetentionHeld | Should Be $true
            $row.Deleted | Should Be 0
            $row.DeleteSkipped | Should Be 3
            $row.Detail | Should Match 'retention held for 3 backup\(s\): delete cap tripped \(3 planned, cap 2\)'
            @($summary.Freshness)[0].AgeHours | Should Be 0
            (Get-BackupRunFailureMessage -Summary $summary) | Should Match 'DeleteCap 3 planned, cap 2'
            $summary.Errors | Should Be 1
            Get-WorkRootItemCount | Should Be 0
        }

        It 'reports what a dry run over the cap would delete, and fails it' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true; MaxDeletesPerRun = 2 }
            @(Get-TestRequests -Method 'PUT').Count | Should Be 0
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $summary.Counts.UploadBackup.Planned | Should Be 1
            $summary.Counts.DeleteBackup.Planned | Should Be 0
            $summary.Counts.DeleteBackup.Skipped | Should Be 3
            @($summary.BlobsToDelete).Count | Should Be 3
            @($summary.Accounts)[0].Status | Should Be 'DryRun'
            (Get-BackupRunFailureMessage -Summary $summary) | Should Match 'DeleteCap'
            (@(Get-RunLogEntries -Level Info) | Where-Object { $_.Message -like '*not deleting automation/aa-identity-prod/*delete cap tripped (3 planned, cap 2)*' }).Count | Should Be 3

            $atCap = Invoke-TestRun -Overrides @{ DryRun = $false; MaxDeletesPerRun = 3 }
            $atCap.DeleteCapTripped | Should Be $false
            $atCap.FailureCount | Should Be 0
            $atCap.Counts.DeleteBackup.Done | Should Be 3
        }

        It 'never prunes with a cap of 0, but still backs up and fails once a delete is due' {
            Reset-TestWorld
            Set-StandardAccount
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false; MaxDeletesPerRun = 0 }
            $summary.FailureCount | Should Be 0
            $summary.DeleteCapTripped | Should Be $false
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1

            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $held = Invoke-TestRun -Overrides @{ DryRun = $false; MaxDeletesPerRun = 0 }
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $held.DeleteCapTripped | Should Be $true
            @($held.Failures)[0].Action | Should Be 'DeleteCap'
            @($held.Accounts)[0].Status | Should Be 'BackedUp'
        }

        It 'adds planned deletes across accounts for the cap' {
            Reset-TestWorld
            Set-StandardAccount -Account $accountA
            Set-StandardAccount -Account $accountB
            Add-StandardBlobs
            Add-SecondAccountBlobs
            $over = Invoke-TestRun -Overrides @{ DryRun = $false; AutomationAccountNames = 'aa-identity-prod;aa-identity-dev'; MaxDeletesPerRun = 5 }
            @($over.Failures)[0].Detail | Should Match '6 backup blob delete\(s\) planned across 2 account\(s\), MaxDeletesPerRun is 5'
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            @(Get-TestRequests -Method 'PUT').Count | Should Be 2
            $over.AccountsBackedUp | Should Be 2
            @($over.BlobsToDelete).Count | Should Be 6
            (@($over.Accounts | ForEach-Object { $_.RetentionHeld }) -join ',') | Should Be 'True,True'

            Reset-TestWorld
            Set-StandardAccount -Account $accountA
            Set-StandardAccount -Account $accountB
            Add-StandardBlobs
            Add-SecondAccountBlobs
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true; AutomationAccountNames = 'aa-identity-prod; aa-identity-dev'; MaxDeletesPerRun = 6 }
            $summary.DeletesPlanned | Should Be 6
            $summary.AccountsDryRun | Should Be 2
            $summary.FailureCount | Should Be 0
        }

        It 'fails the account when the restored package does not match the manifest' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $global:BarWorld.Tamper = {
                param([string]$Name, [byte[]]$Bytes)
                if ($Name -ne 'automation/aa-identity-prod/20260917-023000Z.zip') { return , $Bytes }
                return , (Edit-TestZipEntry -Bytes $Bytes -EntryName 'runbooks/Sync-Things.ps1' -Text 'Write-Output "changed in storage"')
            }
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }

            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $summary.Counts.VerifyBackup.Failed | Should Be 1
            $summary.FailureCount | Should Be 1
            @($summary.Failures)[0].Detail | Should Match 'runbooks/Sync-Things.ps1 has SHA-256'
            $row = @($summary.Accounts)[0]
            $row.Status | Should Be 'Unverified'
            $row.RemoteVerified | Should Be $false
            $row.DeletesPlanned | Should Be 0
            $summary.DeletesPlanned | Should Be 0
            @($summary.Freshness)[0].NewestBackup | Should Be (Get-TestBlobName -DaysAgo 1)
            (Get-BackupRunFailureMessage -Summary $summary) | Should Match 'VerifyBackup'
            Get-WorkRootItemCount | Should Be 0
        }

        It 'removes the work folder when an export call fails, and never repeats an echoed token' {
            Reset-TestWorld
            Set-StandardAccount -Account $accountA
            Set-StandardAccount -Account $accountB
            Add-StandardBlobs
            Add-SecondAccountBlobs
            # The ARM 403 and the storage 403 both echo the bearer header.
            $global:BarWorld.ContentStatus['aa-identity-prod/Sync-Things'] = 403
            $denied = Get-TestBlobName -Prefix $prefixB -DaysAgo 55
            [void]$global:BarWorld.DenyDelete.Add($denied)
            $report = Join-Path -Path $TestDrive -ChildPath 'reports\token-check.csv'
            $run = Invoke-CapturedTestRun -Overrides @{ DryRun = $false; AutomationAccountNames = 'aa-identity-prod;aa-identity-dev'; ReportPath = $report }
            $summary = $run.Summary

            $summary.FailureCount | Should Be 2
            $exportFailure = @($summary.Failures | Where-Object { $_.Action -eq 'BackupAccount' })[0]
            $exportFailure.Detail | Should Match 'HTTP 403'
            $exportFailure.Detail | Should Match 'AuthorizationFailed'
            # The echo reached the message and was removed, so this is not
            # true by construction.
            $exportFailure.Detail | Should Match 'presenting Bearer \[redacted'
            $exportFailure.Detail.Contains($armToken) | Should Be $false
            $deleteFailure = @($summary.Failures | Where-Object { $_.Action -eq 'DeleteBackup' })[0]
            $deleteFailure.Target | Should Be $denied
            $deleteFailure.Detail | Should Match 'AuthorizationPermissionMismatch'
            $deleteFailure.Detail | Should Match 'presenting Bearer \[redacted'
            $deleteFailure.Detail.Contains($storageToken) | Should Be $false
            @($summary.Accounts)[0].Status | Should Be 'Failed'
            @($summary.Accounts)[1].DeleteFailed | Should Be 1
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1

            # Streams, report, and the serialised summary.
            $run.RecordCount | Should BeGreaterThan 10
            $run.Text | Should Match 'AuthorizationFailed'
            $run.Text | Should Match 'AuthorizationPermissionMismatch'
            $reportText = [System.IO.File]::ReadAllText($report)
            $reportText | Should Match 'AuthorizationFailed'
            $summaryText = ConvertTo-Json -InputObject $summary -Depth 8
            foreach ($secret in @($armToken, $storageToken, 'armsignature00000', 'storagesig0000000')) {
                $run.Text.Contains($secret) | Should Be $false
                $reportText.Contains($secret) | Should Be $false
                $summaryText.Contains($secret) | Should Be $false
            }
            Get-WorkRootItemCount | Should Be 0
        }

        It 'backs up one account when another fails' {
            Reset-TestWorld
            Set-StandardAccount -Account $accountA
            Set-TestAccount -Account $accountB -Runbooks @()
            Add-StandardBlobs
            Add-TestBlob -Name (Get-TestBlobName -Prefix $prefixB -DaysAgo 90)
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false; AutomationAccountNames = 'aa-identity-prod;AA-IDENTITY-DEV;aa-identity-prod' }
            $summary.AccountsRequested | Should Be 2
            $summary.AccountsBackedUp | Should Be 1
            $summary.AccountsFailed | Should Be 1
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            $global:BarWorld.Blobs.ContainsKey((Get-TestBlobName -Prefix $prefixB -DaysAgo 90)) | Should Be $true
            (@($summary.Accounts | ForEach-Object { $_.Status }) -join ',') | Should Be 'BackedUp,Failed'
            @($summary.Freshness)[1].AgeHours | Should Be 2160
        }

        It 'follows runbook list paging and writes the report' {
            Reset-TestWorld
            Set-TestAccount -Account $accountA -Runbooks @(
                (New-TestRunbook -Name 'Runbook-A'), (New-TestRunbook -Name 'Runbook-B'), (New-TestRunbook -Name 'Runbook-C'),
                (New-TestRunbook -Name 'Runbook-D'), (New-TestRunbook -Name 'Runbook-E')
            )
            $global:BarWorld.PageSize = 2
            $report = Join-Path -Path $TestDrive -ChildPath 'reports\runbook-backups.csv'
            # A local run may still pass the list as a JSON array.
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true; ReportPath = $report; AutomationAccountNames = '["aa-identity-prod"]' }
            @($summary.Accounts)[0].RunbooksExported | Should Be 5
            @(Get-TestRequests -Method 'GET' | Where-Object { $_.Uri -like '*/runbooks[?]*' }).Count | Should Be 3
            $rows = @(Import-Csv -LiteralPath $report)
            $rows.Count | Should Be 1
            $rows[0].AutomationAccount | Should Be 'aa-identity-prod'
            $rows[0].Status | Should Be 'DryRun'
            $rows[0].RunbooksExported | Should Be '5'
            $summary.ReportPath | Should Be $report
            @($summary.Freshness)[0].NewestBackup | Should Be ''
            @($global:BarWorld.Downloads).Count | Should Be 0
        }

        It 'uses the US Government endpoints and a subscription id without a lookup' {
            Reset-TestWorld
            Set-StandardAccount
            $summary = Invoke-TestRun -Overrides @{ DryRun = $true; Environment = 'USGov'; SubscriptionName = $subscriptionId }
            $summary.Environment | Should Be 'USGov'
            $summary.FailureCount | Should Be 0
            $hosts = @($global:BarWorld.Requests | ForEach-Object { ([Uri]$_.Uri).Host } | Sort-Object -Unique)
            ($hosts -join ',') | Should Be 'management.usgovcloudapi.net,stbackupexample.blob.core.usgovcloudapi.net'
            @($global:BarWorld.Requests | Where-Object { ([Uri]$_.Uri).AbsolutePath -eq '/subscriptions' }).Count | Should Be 0
        }

        It 'validates its parameters before touching anything' {
            Reset-TestWorld
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = '' } } | Should Throw 'AutomationAccountNames is empty'
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = ' ; , ;' } } | Should Throw 'AutomationAccountNames is empty'
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = '["aa-identity-prod",{"x":1}]' } } | Should Throw 'must be a JSON array of strings'
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = 'bad name' } } | Should Throw 'is not a valid Automation account name'
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = 'aa-identity-prod;aa identity dev' } } | Should Throw '"aa identity dev" is not a valid Automation account name'
            { Invoke-TestRun -Overrides @{ AutomationAccountNames = 'aa-identity-prod aa-identity-dev' } } | Should Throw 'is not a valid Automation account name'
            { Invoke-TestRun -Overrides @{ KeepAtLeast = 0 } } | Should Throw 'KeepAtLeast must be 1 or more'
            { Invoke-TestRun -Overrides @{ StorageAccountName = 'Bad_Name' } } | Should Throw 'is not a valid storage account name'
            { Invoke-TestRun -Overrides @{ Prefix = '../x' } } | Should Throw 'is not valid'
            { Invoke-TestRun -Overrides @{ Prefix = 'automation.' } } | Should Throw 'is not valid'
            { Invoke-TestRun -Overrides @{ MaxShrinkPercent = 101 } } | Should Throw 'between 0 and 100'
            { Invoke-TestRun -Overrides @{ AutomationApiVersion = 'latest' } } | Should Throw 'is not an api-version'
            { Invoke-TestRun -Overrides @{ AutomationApiVersion = '2024-10-23x' } } | Should Throw 'is not an api-version'
            @($global:BarWorld.Requests).Count | Should Be 0
            Get-WorkRootItemCount | Should Be 0
        }

        # A cell may leave automationapiversion blank to mean "not overridden".
        It 'uses the default api-version when the value is blank' {
            foreach ($blank in @('', '   ')) {
                Reset-TestWorld
                Set-StandardAccount
                $summary = Invoke-TestRun -Overrides @{ DryRun = $true; AutomationApiVersion = $blank }
                $summary.FailureCount | Should Be 0
                $summary.AutomationApiVersion | Should Be '2024-10-23'
                $armAutomation = @($global:BarWorld.Requests | Where-Object { $_.Uri -like '*/Microsoft.Automation/*' })
                $armAutomation.Count | Should Be 4
                foreach ($request in $armAutomation) { ([Uri]$request.Uri).Query | Should Match 'api-version=2024-10-23$' }
            }
        }

        It 'fails the account when the service reports another Content-MD5 for the upload' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $global:BarWorld.Md5OnGet = 'AAAAAAAAAAAAAAAAAAAAAA=='
            $summary = Invoke-TestRun -Overrides @{ DryRun = $false }
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 0
            $summary.Counts.VerifyBackup.Failed | Should Be 1
            @($summary.Failures)[0].Detail | Should Match 'the Content-MD5 the service reports is not the package'
            @($summary.Accounts)[0].Status | Should Be 'Unverified'
            Get-WorkRootItemCount | Should Be 0
        }

        It 'never writes a token to any stream on a clean run' {
            Reset-TestWorld
            Set-StandardAccount
            Add-StandardBlobs
            $run = Invoke-CapturedTestRun -Overrides @{ DryRun = $false }
            $run.Summary.FailureCount | Should Be 0
            # What the job would keep, not what the log helper stored.
            $run.Text | Should Match 'Verified: automation/aa-identity-prod/20260917-023000Z.zip'
            $run.Text | Should Match '\[ACTION\] run=00000000-0000-0000-0000-000000000000 Done: delete backup blob'
            foreach ($secret in @($armToken, $storageToken, 'armsignature00000', 'storagesig0000000')) {
                $run.Text.Contains($secret) | Should Be $false
            }
        }
    }

    Context 'run: an error that escapes' {
        # Only Invoke-HttpCore is mocked, so the escaping error is made the
        # way a caller could make one: with the warning preference at Stop,
        # the "already gone" warning of the publish phase, which is outside
        # any try block, ends the run. Preparation logs no warning here: the
        # container holds only well-formed backups of this account.
        It 'removes the work folder when an error escapes the run' {
            Reset-TestWorld
            Set-StandardAccount
            Add-TestBlob -Name (Get-TestBlobName -DaysAgo 1) -Bytes (New-TestBackupBytes -Count 3)
            foreach ($days in @(2, 3, 4, 5, 6, 7, 40)) { Add-TestBlob -Name (Get-TestBlobName -DaysAgo $days) }
            [void]$global:BarWorld.GoneOnDelete.Add((Get-TestBlobName -DaysAgo 40))
            $WarningPreference = 'Stop'
            try {
                # 3>$null keeps the host quiet; the preference still stops.
                { Invoke-TestRun -Overrides @{ DryRun = $false } 3>$null } | Should Throw 'WarningPreference'
            }
            finally { $WarningPreference = 'SilentlyContinue' }
            Get-WorkRootItemCount | Should Be 0
            @(Get-TestRequests -Method 'PUT').Count | Should Be 1
            @(Get-TestRequests -Method 'DELETE').Count | Should Be 1
            (@(Get-RunLogEntries -Level Warn) | ForEach-Object { $_.Message }) -join "`n" | Should Match 'was already gone when the delete ran'
            @(Get-RunLogEntries -Level Warn).Count | Should Be 1
        }
    }

    Context 'failure message' {
        It 'is empty without failures and names the failures otherwise' {
            Get-BackupRunFailureMessage -Summary ([PSCustomObject]@{ RunId = $runId; FailureCount = 0; Failures = @() }) | Should Be ''
            $failed = [PSCustomObject]@{ RunId = $runId; FailureCount = 2; Failures = @([PSCustomObject]@{ Action = 'BackupAccount'; Target = 'aa-identity-prod' }, [PSCustomObject]@{ Action = 'DeleteBackup'; Target = 'automation/x.zip' }) }
            $message = Get-BackupRunFailureMessage -Summary $failed
            $message | Should Match 'recorded 2 failure'
            $message | Should Match 'BackupAccount aa-identity-prod; DeleteBackup automation/x.zip'
            $message | Should Match $runId
        }
    }
}

Describe 'Backup-AutomationRunbooks file contract' {
    $begin = '# INLINE_LIBRARY_BEGIN'
    $end = '# INLINE_LIBRARY_END'
    $runbookText = [System.IO.File]::ReadAllText($runbook)
    $libraryText = [System.IO.File]::ReadAllText($library)

    function Get-TestAst {
        param([string]$Text)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        return [PSCustomObject]@{ Ast = $ast; Errors = @($errors) }
    }

    It 'is ASCII without a byte order mark and parses cleanly' {
        $bytes = [System.IO.File]::ReadAllBytes($runbook)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        $testBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $here -ChildPath 'Backup-AutomationRunbooks.Tests.ps1'))
        @($testBytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        (Get-TestAst -Text $runbookText).Errors.Count | Should Be 0
    }

    It 'carries each marker once, with the library dot-source between them' {
        $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
        $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
        $block = $begin + "`r`n. (Join-Path -Path `$PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')`r`n" + $end
        ($runbookText.Replace("`r`n", "`n")).Contains($block.Replace("`r`n", "`n")) | Should Be $true
    }

    # No pinned count: the library grows, and a clash is what matters.
    It 'defines no library function and documents every function it defines' {
        $mine = @((Get-TestAst -Text $runbookText).Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $theirs = @((Get-TestAst -Text $libraryText).Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $theirs.Count | Should BeGreaterThan 0
        foreach ($name in @('Invoke-HttpCore', 'Invoke-StorageRequest', 'Assert-StorageBlobName', 'New-StorageRequestHeaders')) { ($theirs -contains $name) | Should Be $true }
        $mine.Count | Should BeGreaterThan 0
        (@($mine | Where-Object { $theirs -contains $_.Name } | ForEach-Object { $_.Name }) -join ', ') | Should Be ''
        (@($mine | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name }) -join ', ') | Should Be ''
    }

    It 'sends every web request through the library core' {
        $ast = (Get-TestAst -Text $runbookText).Ast
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $webCommands = @('Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'curl', 'wget', 'Start-BitsTransfer', 'Invoke-HttpCore')
        (@($calls | Where-Object { $webCommands -contains $_ }) -join ', ') | Should Be ''
        ($runbookText -match 'System\.Net\.(WebClient|HttpWebRequest|Http\.)') | Should Be $false
        $runbookText.Contains('Invoke-BlobDownloadCore') | Should Be $false
        ($calls -contains 'Invoke-StorageRequest') | Should Be $true
        # The two requests the runbook builds itself still use the library's
        # retry loop: the upload and the raw content read.
        @($calls | Where-Object { $_ -eq 'Invoke-RunbookHttp' }).Count | Should Be 2
    }

    It 'binds only bool, int, and string parameters, with DryRun on by default' {
        $ast = (Get-TestAst -Text $runbookText).Ast
        $parameters = @($ast.ParamBlock.Parameters)
        $parameters.Count | Should Be 18
        $apiVersion = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AutomationApiVersion' })[0]
        $apiVersion.StaticType.Name | Should Be 'String'
        $apiVersion.DefaultValue.Extent.Text | Should Be "'2024-10-23'"
        # A job schedule may carry an empty value; the pattern lets it bind.
        $pattern = [string]@($apiVersion.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidatePattern' })[0].PositionalArguments[0].Value
        foreach ($good in @('', '2023-11-01', '2024-10-23', '2025-01-01-preview')) { ($good -match $pattern) | Should Be $true }
        foreach ($bad in @('latest', ' ', '2024-10-23 ', '2024-1-23')) { ($bad -match $pattern) | Should Be $false }
        $accounts = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AutomationAccountNames' })[0]
        $accounts.StaticType.Name | Should Be 'String'
        $maxDeletes = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MaxDeletesPerRun' })[0]
        $maxDeletes.StaticType.Name | Should Be 'Int32'
        (@($parameters | Where-Object { @('String', 'Int32', 'Boolean') -notcontains $_.StaticType.Name } | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ', ') | Should Be ''
        $dryRun = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' })[0]
        $dryRun.StaticType.Name | Should Be 'Boolean'
        $dryRun.DefaultValue.Extent.Text | Should Be '$true'
        (@($parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'input') | Should Be $false
        $runbookText.Contains('Write-Host') | Should Be $false
    }

    It 'documents every parameter and shows a local run with -AccessToken' {
        $help = (Get-TestAst -Text $runbookText).Ast.GetHelpContent()
        foreach ($parameter in @((Get-TestAst -Text $runbookText).Ast.ParamBlock.Parameters)) {
            $help.Parameters.ContainsKey($parameter.Name.VariablePath.UserPath.ToUpperInvariant()) | Should Be $true
        }
        ((@($help.Examples) -join "`n") -match '-AccessToken \$tokens') | Should Be $true
        ((@($help.Examples) -join "`n") -match "-AutomationAccountNames 'aa-identity-prod;aa-identity-dev'") | Should Be $true
        $help.Description | Should Match 'Graph application permissions: none'
        $help.Description | Should Match 'Recommended schedule'
        $help.Parameters['AUTOMATIONACCOUNTNAMES'] | Should Match 'semicolon-separated list'
        $help.Parameters['AUTOMATIONACCOUNTNAMES'] | Should Match 'local runs only'
        $help.Parameters['AUTOMATIONAPIVERSION'] | Should Match 'empty value\s+also means the default'
    }

    # The header's schedule and stack cell sample describe the corp cell, so
    # they are checked against it. Additions to the cell (another parameter,
    # another stack value) do not break this; a changed schedule or a
    # changed stack value does, and so does a cell key the runbook would not
    # bind.
    $corpCell = Join-Path -Path (Split-Path -Parent $automationRoot) -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'
    It 'agrees with the corp cell on the schedule and the stack cell entry' -Skip:(-not (Test-Path -LiteralPath $corpCell)) {
        function Get-TestHclBlock {
            param([string]$Text, [string]$OpeningPattern)
            $match = [regex]::Match($Text, $OpeningPattern)
            if (-not $match.Success) { return '' }
            $start = $match.Index
            $depth = 0
            for ($i = $start; $i -lt $Text.Length; $i++) {
                if ($Text[$i] -eq '{') { $depth++ }
                elseif ($Text[$i] -eq '}') {
                    $depth--
                    if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) }
                }
            }
            return ''
        }
        function Get-TestHclPairs {
            param([string]$Block, [string]$Name)
            $inner = Get-TestHclBlock -Text $Block -OpeningPattern ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*\{')
            $pairs = @{}
            foreach ($line in $inner.Split("`n")) {
                if ($line -match '^\s*([a-z_]+)\s*=\s*"([^"]*)"\s*$') { $pairs[$Matches[1]] = $Matches[2] }
            }
            return $pairs
        }

        $cell = [System.IO.File]::ReadAllText($corpCell).Replace("`r`n", "`n")
        $text = $runbookText.Replace("`r`n", "`n")
        $cellEntry = Get-TestHclBlock -Text $cell -OpeningPattern '(?m)^\s*runbook-backup\s*=\s*\{'
        $sample = Get-TestHclBlock -Text $text -OpeningPattern '(?m)^\s*runbook-backup\s*=\s*\{'
        $cellEntry | Should Match 'file\s*=\s*"Backup-AutomationRunbooks\.ps1"'
        $sample | Should Match 'file\s*=\s*"Backup-AutomationRunbooks\.ps1"'

        $scheduleKey = ''
        if ($cellEntry -match 'schedule_key\s*=\s*"([^"]+)"') { $scheduleKey = $Matches[1] }
        $scheduleKey | Should Not BeNullOrEmpty
        ($sample -match ('schedule_key\s*=\s*"' + [regex]::Escape($scheduleKey) + '"')) | Should Be $true
        $schedules = Get-TestHclBlock -Text $cell -OpeningPattern '(?m)^\s*schedules\s*=\s*\{'
        $schedule = Get-TestHclBlock -Text $schedules -OpeningPattern ('(?m)^\s*' + [regex]::Escape($scheduleKey) + '\s*=\s*\{')
        $schedule | Should Match 'frequency\s*=\s*"Day"'
        $time = ''
        if ($schedule -match 'start_time\s*=\s*"\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}):00Z"') { $time = $Matches[1] }
        $time | Should Not BeNullOrEmpty
        ($text -match ('every day at\s+' + [regex]::Escape($time) + ' UTC on its ' + [regex]::Escape($scheduleKey) + ' schedule')) | Should Be $true

        $declared = @((Get-TestAst -Text $runbookText).Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() })
        $sampleStack = Get-TestHclPairs -Block $sample -Name 'stack_parameters'
        $cellStack = Get-TestHclPairs -Block $cellEntry -Name 'stack_parameters'
        $sampleStack.Count | Should Be 5
        foreach ($key in $sampleStack.Keys) { $cellStack[$key] | Should Be $sampleStack[$key] }
        $sampleParameters = Get-TestHclPairs -Block $sample -Name 'parameters'
        $cellParameters = Get-TestHclPairs -Block $cellEntry -Name 'parameters'
        foreach ($key in $sampleParameters.Keys) { $cellParameters[$key] | Should Be $sampleParameters[$key] }
        foreach ($key in @($cellStack.Keys) + @($cellParameters.Keys) + @($sampleParameters.Keys) + @('automationapiversion')) {
            ('{0} is a runbook parameter: {1}' -f $key, ($declared -contains $key)) | Should Be ('{0} is a runbook parameter: True' -f $key)
        }
        ($text -match '#\s*automationapiversion\s*=\s*"2023-11-01"') | Should Be $true
    }

    It 'runs its entry point from disk with the dot-source between the markers' {
        $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'repo\automation\runbooks'
        $libDir = Join-Path -Path $TestDrive -ChildPath 'repo\automation\lib'
        New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
        $copy = Join-Path -Path $runbooksDir -ChildPath 'Backup-AutomationRunbooks.ps1'
        Copy-Item -Path $runbook -Destination $copy
        # An invalid account name stops the run inside the run function, after
        # the library has loaded and before any request, so this stays offline.
        { & $copy -AutomationAccountNames 'not valid!' -ResourceGroupName 'rg-identity-automation' -SubscriptionName 'Identity Automation' -StorageAccountName 'stbackupexample' -AccessToken 'local-disk-token-0000' -Verbose:$false 4>$null } | Should Throw 'is not a valid Automation account name'
    }

    # The entry point end to end, from disk and offline. The token table has
    # no Storage entry, so the account's first storage call fails inside
    # preparation before any request is built, and the subscription id skips
    # the lookup: the run records one failure without touching the network.
    # The summary must reach the output before the entry point throws.
    It 'emits its summary and then throws when the run recorded a failure' {
        $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'repo-failing\automation\runbooks'
        $libDir = Join-Path -Path $TestDrive -ChildPath 'repo-failing\automation\lib'
        New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
        $copy = Join-Path -Path $runbooksDir -ChildPath 'Backup-AutomationRunbooks.ps1'
        Copy-Item -Path $runbook -Destination $copy
        Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
        Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

        $armOnly = '{"Arm":"arm-only-token-0000"}'
        $emitted = New-Object System.Collections.ArrayList
        $caught = $null
        try {
            & $copy -AutomationAccountNames 'aa-identity-prod' -ResourceGroupName 'rg-identity-automation' -SubscriptionName '33333333-3333-3333-3333-333333333333' -StorageAccountName 'stbackupexample' -AccessToken $armOnly -RunId '00000000-0000-0000-0000-000000000000' 4>$null 3>$null 2>$null | ForEach-Object { [void]$emitted.Add($_) }
        }
        catch { $caught = $_ }

        $emitted.Count | Should Be 1
        $summary = $emitted[0]
        $summary.Runbook | Should Be 'Backup-AutomationRunbooks'
        $summary.RunId | Should Be '00000000-0000-0000-0000-000000000000'
        $summary.DryRun | Should Be $true
        $summary.AutomationApiVersion | Should Be '2024-10-23'
        $summary.FailureCount | Should Be 1
        @($summary.Failures)[0].Action | Should Be 'BackupAccount'
        @($summary.Failures)[0].Detail | Should Match 'no entry for Storage'
        @($summary.Accounts)[0].Status | Should Be 'Failed'
        $caught | Should Not BeNullOrEmpty
        $caught.Exception.Message | Should Match 'Backup-AutomationRunbooks recorded 1 failure\(s\): BackupAccount aa-identity-prod\. '
        $caught.Exception.Message | Should Match 'run 00000000-0000-0000-0000-000000000000'
        (ConvertTo-Json -InputObject $summary -Depth 8).Contains('arm-only-token-0000') | Should Be $false
    }

    It 'runs when assembled the way Terraform inlines library_path' {
        $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
        $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
        $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail
        $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
        $assembled.Contains('function Invoke-RunbookHttp') | Should Be $true
        (Get-TestAst -Text $assembled).Errors.Count | Should Be 0

        $published = Join-Path -Path $TestDrive -ChildPath 'published\Backup-AutomationRunbooks.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
        [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))
        { & $published -AutomationAccountNames 'aa-identity-prod;not valid!' -ResourceGroupName 'rg-identity-automation' -SubscriptionName 'Identity Automation' -StorageAccountName 'stbackupexample' -Environment USGov -AccessToken 'published-token-0000' 4>$null } | Should Throw 'is not a valid Automation account name'
    }
}

Remove-Variable -Name BarWorld, BarDownloadCalls -Scope Global -ErrorAction SilentlyContinue
