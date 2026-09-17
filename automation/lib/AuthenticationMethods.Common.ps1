# AuthenticationMethods.Common.ps1
#
# The normalize, diff, plan, apply, and export logic for the Entra
# authentication methods policy, shared by scripts/Set-AuthenticationMethods.ps1
# (workstation and pipeline) and automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1
# (Azure Automation). The script dot-sources this file from disk; the runbook
# carries a copy of it between two marker lines that stacks/azure-automation
# fills in at deploy time, because Azure Automation runs one file and a plain
# .ps1 cannot be a module asset. See modules/azure/automation-runbooks/README.md.
#
# Contract with the host file. This library defines no transport, identity,
# or logging of its own. The host must define, before dot-sourcing or inlining
# this file:
#
#   Invoke-GraphRequest -Method -Uri -Body   one Graph call with retries; relative
#                                            URIs may start with "v1.0/" or "beta/"
#   Invoke-GraphGetAll -Uri                  paginated GET
#   Write-RunLog -Level -Message             the structured log
#
# Every function here is prefixed AuthMethods so a host that also carries other
# libraries cannot collide with it.
#
# API versions. The policy singleton is read from beta because two of its three
# policy-level objects (reportSuspiciousActivitySettings and
# systemCredentialPreferences) exist only there, and beta is a superset of
# v1.0 for everything else the files manage. Method configurations are
# patched on v1.0. The policy object is patched on beta only when the body
# carries a beta-only key, otherwise on v1.0.

$script:AuthMethodsKnownIds = @(
    'Fido2', 'MicrosoftAuthenticator', 'TemporaryAccessPass', 'Sms',
    'Voice', 'Email', 'SoftwareOath', 'X509Certificate'
)
$script:AuthMethodsAllUsersId = 'all_users'
$script:AuthMethodsEmptyTargetId = '00000000-0000-0000-0000-000000000000'
$script:AuthMethodsPolicyUri = 'policies/authenticationMethodsPolicy'
$script:AuthMethodsPolicyManagedKeys = @('registrationEnforcement', 'reportSuspiciousActivitySettings', 'systemCredentialPreferences', 'policyMigrationState')
$script:AuthMethodsPolicyBetaOnlyKeys = @('reportSuspiciousActivitySettings', 'systemCredentialPreferences', 'enforceRegistrationAfterAllowedSnoozes')
$script:AuthMethodsIgnoredKeys = @('id', '@odata.context', 'displayName', 'description', 'lastModifiedDateTime', 'policyVersion', 'includeTargets@odata.context', 'authenticationMethodConfigurations@odata.context')
$script:AuthMethodsGroupCache = @{}

# ---------------------------------------------------------------------------
# Plain objects. ConvertFrom-Json yields PSCustomObjects whose property order
# is stable but awkward to compare; everything is converted once into ordered
# hashtables and object arrays so the diff and the export work on one shape.
# ---------------------------------------------------------------------------

function ConvertTo-AuthMethodsPlain {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-AuthMethodsPlain -Value $Value[$key] }
        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-AuthMethodsPlain -Value $item)) }
        return , $items.ToArray()
    }

    if ($Value -is [PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[[string]$property.Name] = ConvertTo-AuthMethodsPlain -Value $property.Value }
        return $copy
    }

    return $Value
}

function ConvertFrom-AuthMethodsJson {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json, [string]$Label = 'json')

    if ([string]::IsNullOrWhiteSpace($Json)) { throw ('{0} is empty.' -f $Label) }
    try { $parsed = $Json | ConvertFrom-Json }
    catch { throw ('{0} is not valid JSON: {1}' -f $Label, $_.Exception.Message) }
    return ConvertTo-AuthMethodsPlain -Value $parsed
}

function ConvertTo-AuthMethodsJson {
    param([AllowNull()][object]$Value)

    $text = ConvertTo-Json -InputObject $Value -Depth 20
    return ($text -replace "`r`n", "`n")
}

function Test-AuthMethodsGuid {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Test-AuthMethodsTargetNode {
    <# A target is any object with targetType and id: authenticationMethodTarget,
       excludeTarget, includeTarget, featureTarget, and the registration campaign
       targets all share that shape. #>
    param([AllowNull()][object]$Node)

    if ($null -eq $Node -or -not ($Node -is [System.Collections.IDictionary])) { return $false }
    return ($Node.Contains('targetType') -and $Node.Contains('id'))
}

# ---------------------------------------------------------------------------
# Group names to IDs and back. Names are resolved with a displayName filter and
# must match exactly one group; IDs are resolved by object ID and fall back to
# the ID itself when the group no longer exists, so an export never invents a
# name. Both directions are cached for the run.
# ---------------------------------------------------------------------------

function Resolve-AuthMethodsGroupId {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cacheKey = 'name:' + $Name.ToLowerInvariant()
    if ($script:AuthMethodsGroupCache.ContainsKey($cacheKey)) { return $script:AuthMethodsGroupCache[$cacheKey] }

    $escaped = $Name.Replace("'", "''")
    $uri = "groups?`$filter=displayName eq '{0}'&`$select=id,displayName" -f [Uri]::EscapeDataString($escaped)
    $found = @(Invoke-GraphGetAll -Uri $uri)
    if ($found.Count -eq 0) { throw ('Group "{0}" was not found. Every group in the desired state must exist by display name.' -f $Name) }
    if ($found.Count -gt 1) { throw ('Group "{0}" matches {1} groups. Display names in the desired state must be unique.' -f $Name, $found.Count) }

    $id = [string]$found[0].id
    $script:AuthMethodsGroupCache[$cacheKey] = $id
    $script:AuthMethodsGroupCache['id:' + $id.ToLowerInvariant()] = [string]$found[0].displayName
    return $id
}

function Resolve-AuthMethodsGroupName {
    param([Parameter(Mandatory = $true)][string]$Id)

    $cacheKey = 'id:' + $Id.ToLowerInvariant()
    if ($script:AuthMethodsGroupCache.ContainsKey($cacheKey)) { return $script:AuthMethodsGroupCache[$cacheKey] }

    $name = $null
    try {
        $group = Invoke-GraphRequest -Method GET -Uri ('groups/{0}?$select=id,displayName' -f $Id)
        if ($null -ne $group -and $group.PSObject.Properties['displayName']) { $name = [string]$group.displayName }
    }
    catch {
        Write-RunLog -Level Warn -Message ('Group {0} could not be read ({1}); the export keeps the ID.' -f $Id, $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $Id }

    $script:AuthMethodsGroupCache[$cacheKey] = $name
    return $name
}

function Resolve-AuthMethodsTargets {
    <# Walks a plain object and rewrites the id of every group target: display
       name to object ID (ToId) or object ID to display name (ToName). all_users
       and the all-zeros GUID pass through in both directions; a value that is
       already a GUID passes through ToId, so an exported file that kept an ID
       for a deleted group still applies. Returns a new object. #>
    param(
        [AllowNull()][object]$Node,
        [Parameter(Mandatory = $true)][ValidateSet('ToId', 'ToName')][string]$Direction
    )

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Node.Keys) { $copy[[string]$key] = Resolve-AuthMethodsTargets -Node $Node[$key] -Direction $Direction }

        if ((Test-AuthMethodsTargetNode -Node $copy) -and ([string]$copy['targetType']).ToLowerInvariant() -eq 'group') {
            $id = [string]$copy['id']
            $passThrough = ($id -eq $script:AuthMethodsAllUsersId) -or ($id -eq $script:AuthMethodsEmptyTargetId) -or [string]::IsNullOrWhiteSpace($id)
            if (-not $passThrough) {
                if ($Direction -eq 'ToId' -and -not (Test-AuthMethodsGuid -Text $id)) { $copy['id'] = Resolve-AuthMethodsGroupId -Name $id }
                elseif ($Direction -eq 'ToName' -and (Test-AuthMethodsGuid -Text $id)) { $copy['id'] = Resolve-AuthMethodsGroupName -Id $id }
            }
        }
        return $copy
    }

    if ($Node -is [string] -or $Node -is [bool] -or $Node -is [ValueType]) { return $Node }

    if ($Node -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Node) { [void]$items.Add((Resolve-AuthMethodsTargets -Node $item -Direction $Direction)) }
        return , $items.ToArray()
    }

    return $Node
}

# ---------------------------------------------------------------------------
# Diff. The desired object is walked and each field looked up in the live
# object; live fields the desired object does not mention are unmanaged and
# never reported. Target lists are sets keyed by (targetType, id), so ordering
# is never drift but an extra live target is. Scalars compare case-insensitively
# for strings and by value for numbers and booleans.
# ---------------------------------------------------------------------------

function Test-AuthMethodsScalarEqual {
    param([AllowNull()][object]$Desired, [AllowNull()][object]$Live)

    if ($null -eq $Desired -and $null -eq $Live) { return $true }
    if ($null -eq $Desired -or $null -eq $Live) { return $false }
    if ($Desired -is [bool] -or $Live -is [bool]) {
        $d = $null
        $l = $null
        try { $d = [System.Convert]::ToBoolean($Desired); $l = [System.Convert]::ToBoolean($Live) } catch { return $false }
        return ($d -eq $l)
    }
    $dNumber = 0.0
    $lNumber = 0.0
    if ([double]::TryParse([string]$Desired, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dNumber) -and
        [double]::TryParse([string]$Live, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$lNumber)) {
        return ($dNumber -eq $lNumber)
    }
    return ([string]$Desired).Trim().Equals(([string]$Live).Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Get-AuthMethodsElementKey {
    param([AllowNull()][object]$Element)

    if (Test-AuthMethodsTargetNode -Node $Element) {
        return ('{0}:{1}' -f ([string]$Element['targetType']).ToLowerInvariant(), ([string]$Element['id']).ToLowerInvariant())
    }
    if ($Element -is [System.Collections.IDictionary]) {
        if ($Element.Contains('priority')) { return ('priority:' + [string]$Element['priority']) }
        if ($Element.Contains('identifier')) { return ('identifier:' + ([string]$Element['identifier']).ToLowerInvariant()) }
        return (ConvertTo-Json -InputObject $Element -Depth 20 -Compress).ToLowerInvariant()
    }
    return ([string]$Element).ToLowerInvariant()
}

function ConvertTo-AuthMethodsDisplayValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '(absent)' }
    if ($Value -is [System.Collections.IDictionary] -or ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))) {
        return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
    }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return [string]$Value
}

function Add-AuthMethodsDifference {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Differences,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Changed', 'Missing', 'Extra')][string]$Kind,
        [AllowNull()][object]$Desired,
        [AllowNull()][object]$Live
    )

    [void]$Differences.Add([PSCustomObject]@{
            Path    = $Path
            Kind    = $Kind
            Desired = (ConvertTo-AuthMethodsDisplayValue -Value $Desired)
            Live    = (ConvertTo-AuthMethodsDisplayValue -Value $Live)
        })
}

function Compare-AuthMethodsNode {
    param(
        [AllowNull()][object]$Desired,
        [AllowNull()][object]$Live,
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$Differences
    )

    if ($Desired -is [System.Collections.IDictionary]) {
        if ($null -eq $Live -or -not ($Live -is [System.Collections.IDictionary])) {
            Add-AuthMethodsDifference -Differences $Differences -Path $Path -Kind Missing -Desired $Desired -Live $Live
            return
        }
        foreach ($key in $Desired.Keys) {
            $name = [string]$key
            if ($script:AuthMethodsIgnoredKeys -contains $name) { continue }
            $childPath = if ([string]::IsNullOrEmpty($Path)) { $name } else { '{0}.{1}' -f $Path, $name }
            $liveKey = $null
            foreach ($candidate in $Live.Keys) { if (([string]$candidate).Equals($name, [StringComparison]::OrdinalIgnoreCase)) { $liveKey = $candidate; break } }
            if ($null -eq $liveKey) {
                Add-AuthMethodsDifference -Differences $Differences -Path $childPath -Kind Missing -Desired $Desired[$key] -Live $null
                continue
            }
            Compare-AuthMethodsNode -Desired $Desired[$key] -Live $Live[$liveKey] -Path $childPath -Differences $Differences
        }
        return
    }

    if ($Desired -is [System.Collections.IEnumerable] -and -not ($Desired -is [string])) {
        $desiredItems = @($Desired)
        $liveItems = @()
        if ($null -ne $Live -and $Live -is [System.Collections.IEnumerable] -and -not ($Live -is [string])) { $liveItems = @($Live) }
        elseif ($null -ne $Live) {
            Add-AuthMethodsDifference -Differences $Differences -Path $Path -Kind Changed -Desired $Desired -Live $Live
            return
        }

        $allScalar = $true
        foreach ($item in ($desiredItems + $liveItems)) {
            if ($item -is [System.Collections.IDictionary] -or ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string]))) { $allScalar = $false; break }
        }

        if ($allScalar) {
            $d = @($desiredItems | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
            $l = @($liveItems | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
            if (($d -join '|') -ne ($l -join '|')) {
                Add-AuthMethodsDifference -Differences $Differences -Path $Path -Kind Changed -Desired $desiredItems -Live $liveItems
            }
            return
        }

        $liveByKey = [ordered]@{}
        foreach ($item in $liveItems) { $liveByKey[(Get-AuthMethodsElementKey -Element $item)] = $item }
        $seen = @{}
        foreach ($item in $desiredItems) {
            $key = Get-AuthMethodsElementKey -Element $item
            $seen[$key] = $true
            $elementPath = '{0}[{1}]' -f $Path, $key
            if (-not $liveByKey.Contains($key)) {
                Add-AuthMethodsDifference -Differences $Differences -Path $elementPath -Kind Missing -Desired $item -Live $null
                continue
            }
            Compare-AuthMethodsNode -Desired $item -Live $liveByKey[$key] -Path $elementPath -Differences $Differences
        }
        foreach ($key in $liveByKey.Keys) {
            if ($seen.ContainsKey($key)) { continue }
            Add-AuthMethodsDifference -Differences $Differences -Path ('{0}[{1}]' -f $Path, $key) -Kind Extra -Desired $null -Live $liveByKey[$key]
        }
        return
    }

    if (-not (Test-AuthMethodsScalarEqual -Desired $Desired -Live $Live)) {
        $kind = if ($null -eq $Live) { 'Missing' } else { 'Changed' }
        Add-AuthMethodsDifference -Differences $Differences -Path $Path -Kind $kind -Desired $Desired -Live $Live
    }
}

function Get-AuthMethodsDifferences {
    <# Field-level differences between one desired object and its live
       counterpart, as an array of {Path, Kind, Desired, Live}. #>
    param([AllowNull()][object]$Desired, [AllowNull()][object]$Live)

    $differences = New-Object System.Collections.ArrayList
    Compare-AuthMethodsNode -Desired $Desired -Live $Live -Path '' -Differences $differences
    return @($differences.ToArray())
}

# ---------------------------------------------------------------------------
# Desired state in, live state in.
# ---------------------------------------------------------------------------

function Import-AuthMethodsDesiredState {
    <# Reads policy.json (optional) and methods/*.json from a folder. Group
       names are left as written; Get-AuthMethodsPlan resolves them. #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Container)) { throw ('Desired state folder not found: {0}' -f $Path) }

    $policy = $null
    $policyPath = Join-Path -Path $Path -ChildPath 'policy.json'
    if (Test-Path -Path $policyPath -PathType Leaf) {
        $policy = ConvertFrom-AuthMethodsJson -Json ([System.IO.File]::ReadAllText($policyPath)) -Label $policyPath
    }

    $methods = [ordered]@{}
    $methodsPath = Join-Path -Path $Path -ChildPath 'methods'
    if (Test-Path -Path $methodsPath -PathType Container) {
        foreach ($file in (Get-ChildItem -Path $methodsPath -Filter '*.json' -File | Sort-Object -Property Name)) {
            $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $methods[$id] = ConvertFrom-AuthMethodsJson -Json ([System.IO.File]::ReadAllText($file.FullName)) -Label $file.FullName
        }
    }

    if ($null -eq $policy -and $methods.Count -eq 0) { throw ('No policy.json and no methods/*.json under {0}.' -f $Path) }
    return @{ Policy = $policy; Methods = $methods }
}

function Import-AuthMethodsDesiredStateFromJson {
    <# The runbook's equivalent: one JSON string per file, keyed by method id,
       plus the policy JSON. #>
    param(
        [AllowNull()][AllowEmptyString()][string]$PolicyJson = '',
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$MethodJson
    )

    $policy = $null
    if (-not [string]::IsNullOrWhiteSpace($PolicyJson)) { $policy = ConvertFrom-AuthMethodsJson -Json $PolicyJson -Label 'policy' }

    $methods = [ordered]@{}
    foreach ($id in ($MethodJson.Keys | Sort-Object)) {
        $methods[[string]$id] = ConvertFrom-AuthMethodsJson -Json ([string]$MethodJson[$id]) -Label ('method ' + $id)
    }

    if ($null -eq $policy -and $methods.Count -eq 0) { throw 'No desired state was supplied.' }
    return @{ Policy = $policy; Methods = $methods }
}

function Get-AuthMethodsLivePolicy {
    <# GET the policy singleton from beta, which expands
       authenticationMethodConfigurations. Returns a plain object plus the
       configurations indexed by id. #>
    $raw = Invoke-GraphRequest -Method GET -Uri ('beta/' + $script:AuthMethodsPolicyUri)
    if ($null -eq $raw) { throw 'GET policies/authenticationMethodsPolicy returned nothing.' }
    $policy = ConvertTo-AuthMethodsPlain -Value $raw

    $methods = [ordered]@{}
    if ($policy.Contains('authenticationMethodConfigurations')) {
        foreach ($configuration in @($policy['authenticationMethodConfigurations'])) {
            if ($null -eq $configuration -or -not $configuration.Contains('id')) { continue }
            $methods[[string]$configuration['id']] = $configuration
        }
    }
    return @{ Policy = $policy; Methods = $methods }
}

function Find-AuthMethodsKey {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Table, [Parameter(Mandatory = $true)][string]$Key)

    foreach ($candidate in $Table.Keys) { if (([string]$candidate).Equals($Key, [StringComparison]::OrdinalIgnoreCase)) { return $candidate } }
    return $null
}

# ---------------------------------------------------------------------------
# Plan. Resolve names, diff every managed object, apply the two guards, and
# produce the PATCH bodies. Pure with respect to writes: nothing here changes
# the tenant, so a dry run and a live run compute the same plan.
# ---------------------------------------------------------------------------

function Test-AuthMethodsLeavesNoneEnabled {
    <# True when applying the desired states over the live states would leave
       no enabled method configuration. Live configurations the desired state
       does not mention keep their live state. #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$LiveMethods,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$DesiredMethods
    )

    $states = @{}
    foreach ($id in $LiveMethods.Keys) {
        $state = ''
        if ($LiveMethods[$id] -is [System.Collections.IDictionary] -and $LiveMethods[$id].Contains('state')) { $state = [string]$LiveMethods[$id]['state'] }
        $states[([string]$id).ToLowerInvariant()] = $state
    }
    foreach ($id in $DesiredMethods.Keys) {
        if ($DesiredMethods[$id] -is [System.Collections.IDictionary] -and $DesiredMethods[$id].Contains('state')) {
            $states[([string]$id).ToLowerInvariant()] = [string]$DesiredMethods[$id]['state']
        }
    }
    $enabled = @($states.Values | Where-Object { ([string]$_).Equals('enabled', [StringComparison]::OrdinalIgnoreCase) })
    return ($enabled.Count -eq 0)
}

function Get-AuthMethodsPlan {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Live,
        [bool]$AllowMigrationStateChange = $false
    )

    $drift = New-Object System.Collections.ArrayList
    $methodPatches = [ordered]@{}
    $desiredMethods = [ordered]@{}

    foreach ($id in $Desired.Methods.Keys) {
        $resolved = Resolve-AuthMethodsTargets -Node $Desired.Methods[$id] -Direction ToId
        $desiredMethods[[string]$id] = $resolved

        $liveKey = Find-AuthMethodsKey -Table $Live.Methods -Key ([string]$id)
        if ($null -eq $liveKey) {
            throw ('Method "{0}" is in the desired state but the tenant policy has no configuration with that id. File names under methods/ must be Graph configuration ids ({1}).' -f $id, ($script:AuthMethodsKnownIds -join ', '))
        }
        $differences = @(Get-AuthMethodsDifferences -Desired $resolved -Live $Live.Methods[$liveKey])
        foreach ($difference in $differences) {
            [void]$drift.Add([PSCustomObject]@{
                    Scope   = 'Method'
                    Id      = [string]$liveKey
                    Path    = $difference.Path
                    Kind    = $difference.Kind
                    Desired = $difference.Desired
                    Live    = $difference.Live
                    Guarded = $false
                })
        }
        if ($differences.Count -gt 0) { $methodPatches[[string]$liveKey] = $resolved }
    }

    if ($desiredMethods.Count -gt 0 -and (Test-AuthMethodsLeavesNoneEnabled -LiveMethods $Live.Methods -DesiredMethods $desiredMethods)) {
        throw 'Refusing to plan: the desired state would leave no enabled authentication method configuration in the tenant. At least one method must stay enabled or nobody can register or use MFA.'
    }

    $policyPatch = $null
    $migrationStateHeld = $false
    if ($null -ne $Desired.Policy) {
        $resolvedPolicy = Resolve-AuthMethodsTargets -Node $Desired.Policy -Direction ToId
        $body = [ordered]@{}
        foreach ($key in $resolvedPolicy.Keys) {
            $name = [string]$key
            if ($script:AuthMethodsPolicyManagedKeys -notcontains $name) {
                Write-RunLog -Level Warn -Message ('policy.json key "{0}" is not a managed policy-level setting and is ignored.' -f $name)
                continue
            }
            $liveKey = Find-AuthMethodsKey -Table $Live.Policy -Key $name
            $liveValue = $null
            if ($null -ne $liveKey) { $liveValue = $Live.Policy[$liveKey] }
            $differences = @(Get-AuthMethodsDifferences -Desired ([ordered]@{ $name = $resolvedPolicy[$key] }) -Live ([ordered]@{ $name = $liveValue }))
            if ($differences.Count -eq 0) { continue }

            $guarded = ($name -eq 'policyMigrationState' -and -not $AllowMigrationStateChange)
            foreach ($difference in $differences) {
                [void]$drift.Add([PSCustomObject]@{
                        Scope   = 'Policy'
                        Id      = 'authenticationMethodsPolicy'
                        Path    = $difference.Path
                        Kind    = $difference.Kind
                        Desired = $difference.Desired
                        Live    = $difference.Live
                        Guarded = $guarded
                    })
            }
            if ($guarded) {
                $migrationStateHeld = $true
                Write-RunLog -Level Warn -Message ('policyMigrationState differs (desired {0}, live {1}) and AllowMigrationStateChange is false; held, not patched. migrationComplete switches off the legacy per-user MFA and SSPR settings tenant-wide.' -f $resolvedPolicy[$key], $liveValue)
                continue
            }
            $body[$name] = $resolvedPolicy[$key]
        }
        if ($body.Count -gt 0) { $policyPatch = $body }
    }

    return @{
        Drift              = @($drift.ToArray())
        MethodPatches      = $methodPatches
        PolicyPatch        = $policyPatch
        MigrationStateHeld = $migrationStateHeld
        DesiredMethods     = $desiredMethods
    }
}

function Get-AuthMethodsPolicyPatchVersion {
    <# beta when the body carries any property that exists only there, at any
       depth (the registration campaign's enforceRegistrationAfterAllowedSnoozes
       is nested); v1.0 otherwise. #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Body)

    $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    foreach ($name in $script:AuthMethodsPolicyBetaOnlyKeys) {
        if ($json.IndexOf('"' + $name + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'beta' }
    }
    return 'v1.0'
}

# ---------------------------------------------------------------------------
# Apply. One PATCH per drifted method with the whole desired file as the body
# (Graph treats absent properties as unchanged), then one PATCH for the policy
# object. Every write is announced with "Would" in a dry run.
# ---------------------------------------------------------------------------

function Invoke-AuthMethodsApply {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [bool]$DryRun = $true
    )

    $patched = 0
    $planned = 0
    $failed = 0

    foreach ($id in $Plan.MethodPatches.Keys) {
        $planned++
        $uri = 'v1.0/{0}/authenticationMethodConfigurations/{1}' -f $script:AuthMethodsPolicyUri, $id
        $fields = @($Plan.Drift | Where-Object { $_.Scope -eq 'Method' -and $_.Id -eq $id }).Count
        if ($DryRun) {
            Write-RunLog -Level Action -Message ('Would PATCH {0} ({1} field difference(s)).' -f $uri, $fields)
            continue
        }
        try {
            Invoke-GraphRequest -Method PATCH -Uri $uri -Body $Plan.MethodPatches[$id] | Out-Null
            $patched++
            Write-RunLog -Level Action -Message ('PATCHed {0} ({1} field difference(s)).' -f $uri, $fields)
        }
        catch {
            $failed++
            Write-RunLog -Level Error -Message ('Failed to PATCH {0}: {1}' -f $uri, $_.Exception.Message)
        }
    }

    if ($null -ne $Plan.PolicyPatch) {
        $planned++
        $version = Get-AuthMethodsPolicyPatchVersion -Body $Plan.PolicyPatch
        $uri = '{0}/{1}' -f $version, $script:AuthMethodsPolicyUri
        $keys = @($Plan.PolicyPatch.Keys) -join ', '
        if ($DryRun) {
            Write-RunLog -Level Action -Message ('Would PATCH {0} ({1}).' -f $uri, $keys)
        }
        else {
            try {
                Invoke-GraphRequest -Method PATCH -Uri $uri -Body $Plan.PolicyPatch | Out-Null
                $patched++
                Write-RunLog -Level Action -Message ('PATCHed {0} ({1}).' -f $uri, $keys)
            }
            catch {
                $failed++
                Write-RunLog -Level Error -Message ('Failed to PATCH {0}: {1}' -f $uri, $_.Exception.Message)
            }
        }
    }

    return @{ Planned = $planned; Patched = $patched; Failed = $failed }
}

# ---------------------------------------------------------------------------
# Export. The live policy written into the folder layout with IDs replaced by
# names, for adopting a tenant. policyMigrationState is logged, never written.
# ---------------------------------------------------------------------------

function Export-AuthMethodsDesiredState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Live,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $methodsPath = Join-Path -Path $Path -ChildPath 'methods'
    if (-not (Test-Path -Path $methodsPath)) { New-Item -ItemType Directory -Path $methodsPath -Force | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $written = New-Object System.Collections.ArrayList

    $policy = [ordered]@{}
    foreach ($key in $script:AuthMethodsPolicyManagedKeys) {
        $liveKey = Find-AuthMethodsKey -Table $Live.Policy -Key $key
        if ($null -eq $liveKey) { continue }
        if ($key -eq 'policyMigrationState') {
            Write-RunLog -Level Info -Message ('Live policyMigrationState is {0}; not written to policy.json (see the folder README).' -f $Live.Policy[$liveKey])
            continue
        }
        $policy[$key] = Resolve-AuthMethodsTargets -Node $Live.Policy[$liveKey] -Direction ToName
    }
    $policyFile = Join-Path -Path $Path -ChildPath 'policy.json'
    [System.IO.File]::WriteAllText($policyFile, (ConvertTo-AuthMethodsJson -Value $policy) + "`n", $utf8NoBom)
    [void]$written.Add($policyFile)

    foreach ($id in $script:AuthMethodsKnownIds) {
        $liveKey = Find-AuthMethodsKey -Table $Live.Methods -Key $id
        if ($null -eq $liveKey) {
            Write-RunLog -Level Warn -Message ('The tenant policy has no {0} configuration; no file written.' -f $id)
            continue
        }
        $configuration = Resolve-AuthMethodsTargets -Node $Live.Methods[$liveKey] -Direction ToName
        $body = [ordered]@{}
        foreach ($key in $configuration.Keys) {
            if ($script:AuthMethodsIgnoredKeys -contains [string]$key) { continue }
            $body[[string]$key] = $configuration[$key]
        }
        $file = Join-Path -Path $methodsPath -ChildPath ('{0}.json' -f $liveKey)
        [System.IO.File]::WriteAllText($file, (ConvertTo-AuthMethodsJson -Value $body) + "`n", $utf8NoBom)
        [void]$written.Add($file)
    }

    return @($written.ToArray())
}

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------

function Format-AuthMethodsDriftTable {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Drift)

    if ($null -eq $Drift -or @($Drift).Count -eq 0) { return 'No drift: the live authentication methods policy matches the desired state.' }
    $rows = @($Drift | Select-Object -Property Scope, Id, Path, Kind, Desired, Live, Guarded)
    return ($rows | Format-Table -Property Scope, Id, Path, Kind, Desired, Live, Guarded -AutoSize -Wrap | Out-String).TrimEnd()
}
