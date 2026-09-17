# Pester tests for scripts/Set-AuthenticationMethods.ps1 and the library it
# dot-sources, automation/lib/AuthenticationMethods.Common.ps1.
#
# Written in the Pester 3/4 assertion syntax ("Should Be") because Windows
# PowerShell 5.1 ships Pester 3.4.0. The script is dot-sourced, which loads
# its functions and the library without running it; the entry point checks for
# that. Every Graph call goes through Invoke-GraphGetAll or Invoke-GraphRequest,
# and both are mocked here, so nothing in this file touches a tenant.
#
# The live fixture is the beta GET response for a tenant that matches the
# repository's own desired state exactly, so the shipped files are exercised
# against the field names the docs give, and each drift test mutates one field.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script = Join-Path -Path $repoRoot -ChildPath 'scripts\Set-AuthenticationMethods.ps1'
$desiredStatePath = Join-Path -Path $repoRoot -ChildPath 'policies\entra\authentication-methods'

Describe 'Set-AuthenticationMethods' {
    . $script -DesiredStatePath $desiredStatePath -AccessToken 'test-token'
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'

    $global:AuthMethodsTestGroups = @{
        'Onboarding TAP'           = '11111111-1111-1111-1111-111111111111'
        'PIM Privileged Users'     = '22222222-2222-2222-2222-222222222222'
        'SEC Break Glass Accounts' = '33333333-3333-3333-3333-333333333333'
        'Extra Group'              = '44444444-4444-4444-4444-444444444444'
    }

    $liveJson = @'
{
  "@odata.context": "https://graph.microsoft.com/beta/$metadata#authenticationMethodsPolicy",
  "id": "authenticationMethodsPolicy",
  "displayName": "Authentication Methods Policy",
  "description": "The tenant-wide policy",
  "lastModifiedDateTime": "2026-09-01T00:00:00Z",
  "policyVersion": "1.5",
  "policyMigrationState": "preMigration",
  "registrationEnforcement": {
    "authenticationMethodsRegistrationCampaign": {
      "snoozeDurationInDays": 3,
      "enforceRegistrationAfterAllowedSnoozes": true,
      "state": "enabled",
      "excludeTargets": [ { "id": "33333333-3333-3333-3333-333333333333", "targetType": "group" } ],
      "includeTargets": [ { "id": "all_users", "targetType": "group", "targetedAuthenticationMethod": "microsoftAuthenticator" } ]
    }
  },
  "reportSuspiciousActivitySettings": {
    "@odata.type": "#microsoft.graph.reportSuspiciousActivitySettings",
    "state": "enabled",
    "includeTarget": { "targetType": "group", "id": "all_users" },
    "voiceReportingCode": 0
  },
  "systemCredentialPreferences": {
    "@odata.type": "#microsoft.graph.systemCredentialPreferences",
    "excludeTargets": [],
    "includeTargets": [ { "id": "all_users", "targetType": "group" } ],
    "state": "enabled"
  },
  "authenticationMethodConfigurations": [
    {
      "@odata.type": "#microsoft.graph.fido2AuthenticationMethodConfiguration",
      "id": "Fido2",
      "state": "enabled",
      "isSelfServiceRegistrationAllowed": true,
      "isAttestationEnforced": true,
      "keyRestrictions": { "isEnforced": false, "enforcementType": "block", "aaGuids": [] },
      "excludeTargets": [],
      "includeTargets": [ { "targetType": "group", "id": "all_users", "isRegistrationRequired": false } ]
    },
    {
      "@odata.type": "#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration",
      "id": "MicrosoftAuthenticator",
      "state": "enabled",
      "isSoftwareOathEnabled": false,
      "excludeTargets": [],
      "featureSettings": {
        "numberMatchingRequiredState": { "state": "enabled", "includeTarget": { "targetType": "group", "id": "all_users" }, "excludeTarget": { "targetType": "group", "id": "00000000-0000-0000-0000-000000000000" } },
        "displayAppInformationRequiredState": { "state": "enabled", "includeTarget": { "targetType": "group", "id": "all_users" }, "excludeTarget": { "targetType": "group", "id": "00000000-0000-0000-0000-000000000000" } },
        "displayLocationInformationRequiredState": { "state": "enabled", "includeTarget": { "targetType": "group", "id": "all_users" }, "excludeTarget": { "targetType": "group", "id": "00000000-0000-0000-0000-000000000000" } },
        "companionAppAllowedState": { "state": "default", "includeTarget": { "targetType": "group", "id": "all_users" }, "excludeTarget": { "targetType": "group", "id": "00000000-0000-0000-0000-000000000000" } }
      },
      "includeTargets": [ { "targetType": "group", "id": "all_users", "isRegistrationRequired": false, "authenticationMode": "any", "outlookMobileAllowedState": "default", "displayAppInformationRequiredState": "default", "numberMatchingRequiredState": "default" } ]
    },
    {
      "@odata.type": "#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration",
      "id": "TemporaryAccessPass",
      "state": "enabled",
      "defaultLifetimeInMinutes": 60,
      "defaultLength": 8,
      "minimumLifetimeInMinutes": 10,
      "maximumLifetimeInMinutes": 480,
      "isUsableOnce": true,
      "excludeTargets": [],
      "includeTargets": [ { "targetType": "group", "id": "11111111-1111-1111-1111-111111111111", "isRegistrationRequired": false } ]
    },
    {
      "@odata.type": "#microsoft.graph.smsAuthenticationMethodConfiguration",
      "id": "Sms",
      "state": "disabled",
      "excludeTargets": [],
      "includeTargets": [ { "targetType": "group", "id": "all_users", "isRegistrationRequired": false, "isUsableForSignIn": true } ]
    },
    {
      "@odata.type": "#microsoft.graph.voiceAuthenticationMethodConfiguration",
      "id": "Voice",
      "state": "disabled",
      "isOfficePhoneAllowed": false,
      "excludeTargets": [],
      "includeTargets": [ { "targetType": "group", "id": "all_users", "isRegistrationRequired": false } ]
    },
    {
      "@odata.type": "#microsoft.graph.emailAuthenticationMethodConfiguration",
      "id": "Email",
      "state": "disabled",
      "allowExternalIdToUseEmailOtp": "disabled",
      "excludeTargets": [],
      "includeTargets": []
    },
    {
      "@odata.type": "#microsoft.graph.softwareOathAuthenticationMethodConfiguration",
      "id": "SoftwareOath",
      "state": "enabled",
      "excludeTargets": [],
      "includeTargets": [ { "targetType": "group", "id": "all_users", "isRegistrationRequired": false } ]
    },
    {
      "@odata.type": "#microsoft.graph.x509CertificateAuthenticationMethodConfiguration",
      "id": "X509Certificate",
      "state": "enabled",
      "excludeTargets": [],
      "certificateUserBindings": [ { "x509CertificateField": "PrincipalName", "userProperty": "userPrincipalName", "priority": 1 } ],
      "authenticationModeConfiguration": { "x509CertificateAuthenticationDefaultMode": "x509CertificateMultiFactor", "rules": [] },
      "issuerHintsConfiguration": { "state": "disabled" },
      "crlValidationConfiguration": { "state": "disabled", "exemptedCertificateAuthoritiesSubjectKeyIdentifiers": [] },
      "certificateAuthorityScopes": [],
      "includeTargets": [ { "targetType": "group", "id": "22222222-2222-2222-2222-222222222222", "isRegistrationRequired": false } ]
    },
    {
      "@odata.type": "#microsoft.graph.hardwareOathAuthenticationMethodConfiguration",
      "id": "HardwareOath",
      "state": "disabled",
      "excludeTargets": [],
      "includeTargets": []
    }
  ]
}
'@

    function New-LiveFixture {
        param([scriptblock]$Mutate = $null)
        $live = $liveJson | ConvertFrom-Json
        if ($null -ne $Mutate) { & $Mutate $live }
        return $live
    }

    function Get-LiveMethod {
        param([object]$Live, [string]$Id)
        return @($Live.authenticationMethodConfigurations | Where-Object { $_.id -eq $Id })[0]
    }

    $global:AuthMethodsTestLive = New-LiveFixture
    $global:AuthMethodsTestPatches = New-Object System.Collections.ArrayList

    Mock Invoke-GraphGetAll {
        if ($Uri -like 'groups?*') {
            $decoded = [Uri]::UnescapeDataString($Uri)
            if ($decoded -match "displayName eq '([^']*)'") {
                $name = $Matches[1].Replace("''", "'")
                if ($name -eq 'Ambiguous Group') {
                    return @([PSCustomObject]@{ id = 'a1'; displayName = $name }, [PSCustomObject]@{ id = 'a2'; displayName = $name })
                }
                if ($global:AuthMethodsTestGroups.ContainsKey($name)) {
                    return @([PSCustomObject]@{ id = $global:AuthMethodsTestGroups[$name]; displayName = $name })
                }
            }
            return @()
        }
        return @()
    }

    Mock Invoke-GraphRequest {
        if ($Method -eq 'GET' -and $Uri -eq 'beta/policies/authenticationMethodsPolicy') { return $global:AuthMethodsTestLive }
        if ($Method -eq 'GET' -and $Uri -like 'groups/*') {
            $id = ($Uri -split '[/?]')[1]
            foreach ($name in $global:AuthMethodsTestGroups.Keys) {
                if ($global:AuthMethodsTestGroups[$name] -eq $id) { return [PSCustomObject]@{ id = $id; displayName = $name } }
            }
            throw ('Graph GET groups/{0} failed with HTTP 404 after 1 attempt(s): not found' -f $id)
        }
        if ($Method -eq 'PATCH') {
            [void]$global:AuthMethodsTestPatches.Add([PSCustomObject]@{ Uri = $Uri; Body = $Body })
            return $null
        }
        return $null
    }

    Context 'normalization' {
        It 'resolves a group display name to its object id in include targets' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"Onboarding TAP","isRegistrationRequired":false}]}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToId
            $resolved['includeTargets'][0]['id'] | Should Be '11111111-1111-1111-1111-111111111111'
        }

        It 'passes all_users through unchanged' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTarget":{"targetType":"group","id":"all_users"}}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToId
            $resolved['includeTarget']['id'] | Should Be 'all_users'
            Assert-MockCalled Invoke-GraphGetAll -Exactly 0 -Scope It
        }

        It 'passes the empty-target GUID and an existing GUID through unchanged' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"excludeTarget":{"targetType":"group","id":"00000000-0000-0000-0000-000000000000"},"includeTargets":[{"targetType":"group","id":"55555555-5555-5555-5555-555555555555"}]}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToId
            $resolved['excludeTarget']['id'] | Should Be '00000000-0000-0000-0000-000000000000'
            $resolved['includeTargets'][0]['id'] | Should Be '55555555-5555-5555-5555-555555555555'
            Assert-MockCalled Invoke-GraphGetAll -Exactly 0 -Scope It
        }

        It 'leaves role and administrative unit feature targets alone' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTarget":{"targetType":"role","id":"Global Administrator"}}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToId
            $resolved['includeTarget']['id'] | Should Be 'Global Administrator'
            Assert-MockCalled Invoke-GraphGetAll -Exactly 0 -Scope It
        }

        It 'refuses a group name that does not exist' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"No Such Group"}]}'
            { Resolve-AuthMethodsTargets -Node $node -Direction ToId } | Should Throw 'was not found'
        }

        It 'refuses an ambiguous group name' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"Ambiguous Group"}]}'
            { Resolve-AuthMethodsTargets -Node $node -Direction ToId } | Should Throw 'matches 2 groups'
        }

        It 'resolves object ids back to display names for export' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"22222222-2222-2222-2222-222222222222"},{"targetType":"group","id":"all_users"}]}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToName
            $resolved['includeTargets'][0]['id'] | Should Be 'PIM Privileged Users'
            $resolved['includeTargets'][1]['id'] | Should Be 'all_users'
        }

        It 'keeps the id when the group no longer exists' {
            $node = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"99999999-9999-9999-9999-999999999999"}]}'
            $resolved = Resolve-AuthMethodsTargets -Node $node -Direction ToName
            $resolved['includeTargets'][0]['id'] | Should Be '99999999-9999-9999-9999-999999999999'
        }

        It 'does not treat target ordering as drift' {
            $desired = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"PIM Privileged Users","isRegistrationRequired":false},{"targetType":"group","id":"Onboarding TAP","isRegistrationRequired":false}]}'
            $live = ConvertFrom-AuthMethodsJson -Json '{"includeTargets":[{"targetType":"group","id":"11111111-1111-1111-1111-111111111111","isRegistrationRequired":false},{"targetType":"group","id":"22222222-2222-2222-2222-222222222222","isRegistrationRequired":false}]}'
            $resolved = Resolve-AuthMethodsTargets -Node $desired -Direction ToId
            @(Get-AuthMethodsDifferences -Desired $resolved -Live $live).Count | Should Be 0
        }

        It 'compares scalar lists as sets' {
            $desired = ConvertFrom-AuthMethodsJson -Json '{"keyRestrictions":{"aaGuids":["b","A"]}}'
            $live = ConvertFrom-AuthMethodsJson -Json '{"keyRestrictions":{"aaGuids":["a","B"]}}'
            @(Get-AuthMethodsDifferences -Desired $desired -Live $live).Count | Should Be 0
        }
    }

    Context 'drift detection' {
        It 'finds no drift when the tenant matches the repository files' {
            $desired = Import-AuthMethodsDesiredState -Path $desiredStatePath
            $live = Get-AuthMethodsLivePolicy
            $plan = Get-AuthMethodsPlan -Desired $desired -Live $live
            @($plan.Drift).Count | Should Be 0
            $plan.MethodPatches.Count | Should Be 0
            $plan.PolicyPatch | Should BeNullOrEmpty
            $desired.Methods.Count | Should Be 8
        }

        It 'reports one field-level difference with the desired and live values' {
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'Fido2').isSelfServiceRegistrationAllowed = $false }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $desiredStatePath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Id | Should Be 'Fido2'
            $plan.Drift[0].Path | Should Be 'isSelfServiceRegistrationAllowed'
            $plan.Drift[0].Kind | Should Be 'Changed'
            $plan.Drift[0].Desired | Should Be 'true'
            $plan.Drift[0].Live | Should Be 'false'
            @($plan.MethodPatches.Keys) | Should Be @('Fido2')
        }

        It 'reports a target the tenant has that the file does not' {
            $global:AuthMethodsTestLive = New-LiveFixture {
                param($l)
                $m = Get-LiveMethod -Live $l -Id 'SoftwareOath'
                $m.includeTargets = @($m.includeTargets) + @([PSCustomObject]@{ targetType = 'group'; id = '44444444-4444-4444-4444-444444444444'; isRegistrationRequired = $false })
            }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $desiredStatePath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Kind | Should Be 'Extra'
            $plan.Drift[0].Path | Should Be 'includeTargets[group:44444444-4444-4444-4444-444444444444]'
        }

        It 'reports a target the file has that the tenant does not' {
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'TemporaryAccessPass').includeTargets = @() }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $desiredStatePath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Kind | Should Be 'Missing'
            $plan.Drift[0].Path | Should Be 'includeTargets[group:11111111-1111-1111-1111-111111111111]'
        }

        It 'ignores live fields the file does not manage' {
            $global:AuthMethodsTestLive = New-LiveFixture {
                param($l)
                (Get-LiveMethod -Live $l -Id 'MicrosoftAuthenticator').featureSettings.numberMatchingRequiredState.state = 'disabled'
                (Get-LiveMethod -Live $l -Id 'Sms').includeTargets = @()
            }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $desiredStatePath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 0
        }

        It 'reports a nested policy-level difference' {
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) $l.registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays = 14 }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $desiredStatePath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Scope | Should Be 'Policy'
            $plan.Drift[0].Path | Should Be 'registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays'
            @($plan.PolicyPatch.Keys) | Should Be @('registrationEnforcement')
        }

        It 'refuses a method file whose name is not a configuration id' {
            $desired = Import-AuthMethodsDesiredState -Path $desiredStatePath
            $desired.Methods['Carrier Pigeon'] = ConvertFrom-AuthMethodsJson -Json '{"state":"enabled"}'
            { Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy) } | Should Throw 'no configuration with that id'
        }
    }

    Context 'guards' {
        $global:AuthMethodsTestLive = New-LiveFixture

        It 'refuses to plan a state with no enabled method' {
            $desired = @{ Policy = $null; Methods = [ordered]@{} }
            foreach ($id in @('Fido2', 'MicrosoftAuthenticator', 'TemporaryAccessPass', 'SoftwareOath', 'X509Certificate')) {
                $desired.Methods[$id] = ConvertFrom-AuthMethodsJson -Json '{"state":"disabled"}'
            }
            { Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy) } | Should Throw 'no enabled authentication method'
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'counts a live method the files do not mention when applying the guard' {
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'HardwareOath').state = 'enabled' }
            $desired = @{ Policy = $null; Methods = [ordered]@{} }
            foreach ($id in @('Fido2', 'MicrosoftAuthenticator', 'TemporaryAccessPass', 'SoftwareOath', 'X509Certificate')) {
                $desired.Methods[$id] = ConvertFrom-AuthMethodsJson -Json '{"state":"disabled"}'
            }
            $plan = Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy)
            $plan.MethodPatches.Count | Should Be 5
        }

        It 'holds a policyMigrationState difference unless explicitly allowed' {
            $global:AuthMethodsTestLive = New-LiveFixture
            $desired = @{ Policy = (ConvertFrom-AuthMethodsJson -Json '{"policyMigrationState":"migrationComplete"}'); Methods = [ordered]@{} }
            $plan = Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy) -AllowMigrationStateChange $false
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Guarded | Should Be $true
            $plan.Drift[0].Live | Should Be 'preMigration'
            $plan.MigrationStateHeld | Should Be $true
            $plan.PolicyPatch | Should BeNullOrEmpty
        }

        It 'sends policyMigrationState when allowed' {
            $global:AuthMethodsTestLive = New-LiveFixture
            $desired = @{ Policy = (ConvertFrom-AuthMethodsJson -Json '{"policyMigrationState":"migrationComplete"}'); Methods = [ordered]@{} }
            $plan = Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy) -AllowMigrationStateChange $true
            $plan.Drift[0].Guarded | Should Be $false
            $plan.MigrationStateHeld | Should Be $false
            $plan.PolicyPatch['policyMigrationState'] | Should Be 'migrationComplete'
            Get-AuthMethodsPolicyPatchVersion -Body $plan.PolicyPatch | Should Be 'v1.0'
        }

        It 'ignores a policy.json key that is not a managed setting' {
            $global:AuthMethodsTestLive = New-LiveFixture
            $desired = @{ Policy = (ConvertFrom-AuthMethodsJson -Json '{"displayName":"Renamed","policyVersion":"9"}'); Methods = [ordered]@{} }
            $plan = Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 0
            $plan.PolicyPatch | Should BeNullOrEmpty
        }
    }

    Context 'apply' {
        It 'makes no PATCH in a dry run even when drift exists' {
            $global:AuthMethodsTestPatches.Clear()
            $global:AuthMethodsTestLive = New-LiveFixture {
                param($l)
                (Get-LiveMethod -Live $l -Id 'Fido2').isSelfServiceRegistrationAllowed = $false
                (Get-LiveMethod -Live $l -Id 'Sms').state = 'enabled'
            }
            $summary = Invoke-AuthenticationMethodsRun -DesiredStatePath $desiredStatePath -DryRun $true -AccessToken 'test-token' -ReportPath (Join-Path -Path $TestDrive -ChildPath 'dry.json') 6>$null
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -eq 'PATCH' }
            $summary.DryRun | Should Be $true
            $summary.Mode | Should Be 'Report'
            $summary.DriftCount | Should Be 2
            $summary.MethodsDrifted | Should Be 2
            $summary.PatchesPlanned | Should Be 2
            $summary.PatchesApplied | Should Be 0
            (Join-Path -Path $TestDrive -ChildPath 'dry.json') | Should Exist
        }

        It 'patches each drifted method on v1.0 with the whole desired file when live' {
            $global:AuthMethodsTestPatches.Clear()
            $global:AuthMethodsTestLive = New-LiveFixture {
                param($l)
                (Get-LiveMethod -Live $l -Id 'Fido2').isSelfServiceRegistrationAllowed = $false
                (Get-LiveMethod -Live $l -Id 'Sms').state = 'enabled'
            }
            $summary = Invoke-AuthenticationMethodsRun -DesiredStatePath $desiredStatePath -DryRun $false -AccessToken 'test-token' 6>$null
            Assert-MockCalled Invoke-GraphRequest -Exactly 2 -Scope It -ParameterFilter { $Method -eq 'PATCH' }
            $summary.PatchesApplied | Should Be 2
            $summary.PolicyDrifted | Should Be $false
            $uris = @($global:AuthMethodsTestPatches | ForEach-Object { $_.Uri } | Sort-Object)
            $uris[0] | Should Be 'v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Fido2'
            $uris[1] | Should Be 'v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms'
            $fido2 = @($global:AuthMethodsTestPatches | Where-Object { $_.Uri -like '*/Fido2' })[0].Body
            $fido2['@odata.type'] | Should Be '#microsoft.graph.fido2AuthenticationMethodConfiguration'
            $fido2['isSelfServiceRegistrationAllowed'] | Should Be $true
            $fido2.Contains('id') | Should Be $false
        }

        It 'patches the policy object on beta when a beta-only setting differs' {
            $global:AuthMethodsTestPatches.Clear()
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) $l.reportSuspiciousActivitySettings.state = 'disabled' }
            $summary = Invoke-AuthenticationMethodsRun -DesiredStatePath $desiredStatePath -DryRun $false -AccessToken 'test-token' 6>$null
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'PATCH' }
            $summary.PolicyDrifted | Should Be $true
            $global:AuthMethodsTestPatches[0].Uri | Should Be 'beta/policies/authenticationMethodsPolicy'
            @($global:AuthMethodsTestPatches[0].Body.Keys) | Should Be @('reportSuspiciousActivitySettings')
        }

        It 'sends resolved group ids, never display names' {
            $global:AuthMethodsTestPatches.Clear()
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'TemporaryAccessPass').isUsableOnce = $false }
            Invoke-AuthenticationMethodsRun -DesiredStatePath $desiredStatePath -DryRun $false -AccessToken 'test-token' 6>$null | Out-Null
            $body = $global:AuthMethodsTestPatches[0].Body
            $body['includeTargets'][0]['id'] | Should Be '11111111-1111-1111-1111-111111111111'
        }

        It 'records an error and continues when a PATCH fails' {
            $global:AuthMethodsTestPatches.Clear()
            $global:AuthMethodsTestLive = New-LiveFixture {
                param($l)
                (Get-LiveMethod -Live $l -Id 'Fido2').isSelfServiceRegistrationAllowed = $false
                (Get-LiveMethod -Live $l -Id 'Sms').state = 'enabled'
            }
            Mock Invoke-GraphRequest {
                if ($Method -eq 'GET' -and $Uri -eq 'beta/policies/authenticationMethodsPolicy') { return $global:AuthMethodsTestLive }
                if ($Method -eq 'PATCH' -and $Uri -like '*/Fido2') { throw 'Graph PATCH failed with HTTP 400 after 1 attempt(s): bad request' }
                return $null
            }
            $summary = Invoke-AuthenticationMethodsRun -DesiredStatePath $desiredStatePath -DryRun $false -AccessToken 'test-token' 6>$null 2>$null
            $summary.PatchesApplied | Should Be 1
            $summary.PatchesFailed | Should Be 1
            $summary.Errors | Should Be 1
        }
    }

    Context 'export round-trip' {
        $exportPath = Join-Path -Path $TestDrive -ChildPath 'export'
        $global:AuthMethodsTestLive = New-LiveFixture

        It 'writes one file per known method and a policy.json with display names' {
            $summary = Invoke-AuthenticationMethodsRun -DesiredStatePath $exportPath -Export $true -AccessToken 'test-token' 6>$null
            $summary.Mode | Should Be 'Export'
            $summary.FilesWritten | Should Be 9
            (Join-Path -Path $exportPath -ChildPath 'policy.json') | Should Exist
            (Join-Path -Path $exportPath -ChildPath 'methods\HardwareOath.json') | Should Not Exist
            $tap = [System.IO.File]::ReadAllText((Join-Path -Path $exportPath -ChildPath 'methods\TemporaryAccessPass.json'))
            $tap | Should Match 'Onboarding TAP'
            $tap | Should Not Match '11111111-1111-1111-1111-111111111111'
            $tap | Should Not Match '"id":\s*"TemporaryAccessPass"'
            $policy = [System.IO.File]::ReadAllText((Join-Path -Path $exportPath -ChildPath 'policy.json'))
            $policy | Should Match 'SEC Break Glass Accounts'
            $policy | Should Not Match 'policyMigrationState'
            $policy | Should Not Match 'policyVersion'
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'shows no drift when the exported files are compared with the same tenant' {
            $desired = Import-AuthMethodsDesiredState -Path $exportPath
            $desired.Methods.Count | Should Be 8
            $plan = Get-AuthMethodsPlan -Desired $desired -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 0
        }

        It 'and still detects a change made after the export' {
            $global:AuthMethodsTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'Voice').isOfficePhoneAllowed = $true }
            $plan = Get-AuthMethodsPlan -Desired (Import-AuthMethodsDesiredState -Path $exportPath) -Live (Get-AuthMethodsLivePolicy)
            @($plan.Drift).Count | Should Be 1
            $plan.Drift[0].Id | Should Be 'Voice'
        }
    }
}
