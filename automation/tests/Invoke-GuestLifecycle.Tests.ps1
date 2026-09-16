# Pester tests for automation/runbooks/Invoke-GuestLifecycle.ps1.
#
# Pester 3/4 assertion syntax. The runbook is dot-sourced so its functions are
# available without running it, and both Graph entry points are mocked.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runbook = Join-Path -Path (Split-Path -Parent $here) -ChildPath 'runbooks\Invoke-GuestLifecycle.ps1'

Describe 'Invoke-GuestLifecycle' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken 'test-token'
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 16, 12, 0, 0, ([DateTimeKind]::Utc)

    function New-TestGuest {
        param([string]$Id, [int]$DormantDays, [bool]$Enabled = $true, [bool]$NeverSignedIn = $false)
        $activity = $null
        $created = $now.AddDays(-400).ToString('o')
        if ($NeverSignedIn) { $created = $now.AddDays(-$DormantDays).ToString('o') }
        else { $activity = [PSCustomObject]@{ lastSignInDateTime = $now.AddDays(-$DormantDays).ToString('o'); lastNonInteractiveSignInDateTime = $now.AddDays(-$DormantDays - 5).ToString('o') } }
        return [PSCustomObject]@{
            id                = $Id
            displayName       = "Guest $Id"
            userPrincipalName = "guest_$Id#EXT#@corp.example.com"
            mail              = "$Id@partner.example.net"
            accountEnabled    = $Enabled
            createdDateTime   = $created
            signInActivity    = $activity
        }
    }

    Context 'dormancy source' {
        It 'uses the most recent sign-in timestamp' {
            $guest = New-TestGuest -Id 'g' -DormantDays 10
            (Get-GuestLastActivity -Guest $guest).ToString('yyyy-MM-dd') | Should Be $now.AddDays(-10).ToString('yyyy-MM-dd')
        }

        It 'falls back to createdDateTime when the guest never signed in' {
            $guest = New-TestGuest -Id 'g' -DormantDays 70 -NeverSignedIn $true
            (Get-GuestLastActivity -Guest $guest).ToString('yyyy-MM-dd') | Should Be $now.AddDays(-70).ToString('yyyy-MM-dd')
        }

        It 'returns null when nothing is known' {
            $guest = [PSCustomObject]@{ id = 'x'; userPrincipalName = 'x'; displayName = 'x'; mail = $null; accountEnabled = $true }
            Get-GuestLastActivity -Guest $guest | Should BeNullOrEmpty
        }
    }

    Context 'stage computation' {
        $stage = @{ WarnDays = 60; DisableDays = 90; PurgeDays = 120 }

        It 'is Active below WarnDays' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 59) -Now $now @stage
            $r.Stage | Should Be 'Active'
            $r.Action | Should Be 'None'
        }

        It 'warns exactly at WarnDays' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 60) -Now $now @stage
            $r.Stage | Should Be 'Warn'
            $r.Action | Should Be 'Warn'
        }

        It 'does not warn twice' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 75) -Now $now @stage -IsWarned $true
            $r.Action | Should Be 'None'
        }

        It 'disables a warned guest exactly at DisableDays' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 90) -Now $now @stage -IsWarned $true
            $r.Stage | Should Be 'Disable'
            $r.Action | Should Be 'Disable'
        }

        It 'warns first when a guest past DisableDays was never warned' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 120) -Now $now @stage
            $r.Stage | Should Be 'Disable'
            $r.Action | Should Be 'Warn'
        }

        It 'purges a disabled guest at DisableDays plus PurgeDays' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 210 -Enabled $false) -Now $now @stage -IsDisabled $true
            $r.Stage | Should Be 'Purge'
            $r.Action | Should Be 'Purge'
        }

        It 'does not purge one day early' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 209 -Enabled $false) -Now $now @stage -IsDisabled $true
            $r.Stage | Should Be 'Disable'
            $r.Action | Should Be 'None'
        }

        It 'holds a disabled-stage guest that someone re-enabled' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 300 -Enabled $true) -Now $now @stage -IsDisabled $true
            $r.Action | Should Be 'Hold'
        }

        It 'climbs one rung at a time past the purge threshold' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 300) -Now $now @stage -IsWarned $true
            $r.Action | Should Be 'Disable'
        }

        It 'resets a warned guest who signed in again' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 3) -Now $now @stage -IsWarned $true
            $r.Stage | Should Be 'Active'
            $r.Action | Should Be 'Reset'
        }

        It 'exempts a member of the exempt group whatever the dormancy' {
            $r = Get-GuestLifecycleStage -Guest (New-TestGuest -Id 'g' -DormantDays 900) -Now $now @stage -IsExempt $true -IsWarned $true
            $r.Stage | Should Be 'Exempt'
            $r.Action | Should Be 'None'
        }

        It 'holds a guest whose dormancy cannot be computed' {
            $guest = [PSCustomObject]@{ id = 'x'; userPrincipalName = 'x'; displayName = 'x'; mail = $null; accountEnabled = $true }
            $r = Get-GuestLifecycleStage -Guest $guest -Now $now @stage
            $r.Action | Should Be 'Hold'
        }
    }

    Context 'circuit breaker' {
        It 'passes at the cap' {
            { Test-CircuitBreaker -PlannedDisables 25 -PlannedPurges 10 -MaxDisablePerRun 25 -MaxPurgePerRun 10 } | Should Not Throw
        }

        It 'trips one over the disable cap' {
            { Test-CircuitBreaker -PlannedDisables 26 -PlannedPurges 0 -MaxDisablePerRun 25 -MaxPurgePerRun 10 } | Should Throw
        }

        It 'trips one over the purge cap' {
            { Test-CircuitBreaker -PlannedDisables 0 -PlannedPurges 11 -MaxDisablePerRun 25 -MaxPurgePerRun 10 } | Should Throw
        }
    }

    Context 'run behaviour with a mocked tenant' {
        $groups = @{
            'LC Guests Warned'   = [PSCustomObject]@{ id = 'g-warned'; displayName = 'LC Guests Warned' }
            'LC Guests Disabled' = [PSCustomObject]@{ id = 'g-disabled'; displayName = 'LC Guests Disabled' }
            'LC Guests Exempt'   = [PSCustomObject]@{ id = 'g-exempt'; displayName = 'LC Guests Exempt' }
        }

        $guests = @(
            (New-TestGuest -Id 'active' -DormantDays 5),
            (New-TestGuest -Id 'warnme' -DormantDays 61),
            (New-TestGuest -Id 'disableme' -DormantDays 95),
            (New-TestGuest -Id 'purgeme' -DormantDays 250 -Enabled $false),
            (New-TestGuest -Id 'exempt' -DormantDays 500)
        )
        $warnedMembers = @([PSCustomObject]@{ id = 'disableme' })
        $disabledMembers = @([PSCustomObject]@{ id = 'purgeme' })
        $exemptMembers = @([PSCustomObject]@{ id = 'exempt' })

        Mock Invoke-GraphGetAll {
            if ($Uri -like 'groups[?]*Warned*') { return @($groups['LC Guests Warned']) }
            if ($Uri -like 'groups[?]*Disabled*') { return @($groups['LC Guests Disabled']) }
            if ($Uri -like 'groups[?]*Exempt*') { return @($groups['LC Guests Exempt']) }
            if ($Uri -like 'groups/g-warned/members*') { return $warnedMembers }
            if ($Uri -like 'groups/g-disabled/members*') { return $disabledMembers }
            if ($Uri -like 'groups/g-exempt/members*') { return $exemptMembers }
            if ($Uri -like 'users[?]*') { return $guests }
            if ($Uri -like 'users/*/sponsors*') { return @([PSCustomObject]@{ id = 'sp'; mail = 'sponsor@corp.example.com' }) }
            return @()
        }
        Mock Invoke-GraphRequest { return $null }

        It 'makes no write call in a dry run' {
            $summary = Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $true -AccessToken 'test-token' -Now $now
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It
            $summary.GuestsScanned | Should Be 5
            $summary.PlannedWarn | Should Be 1
            $summary.PlannedDisable | Should Be 1
            $summary.PlannedPurge | Should Be 1
            $summary.StageExempt | Should Be 1
            $summary.Warned | Should Be 0
            $summary.Disabled | Should Be 0
            $summary.Purged | Should Be 0
        }

        It 'performs exactly the planned writes when live' {
            $summary = Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $false -AccessToken 'test-token' -Now $now
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'groups/g-warned/members/$ref' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -like 'users/*/sendMail' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'PATCH' -and $Uri -eq 'users/disableme' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'groups/g-disabled/members/$ref' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'DELETE' -and $Uri -eq 'groups/g-warned/members/disableme/$ref' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 1 -Scope It -ParameterFilter { $Method -eq 'DELETE' -and $Uri -eq 'users/purgeme' }
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It -ParameterFilter { $Uri -like '*exempt*' -or $Uri -like '*active*' }
            $summary.Warned | Should Be 1
            $summary.Disabled | Should Be 1
            $summary.Purged | Should Be 1
            $summary.MailsSent | Should Be 1
        }

        It 'aborts before any write when the disable breaker trips' {
            $many = @()
            $manyWarned = @()
            for ($i = 1; $i -le 30; $i++) {
                $many += New-TestGuest -Id "w$i" -DormantDays 100
                $manyWarned += [PSCustomObject]@{ id = "w$i" }
            }
            Mock Invoke-GraphGetAll {
                if ($Uri -like 'groups[?]*Warned*') { return @($groups['LC Guests Warned']) }
                if ($Uri -like 'groups[?]*Disabled*') { return @($groups['LC Guests Disabled']) }
                if ($Uri -like 'groups[?]*Exempt*') { return @($groups['LC Guests Exempt']) }
                if ($Uri -like 'groups/g-warned/members*') { return $manyWarned }
                if ($Uri -like 'users[?]*') { return $many }
                return @()
            }
            { Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $false -AccessToken 'test-token' -Now $now } | Should Throw
            Assert-MockCalled Invoke-GraphRequest -Exactly 0 -Scope It
        }

        It 'evaluates the breaker in a dry run too' {
            $many = @()
            $manyDisabled = @()
            for ($i = 1; $i -le 11; $i++) {
                $many += New-TestGuest -Id "p$i" -DormantDays 300 -Enabled $false
                $manyDisabled += [PSCustomObject]@{ id = "p$i" }
            }
            Mock Invoke-GraphGetAll {
                if ($Uri -like 'groups[?]*Warned*') { return @($groups['LC Guests Warned']) }
                if ($Uri -like 'groups[?]*Disabled*') { return @($groups['LC Guests Disabled']) }
                if ($Uri -like 'groups[?]*Exempt*') { return @($groups['LC Guests Exempt']) }
                if ($Uri -like 'groups/g-disabled/members*') { return $manyDisabled }
                if ($Uri -like 'users[?]*') { return $many }
                return @()
            }
            { Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $true -AccessToken 'test-token' -Now $now } | Should Throw
        }

        It 'refuses a missing stage group by name' {
            Mock Invoke-GraphGetAll { return @() }
            { Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -DryRun $true -AccessToken 'test-token' -Now $now } | Should Throw
        }

        It 'rejects WarnDays at or above DisableDays' {
            { Invoke-GuestLifecycleRun -SenderMailbox 'iam-noreply@corp.example.com' -WarnDays 90 -DisableDays 90 -DryRun $true -AccessToken 'test-token' -Now $now } | Should Throw
        }
    }
}
