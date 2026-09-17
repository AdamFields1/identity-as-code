# Pester tests for automation/runbooks/Disable-UnauthorizedSubscriptions.ps1.
#
# Pester 3/4 assertion syntax ("Should Be"), because Windows PowerShell 5.1
# ships Pester 3.4.0. The runbook is dot-sourced, which loads
# automation/lib/Runbook.Common.ps1 through its INLINE_LIBRARY block exactly as
# a workstation run does. Every request goes through the library's
# Invoke-HttpCore, which is mocked here with a small fake of the ARM and Graph
# endpoints the runbook uses, shaped like their learn.microsoft.com
# documentation; Start-Sleep and the Az.Accounts probe are mocked too, so
# nothing leaves the machine or waits. Invoke-WebRequest is mocked to throw,
# as a tripwire for any request that bypasses Invoke-HttpCore. All ids are
# fake, all-same-digit GUIDs or plain names. The only real GUID is Microsoft's
# published id of the built-in Owner role, a public constant the runbook must
# check against.
#
# A subscription is canceled only when DryRun is false and AllowCancel is
# true. Most run tests pass AllowCancel $true through $runArgs so they can
# follow the cancel path; the 'DryRun and AllowCancel' context covers all four
# combinations and the defaults.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$automationRoot = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $automationRoot
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Disable-UnauthorizedSubscriptions.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$runbooksModule = Join-Path -Path $repoRoot -ChildPath 'modules\azure\automation-runbooks\main.tf'

# ---------------------------------------------------------------------------
# Fake cloud. Global so the Invoke-HttpCore mock body can reach it.
# ---------------------------------------------------------------------------

function global:New-DusResponse {
    param([int]$Status = 200, [object]$Json = $null)
    $content = ''
    if ($null -ne $Json) { $content = ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
    return @{ StatusCode = $Status; Content = $content; Headers = @{} }
}

function global:New-DusError {
    param([int]$Status, [string]$Code)
    return (New-DusResponse -Status $Status -Json @{ error = @{ code = $Code; message = ('Test error {0}.' -f $Code) } })
}

function global:Reset-DusCloud {
    $global:DusRequests = New-Object System.Collections.ArrayList
    $global:DusCloud = @{
        Subscriptions         = @()
        ManagementGroups      = @()
        Descendants           = @()
        Assignments           = @{}
        SelfAssignments       = @()
        Users                 = @{}
        UpnIndex              = @{}
        Groups                = @{}
        GroupMembers          = @{}
        Created               = @{}
        # Answers for the cancel POST, in order: an HTTP status, or 0 for no
        # response at all. Empty means success.
        CancelQueue           = (New-Object System.Collections.Queue)
        PutStatus             = 0
        DeleteStatus          = 0
        KeepAfterDelete       = $false
        # Subscription ids (or a management group name) whose principalId
        # look-up answers 403, and subscription ids whose atScope read
        # answers 400.
        LookupFailScopes      = @()
        OwnerReadFailScopes   = @()
        # Azure PIM eligibility instances per subscription id, and the
        # subscription ids whose eligibility read answers 403.
        Eligibility           = @{}
        EligibilityFailScopes = @()
        # State a GET of one subscription reports, per id, instead of the
        # listed state (for a cancel that took effect behind an error).
        StateOverrides        = @{}
    }
}

function global:Invoke-DusFakeCloud {
    param([string]$Method, [string]$Uri, [object]$Body)

    $cloud = $global:DusCloud
    $parsed = [Uri]$Uri
    $path = [Uri]::UnescapeDataString($parsed.AbsolutePath)
    $query = [Uri]::UnescapeDataString($parsed.Query)
    $bodyText = ''
    if ($Body -is [byte[]]) { $bodyText = [System.Text.Encoding]::UTF8.GetString($Body) }
    elseif ($null -ne $Body) { $bodyText = [string]$Body }
    [void]$global:DusRequests.Add([PSCustomObject]@{ Method = $Method; HostName = $parsed.Host; Path = $path; Query = $query; Body = $bodyText })

    if ($parsed.Host -like 'graph.*') {
        if ($Method -eq 'GET' -and $path -eq '/v1.0/users') {
            $found = @()
            if ($query -match "userPrincipalName eq '([^']+)'" -and $cloud.UpnIndex.ContainsKey($Matches[1].ToLowerInvariant())) { $found = @($cloud.UpnIndex[$Matches[1].ToLowerInvariant()]) }
            return (New-DusResponse -Json @{ value = $found })
        }
        if ($Method -eq 'GET' -and $path -match '^/v1\.0/users/([^/]+)$') {
            if ($cloud.Users.ContainsKey($Matches[1])) { return (New-DusResponse -Json $cloud.Users[$Matches[1]]) }
            return (New-DusError -Status 404 -Code 'Request_ResourceNotFound')
        }
        if ($Method -eq 'GET' -and $path -eq '/v1.0/groups') {
            $found = @()
            if ($query -match "displayName eq '([^']+)'" -and $cloud.Groups.ContainsKey($Matches[1])) { $found = @($cloud.Groups[$Matches[1]]) }
            return (New-DusResponse -Json @{ value = $found })
        }
        if ($Method -eq 'GET' -and $path -match '^/v1\.0/groups/([^/]+)/transitiveMembers(/microsoft\.graph\.user)?$') {
            $found = @()
            if ($cloud.GroupMembers.ContainsKey($Matches[1])) { $found = @($cloud.GroupMembers[$Matches[1]]) }
            return (New-DusResponse -Json @{ value = $found })
        }
        if ($Method -eq 'POST' -and $path -match '^/v1\.0/users/[^/]+/sendMail$') { return (New-DusResponse -Status 202) }
        throw ('Unexpected Graph request: {0} {1}' -f $Method, $path)
    }

    if ($Method -eq 'GET' -and $path -eq '/subscriptions') { return (New-DusResponse -Json @{ value = @($cloud.Subscriptions) }) }
    if ($Method -eq 'GET' -and $path -match '^/subscriptions/([^/]+)$') {
        $subscriptionId = $Matches[1]
        $found = @($cloud.Subscriptions | Where-Object { $_.subscriptionId -eq $subscriptionId })
        if ($found.Count -eq 0) { return (New-DusError -Status 404 -Code 'SubscriptionNotFound') }
        $one = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $found[0] -Depth 10)
        if ($cloud.StateOverrides.ContainsKey($subscriptionId)) { $one.state = [string]$cloud.StateOverrides[$subscriptionId] }
        return (New-DusResponse -Json $one)
    }
    if ($Method -eq 'GET' -and $path -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleEligibilityScheduleInstances$') {
        $subscriptionId = $Matches[1]
        if (@($cloud.EligibilityFailScopes) -contains $subscriptionId) { return (New-DusError -Status 403 -Code 'AuthorizationFailed') }
        $items = @()
        if ($cloud.Eligibility.ContainsKey($subscriptionId)) { $items = @($cloud.Eligibility[$subscriptionId]) }
        return (New-DusResponse -Json @{ value = $items })
    }
    if ($Method -eq 'GET' -and $path -eq '/providers/Microsoft.Management/managementGroups') { return (New-DusResponse -Json @{ value = @($cloud.ManagementGroups) }) }
    if ($Method -eq 'GET' -and $path -match '^/providers/Microsoft\.Management/managementGroups/[^/]+/descendants$') { return (New-DusResponse -Json @{ value = @($cloud.Descendants) }) }
    if ($Method -eq 'GET' -and $path -match '^/providers/Microsoft\.Management/managementGroups/([^/]+)/providers/Microsoft\.Authorization/roleAssignments$') {
        if (@($cloud.LookupFailScopes) -contains $Matches[1]) { return (New-DusError -Status 403 -Code 'AuthorizationFailed') }
        return (New-DusResponse -Json @{ value = @($cloud.SelfAssignments) })
    }
    if ($Method -eq 'GET' -and $path -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleDefinitions$') {
        $definition = @{
            id         = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -f $Matches[1])
            name       = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
            type       = 'Microsoft.Authorization/roleDefinitions'
            properties = @{ roleName = 'Owner'; type = 'BuiltInRole'; assignableScopes = @('/') }
        }
        return (New-DusResponse -Json @{ value = @($definition) })
    }
    if ($Method -eq 'GET' -and $path -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleAssignments$') {
        $subscriptionId = $Matches[1]
        if ($query -match 'principalId eq') {
            if (@($cloud.LookupFailScopes) -contains $subscriptionId) { return (New-DusError -Status 403 -Code 'AuthorizationFailed') }
            return (New-DusResponse -Json @{ value = @($cloud.SelfAssignments | Where-Object { $_.properties.scope -eq ('/subscriptions/' + $subscriptionId) }) })
        }
        if (@($cloud.OwnerReadFailScopes) -contains $subscriptionId) { return (New-DusError -Status 400 -Code 'BadRequest') }
        $items = @()
        if ($cloud.Assignments.ContainsKey($subscriptionId)) { $items = @($cloud.Assignments[$subscriptionId]) }
        return (New-DusResponse -Json @{ value = $items })
    }
    if ($path -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleAssignments/([^/]+)$') {
        $subscriptionId = $Matches[1]
        $name = $Matches[2]
        switch ($Method) {
            'PUT' {
                if ($cloud.PutStatus -gt 0) { return (New-DusError -Status $cloud.PutStatus -Code 'AuthorizationFailed') }
                $cloud.Created[$name] = @{ SubscriptionId = $subscriptionId; Exists = $true }
                $sent = ConvertFrom-Json -InputObject $bodyText
                return (New-DusResponse -Status 201 -Json @{ name = $name; id = $path; properties = @{ principalId = $sent.properties.principalId; principalType = $sent.properties.principalType; roleDefinitionId = $sent.properties.roleDefinitionId; scope = ('/subscriptions/' + $subscriptionId) } })
            }
            'DELETE' {
                if ($cloud.DeleteStatus -gt 0) { return (New-DusError -Status $cloud.DeleteStatus -Code 'AuthorizationFailed') }
                if ($cloud.Created.ContainsKey($name) -and $cloud.Created[$name].Exists) {
                    if (-not $cloud.KeepAfterDelete) { $cloud.Created[$name].Exists = $false }
                    return (New-DusResponse -Json @{ name = $name })
                }
                return (New-DusResponse -Status 204)
            }
            'GET' {
                if ($cloud.Created.ContainsKey($name) -and $cloud.Created[$name].Exists) { return (New-DusResponse -Json @{ name = $name }) }
                return (New-DusError -Status 404 -Code 'RoleAssignmentNotFound')
            }
        }
    }
    if ($Method -eq 'POST' -and $path -match '^/subscriptions/([^/]+)/providers/Microsoft\.Subscription/cancel$') {
        if ($cloud.CancelQueue.Count -gt 0) {
            $status = [int]$cloud.CancelQueue.Dequeue()
            # 0 stands for a request that got no HTTP response at all.
            if ($status -eq 0) { throw 'The operation has timed out.' }
            $code = 'SubscriptionCancelFailed'
            if ($status -eq 403) { $code = 'AuthorizationFailed' }
            if ($status -eq 429) { $code = 'TooManyRequests' }
            return (New-DusError -Status $status -Code $code)
        }
        return (New-DusResponse -Json @{ subscriptionId = $Matches[1] })
    }
    throw ('Unexpected ARM request: {0} {1}' -f $Method, $path)
}

Describe 'Disable-UnauthorizedSubscriptions' {
    . $runbook -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken 'dot-source-token-0000'
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    Mock Invoke-HttpCore { return (Invoke-DusFakeCloud -Method $Method -Uri $Uri -Body $Body) }
    Mock Invoke-WebRequest { throw 'network call in test' }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }

    # Fake, all-same-digit ids.
    $runId = '00000000-0000-0000-0000-000000000000'
    $selfId = '11111111-1111-1111-1111-111111111111'
    $subAllowed = '22222222-2222-2222-2222-222222222222'
    $subCandidate = '33333333-3333-3333-3333-333333333333'
    $subGroupAllowed = '44444444-4444-4444-4444-444444444444'
    $subWorkload = '55555555-5555-5555-5555-555555555555'
    $subCorporate = '66666666-6666-6666-6666-666666666666'
    $subExcluded = '88888888-8888-8888-8888-888888888888'
    $subDisabled = '99999999-9999-9999-9999-999999999999'
    $alexId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $blairId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $caseyId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $groupId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $workloadId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $otherRoleId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    $ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    $patterns = @('MSDN_*', 'FreeTrial_*', 'PayAsYouGo_*', 'Pay-as-you-go_*')
    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 6, 30, 0, ([DateTimeKind]::Utc)

    function ConvertTo-TestBase64Url {
        param([string]$Text)
        return ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    $graphToken = 'graph-test-token-0000000000'
    $armToken = '{0}.{1}.{2}' -f (ConvertTo-TestBase64Url -Text '{"typ":"JWT","alg":"none"}'), (ConvertTo-TestBase64Url -Text ('{"aud":"https://management.azure.com/","oid":"' + $selfId + '"}')), 'testsignature0000'
    $tokens = @{ Graph = $graphToken; Arm = $armToken }

    $script:TestAssignmentCounter = 0
    function New-TestAssignment {
        param(
            [string]$SubscriptionId,
            [string]$PrincipalId,
            [string]$PrincipalType = 'User',
            [string]$RoleId = $ownerRoleId,
            [string]$Scope = '',
            [string]$Name = '',
            [string]$Description = '',
            [string]$CreatedOn = ''
        )
        if (-not $Scope) { $Scope = '/subscriptions/' + $SubscriptionId }
        if (-not $Name) {
            # Plain names, not generated GUIDs: test ids are all-same-digit.
            $script:TestAssignmentCounter++
            $Name = 'assignment-{0}' -f $script:TestAssignmentCounter
        }
        return [PSCustomObject]@{
            id         = ('{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f $Scope, $Name)
            name       = $Name
            type       = 'Microsoft.Authorization/roleAssignments'
            properties = [PSCustomObject]@{
                roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $SubscriptionId, $RoleId)
                principalId      = $PrincipalId
                principalType    = $PrincipalType
                scope            = $Scope
                description      = $Description
                createdOn        = $CreatedOn
            }
        }
    }

    # A role eligibility schedule instance shaped like the 2020-10-01 List For
    # Scope sample. Start and End may be strings or DateTime values.
    function New-TestEligibility {
        param(
            [string]$SubscriptionId,
            [string]$PrincipalId,
            [string]$PrincipalType = 'User',
            [string]$RoleId = $ownerRoleId,
            [string]$Scope = '',
            [string]$Status = 'Provisioned',
            [string]$MemberType = 'Direct',
            [object]$Start = '2026-01-01T00:00:00Z',
            [object]$End = $null
        )
        if (-not $Scope) { $Scope = '/subscriptions/' + $SubscriptionId }
        return [PSCustomObject]@{
            id         = ('{0}/providers/Microsoft.Authorization/RoleEligibilityScheduleInstances/eligibility-{1}' -f $Scope, $PrincipalId)
            name       = ('eligibility-{0}' -f $PrincipalId)
            type       = 'Microsoft.Authorization/RoleEligibilityScheduleInstances'
            properties = [PSCustomObject]@{
                scope            = $Scope
                roleDefinitionId = ('/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $SubscriptionId, $RoleId)
                principalId      = $PrincipalId
                principalType    = $PrincipalType
                status           = $Status
                startDateTime    = $Start
                endDateTime      = $End
                memberType       = $MemberType
            }
        }
    }

    $tempDescription = 'Temporary elevation by Disable-UnauthorizedSubscriptions, run {0}. Removed by the same run.' -f $runId
    function New-TestLeftover {
        param([string]$SubscriptionId, [string]$Name, [string]$CreatedOn = '')
        $global:DusCloud.Created[$Name] = @{ SubscriptionId = $SubscriptionId; Exists = $true }
        return (New-TestAssignment -SubscriptionId $SubscriptionId -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Name $Name -Description $tempDescription -CreatedOn $CreatedOn)
    }

    function New-TestSubscription {
        param([string]$Id, [string]$Name, [string]$QuotaId = 'MSDN_2014-09-01', [string]$State = 'Enabled')
        return [PSCustomObject]@{
            id                   = '/subscriptions/' + $Id
            authorizationSource  = 'RoleBased'
            subscriptionId       = $Id
            displayName          = $Name
            state                = $State
            subscriptionPolicies = [PSCustomObject]@{ locationPlacementId = 'Public_2014-09-01'; quotaId = $QuotaId; spendingLimit = 'On' }
        }
    }

    function New-TestUser {
        param([string]$Id, [string]$Name, [string]$Upn, [string]$Mail = '')
        return [PSCustomObject]@{ id = $Id; displayName = $Name; userPrincipalName = $Upn; mail = $Mail }
    }

    # The standard tenant: one subscription per decision.
    function Set-StandardTenant {
        param([string[]]$Only = @())
        Reset-DusCloud
        $cloud = $global:DusCloud
        $all = @(
            (New-TestSubscription -Id $subAllowed -Name 'Dev Alex' -QuotaId 'MSDN_2014-09-01'),
            (New-TestSubscription -Id $subCandidate -Name 'Trial Blair' -QuotaId 'FreeTrial_2014-09-01'),
            (New-TestSubscription -Id $subGroupAllowed -Name 'Payg Casey' -QuotaId 'PayAsYouGo_2014-09-01'),
            (New-TestSubscription -Id $subWorkload -Name 'Workload Only' -QuotaId 'MSDN_2014-09-01'),
            (New-TestSubscription -Id $subCorporate -Name 'Corp Platform' -QuotaId 'EnterpriseAgreement_2014-09-01'),
            (New-TestSubscription -Id $subExcluded -Name 'Lab Shared' -QuotaId 'MSDN_2014-09-01'),
            (New-TestSubscription -Id $subDisabled -Name 'Old Trial' -QuotaId 'FreeTrial_2014-09-01' -State 'Disabled')
        )
        if ($Only.Count -gt 0) { $all = @($all | Where-Object { $Only -contains $_.subscriptionId }) }
        $cloud.Subscriptions = $all
        $cloud.Assignments[$subAllowed] = @((New-TestAssignment -SubscriptionId $subAllowed -PrincipalId $alexId))
        $cloud.Assignments[$subCandidate] = @(
            (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId),
            (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $workloadId -PrincipalType 'ServicePrincipal'),
            (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId -RoleId $otherRoleId)
        )
        $cloud.Assignments[$subGroupAllowed] = @((New-TestAssignment -SubscriptionId $subGroupAllowed -PrincipalId $caseyId))
        $cloud.Assignments[$subWorkload] = @(
            (New-TestAssignment -SubscriptionId $subWorkload -PrincipalId $workloadId -PrincipalType 'ServicePrincipal'),
            (New-TestAssignment -SubscriptionId $subWorkload -PrincipalId $alexId -Scope '/providers/Microsoft.Management/managementGroups/mg-sandbox')
        )
        $cloud.Assignments[$subCorporate] = @((New-TestAssignment -SubscriptionId $subCorporate -PrincipalId $blairId))
        $cloud.Assignments[$subExcluded] = @((New-TestAssignment -SubscriptionId $subExcluded -PrincipalId $blairId))
        $cloud.Users[$alexId] = New-TestUser -Id $alexId -Name 'Alex Example' -Upn 'alex@corp.example.com' -Mail 'alex@corp.example.com'
        $cloud.Users[$blairId] = New-TestUser -Id $blairId -Name 'Blair Example' -Upn 'blair@corp.example.com' -Mail 'blair@corp.example.com'
        $cloud.Users[$caseyId] = New-TestUser -Id $caseyId -Name 'Casey Example' -Upn 'casey@corp.example.com' -Mail 'casey@corp.example.com'
        # Graph returns the allowlisted user's id in upper case on purpose.
        $cloud.UpnIndex['alex@corp.example.com'] = @((New-TestUser -Id $alexId.ToUpperInvariant() -Name 'Alex Example' -Upn 'alex@corp.example.com'))
        $cloud.Groups['SEC Subscription Owners'] = @([PSCustomObject]@{ id = $groupId; displayName = 'SEC Subscription Owners' })
        $cloud.GroupMembers[$groupId] = @([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.user'; id = $caseyId.ToUpperInvariant() })
    }

    # Lists in the semicolon form a schedule passes. AllowCancel is on so the
    # run tests can follow the cancel path; DryRun keeps its default (true)
    # unless a test turns it off.
    $runArgs = @{
        SenderMailbox               = 'iam-noreply@corp.example.com'
        Recipients                  = 'cloud-governance@corp.example.com'
        AllowedOwnerUpns            = 'alex@corp.example.com'
        AllowedOwnerGroupNames      = 'SEC Subscription Owners'
        ExcludedSubscriptionNames   = 'lab shared'
        ElevationPropagationSeconds = 7
        AllowCancel                 = $true
        AccessToken                 = $tokens
        RunId                       = $runId
        Now                         = $now
    }

    function Get-TestWrites { return @($global:DusRequests | Where-Object { $_.Method -ne 'GET' }) }
    function Get-TestRequests {
        param([string]$Method, [string]$PathLike)
        return @($global:DusRequests | Where-Object { $_.Method -eq $Method -and $_.Path -like $PathLike })
    }
    function Get-TestItems {
        param([object]$Summary, [string]$Action)
        return @($Summary.Items | Where-Object { $_.Action -eq $Action })
    }

    Context 'object ids' {
        It 'normalises case, braces, and surrounding space' {
            ConvertTo-NormalizedObjectId -Value ' {AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA} ' | Should Be $alexId
        }

        It 'accepts a Guid value' {
            ConvertTo-NormalizedObjectId -Value ([Guid]$blairId) | Should Be $blairId
        }

        It 'returns an empty string for null, empty, and non-GUID text' {
            ConvertTo-NormalizedObjectId -Value $null | Should Be ''
            ConvertTo-NormalizedObjectId -Value '  ' | Should Be ''
            ConvertTo-NormalizedObjectId -Value 'alex@corp.example.com' | Should Be ''
        }

        It 'throws when handed an object instead of an id string' {
            { ConvertTo-NormalizedObjectId -Value ([PSCustomObject]@{ id = $alexId }) } | Should Throw 'must be a string or a Guid'
            { ConvertTo-NormalizedObjectId -Value @{ id = $alexId } } | Should Throw 'must be a string or a Guid'
        }

        It 'builds a case-insensitive set of normalised ids' {
            $set = New-PrincipalIdSet -Ids @($alexId.ToUpperInvariant(), ('{' + $blairId + '}'))
            ($set -is [System.Collections.Generic.HashSet[string]]) | Should Be $true
            $set.Count | Should Be 2
            $set.Contains($alexId) | Should Be $true
            $set.Contains($blairId) | Should Be $true
        }

        It 'refuses a user object or a non-GUID string in the set' {
            { New-PrincipalIdSet -Ids @([PSCustomObject]@{ id = $alexId }) } | Should Throw 'must be a string or a Guid'
            { New-PrincipalIdSet -Ids @('alex@corp.example.com') } | Should Throw 'is not an object id'
        }

        It 'refuses a plain string array where the decision needs a principal set' {
            $sub = New-TestSubscription -Id $subCandidate -Name 'Trial Blair' -QuotaId 'FreeTrial_2014-09-01'
            { Get-SubscriptionDecision -Subscription $sub -RestrictedQuotaIdPatterns $patterns -AllowedPrincipalIds @($alexId) } | Should Throw 'HashSet'
        }
    }

    Context 'offer patterns' {
        It 'matches every documented restricted quota id with the default patterns, given as the semicolon list a schedule passes' {
            $defaults = @(Confirm-RestrictedQuotaIdPatterns -Patterns @(ConvertTo-StringList -Value 'MSDN_*;FreeTrial_*;PayAsYouGo_*;Pay-as-you-go_*'))
            $defaults.Count | Should Be 4
            # A local run may still pass the JSON array form.
            $fromJson = @(Confirm-RestrictedQuotaIdPatterns -Patterns @(ConvertTo-StringList -Value '["MSDN_*","FreeTrial_*","PayAsYouGo_*","Pay-as-you-go_*"]'))
            ($fromJson -join ';') | Should Be ($defaults -join ';')
            Get-MatchingQuotaPattern -QuotaId 'MSDN_2014-09-01' -Patterns $defaults | Should Be 'MSDN_*'
            Get-MatchingQuotaPattern -QuotaId 'FreeTrial_2014-09-01' -Patterns $defaults | Should Be 'FreeTrial_*'
            Get-MatchingQuotaPattern -QuotaId 'PayAsYouGo_2014-09-01' -Patterns $defaults | Should Be 'PayAsYouGo_*'
            Get-MatchingQuotaPattern -QuotaId 'Pay-as-you-go_2014-09-01' -Patterns $defaults | Should Be 'Pay-as-you-go_*'
        }

        It 'does not match agreement-billed or unknown quota ids' {
            Get-MatchingQuotaPattern -QuotaId 'EnterpriseAgreement_2014-09-01' -Patterns $patterns | Should Be ''
            Get-MatchingQuotaPattern -QuotaId 'MSDNDevTest_2014-09-01' -Patterns $patterns | Should Be ''
            Get-MatchingQuotaPattern -QuotaId '' -Patterns $patterns | Should Be ''
        }

        It 'refuses a pattern that would match a quota id agreement-billed offers share' {
            { Confirm-RestrictedQuotaIdPatterns -Patterns @('*') } | Should Throw 'EnterpriseAgreement_2014-09-01'
            { Confirm-RestrictedQuotaIdPatterns -Patterns @('MSDN*') } | Should Throw 'MSDNDevTest_2014-09-01'
            { Confirm-RestrictedQuotaIdPatterns -Patterns @('CSP_*') } | Should Throw 'CSP_2015-05-01'
        }

        It 'refuses an empty list and wildcard brackets' {
            { Confirm-RestrictedQuotaIdPatterns -Patterns @() } | Should Throw 'is empty'
            { Confirm-RestrictedQuotaIdPatterns -Patterns @('[F]reeTrial_*') } | Should Throw 'may contain only'
        }
    }

    Context 'decision' {
        $allowed = New-PrincipalIdSet -Ids @($alexId.ToUpperInvariant(), $groupId)

        function Get-TestDecision {
            param(
                [object]$Subscription,
                [object[]]$Assignments = @(),
                [string[]]$Excluded = @('Lab Shared'),
                [string]$ReadError = '',
                [object[]]$Eligible = $null,
                [string]$EligibleError = ''
            )
            return (Get-SubscriptionDecision -Subscription $Subscription -RoleAssignments $Assignments -RestrictedQuotaIdPatterns $patterns -AllowedPrincipalIds $allowed -ExcludedSubscriptions $Excluded -OwnerRoleId $ownerRoleId -IdentityPrincipalId $selfId -AssignmentReadError $ReadError -EligibleAssignments $Eligible -EligibilityReadError $EligibleError -Now $now)
        }

        $restricted = New-TestSubscription -Id $subCandidate -Name 'Trial Blair' -QuotaId 'FreeTrial_2014-09-01'

        It 'allows a subscription whose direct owner is allowlisted, comparing normalised id strings' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId))
            $d.Decision | Should Be 'Allowed'
            (@($d.AllowedOwnerIds) -join ',') | Should Be $alexId
            @($d.OtherHumanOwnerIds).Count | Should Be 0
            Test-DecisionReportable -Decision $d | Should Be $false
        }

        It 'allows a co-owned subscription but names the owner who is not allowlisted and reports it' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId), (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId))
            $d.Decision | Should Be 'Allowed'
            (@($d.AllowedOwnerIds) -join ',') | Should Be $alexId
            (@($d.OtherHumanOwnerIds) -join ',') | Should Be $blairId
            $d.Reason | Should Match 'not allowlisted'
            Test-DecisionReportable -Decision $d | Should Be $true
        }

        It 'never lets a group owner make a subscription allowed, even an allowlisted group' {
            $groupOnly = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $groupId.ToUpperInvariant() -PrincipalType 'Group'))
            $groupOnly.Decision | Should Be 'NeedsReview'
            (@($groupOnly.GroupOwnerIds) -join ',') | Should Be $groupId
            @($groupOnly.AllowedOwnerIds).Count | Should Be 0
            $withOffender = Get-TestDecision -Subscription $restricted -Assignments @(
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $groupId -PrincipalType 'Group'),
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId)
            )
            $withOffender.Decision | Should Be 'Candidate'
            (@($withOffender.HumanOwnerIds) -join ',') | Should Be $blairId
        }

        It 'treats a User owner with an empty or non-GUID principalId as unknown, never as a human' {
            foreach ($bad in @($null, '', 'not-a-guid')) {
                $owner = New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId
                $owner.properties.principalId = $bad
                $d = Get-TestDecision -Subscription $restricted -Assignments @($owner)
                $d.Decision | Should Be 'NeedsReview'
                @($d.HumanOwnerIds).Count | Should Be 0
                $d.IgnoredOwnerCount | Should Be 1
            }
        }

        It 'refuses an owner principalId that is an object rather than a string' {
            $odd = New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId
            $odd.properties.principalId = [PSCustomObject]@{ id = $blairId }
            { Get-TestDecision -Subscription $restricted -Assignments @($odd) } | Should Throw 'must be a string or a Guid'
        }

        It 'excludes by display name, case-insensitively and ignoring surrounding space, and by subscription id' {
            $lab = New-TestSubscription -Id $subExcluded -Name 'Lab Shared'
            (Get-TestDecision -Subscription $lab -Excluded @('LAB SHARED')).Decision | Should Be 'Excluded'
            (Get-TestDecision -Subscription $lab -Excluded @($subExcluded.ToUpperInvariant())).Decision | Should Be 'Excluded'
            $spaced = New-TestSubscription -Id $subExcluded -Name 'Lab Shared '
            (Get-TestDecision -Subscription $spaced -Excluded @(' Lab Shared')).Decision | Should Be 'Excluded'
        }

        It 'keeps the offer pattern on an excluded decision, so a restricted one is reported' {
            $lab = Get-TestDecision -Subscription (New-TestSubscription -Id $subExcluded -Name 'Lab Shared') -Excluded @($subExcluded)
            $lab.MatchedPattern | Should Be 'MSDN_*'
            $lab.OwnersRead | Should Be $false
            Test-DecisionReportable -Decision $lab | Should Be $true
            $corp = Get-TestDecision -Subscription (New-TestSubscription -Id $subCorporate -Name 'Corp' -QuotaId 'EnterpriseAgreement_2014-09-01') -Excluded @($subCorporate)
            $corp.Decision | Should Be 'Excluded'
            Test-DecisionReportable -Decision $corp | Should Be $false
        }

        It 'skips an offer that is not restricted, and one with no quota id' {
            $corp = New-TestSubscription -Id $subCorporate -Name 'Corp Platform' -QuotaId 'EnterpriseAgreement_2014-09-01'
            (Get-TestDecision -Subscription $corp -Assignments @((New-TestAssignment -SubscriptionId $subCorporate -PrincipalId $blairId))).Decision | Should Be 'NotRestricted'
            $blank = New-TestSubscription -Id $subCorporate -Name 'Blank' -QuotaId ''
            (Get-TestDecision -Subscription $blank).Reason | Should Be 'quotaId not reported'
        }

        It 'skips a subscription that is not Enabled' {
            (Get-TestDecision -Subscription (New-TestSubscription -Id $subDisabled -Name 'Old' -QuotaId 'FreeTrial_2014-09-01' -State 'Disabled')).Decision | Should Be 'NotEnabled'
            (Get-TestDecision -Subscription (New-TestSubscription -Id $subDisabled -Name 'Old' -QuotaId 'FreeTrial_2014-09-01' -State 'Warned')).Decision | Should Be 'NotEnabled'
        }

        It 'sends a subscription owned only by workloads to review' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @(
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $workloadId -PrincipalType 'ServicePrincipal'),
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId -PrincipalType 'AgentUser')
            )
            $d.Decision | Should Be 'NeedsReview'
            $d.IgnoredOwnerCount | Should Be 2
        }

        It 'sends a subscription owned only by a group that is not allowed to review' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $workloadId -PrincipalType 'Group'))
            $d.Decision | Should Be 'NeedsReview'
            (@($d.GroupOwnerIds) -join ',') | Should Be $workloadId
        }

        It 'does not count an owner inherited from a management group, allowlisted or not' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId -Scope '/providers/Microsoft.Management/managementGroups/mg-sandbox'))
            $d.Decision | Should Be 'NeedsReview'
            $d.DirectOwnerCount | Should Be 0
        }

        It 'treats an owner with no principal type as unknown, never as a human' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId -PrincipalType ''))
            $d.Decision | Should Be 'NeedsReview'
        }

        It 'sends a subscription whose owners could not be read to review' {
            $d = Get-TestDecision -Subscription $restricted -ReadError 'HTTP 403'
            $d.Decision | Should Be 'NeedsReview'
            $d.OwnersRead | Should Be $false
        }

        It 'makes a candidate of a restricted subscription whose human owners are not allowed' {
            $d = Get-TestDecision -Subscription $restricted -Assignments @(
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId),
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId -RoleId $otherRoleId),
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Name 'leftover-1' -Description 'Temporary elevation by Disable-UnauthorizedSubscriptions, run x.' -CreatedOn '2026-09-16T06:30:00Z'),
                (New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Name 'granted-by-hand')
            )
            $d.Decision | Should Be 'Candidate'
            $d.OwnersRead | Should Be $true
            (@($d.HumanOwnerIds) -join ',') | Should Be $blairId
            $d.MatchedPattern | Should Be 'FreeTrial_*'
            (@($d.TemporaryAssignments) | ForEach-Object { $_.Name }) -join ',' | Should Be 'leftover-1'
            @($d.TemporaryAssignments)[0].CreatedOn | Should Be '2026-09-16T06:30:00Z'
            (@($d.OtherSelfAssignments) -join ',') | Should Be 'granted-by-hand'
        }

        $blairOwns = @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $blairId))

        It 'allows a subscription whose allowlisted user is eligible for Owner there through Azure PIM, and reports the co-ownership' {
            $eligible = @((New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId.ToUpperInvariant()))
            $d = Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible $eligible
            $d.Decision | Should Be 'Allowed'
            $d.EligibilityRead | Should Be $true
            (@($d.EligibleAllowedOwnerIds) -join ',') | Should Be $alexId
            @($d.AllowedOwnerIds).Count | Should Be 0
            (@($d.OtherHumanOwnerIds) -join ',') | Should Be $blairId
            $d.Reason | Should Match '^1 allowlisted eligible \(Azure PIM\) Owner\(s\) at subscription scope; also 1 human direct Owner\(s\) not allowlisted'
            Test-DecisionReportable -Decision $d | Should Be $true
            (ConvertTo-DecisionReportRow -Decision $d).EligibleAllowedOwnerIds | Should Be $alexId
        }

        It 'ignores an eligibility that is expired, not started, not provisioned, inherited, through a group, for another role or scope, or for a user who is not allowlisted' {
            $variants = @(
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -End '2026-09-16T00:00:00Z'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Start '2026-09-18T00:00:00Z'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Status 'Revoked'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -MemberType 'Inherited'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Scope '/providers/Microsoft.Management/managementGroups/mg-sandbox'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Scope "/subscriptions/$subCandidate/resourceGroups/rg-lab"),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $groupId -PrincipalType 'Group'),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -RoleId $otherRoleId),
                (New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $caseyId)
            )
            foreach ($variant in $variants) {
                $d = Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @($variant)
                $d.Decision | Should Be 'Candidate'
                $d.EligibilityRead | Should Be $true
                $d.Reason | Should Match 'none allowlisted; no allowlisted eligible Owner$'
            }
            (Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @()).Decision | Should Be 'Candidate'
        }

        It 'counts an eligibility whose status, member type, or times are missing or unreadable, because it only protects' {
            $vague = New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Status '' -MemberType '' -Start 'some day' -End ''
            (Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @($vague)).Decision | Should Be 'Allowed'
        }

        It 'reads the eligibility window the same way from DateTime values, as PowerShell 7 parses them' {
            $start = New-Object -TypeName DateTime -ArgumentList 2026, 9, 1, 0, 0, 0, ([DateTimeKind]::Utc)
            $current = New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Start $start -End $now.AddDays(30)
            (Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @($current)).Decision | Should Be 'Allowed'
            $ended = New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId -Start $start -End $now.AddMinutes(-1)
            (Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @($ended)).Decision | Should Be 'Candidate'
        }

        It 'sends a would-be candidate to review when the eligible owners cannot be read, and skips the check when no list is given' {
            $d = Get-TestDecision -Subscription $restricted -Assignments $blairOwns -EligibleError 'HTTP 403'
            $d.Decision | Should Be 'NeedsReview'
            $d.Reason | Should Match 'eligible \(Azure PIM\) Owner assignments could not be read: HTTP 403'
            $unchecked = Get-TestDecision -Subscription $restricted -Assignments $blairOwns
            $unchecked.Decision | Should Be 'Candidate'
            $unchecked.EligibilityRead | Should Be $false
            # An allowed direct owner never needs the eligibility list.
            (Get-TestDecision -Subscription $restricted -Assignments @((New-TestAssignment -SubscriptionId $subCandidate -PrincipalId $alexId)) -EligibleError 'HTTP 403').Decision | Should Be 'Allowed'
        }

        It 'never returns WouldCancel itself; the run does that' {
            (Get-TestDecision -Subscription $restricted -Assignments $blairOwns -Eligible @()).Decision | Should Be 'Candidate'
            $wouldCancel = [PSCustomObject]@{ Decision = 'WouldCancel' }
            Test-DecisionReportable -Decision $wouldCancel | Should Be $true
        }
    }

    Context 'exclusions resolved to ids' {
        $subs = @(
            (New-TestSubscription -Id $subExcluded -Name 'Lab Shared '),
            (New-TestSubscription -Id $subCandidate -Name 'Trial Blair')
        )

        It 'keeps ids, resolves a unique name to its id, and warns about the name' {
            Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $runId -AccessToken $tokens
            $map = Resolve-ExcludedSubscriptionIds -Entries @($subCorporate.ToUpperInvariant(), 'lab shared') -Subscriptions $subs
            (@($map.Keys) -join ',') | Should Be ('{0},{1}' -f $subCorporate, $subExcluded)
            $map[$subCorporate] | Should Be 'by id'
            $map[$subExcluded] | Should Be 'by display name "lab shared"'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*"lab shared" is a display name, resolved to subscription 88888888-*' }).Count | Should Be 1
        }

        It 'warns about a name that matches nothing and leaves it out' {
            Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $runId -AccessToken $tokens
            $map = Resolve-ExcludedSubscriptionIds -Entries @('Gone') -Subscriptions $subs
            $map.Count | Should Be 0
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*"Gone" matches no swept subscription*' }).Count | Should Be 1
        }

        It 'refuses a name that a second subscription has been renamed to' {
            $renamed = $subs + @((New-TestSubscription -Id $subWorkload -Name 'LAB SHARED'))
            { Resolve-ExcludedSubscriptionIds -Entries @('Lab Shared') -Subscriptions $renamed } | Should Throw 'matches 2 subscriptions'
        }
    }

    Context 'elevation and mail helpers' {
        It 'doubles the propagation delay and caps it at 300 seconds' {
            Get-ElevationRetryDelaySeconds -Attempt 1 -BaseSeconds 60 | Should Be 60
            Get-ElevationRetryDelaySeconds -Attempt 2 -BaseSeconds 60 | Should Be 120
            Get-ElevationRetryDelaySeconds -Attempt 3 -BaseSeconds 60 | Should Be 240
            Get-ElevationRetryDelaySeconds -Attempt 4 -BaseSeconds 60 | Should Be 300
            Get-ElevationRetryDelaySeconds -Attempt 1 -BaseSeconds 0 | Should Be 5
        }

        It 'sizes the elevation window from the wait, the retries, the checks, and a 30 minute margin' {
            # 60 + 6 + 60 + 120 + 240 + 300 = 786 seconds, 14 minutes, plus 30.
            Get-ElevationWindowMinutes -PropagationSeconds 60 -MaxAttempts 5 | Should Be 44
            Get-ElevationWindowMinutes -PropagationSeconds 0 -MaxAttempts 1 | Should Be 31
            # 7 + 6 + 7 + 14 + 28 + 56 = 118 seconds, 2 minutes, plus 30.
            Get-ElevationWindowMinutes -PropagationSeconds 7 -MaxAttempts 5 | Should Be 32
        }

        It 'treats a temporary assignment as a leftover only once it is older than the window' {
            Test-LeftoverOldEnough -CreatedOn $now.AddMinutes(-45).ToString('o') -Now $now -WindowMinutes 44 | Should Be $true
            Test-LeftoverOldEnough -CreatedOn $now.AddMinutes(-44).ToString('o') -Now $now -WindowMinutes 44 | Should Be $true
            Test-LeftoverOldEnough -CreatedOn $now.AddMinutes(-5).ToString('o') -Now $now -WindowMinutes 44 | Should Be $false
            Test-LeftoverOldEnough -CreatedOn $now.AddMinutes(5).ToString('o') -Now $now -WindowMinutes 44 | Should Be $false
            Test-LeftoverOldEnough -CreatedOn '2026-09-17T06:25:00.1234567Z' -Now $now -WindowMinutes 44 | Should Be $false
            Test-LeftoverOldEnough -CreatedOn '' -Now $now -WindowMinutes 44 | Should Be $true
            Test-LeftoverOldEnough -CreatedOn 'yesterday-ish' -Now $now -WindowMinutes 44 | Should Be $true
        }

        It 'reads createdOn the same way whether ConvertFrom-Json kept a string or made a DateTime' {
            $asDate = New-Object -TypeName DateTime -ArgumentList 2026, 9, 17, 6, 25, 0, ([DateTimeKind]::Utc)
            $text = ConvertTo-TimestampText -Value $asDate
            $text | Should Be '2026-09-17T06:25:00.0000000Z'
            ConvertTo-TimestampText -Value ' 2026-09-17T06:25:00Z ' | Should Be '2026-09-17T06:25:00Z'
            ConvertTo-TimestampText -Value $null | Should Be ''
            Test-LeftoverOldEnough -CreatedOn $text -Now $now -WindowMinutes 44 | Should Be $false
        }

        It 'builds no failure message for a clean summary, and names every assignment in doubt otherwise' {
            $clean = [PSCustomObject]@{ RunId = $runId; CleanupFailureCount = 0; UnconfirmedRemovals = @(); LeftoverLookupFailures = @() }
            Get-DisableRunFailureMessage -Summary $clean | Should Be ''
            $dirty = [PSCustomObject]@{
                RunId                  = $runId
                CleanupFailureCount    = 2
                UnconfirmedRemovals    = @(
                    [PSCustomObject]@{ SubscriptionId = $subCandidate; AssignmentName = 'assignment-a'; Detail = 'x' },
                    [PSCustomObject]@{ SubscriptionId = $subAllowed; AssignmentName = 'assignment-b'; Detail = 'y' }
                )
                LeftoverLookupFailures = @([PSCustomObject]@{ Scope = "/subscriptions/$subCorporate"; Detail = 'HTTP 403' })
            }
            $message = Get-DisableRunFailureMessage -Summary $dirty
            $message | Should Match "run $runId failed after emitting its summary"
            $message | Should Match '2 temporary Owner assignment\(s\) of this identity could not be confirmed removed'
            $message | Should Match "subscription $subCandidate assignment assignment-a; subscription $subAllowed assignment assignment-b"
            $message | Should Match "could not be looked for at 1 scope\(s\): /subscriptions/$subCorporate"
            $countOnly = [PSCustomObject]@{ RunId = $runId; CleanupFailureCount = 1 }
            Get-DisableRunFailureMessage -Summary $countOnly | Should Match 'see Failures in the summary'
        }

        It 'skips an owner without a valid object id instead of listing users' {
            Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $runId -AccessToken $tokens -DryRun $false
            Reset-DusCloud
            $global:DusCloud.Users[$blairId] = New-TestUser -Id $blairId -Name 'Blair Example' -Upn 'blair@corp.example.com' -Mail 'blair@corp.example.com'
            $contacts = @(Get-OwnerContacts -UserIds @('', 'not-a-guid', $blairId.ToUpperInvariant()))
            $contacts.Count | Should Be 1
            $contacts[0].Address | Should Be 'blair@corp.example.com'
            (@($global:DusRequests | ForEach-Object { $_.Path }) -join ',') | Should Be "/v1.0/users/$blairId"
        }

        It 'confirms a removal with GET even when the DELETE fails, and fails only when the assignment is still there' {
            Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $runId -AccessToken $tokens -DryRun $false
            Reset-DusCloud
            $global:DusCloud.DeleteStatus = 403
            Remove-TemporaryOwnerAssignment -SubscriptionId $subCandidate -AssignmentName 'already-gone'
            (@($global:DusRequests | ForEach-Object { $_.Method }) -join ',') | Should Be 'DELETE,GET'
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like '*already-gone*failed, but ARM reports it gone*' }).Count | Should Be 1

            $global:DusCloud.Created['still-there'] = @{ SubscriptionId = $subCandidate; Exists = $true }
            $caught = ''
            try { Remove-TemporaryOwnerAssignment -SubscriptionId $subCandidate -AssignmentName 'still-there' } catch { $caught = $_.Exception.Message }
            $caught | Should Match 'still-there on subscription 33333333-3333-3333-3333-333333333333, and it is still present'
            $caught | Should Match 'HTTP 403'
            $caught | Should Match 'Remove it by hand: DELETE /subscriptions/33333333-3333-3333-3333-333333333333/providers/Microsoft.Authorization/roleAssignments/still-there'
        }

        It 'reads the oid claim of a token' {
            Get-AccessTokenObjectId -AccessToken $armToken | Should Be $selfId
        }

        It 'refuses a token that is not a JWT without echoing it' {
            $caught = ''
            try { Get-AccessTokenObjectId -AccessToken 'opaque-secret-value-12345' } catch { $caught = $_.Exception.Message }
            $caught | Should Match 'not a JSON Web Token'
            $caught.Contains('opaque-secret-value-12345') | Should Be $false
        }

        It 'refuses a token without an oid claim' {
            $noOid = '{0}.{1}.sig' -f (ConvertTo-TestBase64Url -Text '{"alg":"none"}'), (ConvertTo-TestBase64Url -Text '{"aud":"x"}')
            { Get-AccessTokenObjectId -AccessToken $noOid } | Should Throw 'no oid claim'
        }

        It 'recognises only its own temporary assignment description' {
            Test-TemporaryElevation -Description 'Temporary elevation by Disable-UnauthorizedSubscriptions, run 1.' | Should Be $true
            Test-TemporaryElevation -Description 'Break glass owner' | Should Be $false
            Test-TemporaryElevation -Description '' | Should Be $false
        }

        It 'prefers mail and never mails a guest #EXT# name' {
            Get-UserMailAddress -User (New-TestUser -Id $alexId -Name 'A' -Upn 'alex@corp.example.com' -Mail 'alex.mail@corp.example.com') | Should Be 'alex.mail@corp.example.com'
            Get-UserMailAddress -User (New-TestUser -Id $alexId -Name 'A' -Upn 'alex@corp.example.com') | Should Be 'alex@corp.example.com'
            Get-UserMailAddress -User (New-TestUser -Id $alexId -Name 'G' -Upn 'guest_partner.example.net#EXT#@corp.example.com') | Should Be ''
        }

        It 'encodes subscription and owner names in the notice' {
            $d = [PSCustomObject]@{ SubscriptionId = $subCandidate; DisplayName = '<b>Trial</b>'; QuotaId = 'FreeTrial_2014-09-01' }
            $html = New-CancelNoticeHtml -Decision $d -OwnerNames @('Blair & Co') -ContactAddresses @('cloud-governance@corp.example.com') -RunId $runId -Now $now
            $html.Contains('&lt;b&gt;Trial&lt;/b&gt;') | Should Be $true
            $html.Contains('Blair &amp; Co') | Should Be $true
            $html.Contains('2026-12-16') | Should Be $true
            $html.Contains('was canceled') | Should Be $true
            $html.Contains('Azure support request within 90 days') | Should Be $true
            $html.Contains('enable') | Should Be $false
        }

        It 'marks the digest of a run that could not cancel, explains WouldCancel, and encodes the notes' {
            $rows = @([PSCustomObject]@{ SubscriptionId = $subCandidate; DisplayName = 'Trial Blair'; QuotaId = 'FreeTrial_2014-09-01'; Decision = 'WouldCancel'; Reason = 'AllowCancel is false; restricted offer' })
            $held = New-RunDigestHtml -Decisions $rows -DryRun $false -AllowCancel $false -Notes @('4 subscription(s) <over> the cap') -RunId $runId
            $held | Should Match '\(live; AllowCancel is false, so no Owner assignment was created and nothing was canceled\)'
            $held | Should Match 'WouldCancel rows meet the cancel rule'
            $held.Contains('<p>4 subscription(s) &lt;over&gt; the cap</p>') | Should Be $true
            $live = New-RunDigestHtml -Decisions @() -DryRun $false -AllowCancel $true -RunId $runId
            $live | Should Match '\(live\)'
            $live.Contains('WouldCancel') | Should Be $false
            New-RunDigestHtml -Decisions @() -DryRun $true -AllowCancel $true -RunId $runId | Should Match '\(dry run, nothing was changed\)'
        }

        It 'finds the MayHaveBeenApplied flag the library sets on a POST it did not repeat' {
            $flagged = New-Object System.InvalidOperationException('POST failed')
            $flagged.Data['MayHaveBeenApplied'] = $true
            Test-CancelMayHaveBeenApplied -ErrorRecord $flagged | Should Be $true
            $wrapped = New-Object System.Exception('outer', $flagged)
            Test-CancelMayHaveBeenApplied -ErrorRecord $wrapped | Should Be $true
            $clear = New-Object System.InvalidOperationException('POST failed with 409')
            $clear.Data['MayHaveBeenApplied'] = $false
            Test-CancelMayHaveBeenApplied -ErrorRecord $clear | Should Be $false
            Test-CancelMayHaveBeenApplied -ErrorRecord (New-Object System.Exception('plain')) | Should Be $false
            Test-CancelMayHaveBeenApplied -ErrorRecord $null | Should Be $false
        }
    }

    function Get-RunArgs {
        param([hashtable]$Change = @{})
        $copy = $runArgs.Clone()
        foreach ($key in $Change.Keys) { $copy[$key] = $Change[$key] }
        return $copy
    }

    Context 'run: what is left alone' {
        It 'skips a subscription whose owner is allowlisted by UPN, although Graph returns the id in upper case' {
            Set-StandardTenant -Only @($subAllowed)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowedCount | Should Be 1
            $summary.CandidateCount | Should Be 0
            @(Get-TestRequests -Method GET -PathLike '/v1.0/users').Count | Should Be 1
            (Get-TestWrites).Count | Should Be 0
        }

        It 'skips a subscription whose owner is a transitive member of an allowed group' {
            Set-StandardTenant -Only @($subGroupAllowed)
            $a = Get-RunArgs @{ DryRun = $false; AllowedOwnerUpns = '' }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowedCount | Should Be 1
            $summary.CandidateCount | Should Be 0
            @(Get-TestRequests -Method GET -PathLike "/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.user").Count | Should Be 1
            (Get-TestWrites).Count | Should Be 0
        }

        It 'never judges or writes to an excluded subscription, and lists a restricted one in the digest' {
            Set-StandardTenant -Only @($subExcluded)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.ExcludedCount | Should Be 1
            $summary.ExcludedRestrictedCount | Should Be 1
            $touched = @($global:DusRequests | Where-Object { $_.Path -like "*$subExcluded*" })
            $touched.Count | Should Be 1
            $touched[0].Method | Should Be 'GET'
            $touched[0].Query | Should Match "principalId eq '$selfId'"
            $writes = @(Get-TestWrites)
            ($writes | ForEach-Object { $_.Method + ' ' + $_.Path }) -join ',' | Should Be 'POST /v1.0/users/iam-noreply@corp.example.com/sendMail'
            $digest = ConvertFrom-Json -InputObject $writes[0].Body
            $digest.message.body.content | Should Match 'Lab Shared'
            $digest.message.body.content | Should Match 'by display name &quot;lab shared&quot;'
            @($summary.Reviewable)[0].Decision | Should Be 'Excluded'
        }

        It 'skips a subscription of an offer that is not restricted without reading its owners' {
            Set-StandardTenant -Only @($subCorporate)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.NotRestrictedCount | Should Be 1
            $touched = @($global:DusRequests | Where-Object { $_.Path -like "*$subCorporate*" })
            $touched.Count | Should Be 1
            $touched[0].Query | Should Match 'principalId eq'
            @(Get-TestRequests -Method GET -PathLike "/subscriptions/$subCorporate/providers/Microsoft.Authorization/roleDefinitions").Count | Should Be 0
            (Get-TestWrites).Count | Should Be 0
        }

        It 'does not cancel a co-owned allowed subscription, and lists it in the digest' {
            Set-StandardTenant -Only @($subAllowed)
            $global:DusCloud.Assignments[$subAllowed] = @(
                (New-TestAssignment -SubscriptionId $subAllowed -PrincipalId $alexId),
                (New-TestAssignment -SubscriptionId $subAllowed -PrincipalId $blairId)
            )
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowedCount | Should Be 1
            $summary.CoOwnedAllowedCount | Should Be 1
            $summary.CandidateCount | Should Be 0
            $writes = @(Get-TestWrites)
            $writes.Count | Should Be 1
            $writes[0].Path | Should Be '/v1.0/users/iam-noreply@corp.example.com/sendMail'
            (ConvertFrom-Json -InputObject $writes[0].Body).message.body.content | Should Match $blairId
        }

        It 'sends a subscription owned only by an allowlisted group to review, not to Allowed' {
            Set-StandardTenant -Only @($subGroupAllowed)
            $global:DusCloud.Assignments[$subGroupAllowed] = @((New-TestAssignment -SubscriptionId $subGroupAllowed -PrincipalId $groupId -PrincipalType 'Group'))
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowedCount | Should Be 0
            $summary.NeedsReviewCount | Should Be 1
            @(Get-TestWrites | Where-Object { $_.HostName -notlike 'graph.*' }).Count | Should Be 0
        }

        It 'stops before any write when an excluded name matches two subscriptions' {
            Set-StandardTenant -Only @($subExcluded, $subCandidate)
            # The owner of the candidate renames it to the excluded name.
            @($global:DusCloud.Subscriptions | Where-Object { $_.subscriptionId -eq $subCandidate })[0].displayName = 'LAB SHARED '
            $a = Get-RunArgs @{ DryRun = $false }
            { Invoke-DisableUnauthorizedSubscriptionsRun @a } | Should Throw 'ExcludedSubscriptionNames entry "lab shared" matches 2 subscriptions'
            (Get-TestWrites).Count | Should Be 0
        }

        It 'refuses a live run without Recipients before any request' {
            Set-StandardTenant
            $a = Get-RunArgs @{ DryRun = $false; Recipients = '' }
            { Invoke-DisableUnauthorizedSubscriptionsRun @a } | Should Throw 'Recipients is empty'
            $global:DusRequests.Count | Should Be 0
        }

        It 'reports a subscription with no human owner for review and never elevates on it' {
            Set-StandardTenant -Only @($subWorkload)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.NeedsReviewCount | Should Be 1
            $summary.CandidateCount | Should Be 0
            @(Get-TestWrites | Where-Object { $_.HostName -notlike 'graph.*' }).Count | Should Be 0
            $review = @(Get-TestItems -Summary $summary -Action 'ReviewSubscription')
            $review.Count | Should Be 1
            $review[0].Outcome | Should Be 'Skipped'
            (@($summary.Reviewable) | ForEach-Object { $_.SubscriptionId }) -join ',' | Should Be $subWorkload
            $summary.Warnings | Should BeGreaterThan 0
            @(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail').Count | Should Be 1
        }

        It 'makes no write in a dry run with AllowCancel and records every step as planned' {
            Set-StandardTenant
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @runArgs
            (Get-TestWrites).Count | Should Be 0
            $summary.DryRun | Should Be $true
            $summary.CandidateCount | Should Be 1
            $summary.CanceledCount | Should Be 0
            $summary.Counts.GrantTemporaryOwner.Planned | Should Be 1
            $summary.Counts.CancelSubscription.Planned | Should Be 1
            $summary.Counts.RemoveTemporaryOwner.Planned | Should Be 1
            $summary.Counts.NotifyOwners.Planned | Should Be 1
            $summary.Counts.SendDigest.Planned | Should Be 1
            $summary.Done | Should Be 0
            Assert-MockCalled Start-Sleep -Exactly 0 -Scope It
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Would cancel Trial Blair*' }).Count | Should Be 1
        }

        It 'sweeps only the descendants of a management group' {
            Set-StandardTenant
            $global:DusCloud.ManagementGroups = @([PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox'; name = 'mg-sandbox'; type = 'Microsoft.Management/managementGroups'; properties = [PSCustomObject]@{ displayName = 'Sandbox' } })
            $global:DusCloud.Descendants = @([PSCustomObject]@{ id = "/subscriptions/$subCandidate"; name = $subCandidate; type = 'Microsoft.Management/managementGroups/subscriptions'; properties = [PSCustomObject]@{ displayName = 'Trial Blair'; parent = [PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox' } } })
            $a = Get-RunArgs @{ ManagementGroupName = 'Sandbox' }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.SubscriptionsScanned | Should Be 1
            $summary.CandidateCount | Should Be 1
            @(Get-TestRequests -Method GET -PathLike "/subscriptions/$subAllowed/*").Count | Should Be 0
            @(Get-TestRequests -Method GET -PathLike '/providers/Microsoft.Management/managementGroups/mg-sandbox/providers/Microsoft.Authorization/roleAssignments').Count | Should Be 1
            (Get-TestWrites).Count | Should Be 0
        }
    }

    Context 'run: DryRun and AllowCancel' {
        # The standard tenant has one subscription that meets the cancel rule
        # (Trial Blair) and one to review (Workload Only). A leftover on the
        # Disabled subscription shows the non-destructive cleanup still runs.
        function Set-GateTenant {
            param([string]$Leftover)
            Set-StandardTenant
            $global:DusCloud.SelfAssignments = @((New-TestLeftover -SubscriptionId $subDisabled -Name $Leftover))
        }

        function Assert-NoElevation {
            param([object]$Summary)
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            @(Get-TestItems -Summary $Summary -Action 'GrantTemporaryOwner').Count | Should Be 0
            @(Get-TestItems -Summary $Summary -Action 'RemoveTemporaryOwner').Count | Should Be 0
            @(Get-TestItems -Summary $Summary -Action 'NotifyOwners').Count | Should Be 0
            # Owner contacts are read only for a notice.
            @(Get-TestRequests -Method GET -PathLike "/v1.0/users/$blairId").Count | Should Be 0
            $held = @(Get-TestItems -Summary $Summary -Action 'CancelSubscription')
            $held.Count | Should Be 1
            $held[0].Target | Should Be "Trial Blair ($subCandidate)"
            $held[0].Outcome | Should Be 'Skipped'
            $held[0].Detail | Should Be 'WouldCancel: AllowCancel is false'
            $Summary.AllowCancel | Should Be $false
            $Summary.CandidateCount | Should Be 1
            $Summary.WouldCancelCount | Should Be 1
            $Summary.CanceledCount | Should Be 0
            $would = @($Summary.Reviewable | Where-Object { $_.Decision -eq 'WouldCancel' })
            $would.Count | Should Be 1
            $would[0].SubscriptionId | Should Be $subCandidate
            $would[0].Reason | Should Match '^AllowCancel is false; restricted offer FreeTrial_2014-09-01 \(pattern FreeTrial_\*\); 1 human direct Owner\(s\), none allowlisted'
            @($Summary.Reviewable | Where-Object { $_.Decision -eq 'Candidate' }).Count | Should Be 0
        }

        It 'DryRun true, AllowCancel false: writes nothing, plans no grant or cancel, and reports WouldCancel' {
            Set-GateTenant -Leftover 'leftover-gate-a'
            $a = Get-RunArgs @{ AllowCancel = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            (Get-TestWrites).Count | Should Be 0
            $summary.DryRun | Should Be $true
            Assert-NoElevation -Summary $summary
            $summary.Counts.RemoveLeftoverOwner.Planned | Should Be 1
            $summary.Counts.SendDigest.Planned | Should Be 1
            $global:DusCloud.Created['leftover-gate-a'].Exists | Should Be $true
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Would grant*' -or $_.Message -like 'Would cancel*' }).Count | Should Be 0
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'WouldCancel Trial Blair*AllowCancel is false*' }).Count | Should Be 1
        }

        It 'DryRun true, AllowCancel true: writes nothing and plans the grant, the cancel, the removal, and the notice' {
            Set-GateTenant -Leftover 'leftover-gate-b'
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @runArgs
            (Get-TestWrites).Count | Should Be 0
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            $summary.DryRun | Should Be $true
            $summary.AllowCancel | Should Be $true
            $summary.WouldCancelCount | Should Be 0
            $summary.CanceledCount | Should Be 0
            foreach ($step in @('GrantTemporaryOwner', 'CancelSubscription', 'RemoveTemporaryOwner', 'NotifyOwners', 'SendDigest', 'RemoveLeftoverOwner')) {
                $summary.Counts.$step.Planned | Should Be 1
            }
            @($summary.Reviewable | Where-Object { $_.Decision -eq 'Candidate' }).Count | Should Be 1
            $global:DusCloud.Created['leftover-gate-b'].Exists | Should Be $true
        }

        It 'DryRun false, AllowCancel false: removes leftovers and sends the digest, but never elevates, cancels, or notifies owners' {
            Set-GateTenant -Leftover 'leftover-gate-c'
            $a = Get-RunArgs @{ DryRun = $false; AllowCancel = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.DryRun | Should Be $false
            Assert-NoElevation -Summary $summary
            $writes = @(Get-TestWrites)
            ($writes | ForEach-Object { $_.Method + ' ' + $_.Path }) -join ',' | Should Be ("DELETE /subscriptions/$subDisabled/providers/Microsoft.Authorization/roleAssignments/leftover-gate-c,POST /v1.0/users/iam-noreply@corp.example.com/sendMail")
            $global:DusCloud.Created['leftover-gate-c'].Exists | Should Be $false
            $global:DusCloud.Created.Count | Should Be 1
            $summary.Counts.RemoveLeftoverOwner.Done | Should Be 1
            $summary.Counts.SendDigest.Done | Should Be 1
            $digest = ConvertFrom-Json -InputObject $writes[1].Body
            $digest.message.subject | Should Be 'Unauthorized subscription guard (AllowCancel is false): 1 would be canceled, 1 to review, 0 failure(s)'
            (@($digest.message.toRecipients) | ForEach-Object { $_.emailAddress.address }) -join ',' | Should Be 'cloud-governance@corp.example.com'
            $digest.message.body.content | Should Match '<td>WouldCancel</td><td>AllowCancel is false; restricted offer'
            $digest.message.body.content | Should Match 'AllowCancel is false, so no Owner assignment was created and nothing was canceled'
            Get-DisableRunFailureMessage -Summary $summary | Should Be ''
        }

        It 'DryRun false, AllowCancel true: grants, cancels, removes, and notifies' {
            Set-GateTenant -Leftover 'leftover-gate-d'
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowCancel | Should Be $true
            @(Get-TestRequests -Method PUT -PathLike "/subscriptions/$subCandidate/providers/Microsoft.Authorization/roleAssignments/*").Count | Should Be 1
            @(Get-TestRequests -Method POST -PathLike "/subscriptions/$subCandidate/providers/Microsoft.Subscription/cancel").Count | Should Be 1
            $summary.CandidateCount | Should Be 1
            $summary.WouldCancelCount | Should Be 0
            $summary.CanceledCount | Should Be 1
            $summary.Counts.NotifyOwners.Done | Should Be 1
            $summary.Counts.RemoveLeftoverOwner.Done | Should Be 1
            $digest = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1).Body
            $digest.message.subject | Should Be 'Unauthorized subscription guard: 1 candidate(s), 1 canceled, 1 to review, 0 failure(s)'
            $digest.message.body.content | Should Not Match 'WouldCancel'
        }

        It 'defaults AllowCancel to false when the run function is called without it' {
            Set-StandardTenant -Only @($subCandidate)
            $a = Get-RunArgs @{ DryRun = $false }
            $a.Remove('AllowCancel')
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.AllowCancel | Should Be $false
            $summary.WouldCancelCount | Should Be 1
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
        }

        It 'refuses to elevate when the elevation step is called with AllowCancel false' {
            Initialize-RunContext -RunbookName 'Disable-UnauthorizedSubscriptions' -RunId $runId -AccessToken $tokens -DryRun $false
            Reset-DusCloud
            $held = New-RunSummary -DryRun $false
            $d = [PSCustomObject]@{ SubscriptionId = $subCandidate; DisplayName = 'Trial Blair'; QuotaId = 'FreeTrial_2014-09-01' }
            { Invoke-JitSubscriptionCancel -AllowCancel $false -Summary $held -Decision $d -PrincipalId $selfId -OwnerRoleId $ownerRoleId -PropagationSeconds 0 } | Should Throw 'AllowCancel is false'
            $global:DusRequests.Count | Should Be 0
            $held.Items.Count | Should Be 0
        }

        It 'warns instead of stopping when more subscriptions than the cap meet the rule while AllowCancel is false, live or dry' {
            Set-StandardTenant -Only @($subAllowed, $subCandidate, $subGroupAllowed, $subWorkload)
            foreach ($id in @($subAllowed, $subGroupAllowed, $subWorkload)) {
                $global:DusCloud.Assignments[$id] = @((New-TestAssignment -SubscriptionId $id -PrincipalId $blairId))
            }
            $global:DusCloud.Assignments[$subCandidate] = @($global:DusCloud.Assignments[$subCandidate]) + @((New-TestLeftover -SubscriptionId $subCandidate -Name 'leftover-over-cap'))
            $a = Get-RunArgs @{ DryRun = $false; AllowCancel = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.BreakerWouldTrip | Should Be $true
            $summary.CandidateCount | Should Be 4
            $summary.WouldCancelCount | Should Be 4
            $summary.Counts.CancelSubscription.Skipped | Should Be 4
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            $global:DusCloud.Created['leftover-over-cap'].Exists | Should Be $false
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '4 subscription(s) meet the cancel rule, more than MaxDisablesPerRun (3). AllowCancel is false*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Error).Count | Should Be 0
            $digest = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1).Body
            $digest.message.subject | Should Match '4 would be canceled'
            $digest.message.body.content | Should Match 'with AllowCancel true the circuit breaker would stop the run before any grant or cancel'

            $global:DusRequests.Clear()
            $dry = Get-RunArgs @{ AllowCancel = $false }
            $drySummary = Invoke-DisableUnauthorizedSubscriptionsRun @dry
            $drySummary.BreakerWouldTrip | Should Be $true
            (Get-TestWrites).Count | Should Be 0
        }

        It 'keeps BreakerWouldTrip false at the cap' {
            Set-StandardTenant -Only @($subCandidate)
            $a = Get-RunArgs @{ DryRun = $false; AllowCancel = $false; MaxDisablesPerRun = 1 }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.BreakerWouldTrip | Should Be $false
            $summary.WouldCancelCount | Should Be 1
        }
    }

    Context 'run: lists and Azure PIM eligibility' {
        It 'reads every list as a semicolon list, and as a JSON array in a local run' {
            $forms = @(
                @{
                    RestrictedQuotaIdPatterns = 'MSDN_*; FreeTrial_*'
                    AllowedOwnerUpns          = 'alex@corp.example.com; blair@corp.example.com'
                    AllowedOwnerGroupNames    = 'SEC Subscription Owners;SEC Platform Owners'
                    ExcludedSubscriptionNames = "$subExcluded;$subCorporate"
                    Recipients                = 'cloud-governance@corp.example.com;iam-team@corp.example.com'
                },
                @{
                    RestrictedQuotaIdPatterns = '["MSDN_*","FreeTrial_*"]'
                    AllowedOwnerUpns          = '["alex@corp.example.com","blair@corp.example.com"]'
                    AllowedOwnerGroupNames    = '["SEC Subscription Owners","SEC Platform Owners"]'
                    ExcludedSubscriptionNames = ('["{0}","{1}"]' -f $subExcluded, $subCorporate)
                    Recipients                = '["cloud-governance@corp.example.com","iam-team@corp.example.com"]'
                }
            )
            foreach ($form in $forms) {
                Set-StandardTenant
                $cloud = $global:DusCloud
                $cloud.UpnIndex['blair@corp.example.com'] = @((New-TestUser -Id $blairId -Name 'Blair Example' -Upn 'blair@corp.example.com'))
                $cloud.Groups['SEC Platform Owners'] = @([PSCustomObject]@{ id = $workloadId; displayName = 'SEC Platform Owners' })
                $form.DryRun = $false
                $a = Get-RunArgs $form
                $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
                # Blair is allowlisted now; pay-as-you-go is no longer restricted.
                $summary.CandidateCount | Should Be 0
                $summary.AllowedCount | Should Be 2
                $summary.NotRestrictedCount | Should Be 1
                $summary.ExcludedCount | Should Be 2
                $summary.NeedsReviewCount | Should Be 1
                @(Get-TestRequests -Method GET -PathLike "/v1.0/groups/$workloadId/transitiveMembers/microsoft.graph.user").Count | Should Be 1
                @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'Settings:*Patterns=MSDN_*;FreeTrial_* AllowedUpns=2 AllowedGroups=2 Excluded=2 *Recipients=2 *' }).Count | Should Be 1
                $digest = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1).Body
                (@($digest.message.toRecipients) | ForEach-Object { $_.emailAddress.address }) -join ',' | Should Be 'cloud-governance@corp.example.com,iam-team@corp.example.com'
                @(Get-TestWrites | Where-Object { $_.HostName -notlike 'graph.*' }).Count | Should Be 0
            }
        }

        It 'does not cancel a subscription whose allowlisted owner is only eligible, and reads eligibility only for would-be candidates' {
            Set-StandardTenant
            $global:DusCloud.Eligibility[$subCandidate] = @((New-TestEligibility -SubscriptionId $subCandidate -PrincipalId $alexId))
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.CandidateCount | Should Be 0
            $summary.AllowedCount | Should Be 3
            $summary.EligibleAllowedCount | Should Be 1
            $summary.CoOwnedAllowedCount | Should Be 1
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            $reads = @(Get-TestRequests -Method GET -PathLike '*/providers/Microsoft.Authorization/roleEligibilityScheduleInstances')
            $reads.Count | Should Be 1
            $reads[0].Path | Should Be "/subscriptions/$subCandidate/providers/Microsoft.Authorization/roleEligibilityScheduleInstances"
            $reads[0].Query | Should Match 'filter=atScope\(\)'
            $reads[0].Query | Should Match 'api-version=2020-10-01'
            $row = @($summary.Reviewable | Where-Object { $_.SubscriptionId -eq $subCandidate })[0]
            $row.Decision | Should Be 'Allowed'
            $row.Reason | Should Match 'eligible \(Azure PIM\)'
            $digest = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1).Body
            $digest.message.body.content | Should Match $blairId
        }

        It 'sends a would-be candidate to review when its eligibility cannot be read, and never elevates on it' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.EligibilityFailScopes = @($subCandidate)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.CandidateCount | Should Be 0
            $summary.NeedsReviewCount | Should Be 1
            (Get-TestItems -Summary $summary -Action 'ReviewSubscription')[0].Detail | Should Match 'could not be read: .*HTTP 403'
            @(Get-TestWrites | Where-Object { $_.HostName -notlike 'graph.*' }).Count | Should Be 0
        }
    }

    Context 'run: circuit breaker and identity guard' {
        It 'aborts before any write when the candidates exceed the cap, live or dry' {
            Set-StandardTenant -Only @($subAllowed, $subCandidate, $subGroupAllowed, $subWorkload)
            foreach ($id in @($subAllowed, $subGroupAllowed, $subWorkload)) {
                $global:DusCloud.Assignments[$id] = @((New-TestAssignment -SubscriptionId $id -PrincipalId $blairId))
            }
            $a = Get-RunArgs @{ DryRun = $false }
            { Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null } | Should Throw 'Circuit breaker tripped: subscription cancels: 4 planned, cap is 3. Nothing was changed.'
            (Get-TestWrites).Count | Should Be 0
            { Invoke-DisableUnauthorizedSubscriptionsRun @runArgs 2>$null } | Should Throw 'Circuit breaker tripped'
            (Get-TestWrites).Count | Should Be 0
        }

        It 'passes the breaker when the candidates equal the cap' {
            Set-StandardTenant -Only @($subCandidate)
            $a = Get-RunArgs @{ MaxDisablesPerRun = 1 }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.CandidateCount | Should Be 1
        }

        function Set-BreakerTenant {
            Set-StandardTenant -Only @($subAllowed, $subCandidate, $subGroupAllowed, $subWorkload)
            foreach ($id in @($subAllowed, $subGroupAllowed, $subWorkload)) {
                $global:DusCloud.Assignments[$id] = @((New-TestAssignment -SubscriptionId $id -PrincipalId $blairId))
            }
            $global:DusCloud.Assignments[$subCandidate] = @($global:DusCloud.Assignments[$subCandidate]) + @((New-TestLeftover -SubscriptionId $subCandidate -Name 'leftover-before-breaker'))
        }

        It 'removes a leftover before the breaker trips, and names it in the breaker error' {
            Set-BreakerTenant
            $a = Get-RunArgs @{ DryRun = $false }
            $caught = ''
            try { Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null | Out-Null } catch { $caught = $_.Exception.Message }
            $caught | Should Match 'Circuit breaker tripped: subscription cancels: 4 planned, cap is 3\.'
            $caught | Should Match 'it removed 1 leftover temporary Owner assignment\(s\) of this identity \(leftover-before-breaker\)'
            $writes = @(Get-TestWrites)
            ($writes | ForEach-Object { $_.Method + ' ' + $_.Path }) -join ',' | Should Be "DELETE /subscriptions/$subCandidate/providers/Microsoft.Authorization/roleAssignments/leftover-before-breaker"
            $global:DusCloud.Created['leftover-before-breaker'].Exists | Should Be $false
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like '*Circuit breaker tripped*leftover-before-breaker*' }).Count | Should Be 1
        }

        It 'names a leftover in a dry-run breaker error without removing it' {
            Set-BreakerTenant
            $caught = ''
            try { Invoke-DisableUnauthorizedSubscriptionsRun @runArgs 2>$null | Out-Null } catch { $caught = $_.Exception.Message }
            $caught | Should Match 'it would remove 1 leftover temporary Owner assignment\(s\) of this identity \(leftover-before-breaker\)'
            (Get-TestWrites).Count | Should Be 0
            $global:DusCloud.Created['leftover-before-breaker'].Exists | Should Be $true
        }

        It 'names a leftover it could not remove in the breaker error' {
            Set-BreakerTenant
            $global:DusCloud.DeleteStatus = 403
            $a = Get-RunArgs @{ DryRun = $false }
            $caught = ''
            try { Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null | Out-Null } catch { $caught = $_.Exception.Message }
            $caught | Should Match 'Circuit breaker tripped'
            $caught | Should Match ('could NOT confirm the removal of 1 leftover\(s\).*subscription {0} assignment leftover-before-breaker' -f $subCandidate)
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
        }

        It 'stops a live run before any write when the configured principal id is not the token oid' {
            Set-StandardTenant
            $a = Get-RunArgs @{ DryRun = $false; IdentityPrincipalId = $workloadId }
            { Invoke-DisableUnauthorizedSubscriptionsRun @a } | Should Throw 'does not match the oid'
            (Get-TestWrites).Count | Should Be 0
        }

        It 'stops a live run when the acting principal cannot be determined' {
            Set-StandardTenant
            $a = Get-RunArgs @{ DryRun = $false; AccessToken = @{ Graph = $graphToken; Arm = 'opaque-arm-token-0000000' } }
            { Invoke-DisableUnauthorizedSubscriptionsRun @a } | Should Throw 'not a JSON Web Token'
            (Get-TestWrites).Count | Should Be 0
        }
    }

    Context 'run: just-in-time elevation' {
        It 'grants, cancels, removes and verifies, then notifies, when live with AllowCancel' {
            Set-StandardTenant
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.CandidateCount | Should Be 1
            $summary.AllowedCount | Should Be 2
            $summary.NeedsReviewCount | Should Be 1
            $summary.ExcludedCount | Should Be 1
            $summary.NotRestrictedCount | Should Be 1
            $summary.NotEnabledCount | Should Be 1
            $summary.CanceledCount | Should Be 1
            $summary.CleanupFailureCount | Should Be 0
            $summary.IdentityPrincipalId | Should Be $selfId
            $summary.Failed | Should Be 0

            $writes = @(Get-TestWrites)
            ($writes | ForEach-Object { $_.Method }) -join ',' | Should Be 'PUT,POST,DELETE,POST,POST'
            $assignmentPath = $writes[0].Path
            $assignmentPath | Should Match ('^/subscriptions/{0}/providers/Microsoft\.Authorization/roleAssignments/[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}}$' -f $subCandidate)
            $writes[0].Query | Should Match 'api-version=2022-04-01'
            $writes[1].Path | Should Be "/subscriptions/$subCandidate/providers/Microsoft.Subscription/cancel"
            $writes[1].Query | Should Match 'api-version=2021-10-01'
            $writes[2].Path | Should Be $assignmentPath

            $grant = ConvertFrom-Json -InputObject $writes[0].Body
            $grant.properties.principalId | Should Be $selfId
            $grant.properties.principalType | Should Be 'ServicePrincipal'
            $grant.properties.roleDefinitionId | Should Be "/subscriptions/$subCandidate/providers/Microsoft.Authorization/roleDefinitions/$ownerRoleId"
            $grant.properties.description | Should Match "^Temporary elevation by Disable-UnauthorizedSubscriptions, run $runId"

            $order = @($global:DusRequests | ForEach-Object { $_.Method + ' ' + $_.Path })
            $deleteAt = [Array]::IndexOf($order, 'DELETE ' + $assignmentPath)
            $verifyAt = [Array]::LastIndexOf($order, 'GET ' + $assignmentPath)
            ($verifyAt -gt $deleteAt) | Should Be $true
            $global:DusCloud.Created.Count | Should Be 1
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0

            $notice = ConvertFrom-Json -InputObject $writes[3].Body
            $notice.message.toRecipients[0].emailAddress.address | Should Be 'blair@corp.example.com'
            $notice.message.ccRecipients[0].emailAddress.address | Should Be 'cloud-governance@corp.example.com'
            $notice.saveToSentItems | Should Be $false
            $digest = ConvertFrom-Json -InputObject $writes[4].Body
            $digest.message.toRecipients[0].emailAddress.address | Should Be 'cloud-governance@corp.example.com'

            @($writes | Where-Object { $_.Path -like '/subscriptions/*' -and $_.Path -notlike "/subscriptions/$subCandidate/*" }).Count | Should Be 0
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 7 }
            foreach ($step in @('GrantTemporaryOwner', 'CancelSubscription', 'RemoveTemporaryOwner', 'NotifyOwners', 'SendDigest')) {
                $summary.Counts.$step.Done | Should Be 1
            }
        }

        It 'retries the cancel call while ARM answers 403 during propagation, then succeeds' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.CancelQueue.Enqueue(403)
            $global:DusCloud.CancelQueue.Enqueue(403)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 3
            $summary.CanceledCount | Should Be 1
            $summary.Counts.CancelSubscription.Done | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 2 -Scope It -ParameterFilter { $Seconds -eq 7 }
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 14 }
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*while the temporary Owner assignment propagates*' }).Count | Should Be 2
            @(Get-TestRequests -Method DELETE -PathLike '*/roleAssignments/*').Count | Should Be 1
        }

        It 'gives up after MaxDisableAttempts answers of 403 and still removes the assignment' {
            Set-StandardTenant -Only @($subCandidate)
            for ($i = 0; $i -lt 5; $i++) { $global:DusCloud.CancelQueue.Enqueue(403) }
            $a = Get-RunArgs @{ DryRun = $false; MaxDisableAttempts = 3 }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 3
            $summary.CanceledCount | Should Be 0
            (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Outcome | Should Be 'Failed'
            (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0].Outcome | Should Be 'Done'
            @(Get-TestRequests -Method DELETE -PathLike '*/roleAssignments/*').Count | Should Be 1
            @(Get-TestItems -Summary $summary -Action 'NotifyOwners').Count | Should Be 0
        }

        It 'does not repeat the cancel after a server error, and counts it when the subscription now reports Disabled' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.CancelQueue.Enqueue(503)
            $global:DusCloud.StateOverrides[$subCandidate] = 'Disabled'
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 1
            $cancel = (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0]
            $cancel.Outcome | Should Be 'Failed'
            $cancel.Detail | Should Match 'HTTP 503'
            $cancel.Detail | Should Match 'POST is not repeated automatically after a server error or a lost response because it may already have been applied'
            @(Get-TestRequests -Method GET -PathLike "/subscriptions/$subCandidate").Count | Should Be 1
            $check = (Get-TestItems -Summary $summary -Action 'CheckCancelState')[0]
            $check.Outcome | Should Be 'Done'
            $check.Detail | Should Match 'now reports state Disabled, so it is counted as canceled'
            $summary.CanceledCount | Should Be 1
            @($summary.UncertainCancels).Count | Should Be 1
            @($summary.UncertainCancels)[0].State | Should Be 'Disabled'
            @($summary.UncertainCancels)[0].CountedAsCanceled | Should Be $true
            (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0].Outcome | Should Be 'Done'
            $summary.Counts.NotifyOwners.Done | Should Be 1
            $digest = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1).Body
            $digest.message.body.content | Should Match 'ended without a clear answer'
        }

        It 'reports a cancel without a clear answer as uncertain while the subscription still reports Enabled, after a lost response too' {
            foreach ($answer in @(502, 0)) {
                Set-StandardTenant -Only @($subCandidate)
                $global:DusCloud.CancelQueue.Enqueue($answer)
                $a = Get-RunArgs @{ DryRun = $false }
                $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
                @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 1
                (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Detail | Should Match 'may already have been applied'
                $check = (Get-TestItems -Summary $summary -Action 'CheckCancelState')[0]
                $check.Outcome | Should Be 'Skipped'
                $check.Detail | Should Match 'still reports state Enabled; the cancel may still take effect'
                $summary.CanceledCount | Should Be 0
                @($summary.UncertainCancels)[0].CountedAsCanceled | Should Be $false
                @(Get-TestItems -Summary $summary -Action 'NotifyOwners').Count | Should Be 0
                @(Get-TestRequests -Method DELETE -PathLike '*/roleAssignments/*').Count | Should Be 1
                @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*ended without a clear answer*still reports state Enabled*' }).Count | Should Be 1
            }
        }

        It 'repeats the cancel after 429 and reads no state when it then succeeds' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.CancelQueue.Enqueue(429)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 2
            $summary.CanceledCount | Should Be 1
            @(Get-TestItems -Summary $summary -Action 'CheckCancelState').Count | Should Be 0
            @($summary.UncertainCancels).Count | Should Be 0
            @(Get-TestRequests -Method GET -PathLike "/subscriptions/$subCandidate").Count | Should Be 0
        }

        It 'removes the temporary assignment when the cancel call fails' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.CancelQueue.Enqueue(409)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            $summary.CanceledCount | Should Be 0
            (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Outcome | Should Be 'Failed'
            (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Detail | Should Match 'HTTP 409'
            (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0].Outcome | Should Be 'Done'
            @(Get-TestRequests -Method DELETE -PathLike "/subscriptions/$subCandidate/providers/Microsoft.Authorization/roleAssignments/*").Count | Should Be 1
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0
            @(Get-TestItems -Summary $summary -Action 'NotifyOwners').Count | Should Be 0
            $summary.FailureCount | Should Be 1
        }

        It 'checks without deleting, and never cancels, when the grant is refused' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.PutStatus = 403
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            @(Get-TestRequests -Method DELETE -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method GET -PathLike "/subscriptions/$subCandidate/providers/Microsoft.Authorization/roleAssignments/*").Count | Should Be 1
            (Get-TestItems -Summary $summary -Action 'GrantTemporaryOwner')[0].Outcome | Should Be 'Failed'
            (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Outcome | Should Be 'Skipped'
            (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0].Outcome | Should Be 'Done'
            $summary.CanceledCount | Should Be 0
        }

        It 'reports a failed cleanup as an error and stops elevating for the rest of the run' {
            Set-StandardTenant -Only @($subAllowed, $subCandidate)
            $global:DusCloud.Assignments[$subAllowed] = @((New-TestAssignment -SubscriptionId $subAllowed -PrincipalId $blairId))
            $global:DusCloud.DeleteStatus = 403
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            $summary.CandidateCount | Should Be 2
            $summary.CleanupFailureCount | Should Be 1
            @(Get-TestRequests -Method PUT -PathLike '*/roleAssignments/*').Count | Should Be 1
            @(Get-TestRequests -Method PUT -PathLike "/subscriptions/$subAllowed/*").Count | Should Be 1
            $removal = @(Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')
            $removal.Count | Should Be 1
            $removal[0].Outcome | Should Be 'Failed'
            $removal[0].Detail | Should Match 'HTTP 403'
            $cancels = @(Get-TestItems -Summary $summary -Action 'CancelSubscription')
            ($cancels | ForEach-Object { $_.Outcome }) -join ',' | Should Be 'Done,Skipped'
            @($summary.Failures | Where-Object { $_.Action -eq 'RemoveTemporaryOwner' }).Count | Should Be 1
            $summary.Errors | Should BeGreaterThan 1
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like '*could not be confirmed removed*' }).Count | Should Be 1
            $lastMail = @(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1
            $lastMail.Body | Should Match 'RemoveTemporaryOwner'
        }

        It 'reports a removal that ARM accepts but that does not take effect' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.KeepAfterDelete = $true
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            @(Get-TestRequests -Method DELETE -PathLike '*/roleAssignments/*').Count | Should Be 3
            $removal = (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0]
            $removal.Outcome | Should Be 'Failed'
            $removal.Detail | Should Match 'still exists after 3 check'
            $summary.CleanupFailureCount | Should Be 1
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 2 }
            Assert-MockCalled Start-Sleep -Exactly 1 -Scope It -ParameterFilter { $Seconds -eq 4 }
        }

        It 'removes a leftover temporary assignment from an interrupted run, and only that one' {
            Set-StandardTenant -Only @($subDisabled)
            $leftoverName = '77777777-7777-7777-7777-777777777777'
            $global:DusCloud.SelfAssignments = @(
                (New-TestAssignment -SubscriptionId $subDisabled -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Name $leftoverName -Description ('Temporary elevation by Disable-UnauthorizedSubscriptions, run {0}. Removed by the same run.' -f $runId)),
                (New-TestAssignment -SubscriptionId $subDisabled -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Name 'granted-by-hand' -Description 'Break glass')
            )
            $global:DusCloud.Created[$leftoverName] = @{ SubscriptionId = $subDisabled; Exists = $true }
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.LeftoverCount | Should Be 1
            $summary.Counts.RemoveLeftoverOwner.Done | Should Be 1
            $deletes = @(Get-TestRequests -Method DELETE -PathLike '*')
            $deletes.Count | Should Be 1
            $deletes[0].Path | Should Be "/subscriptions/$subDisabled/providers/Microsoft.Authorization/roleAssignments/$leftoverName"
            $global:DusCloud.Created[$leftoverName].Exists | Should Be $false
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*granted-by-hand*did not create*' }).Count | Should Be 1
        }

        It 'finds leftovers on Enabled subscriptions that were Excluded or NotRestricted, without a management group' {
            Set-StandardTenant -Only @($subExcluded, $subCorporate)
            $global:DusCloud.SelfAssignments = @(
                (New-TestLeftover -SubscriptionId $subExcluded -Name 'leftover-excluded'),
                (New-TestLeftover -SubscriptionId $subCorporate -Name 'leftover-corporate')
            )
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.LeftoverCount | Should Be 2
            $summary.Counts.RemoveLeftoverOwner.Done | Should Be 2
            $summary.CleanupFailureCount | Should Be 0
            (@(Get-TestRequests -Method DELETE -PathLike '*') | ForEach-Object { $_.Path } | Sort-Object) -join ',' | Should Be ((@(
                        "/subscriptions/$subCorporate/providers/Microsoft.Authorization/roleAssignments/leftover-corporate",
                        "/subscriptions/$subExcluded/providers/Microsoft.Authorization/roleAssignments/leftover-excluded"
                    ) | Sort-Object) -join ',')
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0
        }

        It 'finds a leftover on a restricted subscription whose owners could not be read' {
            Set-StandardTenant -Only @($subCandidate)
            # The atScope read fails with 400; the principalId read still works.
            $global:DusCloud.OwnerReadFailScopes = @($subCandidate)
            $global:DusCloud.SelfAssignments = @((New-TestLeftover -SubscriptionId $subCandidate -Name 'leftover-unread'))
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            $summary.NeedsReviewCount | Should Be 1
            $summary.LeftoverCount | Should Be 1
            $global:DusCloud.Created['leftover-unread'].Exists | Should Be $false
        }

        It 'leaves a temporary assignment younger than the elevation window alone, and removes an older one' {
            Set-StandardTenant -Only @($subDisabled)
            $global:DusCloud.SelfAssignments = @(
                (New-TestLeftover -SubscriptionId $subDisabled -Name 'leftover-young' -CreatedOn $now.AddMinutes(-5).ToString('o')),
                (New-TestLeftover -SubscriptionId $subDisabled -Name 'leftover-old' -CreatedOn $now.AddHours(-2).ToString('o'))
            )
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $summary.LeftoverCount | Should Be 2
            $summary.LeftoverSkippedCount | Should Be 1
            $summary.Counts.RemoveLeftoverOwner.Skipped | Should Be 1
            $summary.Counts.RemoveLeftoverOwner.Done | Should Be 1
            (@(Get-TestRequests -Method DELETE -PathLike '*') | ForEach-Object { $_.Path }) -join ',' | Should Be "/subscriptions/$subDisabled/providers/Microsoft.Authorization/roleAssignments/leftover-old"
            $global:DusCloud.Created['leftover-young'].Exists | Should Be $true
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*leftover-young*less than 32 minutes ago*' }).Count | Should Be 1
            Get-DisableRunFailureMessage -Summary $summary | Should Be ''
        }

        It 'records a failed look-up for leftovers as a failure the job reports' {
            Set-StandardTenant -Only @($subDisabled, $subCorporate)
            $global:DusCloud.LookupFailScopes = @($subDisabled)
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            $summary.LeftoverLookupFailureCount | Should Be 1
            @($summary.LeftoverLookupFailures)[0].Scope | Should Be "/subscriptions/$subDisabled"
            (Get-TestItems -Summary $summary -Action 'FindLeftoverOwner')[0].Outcome | Should Be 'Failed'
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like "*Could not look for leftover*$subDisabled*" }).Count | Should Be 1
            Get-DisableRunFailureMessage -Summary $summary | Should Match "could not be looked for at 1 scope\(s\): /subscriptions/$subDisabled"
            $lastMail = @(Get-TestRequests -Method POST -PathLike '/v1.0/users/*/sendMail') | Select-Object -Last 1
            $lastMail.Body | Should Match 'FindLeftoverOwner'
        }

        It 'looks for leftovers once at the management group and fails the job when it cannot' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.ManagementGroups = @([PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox'; name = 'mg-sandbox'; type = 'Microsoft.Management/managementGroups'; properties = [PSCustomObject]@{ displayName = 'Sandbox' } })
            $global:DusCloud.Descendants = @([PSCustomObject]@{ id = "/subscriptions/$subCandidate"; name = $subCandidate; type = 'Microsoft.Management/managementGroups/subscriptions'; properties = [PSCustomObject]@{ displayName = 'Trial Blair'; parent = [PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox' } } })
            $global:DusCloud.LookupFailScopes = @('mg-sandbox')
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @runArgs -ManagementGroupName 'Sandbox' 2>$null
            $summary.LeftoverLookupFailureCount | Should Be 1
            @($summary.LeftoverLookupFailures)[0].Scope | Should Be '/providers/Microsoft.Management/managementGroups/mg-sandbox'
            @($global:DusRequests | Where-Object { $_.Query -match 'principalId eq' }).Count | Should Be 1
        }

        It 'reports, and never removes, an Owner assignment of itself above a subscription' {
            Set-StandardTenant -Only @($subDisabled)
            $global:DusCloud.ManagementGroups = @([PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox'; name = 'mg-sandbox'; type = 'Microsoft.Management/managementGroups'; properties = [PSCustomObject]@{ displayName = 'Sandbox' } })
            $global:DusCloud.Descendants = @([PSCustomObject]@{ id = "/subscriptions/$subDisabled"; name = $subDisabled; type = 'Microsoft.Management/managementGroups/subscriptions'; properties = [PSCustomObject]@{ displayName = 'Old Trial'; parent = [PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-sandbox' } } })
            $mgScope = '/providers/Microsoft.Management/managementGroups/mg-sandbox'
            $groupScope = "/subscriptions/$subDisabled/resourceGroups/rg-example"
            $global:DusCloud.SelfAssignments = @(
                # Self-granted at the management group, with this runbook's own
                # description on it: still never removed, because the runbook
                # only ever creates subscription-scoped assignments.
                (New-TestAssignment -SubscriptionId $subDisabled -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Scope $mgScope -Name 'self-at-mg' -Description ('Temporary elevation by Disable-UnauthorizedSubscriptions, run {0}. Removed by the same run.' -f $runId)),
                (New-TestAssignment -SubscriptionId $subDisabled -PrincipalId $selfId -PrincipalType 'ServicePrincipal' -Scope $groupScope -Name 'self-at-rg' -Description 'Break glass'),
                (New-TestLeftover -SubscriptionId $subDisabled -Name 'leftover-real')
            )
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a -ManagementGroupName 'Sandbox' 2>$null

            $summary.OffScopeOwnerCount | Should Be 2
            (@($summary.OffScopeOwnerAssignments | ForEach-Object { $_.Name } | Sort-Object) -join ',') | Should Be 'self-at-mg,self-at-rg'
            (@($summary.OffScopeOwnerAssignments | Where-Object { $_.Name -eq 'self-at-mg' })[0].Scope) | Should Be $mgScope
            $summary.Counts.ReviewOwnerAssignment.Failed | Should Be 2
            @($summary.Failures | Where-Object { $_.Action -eq 'ReviewOwnerAssignment' }).Count | Should Be 2
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*self-at-mg*is not a single subscription*' -or $_.Message -like "*self-at-mg*$mgScope*" }).Count | Should BeGreaterThan 0

            # Only the subscription-scoped leftover is deleted.
            $deletes = @(Get-TestRequests -Method DELETE -PathLike '*')
            $deletes.Count | Should Be 1
            $deletes[0].Path | Should Be "/subscriptions/$subDisabled/providers/Microsoft.Authorization/roleAssignments/leftover-real"
            $summary.LeftoverCount | Should Be 1
        }

        It 'never writes an access token to the log or the summary' {
            Set-StandardTenant
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a
            $logText = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
            $summaryText = ConvertTo-Json -InputObject $summary -Depth 10
            foreach ($secret in @($graphToken, $armToken, 'testsignature0000')) {
                $logText.Contains($secret) | Should Be $false
                $summaryText.Contains($secret) | Should Be $false
            }
        }
    }

    # Pester 3.4 scopes a Mock made inside an It to the enclosing Context, so
    # each of these tests has a Context of its own.
    Context 'run: failure recorded inside the cancel step' {
        It 'records the failure and removes the temporary assignment when the cancel step throws' {
            Set-StandardTenant -Only @($subCandidate)
            Mock Invoke-SubscriptionCancel { throw 'simulated crash inside the cancel step' }
            $a = Get-RunArgs @{ DryRun = $false }
            $summary = Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null
            (Get-TestItems -Summary $summary -Action 'CancelSubscription')[0].Detail | Should Match 'simulated crash'
            (Get-TestItems -Summary $summary -Action 'RemoveTemporaryOwner')[0].Outcome | Should Be 'Done'
            @(Get-TestRequests -Method DELETE -PathLike '*/roleAssignments/*').Count | Should Be 1
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0
        }
    }

    # Invoke-RunbookAction catches whatever its block throws, so the test above
    # never leaves the try in Invoke-JitSubscriptionDisable. Here the wrapper
    # itself throws for the cancel step only (calls that do not match the
    # filter still reach the real function), so the exception escapes the try
    # and only the finally block can remove the assignment.
    Context 'run: exception escaping the cancel step' {
        It 'still deletes and verifies the temporary assignment, then lets the exception out' {
            Set-StandardTenant -Only @($subCandidate)
            Mock Invoke-RunbookAction -ParameterFilter { $Action -eq 'CancelSubscription' } { throw 'escaped' }
            $a = Get-RunArgs @{ DryRun = $false }
            $caught = ''
            try { Invoke-DisableUnauthorizedSubscriptionsRun @a 2>$null | Out-Null } catch { $caught = $_.Exception.Message }
            $caught | Should Be 'escaped'
            Assert-MockCalled Invoke-RunbookAction -Exactly 1 -Scope It -ParameterFilter { $Action -eq 'CancelSubscription' }
            $puts = @(Get-TestRequests -Method PUT -PathLike '*/roleAssignments/*')
            $puts.Count | Should Be 1
            $assignmentPath = $puts[0].Path
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            $deletes = @(Get-TestRequests -Method DELETE -PathLike '*')
            $deletes.Count | Should Be 1
            $deletes[0].Path | Should Be $assignmentPath
            $order = @($global:DusRequests | ForEach-Object { $_.Method + ' ' + $_.Path })
            $deleteAt = [Array]::IndexOf($order, 'DELETE ' + $assignmentPath)
            $verifyAt = [Array]::LastIndexOf($order, 'GET ' + $assignmentPath)
            ($deleteAt -gt 0) | Should Be $true
            ($verifyAt -gt $deleteAt) | Should Be $true
            $global:DusCloud.Created.Count | Should Be 1
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Done: remove temporary Owner assignment*' }).Count | Should Be 1
        }
    }

    Context 'inline contract with modules/azure/automation-runbooks' {
        $begin = '# INLINE_LIBRARY_' + 'BEGIN'
        $end = '# INLINE_LIBRARY_' + 'END'
        $runbookText = [System.IO.File]::ReadAllText($runbook)
        $libraryText = [System.IO.File]::ReadAllText($library)
        $jsonTokens = ConvertTo-Json -InputObject @{ Graph = $graphToken; Arm = $armToken } -Compress
        $parseTokens = $null
        $parseErrors = $null
        $runbookAst = [System.Management.Automation.Language.Parser]::ParseInput($runbookText, [ref]$parseTokens, [ref]$parseErrors)

        # Appended to a copy of the library so a run from disk stays offline:
        # every GET answers an empty list and anything else fails the test.
        $offlineCore = @'

function Invoke-HttpCore {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [object]$Body = $null, [string]$ContentType = '', [int]$TimeoutSec = 100, [string]$OutFile = '')
    if ($Method -ne 'GET') { throw ('Offline test: unexpected {0} request.' -f $Method) }
    [void]$global:DusOfflineHosts.Add(([Uri]$Uri).Host)
    return @{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{} }
}
'@

        # The same, but every request goes to the fake cloud above, so an entry
        # point run can go live without leaving the machine.
        $fakeCloudCore = @'

function Invoke-HttpCore {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, [object]$Body = $null, [string]$ContentType = '', [int]$TimeoutSec = 100, [string]$OutFile = '')
    return (Invoke-DusFakeCloud -Method $Method -Uri $Uri -Body $Body)
}
'@

        function Get-OfflineCopy {
            param([string]$Core = $offlineCore)
            $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'automation\runbooks'
            $libDir = Join-Path -Path $TestDrive -ChildPath 'automation\lib'
            New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            $encoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText((Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1'), ($libraryText + $Core), $encoding)
            $copy = Join-Path -Path $runbooksDir -ChildPath 'Disable-UnauthorizedSubscriptions.ps1'
            [System.IO.File]::WriteAllText($copy, $runbookText, $encoding)
            return $copy
        }

        It 'keeps the runbook ASCII, without a byte order mark, and parseable' {
            $bytes = [System.IO.File]::ReadAllBytes($runbook)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            @($parseErrors).Count | Should Be 0
        }

        It 'carries each marker exactly once with the dot-source between them' {
            $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
            $block = [regex]::Escape($begin) + '\r?\n\. \(Join-Path -Path \$PSScriptRoot -ChildPath ''\.\.\\lib\\Runbook\.Common\.ps1''\)\r?\n' + [regex]::Escape($end)
            $runbookText | Should Match $block
        }

        It 'uses the marker strings the runbooks module splits on' {
            $moduleText = [System.IO.File]::ReadAllText($runbooksModule)
            $moduleText.Contains(('library_begin = "{0}"' -f $begin)) | Should Be $true
            $moduleText.Contains(('library_end   = "{0}"' -f $end)) | Should Be $true
        }

        It 'defines no function the library defines' {
            $libraryAst = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$null, [ref]$null)
            $libraryNames = @($libraryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            # No exact pin: the library grows (53 functions at 1.1.0). The
            # clash check below is what matters, and it must see the list.
            ($libraryNames.Count -ge 53) | Should Be $true
            ($libraryNames -contains 'Get-AutomationStringVariable') | Should Be $true
            $mine = @($runbookAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            (@($mine | Where-Object { $libraryNames -contains $_ }) -join ', ') | Should Be ''
        }

        It 'documents every parameter and gives every function help' {
            $help = $runbookAst.GetHelpContent()
            $documented = @($help.Parameters.Keys | ForEach-Object { ([string]$_).ToUpperInvariant() })
            $missing = @($runbookAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Where-Object { $documented -notcontains $_.ToUpperInvariant() })
            ($missing -join ', ') | Should Be ''
            @($help.Examples | Where-Object { $_ -match '-AccessToken' }).Count | Should BeGreaterThan 0
            $functions = @($runbookAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            $undocumented = @($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name })
            ($undocumented -join ', ') | Should Be ''
        }

        It 'declares only bool, int, and string parameters, with DryRun defaulting to true' {
            $allowedTypes = @('bool', 'int', 'string')
            foreach ($parameter in $runbookAst.ParamBlock.Parameters) {
                $allowedTypes -contains $parameter.StaticType.Name.ToLowerInvariant().Replace('int32', 'int').Replace('boolean', 'bool') | Should Be $true
            }
            $dryRun = @($runbookAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' })[0]
            $dryRun.StaticType | Should Be ([bool])
            $dryRun.DefaultValue.Extent.Text | Should Be '$true'
            $runbookText.Contains('Write-Host') | Should Be $false
        }

        It 'declares AllowCancel as a bool defaulting to false, and the offer patterns as a semicolon list' {
            $allowCancel = @($runbookAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowCancel' })
            $allowCancel.Count | Should Be 1
            $allowCancel[0].StaticType | Should Be ([bool])
            $allowCancel[0].DefaultValue.Extent.Text | Should Be '$false'
            $restricted = @($runbookAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RestrictedQuotaIdPatterns' })[0]
            $restricted.DefaultValue.Value | Should Be 'MSDN_*;FreeTrial_*;PayAsYouGo_*;Pay-as-you-go_*'
            $restricted.DefaultValue.Value | Should Be $script:DusDefaultQuotaIdPatterns
            $runFunction = @($runbookAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DisableUnauthorizedSubscriptionsRun' }, $true))[0]
            $runAllowCancel = @($runFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowCancel' })[0]
            $runAllowCancel.DefaultValue.Extent.Text | Should Be '$false'
            # The entry point passes it through.
            $runbookText | Should Match '-AllowCancel \(\[bool\]\$AllowCancel\)'
        }

        It 'carries no #Requires line and no PowerShell 7-only syntax' {
            $runbookAst.ScriptRequirements | Should Be $null
            # The help mentions #Requires in an indented line; a statement starts a line.
            ($runbookText -match '(?m)^#Requires') | Should Be $false
            # On 5.1, $a?.b and $a ?? $b tokenize as a variable whose name holds '?'.
            @($parseTokens | Where-Object { $_.Kind -eq 'Variable' -and ([string]$_.Name).Contains('?') }).Count | Should Be 0
            @($parseTokens | Where-Object { $_.Kind -eq 'Variable' -and ([string]$_.Name) -eq 'input' }).Count | Should Be 0
            @($parseTokens | Where-Object { [string]$_.Kind -like 'Question*' }).Count | Should Be 0
        }

        It 'keeps the help consistent: Cancel is the action, AllowCancel gates it, and the identity is Owner-capable across its management group' {
            $help = $runbookAst.GetHelpContent()
            $text = ((@($help.Synopsis, $help.Description) + @($help.Parameters.Values) + @($help.Examples)) -join "`n") -replace '\s+', ' '
            $text | Should Match 'Why the name says Disable\. The runbook is named for the result: a canceled subscription shows the Disabled state\.'
            $text | Should Match 'Microsoft\.Subscription/cancel\?api-version=2021-10-01'
            $text | Should Match 'deletion timeline'
            $text | Should Match 'canceled only when DryRun is false and AllowCancel is true'
            $text | Should Match 'reported with the reason "AllowCancel is false"'
            $text | Should Match 'daily at 04:00 UTC in the corp cell'
            $text | Should Match 'its own user-assigned managed identity, in an identity tier of its own'
            $text | Should Match 'Reader, for the subscription'
            $text | Should Match 'The condition limits WHAT the identity can assign \(the Owner role, to itself\), not WHERE under that management group'
            $text | Should Match 'effectively Owner-capable across that management group, and it belongs in the most restricted identity tier'
            $text | Should Match 'semicolon list'
            $text | Should Not Match '06:30'
            $text | Should Not Match 'the documented Enable operation reverses'
            $allowCancelHelp = @($help.Parameters.GetEnumerator() | Where-Object { ([string]$_.Key) -ieq 'AllowCancel' } | ForEach-Object { [string]$_.Value })
            $allowCancelHelp.Count | Should Be 1
            ($allowCancelHelp[0] -replace '\s+', ' ') | Should Match 'Default \$false'
            @($help.Examples | Where-Object { $_ -match '-AllowCancel:\$true' }).Count | Should Be 1
        }

        It 'names the cell key as allowcancel everywhere, in the help and in the digest' {
            # allow_cancel is not a stack input or a cell key: a schedule
            # parameter named that way binds to nothing. dry_run is a real
            # stack input and stays as it is.
            $runbookText.Contains('allow_cancel') | Should Be $false
            $text = ($runbookAst.GetHelpContent().Description -replace '\s+', ' ')
            $text | Should Match 'allowcancel = "true" in the cell'
            $text | Should Match 'dry_run = false'
            $cellText = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'))
            $cellText | Should Match 'allowcancel\s*=\s*"false"'
            $cellText.Contains('allow_cancel') | Should Be $false
            $digest = New-RunDigestHtml -Decisions @([PSCustomObject]@{ DisplayName = 'Sandbox one'; SubscriptionId = '11111111-1111-1111-1111-111111111111'; QuotaId = 'MSDN_2014-09-01'; Decision = 'WouldCancel'; Reason = 'AllowCancel is false' }) -Failures @() -DryRun $false -AllowCancel $false -Notes @() -RunId 'run-1'
            $digest | Should Match 'Set allowcancel = "true" in the tenant cell'
            $digest.Contains('allow_cancel') | Should Be $false
        }

        It 'runs from disk through the entry point with the dot-sourced library' {
            $copy = Get-OfflineCopy
            $global:DusOfflineHosts = New-Object System.Collections.ArrayList
            $summary = & $copy -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken $jsonTokens -RunId $runId 3>$null 4>$null
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Disable-UnauthorizedSubscriptions'
            $summary.RunId | Should Be $runId
            $summary.DryRun | Should Be $true
            $summary.Environment | Should Be 'Global'
            $summary.SubscriptionsScanned | Should Be 0
            $summary.IdentityPrincipalId | Should Be $selfId
            (@($global:DusOfflineHosts) -contains 'management.azure.com') | Should Be $true
        }

        It 'emits the summary and then throws, naming the assignment, when a temporary Owner removal is not confirmed' {
            Set-StandardTenant -Only @($subCandidate)
            $global:DusCloud.DeleteStatus = 403
            $copy = Get-OfflineCopy -Core $fakeCloudCore
            $emitted = New-Object System.Collections.ArrayList
            $caught = ''
            try {
                & $copy -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'cloud-governance@corp.example.com' -AllowedOwnerUpns 'alex@corp.example.com' `
                    -ElevationPropagationSeconds 0 -DryRun $false -AllowCancel $true -AccessToken $jsonTokens -RunId $runId 2>$null 3>$null 4>$null |
                    ForEach-Object { [void]$emitted.Add($_) }
            }
            catch { $caught = $_.Exception.Message }

            $emitted.Count | Should Be 1
            $emitted[0].Runbook | Should Be 'Disable-UnauthorizedSubscriptions'
            $emitted[0].DryRun | Should Be $false
            $emitted[0].CleanupFailureCount | Should Be 1
            $puts = @(Get-TestRequests -Method PUT -PathLike '*/roleAssignments/*')
            $puts.Count | Should Be 1
            $assignmentName = ($puts[0].Path -split '/')[-1]
            @($emitted[0].UnconfirmedRemovals)[0].SubscriptionId | Should Be $subCandidate
            @($emitted[0].UnconfirmedRemovals)[0].AssignmentName | Should Be $assignmentName
            $caught | Should Match 'could not be confirmed removed'
            $caught.Contains($subCandidate) | Should Be $true
            $caught.Contains($assignmentName) | Should Be $true
            $caught | Should Match "run $runId failed after emitting its summary"
        }

        It 'ends a clean live run with AllowCancel through the entry point without throwing' {
            Set-StandardTenant -Only @($subCandidate)
            $copy = Get-OfflineCopy -Core $fakeCloudCore
            $summary = & $copy -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'cloud-governance@corp.example.com' -AllowedOwnerUpns 'alex@corp.example.com' `
                -ElevationPropagationSeconds 0 -DryRun $false -AllowCancel $true -AccessToken $jsonTokens -RunId $runId 3>$null 4>$null
            @($summary).Count | Should Be 1
            $summary.AllowCancel | Should Be $true
            $summary.CanceledCount | Should Be 1
            $summary.CleanupFailureCount | Should Be 0
            @($global:DusCloud.Created.Values | Where-Object { $_.Exists }).Count | Should Be 0
        }

        It 'never elevates or cancels through the entry point unless AllowCancel is passed' {
            Set-StandardTenant -Only @($subCandidate)
            $copy = Get-OfflineCopy -Core $fakeCloudCore
            $summary = & $copy -SenderMailbox 'iam-noreply@corp.example.com' -Recipients 'cloud-governance@corp.example.com;iam-team@corp.example.com' -AllowedOwnerUpns 'alex@corp.example.com' `
                -ElevationPropagationSeconds 0 -DryRun $false -AccessToken $jsonTokens -RunId $runId 3>$null 4>$null
            @($summary).Count | Should Be 1
            $summary.DryRun | Should Be $false
            $summary.AllowCancel | Should Be $false
            $summary.WouldCancelCount | Should Be 1
            $summary.CanceledCount | Should Be 0
            @(Get-TestRequests -Method PUT -PathLike '*').Count | Should Be 0
            @(Get-TestRequests -Method POST -PathLike '*/providers/Microsoft.Subscription/cancel').Count | Should Be 0
            $writes = @(Get-TestWrites)
            ($writes | ForEach-Object { $_.Method + ' ' + $_.Path }) -join ',' | Should Be 'POST /v1.0/users/iam-noreply@corp.example.com/sendMail'
            $digest = ConvertFrom-Json -InputObject $writes[0].Body
            (@($digest.message.toRecipients) | ForEach-Object { $_.emailAddress.address }) -join ',' | Should Be 'cloud-governance@corp.example.com,iam-team@corp.example.com'
        }

        It 'refuses an unsafe offer pattern through the entry point before any request' {
            $copy = Get-OfflineCopy
            $global:DusOfflineHosts = New-Object System.Collections.ArrayList
            { & $copy -SenderMailbox 'iam-noreply@corp.example.com' -RestrictedQuotaIdPatterns '*' -AccessToken $jsonTokens 3>$null 4>$null } | Should Throw 'EnterpriseAgreement_2014-09-01'
            $global:DusOfflineHosts.Count | Should Be 0
        }

        It 'runs in US Government when assembled exactly as main.tf inlines the library' {
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail
            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $assembledErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$null, [ref]$assembledErrors) | Out-Null
            @($assembledErrors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Disable-UnauthorizedSubscriptions.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))
            $global:DusOfflineHosts = New-Object System.Collections.ArrayList
            $summary = & {
                param($PublishedPath, $CoreText, $TokenText, $CorrelationId)
                . $PublishedPath -SenderMailbox 'iam-noreply@corp.example.com' -Environment USGov -AccessToken $TokenText -RunId $CorrelationId
                . ([scriptblock]::Create($CoreText))
                $VerbosePreference = 'SilentlyContinue'
                $WarningPreference = 'SilentlyContinue'
                Invoke-DisableUnauthorizedSubscriptionsRun -SenderMailbox 'iam-noreply@corp.example.com' -Environment USGov -AccessToken $TokenText -RunId $CorrelationId
            } $published $offlineCore $jsonTokens $runId
            @($summary).Count | Should Be 1
            $summary.Environment | Should Be 'USGov'
            $summary.RunId | Should Be $runId
            $global:DusOfflineHosts.Count | Should BeGreaterThan 0
            (@($global:DusOfflineHosts | Select-Object -Unique) -join ',') | Should Be 'management.usgovcloudapi.net'
        }
    }
}

Remove-Item -Path Function:\New-DusResponse, Function:\New-DusError, Function:\Reset-DusCloud, Function:\Invoke-DusFakeCloud -ErrorAction SilentlyContinue
Remove-Variable -Name DusCloud, DusRequests, DusOfflineHosts -Scope Global -ErrorAction SilentlyContinue
