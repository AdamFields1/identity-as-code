<#
.SYNOPSIS
    Reads an existing Okta tenant and emits Terraform import blocks plus a values
    skeleton so the tenant can be adopted into stacks/okta-config with a zero-change plan.

.DESCRIPTION
    Lists network zones and the sign-on, MFA enrollment, and password policies (with
    their rules) through the Okta REST API, then writes two files:

      imports.tf            Terraform import blocks addressed to the stack's module
                            resources. Drop this next to a tenant terragrunt.hcl;
                            tenants/okta/root.hcl picks it up automatically.

      values.skeleton.hcl   A starting point for the tenant's inputs block, populated
                            from the live configuration. Review every value, then
                            paste it into terragrunt.hcl.

    The stack manages exactly one policy of each type. When more than one non-system
    policy exists and no name is given, the highest priority one is chosen and the
    others are listed as comments.

    The API token is read from an environment variable and is never written to the
    console, to a file, or to an error message.

.PARAMETER OrgUrl
    Base URL of the tenant, for example https://example-org.oktapreview.com

.PARAMETER TokenEnvVar
    Name of the environment variable holding the SSWS API token. Default: OKTA_API_TOKEN

.PARAMETER OutputDirectory
    Where imports.tf and values.skeleton.hcl are written. Default: .\out (git-ignored).

.PARAMETER SignOnPolicyName
    Name of the sign-on policy to adopt. Optional.

.PARAMETER MfaPolicyName
    Name of the MFA enrollment policy to adopt. Optional.

.PARAMETER PasswordPolicyName
    Name of the password policy to adopt. Optional.

.EXAMPLE
    $env:OKTA_API_TOKEN = '<paste token, do not commit>'
    .\Import-OktaPolicies.ps1 -OrgUrl https://example-org.oktapreview.com -OutputDirectory .\out

.EXAMPLE
    .\Import-OktaPolicies.ps1 -OrgUrl https://example-org.okta.com `
        -SignOnPolicyName 'Workforce sign-on' `
        -MfaPolicyName 'Workforce MFA enrollment' `
        -PasswordPolicyName 'Workforce password'

.NOTES
    Windows PowerShell 5.1 compatible. Requires only Invoke-WebRequest and ConvertFrom-Json.
    Token scopes needed: okta.policies.read, okta.networkZones.read, okta.groups.read.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[a-z0-9][a-z0-9.-]+$')]
    [string]$OrgUrl,

    [ValidateNotNullOrEmpty()]
    [string]$TokenEnvVar = 'OKTA_API_TOKEN',

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path -Path (Get-Location) -ChildPath 'out'),

    [string]$SignOnPolicyName,

    [string]$MfaPolicyName,

    [string]$PasswordPolicyName
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:BaseUri = $OrgUrl.TrimEnd('/')
$script:GroupNameCache = @{}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-OktaApiToken {
    <# Reads the token from the environment. The value is returned to the caller
       and nowhere else. #>
    param([Parameter(Mandatory = $true)][string]$VariableName)

    $value = [Environment]::GetEnvironmentVariable($VariableName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Environment variable '$VariableName' is not set. Export the Okta API token there and re-run."
    }
    return $value
}

function Get-Prop {
    <# Safe nested property read on ConvertFrom-Json output. Returns $null when any
       segment is missing instead of throwing. #>
    param([object]$Object, [Parameter(Mandatory = $true)][string]$Path)

    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Get-PropList {
    <# Like Get-Prop but always yields a flat list with nulls removed. Callers wrap
       the result in @() so a missing or empty property is a zero-length array, never
       the one-element @($null) that PowerShell would otherwise produce. #>
    param([object]$Object, [Parameter(Mandatory = $true)][string]$Path)

    $value = Get-Prop -Object $Object -Path $Path
    if ($null -eq $value) { return }
    return @($value | Where-Object { $null -ne $_ })
}

function Invoke-OktaGet {
    <# Paginated GET. Follows rel="next" Link headers and retries once on 429. #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $results = New-Object System.Collections.ArrayList
    if ($Path -match '^https://') { $uri = $Path } else { $uri = $script:BaseUri + $Path }

    while ($uri) {
        $headers = @{
            Authorization  = "SSWS $Token"
            Accept         = 'application/json'
            'Content-Type' = 'application/json'
        }

        $attempt = 0
        $response = $null
        while ($null -eq $response) {
            $attempt++
            try {
                $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing
            }
            catch [System.Net.WebException] {
                $status = $null
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                if ($status -eq 429 -and $attempt -lt 3) {
                    $resetHeader = $_.Exception.Response.Headers['x-rate-limit-reset']
                    $waitSeconds = 10
                    if ($resetHeader) {
                        $resetEpoch = [int64]$resetHeader
                        $nowEpoch = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                        $waitSeconds = [Math]::Max(1, ($resetEpoch - $nowEpoch) + 1)
                    }
                    Write-Warning "Rate limited by Okta. Waiting $waitSeconds second(s) before retrying."
                    Start-Sleep -Seconds $waitSeconds
                    continue
                }
                throw "GET $uri failed with HTTP $status. Check the org URL and token scopes."
            }
        }

        $page = $response.Content | ConvertFrom-Json
        if ($null -ne $page) {
            foreach ($item in @($page)) { [void]$results.Add($item) }
        }

        $uri = $null
        $link = $response.Headers['Link']
        if ($link) {
            foreach ($part in ($link -split ',')) {
                if ($part -match '<([^>]+)>;\s*rel="next"') { $uri = $Matches[1] }
            }
        }
    }

    return $results.ToArray()
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

function Format-HclScalar {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) { return [string]$Value }
    return Format-HclString -Value ([string]$Value)
}

function Resolve-OktaGroupName {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$Token
    )

    if ($script:GroupNameCache.ContainsKey($GroupId)) { return $script:GroupNameCache[$GroupId] }

    $name = "CHANGEME-group-$GroupId"
    try {
        $group = @(Invoke-OktaGet -Path "/api/v1/groups/$GroupId" -Token $Token)
        $resolved = $null
        if ($group.Count -gt 0) { $resolved = Get-Prop -Object $group[0] -Path 'profile.name' }
        if ($resolved) { $name = [string]$resolved }
    }
    catch {
        Write-Warning "Could not resolve group $GroupId to a name. Placeholder emitted."
    }
    $script:GroupNameCache[$GroupId] = $name
    return $name
}

function Select-OktaPolicy {
    param(
        [AllowNull()][object[]]$Policies,
        [AllowEmptyString()][string]$RequestedName,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $all = @($Policies)
    if ($all.Count -eq 0) {
        Write-Warning "No $Label policies found in the tenant."
        return $null
    }

    if ($RequestedName) {
        $match = @($all | Where-Object { $_.name -eq $RequestedName })
        if ($match.Count -eq 0) {
            $names = ($all | ForEach-Object { $_.name }) -join "', '"
            throw "$Label policy '$RequestedName' not found. Available: '$names'."
        }
        return $match[0]
    }

    $candidates = @($all | Where-Object { -not (Get-Prop -Object $_ -Path 'system') } | Sort-Object -Property priority)
    if ($candidates.Count -eq 0) {
        Write-Warning "Only the system default $Label policy exists. The stack does not manage default policies; nothing to import."
        return $null
    }
    if ($candidates.Count -gt 1) {
        $others = ($candidates | Select-Object -Skip 1 | ForEach-Object { "'$($_.name)' (priority $($_.priority))" }) -join ', '
        Write-Warning "Multiple $Label policies found. Using '$($candidates[0].name)'. Others: $others. Pass a name parameter to choose."
    }
    return $candidates[0]
}

function Get-NetworkBlock {
    <# Emits network_connection and zones_included/excluded lines for a rule, using
       the zone ID -> logical key map so the skeleton never contains an ID. #>
    param(
        [object]$Rule,
        [hashtable]$ZoneKeyById,
        [string]$Indent
    )

    $lines = New-Object System.Collections.ArrayList
    $connection = Get-Prop -Object $Rule -Path 'conditions.network.connection'
    if ($null -eq $connection) { $connection = 'ANYWHERE' }

    if ($connection -eq 'ZONE') {
        [void]$lines.Add("${Indent}network_connection = `"ZONE`"")
        $include = @(Get-PropList -Object $Rule -Path 'conditions.network.include')
        $exclude = @(Get-PropList -Object $Rule -Path 'conditions.network.exclude')
        if ($include.Count -gt 0) {
            $keys = @($include | ForEach-Object { if ($ZoneKeyById.ContainsKey($_)) { $ZoneKeyById[$_] } else { "CHANGEME-unknown-zone-$_" } })
            [void]$lines.Add("${Indent}zones_included     = $(Format-HclList -Values $keys)")
        }
        if ($exclude.Count -gt 0) {
            $keys = @($exclude | ForEach-Object { if ($ZoneKeyById.ContainsKey($_)) { $ZoneKeyById[$_] } else { "CHANGEME-unknown-zone-$_" } })
            [void]$lines.Add("${Indent}zones_excluded     = $(Format-HclList -Values $keys)")
        }
    }
    elseif ($connection -eq 'ANYWHERE') {
        [void]$lines.Add("${Indent}network_connection = `"ANYWHERE`"")
    }
    else {
        [void]$lines.Add("${Indent}network_connection = `"CHANGEME`" # live value '$connection' is not modelled by the stack (ANYWHERE or ZONE only)")
    }

    return $lines.ToArray()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$token = Get-OktaApiToken -VariableName $TokenEnvVar

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$imports = New-Object System.Text.StringBuilder
$values = New-Object System.Text.StringBuilder
$usedKeys = @{}

[void]$imports.AppendLine("# Generated by scripts/Import-OktaPolicies.ps1 on $(Get-Date -Format 'yyyy-MM-dd') for $script:BaseUri")
[void]$imports.AppendLine("# Place beside the tenant terragrunt.hcl. Delete after the first successful apply.")
[void]$imports.AppendLine("")

[void]$values.AppendLine("# Generated by scripts/Import-OktaPolicies.ps1 on $(Get-Date -Format 'yyyy-MM-dd') for $script:BaseUri")
[void]$values.AppendLine("# Review every value. Paste into the tenant terragrunt.hcl inputs block.")
[void]$values.AppendLine("")

# ---- Network zones ---------------------------------------------------------

Write-Host "Reading network zones..."
$zones = @(Invoke-OktaGet -Path '/api/v1/zones' -Token $token)
$zoneKeyById = @{}

[void]$values.AppendLine("network_zones = {")
foreach ($zone in $zones) {
    $key = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name ([string]$zone.name)) -Used $usedKeys
    $zoneKeyById[[string]$zone.id] = $key

    [void]$imports.AppendLine("import {")
    [void]$imports.AppendLine("  to = module.network_zones.okta_network_zone.this[$(Format-HclString -Value $key)]")
    [void]$imports.AppendLine("  id = $(Format-HclString -Value ([string]$zone.id))")
    [void]$imports.AppendLine("}")
    [void]$imports.AppendLine("")

    $zoneType = [string]$zone.type
    if ($zoneType -eq 'DYNAMIC_V2') { $zoneType = 'DYNAMIC' }

    [void]$values.AppendLine("  $(Format-HclString -Value $key) = {")
    [void]$values.AppendLine("    name   = $(Format-HclString -Value ([string]$zone.name))")
    [void]$values.AppendLine("    type   = $(Format-HclString -Value $zoneType)")
    [void]$values.AppendLine("    usage  = $(Format-HclString -Value ([string]$zone.usage))")
    [void]$values.AppendLine("    status = $(Format-HclString -Value ([string]$zone.status))")

    if ($zoneType -eq 'IP') {
        $gateways = @(@(Get-PropList -Object $zone -Path 'gateways') | ForEach-Object { [string]$_.value })
        $proxies = @(@(Get-PropList -Object $zone -Path 'proxies') | ForEach-Object { [string]$_.value })
        if ($gateways.Count -gt 0) { [void]$values.AppendLine("    gateways = $(Format-HclList -Values $gateways)") }
        if ($proxies.Count -gt 0) { [void]$values.AppendLine("    proxies  = $(Format-HclList -Values $proxies)") }
    }
    else {
        $locations = @(@(Get-PropList -Object $zone -Path 'locations') | ForEach-Object {
                $region = Get-Prop -Object $_ -Path 'region'
                if ($region) { [string]$region } else { [string](Get-Prop -Object $_ -Path 'country') }
            })
        $asns = @(@(Get-PropList -Object $zone -Path 'asns') | ForEach-Object { [string]$_ })
        $proxyType = Get-Prop -Object $zone -Path 'proxyType'
        if ($locations.Count -gt 0) { [void]$values.AppendLine("    dynamic_locations  = $(Format-HclList -Values $locations)") }
        if ($asns.Count -gt 0) { [void]$values.AppendLine("    asns               = $(Format-HclList -Values $asns)") }
        if ($proxyType) { [void]$values.AppendLine("    dynamic_proxy_type = $(Format-HclString -Value ([string]$proxyType))") }
    }
    [void]$values.AppendLine("  }")
}
[void]$values.AppendLine("}")
[void]$values.AppendLine("")
Write-Host "  $($zones.Count) zone(s)."

# ---- Sign-on policy --------------------------------------------------------

Write-Host "Reading sign-on policies..."
$signOnPolicies = @(Invoke-OktaGet -Path '/api/v1/policies?type=OKTA_SIGN_ON' -Token $token)
$signOn = Select-OktaPolicy -Policies $signOnPolicies -RequestedName $SignOnPolicyName -Label 'sign-on'

if ($signOn) {
    $policyId = [string]$signOn.id
    $rules = @(Invoke-OktaGet -Path "/api/v1/policies/$policyId/rules" -Token $token)
    $groupIds = @(Get-PropList -Object $signOn -Path 'conditions.people.groups.include')
    $groupNames = @($groupIds | ForEach-Object { Resolve-OktaGroupName -GroupId ([string]$_) -Token $token })

    [void]$imports.AppendLine("import {")
    [void]$imports.AppendLine("  to = module.session_policy.okta_policy_signon.this")
    [void]$imports.AppendLine("  id = $(Format-HclString -Value $policyId)")
    [void]$imports.AppendLine("}")
    [void]$imports.AppendLine("")

    [void]$values.AppendLine("session_policy = {")
    [void]$values.AppendLine("  name            = $(Format-HclString -Value ([string]$signOn.name))")
    [void]$values.AppendLine("  priority        = $(Format-HclScalar -Value $signOn.priority)")
    [void]$values.AppendLine("  status          = $(Format-HclString -Value ([string]$signOn.status))")
    [void]$values.AppendLine("  groups_included = $(Format-HclList -Values $groupNames)")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  # session_defaults are policy-level fallbacks; each rule below carries its live values.")
    [void]$values.AppendLine("  session_defaults = {")
    [void]$values.AppendLine("    idle_minutes      = 120")
    [void]$values.AppendLine("    lifetime_minutes  = 720")
    [void]$values.AppendLine("    persistent_cookie = false")
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  rules = {")

    $ruleKeys = @{}
    foreach ($rule in $rules) {
        $ruleKey = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name ([string]$rule.name)) -Used $ruleKeys
        $isSystem = [bool](Get-Prop -Object $rule -Path 'system')
        $prefix = ''
        if ($isSystem) {
            $prefix = '# '
            [void]$imports.AppendLine("# Rule '$($rule.name)' is system-managed and cannot be imported or deleted. Skipped.")
        }
        else {
            [void]$imports.AppendLine("import {")
            [void]$imports.AppendLine("  to = module.session_policy.okta_policy_rule_signon.this[$(Format-HclString -Value $ruleKey)]")
            [void]$imports.AppendLine("  id = $(Format-HclString -Value "$policyId/$([string]$rule.id)")")
            [void]$imports.AppendLine("}")
        }
        [void]$imports.AppendLine("")

        $signon = Get-Prop -Object $rule -Path 'actions.signon'
        [void]$values.AppendLine("    ${prefix}$(Format-HclString -Value $ruleKey) = {")
        [void]$values.AppendLine("    ${prefix}  name                = $(Format-HclString -Value ([string]$rule.name))")
        [void]$values.AppendLine("    ${prefix}  priority            = $(Format-HclScalar -Value $rule.priority)")
        [void]$values.AppendLine("    ${prefix}  status              = $(Format-HclString -Value ([string]$rule.status))")
        [void]$values.AppendLine("    ${prefix}  access              = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'access'))")
        [void]$values.AppendLine("    ${prefix}  authtype            = $(Format-HclScalar -Value (Get-Prop -Object $rule -Path 'conditions.authContext.authType'))")
        [void]$values.AppendLine("    ${prefix}  mfa_required        = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'requireFactor'))")
        [void]$values.AppendLine("    ${prefix}  mfa_prompt          = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'factorPromptMode'))")
        [void]$values.AppendLine("    ${prefix}  mfa_lifetime        = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'factorLifetime'))")
        [void]$values.AppendLine("    ${prefix}  mfa_remember_device = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'rememberDeviceByDefault'))")
        foreach ($line in (Get-NetworkBlock -Rule $rule -ZoneKeyById $zoneKeyById -Indent "    ${prefix}  ")) { [void]$values.AppendLine($line) }
        [void]$values.AppendLine("    ${prefix}  session_idle        = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'session.maxSessionIdleMinutes'))")
        [void]$values.AppendLine("    ${prefix}  session_lifetime    = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'session.maxSessionLifetimeMinutes'))")
        [void]$values.AppendLine("    ${prefix}  session_persistent  = $(Format-HclScalar -Value (Get-Prop -Object $signon -Path 'session.usePersistentCookie'))")
        [void]$values.AppendLine("    ${prefix}}")
    }
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("}")
    [void]$values.AppendLine("")
    Write-Host "  '$($signOn.name)' with $($rules.Count) rule(s)."
}

# ---- MFA enrollment policy -------------------------------------------------

Write-Host "Reading MFA enrollment policies..."
$mfaPolicies = @(Invoke-OktaGet -Path '/api/v1/policies?type=MFA_ENROLL' -Token $token)
$mfa = Select-OktaPolicy -Policies $mfaPolicies -RequestedName $MfaPolicyName -Label 'MFA enrollment'

if ($mfa) {
    $policyId = [string]$mfa.id
    $rules = @(Invoke-OktaGet -Path "/api/v1/policies/$policyId/rules" -Token $token)
    $groupIds = @(Get-PropList -Object $mfa -Path 'conditions.people.groups.include')
    $groupNames = @($groupIds | ForEach-Object { Resolve-OktaGroupName -GroupId ([string]$_) -Token $token })

    [void]$imports.AppendLine("import {")
    [void]$imports.AppendLine("  to = module.mfa_policy.okta_policy_mfa.this")
    [void]$imports.AppendLine("  id = $(Format-HclString -Value $policyId)")
    [void]$imports.AppendLine("}")
    [void]$imports.AppendLine("")

    $settingsType = [string](Get-Prop -Object $mfa -Path 'settings.type')
    $isOie = ($settingsType -eq 'AUTHENTICATORS')

    [void]$values.AppendLine("mfa_policy = {")
    [void]$values.AppendLine("  name            = $(Format-HclString -Value ([string]$mfa.name))")
    [void]$values.AppendLine("  priority        = $(Format-HclScalar -Value $mfa.priority)")
    [void]$values.AppendLine("  status          = $(Format-HclString -Value ([string]$mfa.status))")
    [void]$values.AppendLine("  groups_included = $(Format-HclList -Values $groupNames)")
    [void]$values.AppendLine("  is_oie          = $(Format-HclScalar -Value $isOie)")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  authenticators = {")

    if ($isOie) {
        foreach ($auth in @(Get-PropList -Object $mfa -Path 'settings.authenticators')) {
            $authKey = [string](Get-Prop -Object $auth -Path 'key')
            $enroll = [string](Get-Prop -Object $auth -Path 'enroll.self')
            if ($authKey -and $enroll) {
                [void]$values.AppendLine("    $authKey = { enroll = $(Format-HclString -Value $enroll) }")
            }
        }
    }
    else {
        $factors = Get-Prop -Object $mfa -Path 'settings.factors'
        if ($factors) {
            foreach ($prop in $factors.PSObject.Properties) {
                $enroll = [string](Get-Prop -Object $prop.Value -Path 'enroll.self')
                $consent = [string](Get-Prop -Object $prop.Value -Path 'consent.type')
                if (-not $consent) { $consent = 'NONE' }
                if ($enroll) {
                    [void]$values.AppendLine("    $($prop.Name) = { enroll = $(Format-HclString -Value $enroll), consent_type = $(Format-HclString -Value $consent) }")
                }
            }
        }
    }
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  rules = {")

    $ruleKeys = @{}
    foreach ($rule in $rules) {
        $ruleKey = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name ([string]$rule.name)) -Used $ruleKeys
        $isSystem = [bool](Get-Prop -Object $rule -Path 'system')
        $prefix = ''
        if ($isSystem) {
            $prefix = '# '
            [void]$imports.AppendLine("# Rule '$($rule.name)' is system-managed and cannot be imported or deleted. Skipped.")
        }
        else {
            [void]$imports.AppendLine("import {")
            [void]$imports.AppendLine("  to = module.mfa_policy.okta_policy_rule_mfa.this[$(Format-HclString -Value $ruleKey)]")
            [void]$imports.AppendLine("  id = $(Format-HclString -Value "$policyId/$([string]$rule.id)")")
            [void]$imports.AppendLine("}")
        }
        [void]$imports.AppendLine("")

        [void]$values.AppendLine("    ${prefix}$(Format-HclString -Value $ruleKey) = {")
        [void]$values.AppendLine("    ${prefix}  name     = $(Format-HclString -Value ([string]$rule.name))")
        [void]$values.AppendLine("    ${prefix}  priority = $(Format-HclScalar -Value $rule.priority)")
        [void]$values.AppendLine("    ${prefix}  status   = $(Format-HclString -Value ([string]$rule.status))")
        [void]$values.AppendLine("    ${prefix}  enroll   = $(Format-HclScalar -Value (Get-Prop -Object $rule -Path 'actions.enroll.self'))")
        foreach ($line in (Get-NetworkBlock -Rule $rule -ZoneKeyById $zoneKeyById -Indent "    ${prefix}  ")) { [void]$values.AppendLine($line) }
        [void]$values.AppendLine("    ${prefix}}")
    }
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("}")
    [void]$values.AppendLine("")
    Write-Host "  '$($mfa.name)' with $($rules.Count) rule(s)."
}

# ---- Password policy -------------------------------------------------------

Write-Host "Reading password policies..."
$passwordPolicies = @(Invoke-OktaGet -Path '/api/v1/policies?type=PASSWORD' -Token $token)
$password = Select-OktaPolicy -Policies $passwordPolicies -RequestedName $PasswordPolicyName -Label 'password'

if ($password) {
    $policyId = [string]$password.id
    $rules = @(Invoke-OktaGet -Path "/api/v1/policies/$policyId/rules" -Token $token)
    $groupIds = @(Get-PropList -Object $password -Path 'conditions.people.groups.include')
    $groupNames = @($groupIds | ForEach-Object { Resolve-OktaGroupName -GroupId ([string]$_) -Token $token })

    [void]$imports.AppendLine("import {")
    [void]$imports.AppendLine("  to = module.password_policy.okta_policy_password.this")
    [void]$imports.AppendLine("  id = $(Format-HclString -Value $policyId)")
    [void]$imports.AppendLine("}")
    [void]$imports.AppendLine("")

    $pw = Get-Prop -Object $password -Path 'settings.password'
    $recovery = Get-Prop -Object $password -Path 'settings.recovery.factors'
    $excludeAttrs = @(@(Get-PropList -Object $pw -Path 'complexity.excludeAttributes') | ForEach-Object { [string]$_ })
    $authProvider = Get-Prop -Object $password -Path 'conditions.authProvider.provider'
    if (-not $authProvider) { $authProvider = 'OKTA' }

    [void]$values.AppendLine("password_policy = {")
    [void]$values.AppendLine("  name            = $(Format-HclString -Value ([string]$password.name))")
    [void]$values.AppendLine("  priority        = $(Format-HclScalar -Value $password.priority)")
    [void]$values.AppendLine("  status          = $(Format-HclString -Value ([string]$password.status))")
    [void]$values.AppendLine("  groups_included = $(Format-HclList -Values $groupNames)")
    [void]$values.AppendLine("  auth_provider   = $(Format-HclString -Value ([string]$authProvider))")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  complexity = {")
    [void]$values.AppendLine("    min_length         = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.minLength'))")
    [void]$values.AppendLine("    min_lowercase      = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.minLowerCase'))")
    [void]$values.AppendLine("    min_uppercase      = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.minUpperCase'))")
    [void]$values.AppendLine("    min_number         = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.minNumber'))")
    [void]$values.AppendLine("    min_symbol         = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.minSymbol'))")
    [void]$values.AppendLine("    exclude_username   = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.excludeUsername'))")
    [void]$values.AppendLine("    exclude_first_name = $(Format-HclScalar -Value ($excludeAttrs -contains 'firstName'))")
    [void]$values.AppendLine("    exclude_last_name  = $(Format-HclScalar -Value ($excludeAttrs -contains 'lastName'))")
    [void]$values.AppendLine("    dictionary_lookup  = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'complexity.dictionary.common.exclude'))")
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  age = {")
    [void]$values.AppendLine("    max_age_days     = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'age.maxAgeDays'))")
    [void]$values.AppendLine("    expire_warn_days = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'age.expireWarnDays'))")
    [void]$values.AppendLine("    min_age_minutes  = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'age.minAgeMinutes'))")
    [void]$values.AppendLine("    history_count    = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'age.historyCount'))")
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  lockout = {")
    [void]$values.AppendLine("    max_attempts          = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'lockout.maxAttempts'))")
    [void]$values.AppendLine("    auto_unlock_minutes   = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'lockout.autoUnlockMinutes'))")
    [void]$values.AppendLine("    show_failures         = $(Format-HclScalar -Value (Get-Prop -Object $pw -Path 'lockout.showLockoutFailures'))")
    $channels = @(@(Get-PropList -Object $pw -Path 'lockout.userLockoutNotificationChannels') | ForEach-Object { [string]$_ })
    [void]$values.AppendLine("    notification_channels = $(Format-HclList -Values $channels)")
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  recovery = {")
    [void]$values.AppendLine("    email               = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'okta_email.status'))")
    [void]$values.AppendLine("    email_token_minutes = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'okta_email.properties.recoveryToken.tokenLifetimeMinutes'))")
    [void]$values.AppendLine("    sms                 = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'okta_sms.status'))")
    [void]$values.AppendLine("    call                = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'okta_call.status'))")
    [void]$values.AppendLine("    question            = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'recovery_question.status'))")
    [void]$values.AppendLine("    question_min_length = $(Format-HclScalar -Value (Get-Prop -Object $recovery -Path 'recovery_question.properties.complexity.minLength'))")
    [void]$values.AppendLine("    skip_unlock         = $(Format-HclScalar -Value (Get-Prop -Object $password -Path 'settings.delegation.options.skipUnlock'))")
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("")
    [void]$values.AppendLine("  rules = {")

    $ruleKeys = @{}
    foreach ($rule in $rules) {
        $ruleKey = Get-UniqueKey -Key (ConvertTo-LogicalKey -Name ([string]$rule.name)) -Used $ruleKeys
        $isSystem = [bool](Get-Prop -Object $rule -Path 'system')
        $prefix = ''
        if ($isSystem) {
            $prefix = '# '
            [void]$imports.AppendLine("# Rule '$($rule.name)' is system-managed and cannot be imported or deleted. Skipped.")
        }
        else {
            [void]$imports.AppendLine("import {")
            [void]$imports.AppendLine("  to = module.password_policy.okta_policy_rule_password.this[$(Format-HclString -Value $ruleKey)]")
            [void]$imports.AppendLine("  id = $(Format-HclString -Value "$policyId/$([string]$rule.id)")")
            [void]$imports.AppendLine("}")
        }
        [void]$imports.AppendLine("")

        [void]$values.AppendLine("    ${prefix}$(Format-HclString -Value $ruleKey) = {")
        [void]$values.AppendLine("    ${prefix}  name            = $(Format-HclString -Value ([string]$rule.name))")
        [void]$values.AppendLine("    ${prefix}  priority        = $(Format-HclScalar -Value $rule.priority)")
        [void]$values.AppendLine("    ${prefix}  status          = $(Format-HclString -Value ([string]$rule.status))")
        [void]$values.AppendLine("    ${prefix}  password_change = $(Format-HclScalar -Value (Get-Prop -Object $rule -Path 'actions.passwordChange.access'))")
        [void]$values.AppendLine("    ${prefix}  password_reset  = $(Format-HclScalar -Value (Get-Prop -Object $rule -Path 'actions.selfServicePasswordReset.access'))")
        [void]$values.AppendLine("    ${prefix}  password_unlock = $(Format-HclScalar -Value (Get-Prop -Object $rule -Path 'actions.selfServiceUnlock.access'))")
        foreach ($line in (Get-NetworkBlock -Rule $rule -ZoneKeyById $zoneKeyById -Indent "    ${prefix}  ")) { [void]$values.AppendLine($line) }
        [void]$values.AppendLine("    ${prefix}}")
    }
    [void]$values.AppendLine("  }")
    [void]$values.AppendLine("}")
    [void]$values.AppendLine("")
    Write-Host "  '$($password.name)' with $($rules.Count) rule(s)."
}

# ---- Write outputs ---------------------------------------------------------

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$importsPath = Join-Path -Path $OutputDirectory -ChildPath 'imports.tf'
$valuesPath = Join-Path -Path $OutputDirectory -ChildPath 'values.skeleton.hcl'

[System.IO.File]::WriteAllText($importsPath, ($imports.ToString() -replace "`r`n", "`n"), $utf8NoBom)
[System.IO.File]::WriteAllText($valuesPath, ($values.ToString() -replace "`r`n", "`n"), $utf8NoBom)

Write-Host ""
Write-Host "Wrote:"
Write-Host "  $importsPath"
Write-Host "  $valuesPath"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Paste values.skeleton.hcl into the tenant terragrunt.hcl inputs block and review every value."
Write-Host "  2. Copy imports.tf next to that terragrunt.hcl."
Write-Host "  3. Run 'terragrunt plan' and iterate until it reports 0 to add, 0 to change, 0 to destroy."
Write-Host "  4. Run 'terragrunt apply' (records imports only), then delete imports.tf."
