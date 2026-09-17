# Pester tests for automation/runbooks/Invoke-AuthenticationMethodsDrift.ps1.
#
# Written in the Pester 3/4 assertion syntax ("Should Be") because Windows
# PowerShell 5.1 ships Pester 3.4.0. The runbook is dot-sourced, which loads
# its functions without running it, and the INLINE_LIBRARY block then loads
# the shared library from disk exactly as Terraform inlines it. The diff logic
# itself is covered by Set-AuthenticationMethods.Tests.ps1; these tests cover
# what the runbook adds: reading the desired state from Automation variables,
# the digest, and the dry-run boundary. Nothing here touches a tenant.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$runbook = Join-Path -Path (Split-Path -Parent $here) -ChildPath 'runbooks\Invoke-AuthenticationMethodsDrift.ps1'
$repoDesiredState = Join-Path -Path $repoRoot -ChildPath 'policies\entra\authentication-methods'

Describe 'Invoke-AuthenticationMethodsDrift' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'iam@corp.example.com' -AccessToken 'test-token'
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    # The live fixture is the repository's own desired state with ids in place
    # of names: enough to show zero drift, and one field is flipped per test.
    $global:DriftTestGroups = @{
        'Onboarding TAP'           = '11111111-1111-1111-1111-111111111111'
        'PIM Privileged Users'     = '22222222-2222-2222-2222-222222222222'
        'SEC Break Glass Accounts' = '33333333-3333-3333-3333-333333333333'
    }

    function New-LiveFixture {
        param([scriptblock]$Mutate = $null)
        $policy = [System.IO.File]::ReadAllText((Join-Path -Path $repoDesiredState -ChildPath 'policy.json')) | ConvertFrom-Json
        $policy | Add-Member -NotePropertyName 'id' -NotePropertyValue 'authenticationMethodsPolicy'
        $policy | Add-Member -NotePropertyName 'policyMigrationState' -NotePropertyValue 'migrationComplete'
        $policy.registrationEnforcement.authenticationMethodsRegistrationCampaign.excludeTargets[0].id = '33333333-3333-3333-3333-333333333333'
        $configurations = @()
        foreach ($file in (Get-ChildItem -Path (Join-Path -Path $repoDesiredState -ChildPath 'methods') -Filter '*.json')) {
            $m = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            $m | Add-Member -NotePropertyName 'id' -NotePropertyValue ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            if ($m.PSObject.Properties['includeTargets']) {
                foreach ($t in @($m.includeTargets)) { if ($global:DriftTestGroups.ContainsKey($t.id)) { $t.id = $global:DriftTestGroups[$t.id] } }
            }
            $configurations += $m
        }
        $policy | Add-Member -NotePropertyName 'authenticationMethodConfigurations' -NotePropertyValue $configurations
        if ($null -ne $Mutate) { & $Mutate $policy }
        return $policy
    }

    function Get-LiveMethod {
        param([object]$Live, [string]$Id)
        return @($Live.authenticationMethodConfigurations | Where-Object { $_.id -eq $Id })[0]
    }

    $global:DriftTestLive = New-LiveFixture

    Mock Get-DesiredStateJson {
        if ($Name -eq 'AuthMethods_Policy') { return [System.IO.File]::ReadAllText((Join-Path -Path $repoDesiredState -ChildPath 'policy.json')) }
        if ($Name -like 'AuthMethods_*') {
            $file = Join-Path -Path $repoDesiredState -ChildPath ('methods\{0}.json' -f $Name.Substring('AuthMethods_'.Length))
            if (Test-Path -Path $file) { return [System.IO.File]::ReadAllText($file) }
        }
        throw ('Automation variable {0} is missing or empty.' -f $Name)
    }

    Mock Invoke-GraphGetAll {
        if ($Uri -like 'groups?*') {
            $decoded = [Uri]::UnescapeDataString($Uri)
            if ($decoded -match "displayName eq '([^']*)'" -and $global:DriftTestGroups.ContainsKey($Matches[1])) {
                return @([PSCustomObject]@{ id = $global:DriftTestGroups[$Matches[1]]; displayName = $Matches[1] })
            }
        }
        return @()
    }

    Mock Invoke-GraphRequest {
        if ($Method -eq 'GET' -and $Uri -eq 'beta/policies/authenticationMethodsPolicy') { return $global:DriftTestLive }
        return $null
    }

    Context 'desired state from Automation variables' {
        It 'reads the policy and one variable per method id' {
            $desired = Get-DesiredStateFromVariables -VariablePrefix 'AuthMethods_' -MethodIds @('Fido2', 'Sms')
            $desired.Methods.Count | Should Be 2
            $desired.Policy | Should Not BeNullOrEmpty
            Assert-MockCalled Get-DesiredStateJson -Exactly 3 -Scope It
        }

        It 'fails when a listed method has no variable' {
            { Get-DesiredStateFromVariables -VariablePrefix 'AuthMethods_' -MethodIds @('Fido2', 'CarrierPigeon') } | Should Throw 'AuthMethods_CarrierPigeon'
        }
    }

    Context 'run behaviour with a mocked tenant' {
        It 'finds no drift, sends nothing, and patches nothing when the tenant matches' {
            $global:DriftTestLive = New-LiveFixture
            $summary = Invoke-AuthenticationMethodsDriftRun -SenderMailbox 'iam-noreply@corp.example.com' -Recipients @('iam@corp.example.com') -DryRun $false -AccessToken 'test-token'
            $summary.DriftCount | Should Be 0
            $summary.DigestSent | Should Be $false
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -ne 'GET' }
        }

        It 'reports drift in a dry run without mailing or patching' {
            $global:DriftTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'Sms').state = 'enabled' }
            $summary = Invoke-AuthenticationMethodsDriftRun -SenderMailbox 'iam-noreply@corp.example.com' -Recipients @('iam@corp.example.com') -DryRun $true -AccessToken 'test-token' -ReportPath (Join-Path -Path $TestDrive -ChildPath 'drift.json')
            $summary.DriftCount | Should Be 1
            $summary.DryRun | Should Be $true
            $summary.DigestSent | Should Be $false
            $summary.PatchesApplied | Should Be 0
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -ne 'GET' }
            (Join-Path -Path $TestDrive -ChildPath 'drift.json') | Should Exist
        }

        It 'patches the drift and mails one digest to the recipients when live' {
            $global:DriftTestLive = New-LiveFixture { param($l) (Get-LiveMethod -Live $l -Id 'Sms').state = 'enabled' }
            $summary = Invoke-AuthenticationMethodsDriftRun -SenderMailbox 'iam-noreply@corp.example.com' -Recipients @('iam@corp.example.com', 'soc@corp.example.com') -DryRun $false -AccessToken 'test-token'
            $summary.PatchesApplied | Should Be 1
            $summary.DigestSent | Should Be $true
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'PATCH' -and $Uri -eq 'v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'users/iam-noreply%40corp.example.com/sendMail' -and @($Body.message.toRecipients).Count -eq 2 -and $Body.message.body.content -like '*Sms*' }
        }

        It 'reads the desired state from a folder for a workstation run' {
            $global:DriftTestLive = New-LiveFixture
            $summary = Invoke-AuthenticationMethodsDriftRun -SenderMailbox 'iam-noreply@corp.example.com' -Recipients @('iam@corp.example.com') -DesiredStatePath $repoDesiredState -AccessToken 'test-token'
            $summary.MethodsDesired | Should Be 8
            Assert-MockCalled Get-DesiredStateJson -Exactly 0 -Scope It
        }
    }
}

Describe 'Invoke-AuthenticationMethodsDrift recipients parsing' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'iam@corp.example.com' -AccessToken 'test-token'
    It 'parses a JSON array string' {
        $r = ConvertTo-RecipientList -Value '["a@corp.example.com","b@corp.example.com"]'
        $r.Count | Should Be 2
        $r[1] | Should Be 'b@corp.example.com'
    }
    It 'parses a comma and semicolon list and trims blanks' {
        $r = ConvertTo-RecipientList -Value ' a@corp.example.com ; b@corp.example.com,, '
        $r.Count | Should Be 2
        $r[0] | Should Be 'a@corp.example.com'
    }
    It 'returns an array for a single address' {
        $r = ConvertTo-RecipientList -Value 'a@corp.example.com'
        @($r).Count | Should Be 1
    }
    It 'rejects a value that is not an address' {
        { ConvertTo-RecipientList -Value 'a@corp.example.com; not-an-address' } | Should Throw
    }
    It 'rejects an empty value' {
        { ConvertTo-RecipientList -Value ' ; ' } | Should Throw
    }
    It 'rejects a malformed JSON array' {
        { ConvertTo-RecipientList -Value '["a@corp.example.com"' } | Should Throw
    }
}
