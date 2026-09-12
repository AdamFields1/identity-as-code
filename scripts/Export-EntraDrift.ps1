<#
.SYNOPSIS
    Compares the application registrations and service principals in an Entra tenant
    against the set managed by stacks/entra-app-registrations, then emits a drift
    report, Terraform import blocks, and a values skeleton for adopting the rest.

.DESCRIPTION
    Terraform is the inventory and guardrail for application registrations, not the
    sole editor (docs/adr/0006-terraform-as-inventory-and-guardrail.md). That leaves
    two questions a plan cannot answer: which registrations exist that Terraform has
    never seen, and which managed registrations have drifted in ways the module
    deliberately ignores. This script answers both.

    It reads every application registration and service principal through Microsoft
    Graph, compares display names to a managed list, and writes three files:

      drift-report.md       Unmanaged registrations, managed registrations with
                            findings (client secrets present, missing service
                            principal), names declared but absent from the tenant,
                            and orphaned tenant-owned service principals.

      imports.tf            Terraform import blocks for every unmanaged registration
                            and its service principal, addressed to the stack's
                            module resources. Drop this next to a tenant
                            terragrunt.hcl; tenants/azure/root.hcl picks it up.

      values.skeleton.hcl   A starting point for the tenant cell's applications
                            block, populated from the live configuration with API
                            permissions resolved to names. Review every value.

    Authentication uses an existing Connect-MgGraph session when one is present.
    Otherwise -TenantId is required and a device code sign-in is started. The script
    never handles a secret, a certificate, or a token value.

    With -WhatIf nothing is written; the report summary is printed to the console.

.PARAMETER ManagedNamesPath
    Path to the managed display names. Either a tenant terragrunt.hcl (the
    display_name values inside its applications block are used) or a plain text file
    with one display name per line. Lines starting with # are ignored.

.PARAMETER TenantId
    Tenant to sign in to when no Graph session exists, or when the existing session
    is for a different tenant. Optional if a matching session already exists.

.PARAMETER Environment
    Microsoft Graph national cloud: Global (default), USGov, or USGovDoD. Endpoints
    differ per cloud and the wrong one fails authentication.

.PARAMETER OutputDirectory
    Where the three files are written. Default: .\out (git-ignored).

.PARAMETER ModuleAddress
    Terraform address of the app-registration module inside the stack. Default:
    module.app_registrations, matching stacks/entra-app-registrations/main.tf.

.PARAMETER IncludeOwnersAndCredentials
    Also read each unmanaged registration's owners and federated identity
    credentials (one extra Graph call each). Populates owners and
    federated_credentials in the skeleton and emits credential import blocks.
    Requires Directory.Read.All in addition to Application.Read.All.

.EXAMPLE
    .\Export-EntraDrift.ps1 -ManagedNamesPath ..\tenants\azure\corp\entra-app-registrations\terragrunt.hcl -TenantId <corp tenant id>

.EXAMPLE
    .\Export-EntraDrift.ps1 -ManagedNamesPath .\managed-apps.txt -Environment USGov -WhatIf

.EXAMPLE
    .\Export-EntraDrift.ps1 -ManagedNamesPath ..\tenants\azure\corp\entra-app-registrations\terragrunt.hcl -IncludeOwnersAndCredentials -OutputDirectory .\out

.NOTES
    Windows PowerShell 5.1 compatible. Requires the Microsoft.Graph.Authentication
    module (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser).
    Graph scopes needed: Application.Read.All, plus Directory.Read.All when
    -IncludeOwnersAndCredentials is set. Read-only throughout.
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$ManagedNamesPath,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [ValidateSet('Global', 'USGov', 'USGovDoD')]
    [string]$Environment = 'Global',

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path -Path (Get-Location) -ChildPath 'out'),

    [ValidateNotNullOrEmpty()]
    [string]$ModuleAddress = 'module.app_registrations',

    [switch]$IncludeOwnersAndCredentials
)

$ErrorActionPreference = 'Stop'

$script:ApiCache = @{}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Field {
    <# Safe nested property read that works on both the hashtables and the
       PSCustomObjects that Invoke-MgGraphRequest can return. Returns $null when
       any segment is missing instead of throwing. #>
    param([object]$Object, [Parameter(Mandatory = $true)][string]$Path)

    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        }
        else {
            $prop = $current.PSObject.Properties[$segment]
            if ($null -eq $prop) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

function Get-FieldList {
    <# Like Get-Field but always yields a flat list with nulls removed. Callers wrap
       the result in @() so a missing property is a zero-length array. #>
    param([object]$Object, [Parameter(Mandatory = $true)][string]$Path)

    $value = Get-Field -Object $Object -Path $Path
    if ($null -eq $value) { return }
    return @($value | Where-Object { $null -ne $_ })
}

function Invoke-GraphGetAll {
    <# Paginated GET through the connected Graph session. Follows @odata.nextLink,
       which is absolute and already points at the right national cloud endpoint.
       Retries once on 429 using Retry-After. #>
    param([Parameter(Mandatory = $true)][string]$Uri)

    $results = New-Object System.Collections.ArrayList
    $next = $Uri

    while ($next) {
        $page = $null
        $attempt = 0
        while ($null -eq $page) {
            $attempt++
            try {
                $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
            }
            catch {
                $status = $null
                $response = Get-Field -Object $_.Exception -Path 'Response'
                if ($response) { $status = [int](Get-Field -Object $response -Path 'StatusCode') }
                if ($status -eq 429 -and $attempt -lt 3) {
                    $waitSeconds = 10
                    $retryAfter = $null
                    try { $retryAfter = $response.Headers.GetValues('Retry-After') } catch { }
                    if ($retryAfter) { $waitSeconds = [Math]::Max(1, [int]($retryAfter | Select-Object -First 1)) }
                    Write-Warning "Throttled by Microsoft Graph. Waiting $waitSeconds second(s) before retrying."
                    Start-Sleep -Seconds $waitSeconds
                    continue
                }
                throw "GET $next failed: $($_.Exception.Message)"
            }
        }

        $value = Get-Field -Object $page -Path 'value'
        if ($null -ne $value) {
            foreach ($item in @($value)) { [void]$results.Add($item) }
        }
        elseif ($null -ne $page -and $null -eq (Get-Field -Object $page -Path '@odata.nextLink')) {
            # A single-object response (no "value" wrapper).
            [void]$results.Add($page)
        }

        $next = Get-Field -Object $page -Path '@odata.nextLink'
    }

    return $results.ToArray()
}

function Get-ManagedNames {
    <# Reads managed display names from a terragrunt.hcl (applications block) or
       from a plain text file. Returns a case-insensitive set. #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $text = [System.IO.File]::ReadAllText($Path)

    if ([System.IO.Path]::GetExtension($Path) -ieq '.hcl') {
        $match = [regex]::Match($text, '(?m)^\s*applications\s*=\s*\{')
        if (-not $match.Success) {
            throw "No 'applications = {' block found in $Path. Pass a plain text file of display names instead."
        }

        # Brace-match from the opening brace of the applications block. Braces
        # inside quoted strings are not special-cased; the tenant cells in this
        # repository do not contain any, and the result is reviewed anyway.
        $start = $match.Index + $match.Length - 1
        $depth = 0
        $end = -1
        for ($i = $start; $i -lt $text.Length; $i++) {
            $ch = $text[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        if ($end -lt 0) { throw "Unbalanced braces in the applications block of $Path." }

        $block = $text.Substring($start, $end - $start + 1)
        foreach ($m in [regex]::Matches($block, 'display_name\s*=\s*"((?:[^"\\]|\\.)*)"')) {
            $raw = $m.Groups[1].Value
            $unescaped = $raw.Replace('\"', '"').Replace('\\', '\')
            [void]$names.Add($unescaped)
        }
    }
    else {
        foreach ($line in ($text -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
            [void]$names.Add($trimmed)
        }
    }

    return $names
}

function ConvertTo-LogicalKey {
    <# Turns a display name into a stable for_each key: lowercase, hyphen separated. #>
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

function Format-HclList {
    param([AllowNull()][string[]]$Values)

    if ($null -eq $Values -or @($Values).Count -eq 0) { return '[]' }
    $quoted = @($Values | ForEach-Object { Format-HclString -Value $_ })
    return '[' + ($quoted -join ', ') + ']'
}

function Format-HclBool {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    return ([bool]$Value).ToString().ToLowerInvariant()
}

function Format-MarkdownCell {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    return $Value.Replace('|', '\|')
}

function Get-ResourceApi {
    <# Resolves a resource app ID (the API an application requests permissions on)
       to its service principal, with app roles and scopes, cached per run. Returns
       $null when the API has no service principal in this tenant. #>
    param([Parameter(Mandatory = $true)][string]$ResourceAppId)

    if ($script:ApiCache.ContainsKey($ResourceAppId)) { return $script:ApiCache[$ResourceAppId] }

    $api = $null
    try {
        $rows = @(Invoke-GraphGetAll -Uri "/v1.0/servicePrincipals(appId='$ResourceAppId')?`$select=id,appId,displayName,appRoles,oauth2PermissionScopes")
        if ($rows.Count -gt 0) { $api = $rows[0] }
    }
    catch {
        Write-Warning "Could not resolve resource API $ResourceAppId. Permission names for it will be placeholders."
    }

    $entry = $null
    if ($api) {
        $roleNames = @{}
        foreach ($r in @(Get-FieldList -Object $api -Path 'appRoles')) {
            $roleNames[[string](Get-Field -Object $r -Path 'id')] = [string](Get-Field -Object $r -Path 'value')
        }
        $scopeNames = @{}
        foreach ($s in @(Get-FieldList -Object $api -Path 'oauth2PermissionScopes')) {
            $scopeNames[[string](Get-Field -Object $s -Path 'id')] = [string](Get-Field -Object $s -Path 'value')
        }

        $displayName = [string](Get-Field -Object $api -Path 'displayName')
        # The module keys required_resource_access by the azuread provider's
        # published API name. Microsoft Graph is the common case and is known;
        # anything else is emitted as a CHANGEME for the reviewer to map.
        $hclKey = 'CHANGEME-' + ($displayName -replace '[^A-Za-z0-9]', '')
        if ($displayName -eq 'Microsoft Graph') { $hclKey = 'MicrosoftGraph' }

        $entry = @{
            DisplayName = $displayName
            HclKey      = $hclKey
            RoleNames   = $roleNames
            ScopeNames  = $scopeNames
        }
    }

    $script:ApiCache[$ResourceAppId] = $entry
    return $entry
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$requiredScopes = @('Application.Read.All')
if ($IncludeOwnersAndCredentials) { $requiredScopes += 'Directory.Read.All' }

$context = Get-MgContext
$needConnect = $true
if ($context) {
    $sameTenant = (-not $TenantId) -or ($context.TenantId -eq $TenantId)
    $sameCloud = (-not $PSBoundParameters.ContainsKey('Environment')) -or ($context.Environment -eq $Environment)
    $missingScopes = @($requiredScopes | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($sameTenant -and $sameCloud -and $missingScopes.Count -eq 0) {
        $needConnect = $false
        Write-Host "Using existing Microsoft Graph session for tenant $($context.TenantId) ($($context.Environment))."
    }
    else {
        Write-Host "Existing Microsoft Graph session does not match (tenant, cloud, or scopes). Reconnecting."
    }
}

if ($needConnect) {
    if (-not $TenantId) {
        throw "No usable Microsoft Graph session. Pass -TenantId to sign in with a device code."
    }
    Write-Host "Signing in to tenant $TenantId ($Environment) with a device code. Scopes: $($requiredScopes -join ', ')"
    Connect-MgGraph -TenantId $TenantId -Environment $Environment -Scopes $requiredScopes -UseDeviceCode -NoWelcome | Out-Null
    $context = Get-MgContext
    if (-not $context) { throw "Connect-MgGraph did not establish a session." }
}

$tenantId = [string]$context.TenantId
$cloud = [string]$context.Environment

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

$managed = Get-ManagedNames -Path $ManagedNamesPath
Write-Host "Managed names: $($managed.Count) from $ManagedNamesPath"

Write-Host "Reading application registrations..."
$applications = @(Invoke-GraphGetAll -Uri "/v1.0/applications?`$select=id,appId,displayName,signInAudience,identifierUris,web,tags,notes,requiredResourceAccess,passwordCredentials,createdDateTime&`$top=999")
Write-Host "  $($applications.Count) registration(s)."

Write-Host "Reading service principals..."
$servicePrincipals = @(Invoke-GraphGetAll -Uri "/v1.0/servicePrincipals?`$select=id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled,appRoleAssignmentRequired&`$top=999")
Write-Host "  $($servicePrincipals.Count) service principal(s)."

# ---------------------------------------------------------------------------
# Classify
# ---------------------------------------------------------------------------

$spByAppId = @{}
$tenantOwnedSps = New-Object System.Collections.ArrayList
$thirdPartyCount = 0
$managedIdentityCount = 0

foreach ($sp in $servicePrincipals) {
    $appId = [string](Get-Field -Object $sp -Path 'appId')
    $type = [string](Get-Field -Object $sp -Path 'servicePrincipalType')
    $ownerOrg = [string](Get-Field -Object $sp -Path 'appOwnerOrganizationId')

    if ($appId -and -not $spByAppId.ContainsKey($appId)) { $spByAppId[$appId] = $sp }

    if ($type -eq 'ManagedIdentity') { $managedIdentityCount++; continue }
    if ($type -eq 'Application' -and $ownerOrg -eq $tenantId) { [void]$tenantOwnedSps.Add($sp); continue }
    if ($type -eq 'Application') { $thirdPartyCount++ }
}

$appByAppId = @{}
$seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$duplicateNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($app in $applications) {
    $appByAppId[[string](Get-Field -Object $app -Path 'appId')] = $app
    $name = [string](Get-Field -Object $app -Path 'displayName')
    if (-not $seenNames.Add($name)) { [void]$duplicateNames.Add($name) }
}

$unmanaged = New-Object System.Collections.ArrayList
$managedFindings = New-Object System.Collections.ArrayList
$foundManagedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($app in ($applications | Sort-Object -Property displayName)) {
    $name = [string](Get-Field -Object $app -Path 'displayName')
    $appId = [string](Get-Field -Object $app -Path 'appId')
    $secretCount = @(Get-FieldList -Object $app -Path 'passwordCredentials').Count
    $hasSp = $spByAppId.ContainsKey($appId)

    if ($managed.Contains($name)) {
        [void]$foundManagedNames.Add($name)
        if ($secretCount -gt 0) {
            [void]$managedFindings.Add(@{ Name = $name; ObjectId = [string](Get-Field -Object $app -Path 'id'); Finding = "$secretCount client secret(s) present. The module never creates secrets; this was added outside Terraform." })
        }
        if (-not $hasSp) {
            [void]$managedFindings.Add(@{ Name = $name; ObjectId = [string](Get-Field -Object $app -Path 'id'); Finding = 'No service principal. The stack always creates one; it was deleted outside Terraform.' })
        }
        if ($duplicateNames.Contains($name)) {
            [void]$managedFindings.Add(@{ Name = $name; ObjectId = [string](Get-Field -Object $app -Path 'id'); Finding = 'Display name is not unique in the tenant. The module sets prevent_duplicate_names; adoption by name is ambiguous.' })
        }
    }
    else {
        [void]$unmanaged.Add($app)
    }
}

$declaredButAbsent = @($managed | Where-Object { -not $foundManagedNames.Contains($_) } | Sort-Object)

$orphanedSps = @($tenantOwnedSps | Where-Object { -not $appByAppId.ContainsKey([string](Get-Field -Object $_ -Path 'appId')) } | Sort-Object -Property displayName)

# ---------------------------------------------------------------------------
# Build outputs
# ---------------------------------------------------------------------------

$generatedOn = Get-Date -Format 'yyyy-MM-dd'
$report = New-Object System.Text.StringBuilder
$imports = New-Object System.Text.StringBuilder
$values = New-Object System.Text.StringBuilder
$usedKeys = @{}

[void]$report.AppendLine("# Entra application drift report")
[void]$report.AppendLine("")
[void]$report.AppendLine("Generated by scripts/Export-EntraDrift.ps1 on $generatedOn.")
[void]$report.AppendLine("")
[void]$report.AppendLine("| | |")
[void]$report.AppendLine("|---|---|")
[void]$report.AppendLine("| Tenant | $tenantId |")
[void]$report.AppendLine("| Cloud | $cloud |")
[void]$report.AppendLine("| Managed names source | $(Format-MarkdownCell -Value $ManagedNamesPath) ($($managed.Count) names) |")
[void]$report.AppendLine("")
[void]$report.AppendLine("## Summary")
[void]$report.AppendLine("")
[void]$report.AppendLine("| Category | Count |")
[void]$report.AppendLine("|----------|-------|")
[void]$report.AppendLine("| Application registrations in tenant | $($applications.Count) |")
[void]$report.AppendLine("| Managed (declared and present) | $($foundManagedNames.Count) |")
[void]$report.AppendLine("| Unmanaged (import candidates) | $($unmanaged.Count) |")
[void]$report.AppendLine("| Managed with findings | $($managedFindings.Count) |")
[void]$report.AppendLine("| Declared but absent (plan will create) | $($declaredButAbsent.Count) |")
[void]$report.AppendLine("| Orphaned tenant-owned service principals | $($orphanedSps.Count) |")
[void]$report.AppendLine("| Third-party enterprise applications (not candidates) | $thirdPartyCount |")
[void]$report.AppendLine("| Managed identities (not candidates) | $managedIdentityCount |")
[void]$report.AppendLine("")

[void]$imports.AppendLine("# Generated by scripts/Export-EntraDrift.ps1 on $generatedOn for tenant $tenantId ($cloud)")
[void]$imports.AppendLine("# Place beside the tenant terragrunt.hcl. Delete after the first successful apply.")
[void]$imports.AppendLine("")

[void]$values.AppendLine("# Generated by scripts/Export-EntraDrift.ps1 on $generatedOn for tenant $tenantId ($cloud)")
[void]$values.AppendLine("# Review every value. Merge into the applications block of the tenant terragrunt.hcl.")
[void]$values.AppendLine("# Keys are derived from display names; rename them before the first apply if you")
[void]$values.AppendLine("# prefer different addresses, never after.")
[void]$values.AppendLine("")
[void]$values.AppendLine("applications = {")

# ---- Unmanaged registrations ----------------------------------------------

[void]$report.AppendLine("## Unmanaged application registrations (import candidates)")
[void]$report.AppendLine("")
if ($unmanaged.Count -eq 0) {
    [void]$report.AppendLine("None. Every registration in the tenant is declared in the managed list.")
    [void]$report.AppendLine("")
}
else {
    [void]$report.AppendLine("| Display name | Object ID | Client ID | Sign-in audience | Secrets | Service principal | Created |")
    [void]$report.AppendLine("|--------------|-----------|-----------|------------------|---------|-------------------|---------|")
}

foreach ($app in $unmanaged) {
    $name = [string](Get-Field -Object $app -Path 'displayName')
    $objectId = [string](Get-Field -Object $app -Path 'id')
    $appId = [string](Get-Field -Object $app -Path 'appId')
    $audience = [string](Get-Field -Object $app -Path 'signInAudience')
    $secretCount = @(Get-FieldList -Object $app -Path 'passwordCredentials').Count
    $created = [string](Get-Field -Object $app -Path 'createdDateTime')
    $sp = $null
    if ($spByAppId.ContainsKey($appId)) { $sp = $spByAppId[$appId] }
    $spCell = 'missing'
    if ($sp) { $spCell = [string](Get-Field -Object $sp -Path 'id') }

    [void]$report.AppendLine("| $(Format-MarkdownCell -Value $name) | $objectId | $appId | $audience | $secretCount | $spCell | $created |")

    $key = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name $name) -Used $usedKeys

    # Import blocks. Application by resource ID, service principal by object ID.
    [void]$imports.AppendLine("import {")
    [void]$imports.AppendLine("  to = $ModuleAddress.azuread_application.this[$(Format-HclString -Value $key)]")
    [void]$imports.AppendLine("  id = $(Format-HclString -Value "/applications/$objectId")")
    [void]$imports.AppendLine("}")
    [void]$imports.AppendLine("")
    if ($sp) {
        [void]$imports.AppendLine("import {")
        [void]$imports.AppendLine("  to = $ModuleAddress.azuread_service_principal.this[$(Format-HclString -Value $key)]")
        [void]$imports.AppendLine("  id = $(Format-HclString -Value ([string](Get-Field -Object $sp -Path 'id')))")
        [void]$imports.AppendLine("}")
        [void]$imports.AppendLine("")
    }
    else {
        [void]$imports.AppendLine("# '$name' has no service principal. The stack will create one on apply; no import needed.")
        [void]$imports.AppendLine("")
    }

    # Values skeleton.
    [void]$values.AppendLine("  $(Format-HclString -Value $key) = {")
    if ($secretCount -gt 0) {
        [void]$values.AppendLine("    # WARNING: $secretCount client secret(s) exist on this registration. The module never")
        [void]$values.AppendLine("    # creates secrets. Move the workload to a federated credential and delete the")
        [void]$values.AppendLine("    # secrets before adoption, or accept a standing drift finding.")
    }
    [void]$values.AppendLine("    display_name     = $(Format-HclString -Value $name)")
    [void]$values.AppendLine("    sign_in_audience = $(Format-HclString -Value $audience)")

    $ownerUpns = @()
    $credentials = @()
    if ($IncludeOwnersAndCredentials) {
        try {
            $owners = @(Invoke-GraphGetAll -Uri "/v1.0/applications/$objectId/owners?`$select=id,userPrincipalName")
            $ownerUpns = @($owners | ForEach-Object { [string](Get-Field -Object $_ -Path 'userPrincipalName') } | Where-Object { $_ })
        }
        catch { Write-Warning "Could not read owners of '$name'." }
        try {
            $credentials = @(Invoke-GraphGetAll -Uri "/v1.0/applications/$objectId/federatedIdentityCredentials")
        }
        catch { Write-Warning "Could not read federated credentials of '$name'." }
        [void]$values.AppendLine("    owners           = $(Format-HclList -Values $ownerUpns)")
    }
    else {
        [void]$values.AppendLine("    owners           = [] # run with -IncludeOwnersAndCredentials to populate")
    }

    $identifierUris = @(@(Get-FieldList -Object $app -Path 'identifierUris') | ForEach-Object { [string]$_ })
    if ($identifierUris.Count -gt 0) { [void]$values.AppendLine("    identifier_uris  = $(Format-HclList -Values $identifierUris)") }

    $redirectUris = @(@(Get-FieldList -Object $app -Path 'web.redirectUris') | ForEach-Object { [string]$_ })
    if ($redirectUris.Count -gt 0) { [void]$values.AppendLine("    web_redirect_uris = $(Format-HclList -Values $redirectUris)") }
    $homepage = Get-Field -Object $app -Path 'web.homePageUrl'
    if ($homepage) { [void]$values.AppendLine("    web_homepage_url = $(Format-HclString -Value ([string]$homepage))") }
    $logout = Get-Field -Object $app -Path 'web.logoutUrl'
    if ($logout) { [void]$values.AppendLine("    web_logout_url   = $(Format-HclString -Value ([string]$logout))") }

    $tags = @(@(Get-FieldList -Object $app -Path 'tags') | ForEach-Object { [string]$_ })
    if ($tags.Count -gt 0) { [void]$values.AppendLine("    tags             = $(Format-HclList -Values $tags)") }

    # API permissions, resolved from IDs to names through each API's service principal.
    $rra = @(Get-FieldList -Object $app -Path 'requiredResourceAccess')
    if ($rra.Count -gt 0) {
        [void]$values.AppendLine("")
        [void]$values.AppendLine("    required_resource_access = {")
        foreach ($entry in $rra) {
            $resourceAppId = [string](Get-Field -Object $entry -Path 'resourceAppId')
            $api = Get-ResourceApi -ResourceAppId $resourceAppId
            $roles = New-Object System.Collections.ArrayList
            $scopes = New-Object System.Collections.ArrayList
            foreach ($access in @(Get-FieldList -Object $entry -Path 'resourceAccess')) {
                $accessId = [string](Get-Field -Object $access -Path 'id')
                $accessType = [string](Get-Field -Object $access -Path 'type')
                $resolved = "CHANGEME-unknown-$accessId"
                if ($api) {
                    if ($accessType -eq 'Role' -and $api.RoleNames.ContainsKey($accessId)) { $resolved = $api.RoleNames[$accessId] }
                    if ($accessType -eq 'Scope' -and $api.ScopeNames.ContainsKey($accessId)) { $resolved = $api.ScopeNames[$accessId] }
                }
                if ($accessType -eq 'Role') { [void]$roles.Add($resolved) } else { [void]$scopes.Add($resolved) }
            }

            $apiKey = "CHANGEME-unknown-api"
            $apiLabel = $resourceAppId
            if ($api) { $apiKey = $api.HclKey; $apiLabel = $api.DisplayName }
            if ($apiKey -like 'CHANGEME-*') {
                [void]$values.AppendLine("      # '$apiLabel': map to the azuread_application_published_app_ids key for this API.")
            }
            [void]$values.AppendLine("      $apiKey = {")
            if ($roles.Count -gt 0) { [void]$values.AppendLine("        application = $(Format-HclList -Values @($roles.ToArray()))") }
            if ($scopes.Count -gt 0) { [void]$values.AppendLine("        delegated   = $(Format-HclList -Values @($scopes.ToArray()))") }
            [void]$values.AppendLine("      }")
        }
        [void]$values.AppendLine("    }")
    }

    # Federated credentials, when read.
    if ($credentials.Count -gt 0) {
        $credKeys = @{}
        [void]$values.AppendLine("")
        [void]$values.AppendLine("    federated_credentials = {")
        foreach ($cred in $credentials) {
            $credName = [string](Get-Field -Object $cred -Path 'name')
            $credId = [string](Get-Field -Object $cred -Path 'id')
            $credKey = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name $credName) -Used $credKeys
            $audiences = @(@(Get-FieldList -Object $cred -Path 'audiences') | ForEach-Object { [string]$_ })
            [void]$values.AppendLine("      $(Format-HclString -Value $credKey) = {")
            [void]$values.AppendLine("        display_name = $(Format-HclString -Value $credName)")
            [void]$values.AppendLine("        issuer       = $(Format-HclString -Value ([string](Get-Field -Object $cred -Path 'issuer')))")
            [void]$values.AppendLine("        subject      = $(Format-HclString -Value ([string](Get-Field -Object $cred -Path 'subject')))")
            [void]$values.AppendLine("        audiences    = $(Format-HclList -Values $audiences)")
            [void]$values.AppendLine("      }")

            [void]$imports.AppendLine("import {")
            [void]$imports.AppendLine("  to = $ModuleAddress.azuread_application_federated_identity_credential.this[$(Format-HclString -Value "$key/$credKey")]")
            [void]$imports.AppendLine("  id = $(Format-HclString -Value "$objectId/federatedIdentityCredential/$credId")")
            [void]$imports.AppendLine("}")
            [void]$imports.AppendLine("")
        }
        [void]$values.AppendLine("    }")
    }

    # Service principal settings.
    if ($sp) {
        [void]$values.AppendLine("")
        [void]$values.AppendLine("    service_principal = {")
        [void]$values.AppendLine("      account_enabled              = $(Format-HclBool -Value (Get-Field -Object $sp -Path 'accountEnabled'))")
        [void]$values.AppendLine("      app_role_assignment_required = $(Format-HclBool -Value (Get-Field -Object $sp -Path 'appRoleAssignmentRequired'))")
        [void]$values.AppendLine("    }")
    }

    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
}

[void]$values.AppendLine("}")
if ($unmanaged.Count -gt 0) { [void]$report.AppendLine("") }

# ---- Managed registrations with findings ----------------------------------

[void]$report.AppendLine("## Managed registrations with findings")
[void]$report.AppendLine("")
if ($managedFindings.Count -eq 0) {
    [void]$report.AppendLine("None.")
}
else {
    [void]$report.AppendLine("| Display name | Object ID | Finding |")
    [void]$report.AppendLine("|--------------|-----------|---------|")
    foreach ($f in $managedFindings) {
        [void]$report.AppendLine("| $(Format-MarkdownCell -Value $f.Name) | $($f.ObjectId) | $(Format-MarkdownCell -Value $f.Finding) |")
    }
}
[void]$report.AppendLine("")

# ---- Declared but absent --------------------------------------------------

[void]$report.AppendLine("## Declared but absent")
[void]$report.AppendLine("")
if ($declaredButAbsent.Count -eq 0) {
    [void]$report.AppendLine("None. Every managed name exists in the tenant.")
}
else {
    [void]$report.AppendLine("These names are in the managed list but no registration carries them. A plan will create them; if that is not intended, the name is misspelled or the registration was deleted outside Terraform.")
    [void]$report.AppendLine("")
    foreach ($n in $declaredButAbsent) { [void]$report.AppendLine("- $(Format-MarkdownCell -Value $n)") }
}
[void]$report.AppendLine("")

# ---- Orphaned service principals ------------------------------------------

[void]$report.AppendLine("## Orphaned tenant-owned service principals")
[void]$report.AppendLine("")
if ($orphanedSps.Count -eq 0) {
    [void]$report.AppendLine("None.")
}
else {
    [void]$report.AppendLine("Service principals owned by this tenant whose application registration no longer exists. Usually a deleted registration whose enterprise application was left behind.")
    [void]$report.AppendLine("")
    [void]$report.AppendLine("| Display name | Object ID | Client ID |")
    [void]$report.AppendLine("|--------------|-----------|-----------|")
    foreach ($sp in $orphanedSps) {
        [void]$report.AppendLine("| $(Format-MarkdownCell -Value ([string](Get-Field -Object $sp -Path 'displayName'))) | $([string](Get-Field -Object $sp -Path 'id')) | $([string](Get-Field -Object $sp -Path 'appId')) |")
    }
}
[void]$report.AppendLine("")

# ---------------------------------------------------------------------------
# Write (or, under -WhatIf, print)
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Summary:"
Write-Host "  registrations $($applications.Count), managed $($foundManagedNames.Count), unmanaged $($unmanaged.Count), findings $($managedFindings.Count), declared-but-absent $($declaredButAbsent.Count), orphaned SPs $($orphanedSps.Count)"
Write-Host ""

$reportPath = Join-Path -Path $OutputDirectory -ChildPath 'drift-report.md'
$importsPath = Join-Path -Path $OutputDirectory -ChildPath 'imports.tf'
$valuesPath = Join-Path -Path $OutputDirectory -ChildPath 'values.skeleton.hcl'

if ($PSCmdlet.ShouldProcess($OutputDirectory, "Write drift-report.md, imports.tf, values.skeleton.hcl")) {
    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($reportPath, ($report.ToString() -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($importsPath, ($imports.ToString() -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($valuesPath, ($values.ToString() -replace "`r`n", "`n"), $utf8NoBom)

    Write-Host "Wrote:"
    Write-Host "  $reportPath"
    Write-Host "  $importsPath"
    Write-Host "  $valuesPath"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Read drift-report.md. Decide which unmanaged registrations to adopt and which to delete."
    Write-Host "  2. Merge the chosen entries from values.skeleton.hcl into the tenant terragrunt.hcl and review every value."
    Write-Host "  3. Copy imports.tf next to that terragrunt.hcl, keeping only the blocks for adopted registrations."
    Write-Host "  4. Run 'terragrunt plan' and iterate until it reports 0 to add, 0 to change, 0 to destroy."
    Write-Host "  5. Run 'terragrunt apply' (records imports only), then delete imports.tf."
}
else {
    Write-Host "Dry run. Nothing written. Report follows."
    Write-Host ""
    Write-Host $report.ToString()
}
