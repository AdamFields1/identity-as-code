# Pester tests for automation/runbooks/Invoke-AppCredentialHygiene.ps1.
#
# Written in the Pester 3/4 assertion syntax ("Should Be") because Windows
# PowerShell 5.1 ships Pester 3.4.0. The runbook is dot-sourced, which loads
# its functions without running it; the entry point checks for that. Every
# Graph call goes through Invoke-GraphGetAll or Invoke-GraphRequest, and both
# are mocked here; the retry context also mocks Invoke-RestCall and Start-Sleep,
# so nothing in this file touches a tenant or waits.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runbook = Join-Path -Path (Split-Path -Parent $here) -ChildPath 'runbooks\Invoke-AppCredentialHygiene.ps1'

Describe 'Invoke-AppCredentialHygiene' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken 'test-token'
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 16, 12, 0, 0, ([DateTimeKind]::Utc)

    function New-TestCredential {
        param([string]$KeyId, [object]$EndDateTime, [string]$Name = 'cred')
        return [PSCustomObject]@{ keyId = $KeyId; displayName = $Name; endDateTime = $EndDateTime; type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $null }
    }

    function New-TestApplication {
        param([string]$Id, [string]$Name, [object[]]$Secrets = @(), [object[]]$Keys = @(), [string[]]$Tags = @())
        return [PSCustomObject]@{ id = $Id; appId = "client-$Id"; displayName = $Name; tags = $Tags; passwordCredentials = $Secrets; keyCredentials = $Keys }
    }

    Context 'credential classification boundaries' {
        It 'is Healthy when the end date is beyond WarnDays' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddDays(31).ToString('o')) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Healthy'
            $r.Removable | Should Be $false
        }

        It 'is Expiring exactly WarnDays out' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddDays(30).ToString('o')) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expiring'
            $r.DaysToExpiry | Should Be 30
        }

        It 'is Expiring one second before expiry' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddSeconds(1).ToString('o')) -Kind Certificate -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expiring'
            $r.DaysToExpiry | Should Be 1
        }

        It 'is Expired at exactly now' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.ToString('o')) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expired'
            $r.DaysExpired | Should Be 0
            $r.Removable | Should Be $false
        }

        It 'is Expired but not Removable one day inside the grace period' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddDays(-29).ToString('o')) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expired'
            $r.Removable | Should Be $false
        }

        It 'is Removable at exactly RemoveAfterDays past expiry' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddDays(-30).ToString('o')) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expired'
            $r.DaysExpired | Should Be 30
            $r.Removable | Should Be $true
        }

        It 'accepts a DateTime value as well as a string' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $now.AddDays(-40)) -Kind Secret -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Expired'
            $r.Removable | Should Be $true
        }

        It 'is Healthy with no end date' {
            $r = Get-CredentialAssessment -Credential (New-TestCredential -KeyId 'k' -EndDateTime $null) -Kind Certificate -Now $now -WarnDays 30 -RemoveAfterDays 30
            $r.State | Should Be 'Healthy'
            $r.EndDate | Should BeNullOrEmpty
        }
    }

    Context 'application findings and exclusions' {
        $apps = @(
            (New-TestApplication -Id 'a1' -Name 'Payroll API' -Secrets @((New-TestCredential -KeyId 's1' -EndDateTime $now.AddDays(10).ToString('o')), (New-TestCredential -KeyId 's2' -EndDateTime $now.AddDays(200).ToString('o')))),
            (New-TestApplication -Id 'a2' -Name 'Legacy Sync' -Keys @((New-TestCredential -KeyId 'c1' -EndDateTime $now.AddDays(-45).ToString('o')))),
            (New-TestApplication -Id 'a3' -Name 'Tagged App' -Tags @('NoCredentialHygiene') -Secrets @((New-TestCredential -KeyId 's3' -EndDateTime $now.AddDays(-400).ToString('o')))),
            (New-TestApplication -Id 'a4' -Name 'Named Exclusion' -Secrets @((New-TestCredential -KeyId 's4' -EndDateTime $now.AddDays(-400).ToString('o'))))
        )

        It 'reports only non-healthy credentials of non-excluded applications' {
            $r = Get-ApplicationFindings -Applications $apps -Now $now -WarnDays 30 -RemoveAfterDays 30 -ExcludedAppTag 'NoCredentialHygiene' -ExcludedAppNames @('Named Exclusion')
            @($r.Findings).Count | Should Be 2
            @($r.Findings | Where-Object { $_.State -eq 'Expiring' }).Count | Should Be 1
            @($r.Findings | Where-Object { $_.State -eq 'Expired' -and $_.Kind -eq 'Certificate' -and $_.Removable }).Count | Should Be 1
            $r.Counters.Applications | Should Be 4
            $r.Counters.Excluded | Should Be 2
            $r.Counters.Healthy | Should Be 1
        }

        It 'excludes by tag' {
            Test-ApplicationExcluded -Application $apps[2] -ExcludedAppTag 'NoCredentialHygiene' -ExcludedAppNames @() | Should Be $true
        }

        It 'excludes by name' {
            Test-ApplicationExcluded -Application $apps[3] -ExcludedAppTag 'NoCredentialHygiene' -ExcludedAppNames @('Named Exclusion') | Should Be $true
        }

        It 'does not exclude an ordinary application' {
            Test-ApplicationExcluded -Application $apps[0] -ExcludedAppTag 'NoCredentialHygiene' -ExcludedAppNames @('Named Exclusion') | Should Be $false
        }
    }

    Context 'national cloud switch' {
        It 'selects the US Government Graph endpoint' {
            (Get-CloudEndpoints -Environment 'USGov').Graph | Should Be 'https://graph.microsoft.us'
        }

        It 'selects the global Graph endpoint by default' {
            (Get-CloudEndpoints -Environment 'Global').Graph | Should Be 'https://graph.microsoft.com'
        }
    }

    Context 'retries with backoff' {
        Mock Start-Sleep { }

        It 'retries on 429 and honours Retry-After' {
            $global:CredentialHygieneCalls = 0
            Mock Invoke-RestCall {
                $global:CredentialHygieneCalls++
                if ($global:CredentialHygieneCalls -lt 3) { return @{ StatusCode = 429; Content = ''; Headers = @{ 'Retry-After' = '3' } } }
                return @{ StatusCode = 200; Content = '{"value":[{"id":"x"}]}'; Headers = @{} }
            }
            Initialize-GraphSession -Environment 'Global' -AccessToken 'test-token'
            $result = Invoke-GraphRequest -Method GET -Uri 'applications'
            @($result.value).Count | Should Be 1
            $global:CredentialHygieneCalls | Should Be 3
            Assert-MockCalled Start-Sleep -Exactly 2 -Scope It -ParameterFilter { $Seconds -eq 3 }
        }

        It 'gives up after MaxAttempts on 5xx' {
            Mock Invoke-RestCall { return @{ StatusCode = 503; Content = 'upstream'; Headers = @{} } }
            Initialize-GraphSession -Environment 'Global' -AccessToken 'test-token'
            { Invoke-GraphRequest -Method GET -Uri 'applications' -MaxAttempts 3 } | Should Throw
            Assert-MockCalled Invoke-RestCall -Exactly 3 -Scope It
        }

        It 'does not retry a 403' {
            Mock Invoke-RestCall { return @{ StatusCode = 403; Content = '{"error":{"code":"Authorization_RequestDenied"}}'; Headers = @{} } }
            Initialize-GraphSession -Environment 'Global' -AccessToken 'test-token'
            { Invoke-GraphRequest -Method GET -Uri 'applications' } | Should Throw
            Assert-MockCalled Invoke-RestCall -Exactly 1 -Scope It
        }

        It 'backs off exponentially without Retry-After and caps at 60 seconds' {
            Get-BackoffSeconds -Attempt 1 | Should Be 2
            Get-BackoffSeconds -Attempt 3 | Should Be 8
            Get-BackoffSeconds -Attempt 9 | Should Be 60
        }
    }

    Context 'run behaviour with a mocked tenant' {
        $tenantApps = @(
            (New-TestApplication -Id 'a1' -Name 'Payroll API' -Secrets @((New-TestCredential -KeyId 's1' -EndDateTime $now.AddDays(10).ToString('o') -Name 'ci'))),
            (New-TestApplication -Id 'a2' -Name 'Legacy Sync' -Secrets @((New-TestCredential -KeyId 's2' -EndDateTime $now.AddDays(-45).ToString('o') -Name 'old')) -Keys @((New-TestCredential -KeyId 'c1' -EndDateTime $now.AddDays(-60).ToString('o') -Name 'oldcert'), (New-TestCredential -KeyId 'c2' -EndDateTime $now.AddDays(300).ToString('o') -Name 'newcert')))
        )

        Mock Invoke-GraphGetAll {
            if ($Uri -like 'applications[?]*') { return $tenantApps }
            if ($Uri -like 'applications/a1/owners*') { return @([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.user'; id = 'o1'; mail = 'payroll.owner@corp.example.com' }) }
            if ($Uri -like 'applications/a2/owners*') { return @() }
            return @()
        }
        Mock Invoke-GraphRequest { return $null }

        It 'makes no write call in a dry run, even with RemoveExpired' {
            $summary = Invoke-CredentialHygieneRun -SenderMailbox 'iam-noreply@corp.example.com' -RemoveExpired $true -DryRun $true -AccessToken 'test-token' -FallbackRecipient 'iam@corp.example.com' -Now $now
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It
            $summary.DryRun | Should Be $true
            $summary.RemovalEnabled | Should Be $false
            $summary.Removed | Should Be 0
            $summary.DigestsSent | Should Be 0
            $summary.DigestsPlanned | Should Be 2
            $summary.RemovalCandidates | Should Be 2
            $summary.CredentialsExpiring | Should Be 1
            $summary.CredentialsExpired | Should Be 2
        }

        It 'sends one digest per recipient and removes capped candidates when live' {
            $summary = Invoke-CredentialHygieneRun -SenderMailbox 'iam-noreply@corp.example.com' -RemoveExpired $true -DryRun $false -AccessToken 'test-token' -FallbackRecipient 'iam@corp.example.com' -Now $now
            Assert-MockCalled Invoke-GraphRequest -Exactly 2 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -like 'users/*/sendMail' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'applications/a2/removePassword' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'PATCH' -and $Uri -eq 'applications/a2' -and $Body -like '*"c2"*' -and $Body -notlike '*"c1"*' }
            $summary.Removed | Should Be 2
            $summary.DigestsSent | Should Be 2
        }

        It 'never removes anything without RemoveExpired' {
            $summary = Invoke-CredentialHygieneRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $false -AccessToken 'test-token' -Now $now
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Method -ne 'POST' -or $Uri -notlike 'users/*/sendMail' }
            $summary.Removed | Should Be 0
        }

        It 'stops at MaxRemovalsPerRun and reports the rest as deferred' {
            $summary = Invoke-CredentialHygieneRun -SenderMailbox 'iam-noreply@corp.example.com' -RemoveExpired $true -DryRun $false -MaxRemovalsPerRun 1 -AccessToken 'test-token' -Now $now
            $summary.Removed | Should Be 1
            $summary.RemovalsDeferred | Should Be 1
        }

        It 'writes a CSV report when asked' {
            $path = Join-Path -Path $TestDrive -ChildPath 'findings.csv'
            Invoke-CredentialHygieneRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $true -AccessToken 'test-token' -ReportPath $path -Now $now | Out-Null
            $path | Should Exist
            @(Import-Csv -Path $path).Count | Should Be 3
        }
    }
}

Describe 'Invoke-AppCredentialHygiene excluded app names parsing' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken 'test-token'
    It 'parses the semicolon list a job schedule passes and trims blanks' {
        $r = ConvertTo-ExcludedAppNameList -Value ' Legacy Portal ; Break Glass App,, '
        @($r).Count | Should Be 2
        $r[0] | Should Be 'Legacy Portal'
    }
    It 'parses a JSON array string from a local run' {
        $r = ConvertTo-ExcludedAppNameList -Value '["Legacy Portal","Break Glass App"]'
        @($r).Count | Should Be 2
        $r[1] | Should Be 'Break Glass App'
    }
    It 'returns an empty list, not null, for the empty default' {
        $r = ConvertTo-ExcludedAppNameList -Value ''
        @($r).Count | Should Be 0
        $app = [PSCustomObject]@{ id = 'a0'; appId = 'client-a0'; displayName = 'Any App'; tags = @(); passwordCredentials = @(); keyCredentials = @() }
        (Test-ApplicationExcluded -Application $app -ExcludedAppTag 'NoCredentialHygiene' -ExcludedAppNames $r) | Should Be $false
    }
    It 'rejects a malformed JSON array' {
        { ConvertTo-ExcludedAppNameList -Value '["Legacy Portal"' } | Should Throw
    }
}
