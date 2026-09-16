<#
.SYNOPSIS
    Reads live PIM eligibilities (Azure resource roles and Entra directory
    roles) and emits Terraform import blocks addressed to this repository's
    stacks, plus values skeletons, so an existing tenant can be adopted with a
    zero-change plan.

.DESCRIPTION
    Two sides, two output folders:

      azure-pim-governance/imports.tf
      azure-pim-governance/values.skeleton.hcl
          From Azure Resource Manager roleEligibilityScheduleInstances at each
          management group and subscription named on the command line. Import
          blocks target module.pim_eligible_assignment.azurerm_pim_eligible_role_assignment.this["<key>"]
          inside stacks/azure-pim-governance, with the provider's composite ID
          "{scope}|{roleDefinitionId}|{principalId}". Role names, group display
          names, and scope display names come from the instance's
          expandedProperties, so the skeleton never contains a GUID.

      entra-pim-governance/imports.tf
      entra-pim-governance/values.skeleton.hcl
          From Microsoft Graph roleManagement/directory/roleEligibilityScheduleInstances.
          Import blocks target module.eligibility.azuread_directory_role_eligibility_schedule_request.this["<key>"]
          inside stacks/entra-pim-governance. azuread 3.x imports that resource
          by the ID of the eligibility schedule REQUEST, not the schedule or the
          instance, so the script resolves each instance's roleEligibilityScheduleId
          to its provisioning request through roleEligibilityScheduleRequests
          (filter targetScheduleId). When Graph no longer holds the request the
          block is emitted commented out with a note, never with a made-up ID;
          that eligibility is recreated by Terraform on the first apply, which
          the plan will show as one add and one remove of an equivalent object.

    The eligibility ID rotation problem. PIM stores an eligibility as a
    schedule with its own GUID. When a time-bound eligibility is renewed or
    extended in the portal, PIM does not edit the schedule in place; it
    creates a new schedule with a new GUID and retires the old one. A tenant
    whose eligibilities expire annually therefore rotates every schedule ID
    once a year, on dates nobody in the repository chose. The azurerm resource
    looks itself up by (scope, role, principal), so a plan reconciles quietly,
    but a naive import generator run right after a renewal would import the
    new schedule for an object Terraform already manages under the old one.

    Recommended sequence:
      1. terragrunt apply -refresh-only in the cell, so state catches up with
         renewed schedules and nothing in Azure changes.
      2. Run this script. Pass -AzureCellPath and -EntraCellPath so entries
         already in the cell keep their existing keys and only new objects
         get generated ones.
      3. Merge the skeleton entries you want into the cell, drop imports.tf
         beside its terragrunt.hcl (root.hcl picks it up), and plan. Expect
         0 to add, 0 to change, 0 to destroy (tests/README.md).
      4. Apply (records the imports only), then delete imports.tf.

    Only eligibilities whose principal is a group are emitted as entries; the
    modules refuse users and service principals by design, so those appear
    as comments for the reviewer. Hop-1 PIM for Groups eligibilities
    (azuread_privileged_access_group_eligibility_schedule) are out of scope
    here; the module README documents their import ID shape.

    Tokens: the script uses, in order, a token passed on the command line,
    an existing Az.Accounts context (Get-AzAccessToken), or the Azure CLI
    (az account get-access-token). Token values are never printed.

.PARAMETER ManagementGroupNames
    Display names of management groups whose eligibilities to read.

.PARAMETER SubscriptionNames
    Display names of subscriptions whose eligibilities to read.

.PARAMETER SkipAzure
    Do not read Azure resource role eligibilities.

.PARAMETER SkipEntra
    Do not read Entra directory role eligibilities.

.PARAMETER Environment
    National cloud: Global (default) or USGov. Selects the ARM and Graph base
    URLs and token resources.

.PARAMETER OutputDirectory
    Where the two cell folders are written. Default: .\out (git-ignored).

.PARAMETER AzureModuleAddress
    Terraform address of the eligible-assignment module inside the Azure
    stack. Default module.pim_eligible_assignment.

.PARAMETER EntraModuleAddress
    Terraform address of the eligibility module inside the Entra stack.
    Default module.eligibility.

.PARAMETER AzureCellPath
    Optional path to an existing tenants/azure/<tenant>/azure-pim-governance/terragrunt.hcl.
    Entries already present keep their keys.

.PARAMETER EntraCellPath
    Optional path to an existing tenants/azure/<tenant>/entra-pim-governance/terragrunt.hcl.

.PARAMETER ArmAccessToken
    Local testing only: an ARM access token obtained by the caller.

.PARAMETER GraphAccessToken
    Local testing only: a Graph access token obtained by the caller.

.EXAMPLE
    az login
    .\Export-PimEligibilityImports.ps1 -ManagementGroupNames 'mg-example-root' -SubscriptionNames 'sub-example-prod','sub-example-nonprod' `
        -AzureCellPath ..\tenants\azure\corp\azure-pim-governance\terragrunt.hcl `
        -EntraCellPath ..\tenants\azure\corp\entra-pim-governance\terragrunt.hcl

.EXAMPLE
    .\Export-PimEligibilityImports.ps1 -SkipAzure -Environment USGov -OutputDirectory .\out

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible; no modules required.
    ARM: Reader at each scope (roleEligibilityScheduleInstances/read is in the
    Reader role). Graph: RoleEligibilitySchedule.Read.Directory (instances)
    and RoleEligibilitySchedule.ReadWrite.Directory or RoleManagement.Read.Directory
    (requests), read-only throughout.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$ManagementGroupNames = @(),

    [string[]]$SubscriptionNames = @(),

    [switch]$SkipAzure,

    [switch]$SkipEntra,

    [ValidateSet('Global', 'USGov')]
    [string]$Environment = 'Global',

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path -Path (Get-Location) -ChildPath 'out'),

    [ValidateNotNullOrEmpty()]
    [string]$AzureModuleAddress = 'module.pim_eligible_assignment',

    [ValidateNotNullOrEmpty()]
    [string]$EntraModuleAddress = 'module.eligibility',

    [string]$AzureCellPath = '',

    [string]$EntraCellPath = '',

    [string]$ArmAccessToken = '',

    [string]$GraphAccessToken = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:RunLog = New-Object System.Collections.ArrayList
$script:RunId = [Guid]::NewGuid().ToString()

# ---------------------------------------------------------------------------
# Logging. Same shape as the runbooks; Info goes to the console because this
# is a workstation script.
# ---------------------------------------------------------------------------

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

    $line = '{0} [{1}] {2}' -f $entry.Timestamp, $Level.ToUpperInvariant(), $Message
    switch ($Level) {
        'Warn' { Write-Warning -Message $line }
        'Error' {
            $ErrorActionPreference = 'Continue'
            Write-Error -Message $line
        }
        default { Write-Host $line }
    }
}

# ---------------------------------------------------------------------------
# Tokens. Command line, Az.Accounts, Azure CLI. Never printed.
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

function Get-ScopedAccessToken {
    param(
        [Parameter(Mandatory = $true)][string]$Resource,
        [AllowEmptyString()][string]$SuppliedToken = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SuppliedToken)) {
        Write-RunLog -Level Info -Message ('Token for {0}: supplied by the caller.' -f $Resource)
        return $SuppliedToken
    }

    if (Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue) {
        $context = $null
        try { $context = Get-AzContext -ErrorAction SilentlyContinue } catch { $context = $null }
        if ($context) {
            $result = Get-AzAccessToken -ResourceUrl $Resource
            $token = $result.Token
            if ($token -is [System.Security.SecureString]) { $token = ConvertFrom-SecureStringToPlain -Value $token }
            Write-RunLog -Level Info -Message ('Token for {0}: Az.Accounts context.' -f $Resource)
            return [string]$token
        }
    }

    if (Get-Command -Name az -ErrorAction SilentlyContinue) {
        $token = & az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($token | Out-String))) {
            Write-RunLog -Level Info -Message ('Token for {0}: Azure CLI.' -f $Resource)
            return ([string]($token | Select-Object -First 1)).Trim()
        }
    }

    throw ('No credential source for {0}. Run az login, Connect-AzAccount, or pass the token parameter.' -f $Resource)
}

# ---------------------------------------------------------------------------
# Transport with retries on 429 and 5xx.
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

function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Token,
        [ValidateRange(1, 10)][int]$MaxAttempts = 5
    )

    $headers = @{ Authorization = 'Bearer ' + $Token; Accept = 'application/json' }
    $attempt = 0
    while ($true) {
        $attempt++
        $result = Invoke-RestCall -Method 'GET' -Uri $Uri -Headers $headers -Body $null
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
            Write-RunLog -Level Warn -Message ('GET {0} returned HTTP {1}; retrying in {2}s (attempt {3} of {4}).' -f $Uri, $status, $wait, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $wait
            continue
        }

        throw ('GET {0} failed with HTTP {1} after {2} attempt(s): {3}' -f $Uri, $status, $attempt, (ConvertTo-SafeErrorText -Content $result.Content))
    }
}

function Invoke-PagedGet {
    <# Follows nextLink (ARM) or @odata.nextLink (Graph). #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $results = New-Object System.Collections.ArrayList
    $next = $Uri
    while ($next) {
        $page = Invoke-ApiRequest -Uri $next -Token $Token
        if ($null -eq $page) { break }
        $value = $page.PSObject.Properties['value']
        if ($null -ne $value) {
            foreach ($item in @($value.Value)) { if ($null -ne $item) { [void]$results.Add($item) } }
        }
        else {
            [void]$results.Add($page)
        }
        $next = $null
        foreach ($name in @('@odata.nextLink', 'nextLink')) {
            $prop = $page.PSObject.Properties[$name]
            if ($prop -and $prop.Value) { $next = [string]$prop.Value; break }
        }
    }
    return $results.ToArray()
}

function Invoke-ArmGetAll {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -match '^https://') { $uri = $Path } else { $uri = $script:ArmBaseUri + '/' + $Path.TrimStart('/') }
    return @(Invoke-PagedGet -Uri $uri -Token $script:ArmToken)
}

function Invoke-GraphGetAll {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -match '^https://') { $uri = $Path } else { $uri = $script:GraphBaseUri + '/v1.0/' + $Path.TrimStart('/') }
    return @(Invoke-PagedGet -Uri $uri -Token $script:GraphToken)
}

# ---------------------------------------------------------------------------
# HCL helpers, shared with the other export scripts.
# ---------------------------------------------------------------------------

function ConvertTo-LogicalKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    $key = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrEmpty($key)) { $key = 'unnamed' }
    return $key
}

function Get-UniqueKey {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][hashtable]$Used
    )

    $candidate = $Key
    $n = 1
    while ($Used.ContainsKey($candidate)) {
        $n++
        $candidate = "$Key-$n"
    }
    $Used[$candidate] = $true
    return $candidate
}

function Format-HclString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return 'null' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-HclBlock {
    <# Returns the text of "<name> = { ... }" at any depth in an HCL file, or
       $null. Brace matching ignores braces inside strings, which the cells in
       this repository do not contain. #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = [regex]::Match($Text, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*\{')
    if (-not $match.Success) { return $null }
    $start = $match.Index + $match.Length - 1
    $depth = 0
    for ($i = $start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) }
        }
    }
    throw ('Unbalanced braces in the {0} block.' -f $Name)
}

function Get-HclMapEntries {
    <# Splits the body of a map block into (key, body) pairs at depth one. #>
    param([Parameter(Mandatory = $true)][string]$Block)

    $entries = New-Object System.Collections.ArrayList
    $body = $Block.Substring(1, $Block.Length - 2)
    $pattern = '(?m)^\s*"?([A-Za-z0-9_-]+)"?\s*=\s*\{'
    $position = 0
    while ($true) {
        $m = [regex]::Match($body.Substring($position), $pattern)
        if (-not $m.Success) { break }
        $keyName = $m.Groups[1].Value
        $braceStart = $position + $m.Index + $m.Length - 1
        $depth = 0
        $end = -1
        for ($i = $braceStart; $i -lt $body.Length; $i++) {
            $ch = $body[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        if ($end -lt 0) { throw ('Unbalanced braces in entry {0}.' -f $keyName) }
        [void]$entries.Add(@{ Key = $keyName; Body = $body.Substring($braceStart, $end - $braceStart + 1) })
        $position = $end + 1
    }
    return $entries.ToArray()
}

function Get-HclStringAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $m = [regex]::Match($Body, '(?m)(?<![A-Za-z0-9_])' + [regex]::Escape($Name) + '\s*=\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Replace('\"', '"').Replace('\\', '\')
}

function Get-AzureCellKeys {
    <# "<type>/<scope name>|<role>|<group>" -> existing key, from an
       azure-pim-governance cell. #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $keys = @{}
    $text = [System.IO.File]::ReadAllText($Path)
    $block = Get-HclBlock -Text $text -Name 'eligibilities'
    if ($null -eq $block) {
        Write-RunLog -Level Warn -Message ('No eligibilities block found in {0}; every key will be generated.' -f $Path)
        return $keys
    }
    foreach ($entry in @(Get-HclMapEntries -Block $block)) {
        $group = Get-HclStringAttribute -Body $entry.Body -Name 'group_display_name'
        $role = Get-HclStringAttribute -Body $entry.Body -Name 'role_name'
        $scopeBlock = Get-HclBlock -Text $entry.Body -Name 'scope'
        if (-not $group -or -not $role -or -not $scopeBlock) { continue }
        $type = Get-HclStringAttribute -Body $scopeBlock -Name 'type'
        $name = Get-HclStringAttribute -Body $scopeBlock -Name 'name'
        if (-not $type -or -not $name) { continue }
        $keys[('{0}/{1}|{2}|{3}' -f $type, $name, $role, $group).ToLowerInvariant()] = $entry.Key
    }
    return $keys
}

function Get-EntraCellKeys {
    <# "<role>|<group>|<scope>" -> existing key, from an entra-pim-governance cell. #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $keys = @{}
    $text = [System.IO.File]::ReadAllText($Path)
    $block = Get-HclBlock -Text $text -Name 'directory_role_eligibilities'
    if ($null -eq $block) {
        Write-RunLog -Level Warn -Message ('No directory_role_eligibilities block found in {0}; every key will be generated.' -f $Path)
        return $keys
    }
    foreach ($entry in @(Get-HclMapEntries -Block $block)) {
        $role = Get-HclStringAttribute -Body $entry.Body -Name 'role_display_name'
        $group = Get-HclStringAttribute -Body $entry.Body -Name 'group_display_name'
        $scope = Get-HclStringAttribute -Body $entry.Body -Name 'directory_scope_id'
        if (-not $scope) { $scope = '/' }
        if (-not $role -or -not $group) { continue }
        $keys[('{0}|{1}|{2}' -f $role, $group, $scope).ToLowerInvariant()] = $entry.Key
    }
    return $keys
}

# ---------------------------------------------------------------------------
# Azure side.
# ---------------------------------------------------------------------------

function Resolve-AzureScopes {
    <# Display names to scope IDs. Fails on a name that does not resolve, and
       on a display name that matches more than one object. #>
    param(
        [AllowNull()][string[]]$ManagementGroupNames,
        [AllowNull()][string[]]$SubscriptionNames
    )

    $scopes = New-Object System.Collections.ArrayList

    if ($ManagementGroupNames -and @($ManagementGroupNames).Count -gt 0) {
        $groups = @(Invoke-ArmGetAll -Path 'providers/Microsoft.Management/managementGroups?api-version=2021-04-01')
        foreach ($name in $ManagementGroupNames) {
            $found = @($groups | Where-Object { [string]$_.properties.displayName -eq $name })
            if ($found.Count -eq 0) { throw ('Management group "{0}" was not found by display name.' -f $name) }
            if ($found.Count -gt 1) { throw ('Management group display name "{0}" is ambiguous ({1} matches).' -f $name, $found.Count) }
            [void]$scopes.Add(@{ Type = 'management_group'; Name = $name; Id = [string]$found[0].id })
        }
    }

    if ($SubscriptionNames -and @($SubscriptionNames).Count -gt 0) {
        $subscriptions = @(Invoke-ArmGetAll -Path 'subscriptions?api-version=2022-12-01')
        foreach ($name in $SubscriptionNames) {
            $found = @($subscriptions | Where-Object { [string]$_.displayName -eq $name })
            if ($found.Count -eq 0) { throw ('Subscription "{0}" was not found by display name.' -f $name) }
            if ($found.Count -gt 1) { throw ('Subscription display name "{0}" is ambiguous ({1} matches).' -f $name, $found.Count) }
            [void]$scopes.Add(@{ Type = 'subscription'; Name = $name; Id = [string]$found[0].id })
        }
    }

    return $scopes.ToArray()
}

function Get-AzureEligibilities {
    <# Direct, provisioned eligibility instances exactly at each scope. #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Scopes)

    $rows = New-Object System.Collections.ArrayList
    foreach ($scope in $Scopes) {
        $instances = @(Invoke-ArmGetAll -Path ('{0}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=atScope()' -f $scope.Id))
        foreach ($instance in $instances) {
            $p = $instance.properties
            if ([string]$p.scope -ne $scope.Id) { continue }
            if ([string]$p.memberType -ne 'Direct') { continue }
            if ([string]$p.status -ne 'Provisioned') { continue }

            $roleName = ''
            $principalName = ''
            $ex = $p.PSObject.Properties['expandedProperties']
            if ($ex -and $ex.Value) {
                if ($ex.Value.roleDefinition) { $roleName = [string]$ex.Value.roleDefinition.displayName }
                if ($ex.Value.principal) { $principalName = [string]$ex.Value.principal.displayName }
            }

            [void]$rows.Add([PSCustomObject]@{
                    ScopeType        = $scope.Type
                    ScopeName        = $scope.Name
                    ScopeId          = $scope.Id
                    RoleName         = $roleName
                    RoleDefinitionId = [string]$p.roleDefinitionId
                    PrincipalId      = [string]$p.principalId
                    PrincipalType    = [string]$p.principalType
                    PrincipalName    = $principalName
                    StartDateTime    = [string]$p.startDateTime
                    EndDateTime      = [string]$p.endDateTime
                    InstanceId       = [string]$instance.id
                })
        }
        Write-RunLog -Level Info -Message ('{0} "{1}": {2} instance(s) read.' -f $scope.Type, $scope.Name, $instances.Count)
    }
    return $rows.ToArray()
}

function Get-DurationDays {
    param([AllowEmptyString()][string]$Start, [AllowEmptyString()][string]$End)

    if ([string]::IsNullOrWhiteSpace($End)) { return $null }
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $endDate = [DateTime]::Parse($End, [Globalization.CultureInfo]::InvariantCulture, $styles)
    $startDate = [DateTime]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace($Start)) { $startDate = [DateTime]::Parse($Start, [Globalization.CultureInfo]::InvariantCulture, $styles) }
    return [int][Math]::Max(1, [Math]::Round(($endDate - $startDate).TotalDays))
}

function Write-AzureOutputs {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][hashtable]$ExistingKeys,
        [Parameter(Mandatory = $true)][string]$ModuleAddress,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $generatedOn = Get-Date -Format 'yyyy-MM-dd'
    $imports = New-Object System.Text.StringBuilder
    $values = New-Object System.Text.StringBuilder
    $used = @{}
    foreach ($k in $ExistingKeys.Values) { $used[$k] = $true }

    [void]$imports.AppendLine("# Generated by scripts/Export-PimEligibilityImports.ps1 on $generatedOn (Azure resource roles).")
    [void]$imports.AppendLine("# Run 'terragrunt apply -refresh-only' in the cell BEFORE trusting these IDs; see the script header.")
    [void]$imports.AppendLine("# Place beside the azure-pim-governance terragrunt.hcl. Delete after the first successful apply.")
    [void]$imports.AppendLine("")

    [void]$values.AppendLine("# Generated by scripts/Export-PimEligibilityImports.ps1 on $generatedOn (Azure resource roles).")
    [void]$values.AppendLine("# Merge into the eligibilities block of the azure-pim-governance cell. Review every value.")
    [void]$values.AppendLine("# duration_days counts from the apply date, so expect the first plan to reconcile end dates.")
    [void]$values.AppendLine("# Every (scope, role) below also needs an entry in policies; the stack refuses one without it.")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("eligibilities = {")

    $emitted = 0
    $skipped = 0
    foreach ($row in ($Rows | Sort-Object -Property ScopeType, ScopeName, RoleName, PrincipalName)) {
        if ($row.PrincipalType -ne 'Group') {
            $skipped++
            [void]$imports.AppendLine(('# Skipped: {0} principal {1} ({2}) is eligible for "{3}" at {4} "{5}". The module manages groups only.' -f $row.PrincipalType, $row.PrincipalName, $row.PrincipalId, $row.RoleName, $row.ScopeType, $row.ScopeName))
            [void]$imports.AppendLine("")
            continue
        }

        $lookup = ('{0}/{1}|{2}|{3}' -f $row.ScopeType, $row.ScopeName, $row.RoleName, $row.PrincipalName).ToLowerInvariant()
        if ($ExistingKeys.ContainsKey($lookup)) { $key = $ExistingKeys[$lookup]; $reused = $true }
        else {
            $key = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name ('{0} {1} {2}' -f $row.PrincipalName, $row.RoleName, $row.ScopeName)) -Used $used
            $reused = $false
        }

        $importId = '{0}|{1}|{2}' -f $row.ScopeId, $row.RoleDefinitionId, $row.PrincipalId
        [void]$imports.AppendLine("import {")
        [void]$imports.AppendLine("  to = $ModuleAddress.azurerm_pim_eligible_role_assignment.this[$(Format-HclString -Value $key)]")
        [void]$imports.AppendLine("  id = $(Format-HclString -Value $importId)")
        [void]$imports.AppendLine("}")
        [void]$imports.AppendLine("")

        if ($reused) {
            [void]$values.AppendLine(('  # {0}: already in the cell; import only.' -f $key))
            continue
        }

        $days = Get-DurationDays -Start $row.StartDateTime -End $row.EndDateTime
        [void]$values.AppendLine("  $(Format-HclString -Value $key) = {")
        [void]$values.AppendLine("    group_display_name = $(Format-HclString -Value $row.PrincipalName)")
        [void]$values.AppendLine("    role_name          = $(Format-HclString -Value $row.RoleName)")
        [void]$values.AppendLine("    scope              = { type = $(Format-HclString -Value $row.ScopeType), name = $(Format-HclString -Value $row.ScopeName) }")
        [void]$values.AppendLine("    justification      = `"CHANGEME: why this group holds this role at this scope, for the reviewer.`"")
        if ($null -eq $days) {
            [void]$values.AppendLine("    expiration         = { permanent = true } # the policy for this (scope, role) must set expiration_required = false")
        }
        elseif ($days -gt 365) {
            [void]$values.AppendLine("    expiration         = { duration_days = 365 } # live eligibility runs $days days; the module caps at 365")
        }
        else {
            [void]$values.AppendLine("    expiration         = { duration_days = $days }")
        }
        [void]$values.AppendLine("  }")
        [void]$values.AppendLine("")
        $emitted++
    }
    [void]$values.AppendLine("}")

    if (-not (Test-Path -Path $Directory)) { New-Item -ItemType Directory -Path $Directory | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path -Path $Directory -ChildPath 'imports.tf'), ($imports.ToString() -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path -Path $Directory -ChildPath 'values.skeleton.hcl'), ($values.ToString() -replace "`r`n", "`n"), $utf8NoBom)

    return @{ Imports = (@($Rows | Where-Object { $_.PrincipalType -eq 'Group' }).Count); NewEntries = $emitted; Skipped = $skipped }
}

# ---------------------------------------------------------------------------
# Entra side.
# ---------------------------------------------------------------------------

function Get-EntraEligibilities {
    param()

    $instances = @(Invoke-GraphGetAll -Path 'roleManagement/directory/roleEligibilityScheduleInstances?$expand=principal,roleDefinition')
    $rows = New-Object System.Collections.ArrayList
    foreach ($instance in $instances) {
        if ([string]$instance.memberType -ne 'Direct') { continue }
        $principalType = ''
        $principalName = ''
        $principal = $instance.PSObject.Properties['principal']
        if ($principal -and $principal.Value) {
            $typeProp = $principal.Value.PSObject.Properties['@odata.type']
            if ($typeProp) { $principalType = ([string]$typeProp.Value) -replace '^#microsoft\.graph\.', '' }
            $principalName = [string]$principal.Value.displayName
        }
        $roleName = ''
        $role = $instance.PSObject.Properties['roleDefinition']
        if ($role -and $role.Value) { $roleName = [string]$role.Value.displayName }

        $scopeId = [string]$instance.directoryScopeId
        if ([string]::IsNullOrWhiteSpace($scopeId)) { $scopeId = '/' }

        [void]$rows.Add([PSCustomObject]@{
                RoleName         = $roleName
                RoleDefinitionId = [string]$instance.roleDefinitionId
                PrincipalId      = [string]$instance.principalId
                PrincipalType    = $principalType
                PrincipalName    = $principalName
                DirectoryScopeId = $scopeId
                ScheduleId       = [string]$instance.roleEligibilityScheduleId
                EndDateTime      = [string]$instance.endDateTime
            })
    }
    Write-RunLog -Level Info -Message ('Entra: {0} instance(s) read, {1} direct.' -f $instances.Count, $rows.Count)
    return $rows.ToArray()
}

function Resolve-EntraRequestId {
    <# The request that provisioned a schedule, or $null when Graph no longer
       holds it. #>
    param([Parameter(Mandatory = $true)][string]$ScheduleId)

    $filter = [Uri]::EscapeDataString(("targetScheduleId eq '{0}' and status eq 'Provisioned'" -f $ScheduleId))
    $requests = @(Invoke-GraphGetAll -Path ('roleManagement/directory/roleEligibilityScheduleRequests?$filter={0}&$select=id,action,status,createdDateTime' -f $filter))
    $candidates = @($requests | Where-Object { [string]$_.action -in @('adminAssign', 'adminUpdate', 'adminExtend', 'adminRenew') } | Sort-Object -Property createdDateTime -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return [string]$candidates[0].id
}

function Write-EntraOutputs {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][hashtable]$ExistingKeys,
        [Parameter(Mandatory = $true)][string]$ModuleAddress,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $generatedOn = Get-Date -Format 'yyyy-MM-dd'
    $imports = New-Object System.Text.StringBuilder
    $values = New-Object System.Text.StringBuilder
    $used = @{}
    foreach ($k in $ExistingKeys.Values) { $used[$k] = $true }

    [void]$imports.AppendLine("# Generated by scripts/Export-PimEligibilityImports.ps1 on $generatedOn (Entra directory roles).")
    [void]$imports.AppendLine("# azuread 3.x imports azuread_directory_role_eligibility_schedule_request by the eligibility schedule")
    [void]$imports.AppendLine("# REQUEST id. Blocks below carry the provisioning request resolved from the live schedule; a commented")
    [void]$imports.AppendLine("# block means Graph no longer holds the request and Terraform will recreate that eligibility on apply.")
    [void]$imports.AppendLine("# Place beside the entra-pim-governance terragrunt.hcl. Delete after the first successful apply.")
    [void]$imports.AppendLine("")

    [void]$values.AppendLine("# Generated by scripts/Export-PimEligibilityImports.ps1 on $generatedOn (Entra directory roles).")
    [void]$values.AppendLine("# Merge into the directory_role_eligibilities block of the entra-pim-governance cell.")
    [void]$values.AppendLine("# Every group named here must also be defined in privileged_groups; the stack refuses one that is not.")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("directory_role_eligibilities = {")

    $imported = 0
    $unresolved = 0
    $emitted = 0
    $skipped = 0
    foreach ($row in ($Rows | Sort-Object -Property RoleName, PrincipalName)) {
        if ($row.PrincipalType -ne 'group') {
            $skipped++
            [void]$imports.AppendLine(('# Skipped: {0} principal {1} ({2}) is eligible for "{3}". The module manages group -> role eligibilities only.' -f $row.PrincipalType, $row.PrincipalName, $row.PrincipalId, $row.RoleName))
            [void]$imports.AppendLine("")
            continue
        }

        $lookup = ('{0}|{1}|{2}' -f $row.RoleName, $row.PrincipalName, $row.DirectoryScopeId).ToLowerInvariant()
        if ($ExistingKeys.ContainsKey($lookup)) { $key = $ExistingKeys[$lookup]; $reused = $true }
        else {
            $key = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name $row.RoleName) -Used $used
            $reused = $false
        }

        $requestId = $null
        try { $requestId = Resolve-EntraRequestId -ScheduleId $row.ScheduleId }
        catch { Write-RunLog -Level Warn -Message ('Could not resolve the request for schedule {0}: {1}' -f $row.ScheduleId, $_.Exception.Message) }

        $address = "$ModuleAddress.azuread_directory_role_eligibility_schedule_request.this[$(Format-HclString -Value $key)]"
        if ($requestId) {
            [void]$imports.AppendLine("import {")
            [void]$imports.AppendLine("  to = $address")
            [void]$imports.AppendLine("  id = $(Format-HclString -Value $requestId)")
            [void]$imports.AppendLine("}")
            $imported++
        }
        else {
            [void]$imports.AppendLine(('# No provisioning request found for schedule {0} ("{1}" -> "{2}"). Graph keeps completed' -f $row.ScheduleId, $row.RoleName, $row.PrincipalName))
            [void]$imports.AppendLine("# requests for a limited time; this eligibility cannot be imported and will be recreated on apply.")
            [void]$imports.AppendLine("# import {")
            [void]$imports.AppendLine("#   to = $address")
            [void]$imports.AppendLine("#   id = `"<request id not available>`"")
            [void]$imports.AppendLine("# }")
            $unresolved++
        }
        [void]$imports.AppendLine("")

        if ($reused) {
            [void]$values.AppendLine(('  # {0}: already in the cell; import only.' -f $key))
            continue
        }

        [void]$values.AppendLine("  $(Format-HclString -Value $key) = {")
        [void]$values.AppendLine("    role_display_name  = $(Format-HclString -Value $row.RoleName)")
        [void]$values.AppendLine("    group_display_name = $(Format-HclString -Value $row.PrincipalName)")
        if ($row.DirectoryScopeId -ne '/') {
            [void]$values.AppendLine("    directory_scope_id = $(Format-HclString -Value $row.DirectoryScopeId)")
        }
        if (-not [string]::IsNullOrWhiteSpace($row.EndDateTime)) {
            [void]$values.AppendLine("    # Live eligibility ends $($row.EndDateTime); the module creates permanent eligibilities. Review.")
        }
        [void]$values.AppendLine("  }")
        [void]$values.AppendLine("")
        $emitted++
    }
    [void]$values.AppendLine("}")

    if (-not (Test-Path -Path $Directory)) { New-Item -ItemType Directory -Path $Directory | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path -Path $Directory -ChildPath 'imports.tf'), ($imports.ToString() -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path -Path $Directory -ChildPath 'values.skeleton.hcl'), ($values.ToString() -replace "`r`n", "`n"), $utf8NoBom)

    return @{ Imports = $imported; Unresolved = $unresolved; NewEntries = $emitted; Skipped = $skipped }
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------

function Invoke-PimEligibilityExport {
    param(
        [string[]]$ManagementGroupNames = @(),
        [string[]]$SubscriptionNames = @(),
        [bool]$SkipAzure = $false,
        [bool]$SkipEntra = $false,
        [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$AzureModuleAddress = 'module.pim_eligible_assignment',
        [string]$EntraModuleAddress = 'module.eligibility',
        [string]$AzureCellPath = '',
        [string]$EntraCellPath = '',
        [string]$ArmAccessToken = '',
        [string]$GraphAccessToken = ''
    )

    $endpoints = Get-CloudEndpoints -Environment $Environment
    $script:ArmBaseUri = $endpoints.Arm
    $script:GraphBaseUri = $endpoints.Graph
    Write-RunLog -Level Info -Message ('Cloud {0}: ARM {1}, Graph {2}.' -f $Environment, $endpoints.Arm, $endpoints.Graph)

    $summary = [ordered]@{
        RunId              = $script:RunId
        Environment        = $Environment
        OutputDirectory    = $OutputDirectory
        AzureScopes        = 0
        AzureImports       = 0
        AzureNewEntries    = 0
        AzureSkipped       = 0
        EntraImports       = 0
        EntraUnresolved    = 0
        EntraNewEntries    = 0
        EntraSkipped       = 0
    }

    if (-not $SkipAzure) {
        if (@($ManagementGroupNames).Count -eq 0 -and @($SubscriptionNames).Count -eq 0) {
            throw 'Pass at least one -ManagementGroupNames or -SubscriptionNames value, or -SkipAzure.'
        }
        $script:ArmToken = Get-ScopedAccessToken -Resource $endpoints.Arm -SuppliedToken $ArmAccessToken
        $existing = @{}
        if ($AzureCellPath) { $existing = Get-AzureCellKeys -Path $AzureCellPath }
        $scopes = @(Resolve-AzureScopes -ManagementGroupNames $ManagementGroupNames -SubscriptionNames $SubscriptionNames)
        $rows = @(Get-AzureEligibilities -Scopes $scopes)
        $result = Write-AzureOutputs -Rows $rows -ExistingKeys $existing -ModuleAddress $AzureModuleAddress -Directory (Join-Path -Path $OutputDirectory -ChildPath 'azure-pim-governance')
        $summary.AzureScopes = $scopes.Count
        $summary.AzureImports = $result.Imports
        $summary.AzureNewEntries = $result.NewEntries
        $summary.AzureSkipped = $result.Skipped
        Write-RunLog -Level Action -Message ('Azure: wrote {0} import block(s), {1} new skeleton entries, {2} non-group principal(s) skipped.' -f $result.Imports, $result.NewEntries, $result.Skipped)
    }

    if (-not $SkipEntra) {
        $script:GraphToken = Get-ScopedAccessToken -Resource $endpoints.Graph -SuppliedToken $GraphAccessToken
        $existing = @{}
        if ($EntraCellPath) { $existing = Get-EntraCellKeys -Path $EntraCellPath }
        $rows = @(Get-EntraEligibilities)
        $result = Write-EntraOutputs -Rows $rows -ExistingKeys $existing -ModuleAddress $EntraModuleAddress -Directory (Join-Path -Path $OutputDirectory -ChildPath 'entra-pim-governance')
        $summary.EntraImports = $result.Imports
        $summary.EntraUnresolved = $result.Unresolved
        $summary.EntraNewEntries = $result.NewEntries
        $summary.EntraSkipped = $result.Skipped
        Write-RunLog -Level Action -Message ('Entra: wrote {0} import block(s), {1} unresolved (commented), {2} new skeleton entries, {3} non-group principal(s) skipped.' -f $result.Imports, $result.Unresolved, $result.NewEntries, $result.Skipped)
    }

    Write-RunLog -Level Info -Message 'Next: merge the skeletons into the cells, drop each imports.tf beside its terragrunt.hcl, plan, and expect 0 to add, 0 to change, 0 to destroy.'
    return [PSCustomObject]$summary
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PimEligibilityExport -ManagementGroupNames $ManagementGroupNames -SubscriptionNames $SubscriptionNames `
        -SkipAzure ([bool]$SkipAzure) -SkipEntra ([bool]$SkipEntra) -Environment $Environment -OutputDirectory $OutputDirectory `
        -AzureModuleAddress $AzureModuleAddress -EntraModuleAddress $EntraModuleAddress `
        -AzureCellPath $AzureCellPath -EntraCellPath $EntraCellPath -ArmAccessToken $ArmAccessToken -GraphAccessToken $GraphAccessToken
}
