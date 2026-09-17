# Pester tests for automation/runbooks/Invoke-PimEligibilityRenewal.ps1.
#
# Pester 3/4 assertion syntax ("Should Be"), because Windows PowerShell 5.1
# ships Pester 3.4.0. The runbook is dot-sourced, which dot-sources
# automation/lib/Runbook.Common.ps1 from disk exactly as a workstation run
# does, and the entry point is skipped. Every HTTP request goes through the
# library's Invoke-HttpCore, which is mocked here with a route table of
# responses shaped like the Graph and ARM documentation (roleEligibilitySchedules,
# privilegedAccess group eligibilitySchedules, roleManagementPolicyAssignments,
# the schedule request endpoints, management groups, descendants,
# subscriptions, sendMail). Nothing leaves the machine and nothing waits.
# The last context checks the runbook against the inline contract and runs
# it from disk and as Terraform would publish it.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$automationRoot = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $automationRoot
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Invoke-PimEligibilityRenewal.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$runbooksModule = Join-Path -Path $repoRoot -ChildPath 'modules\azure\automation-runbooks\main.tf'

Describe 'Invoke-PimEligibilityRenewal' {
    . $runbook
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    $now = New-Object -TypeName DateTime -ArgumentList 2026, 9, 16, 6, 0, 0, ([DateTimeKind]::Utc)

    # Fake values only. The GUIDs are all-same-digit on purpose.
    $graphToken = 'eyJ0eXAiOiJKV1QifQ.pimgraphpayload000000.pimgraphsignature0'
    $armToken = 'eyJ0eXAiOiJKV1QifQ.pimarmpayload00000000.pimarmsignature000'
    $tokens = '{"Graph":"' + $graphToken + '","Arm":"' + $armToken + '"}'
    $runId = '00000000-0000-0000-0000-000000000000'
    $opsGroupId = '11111111-1111-1111-1111-111111111111'
    $userId = '22222222-2222-2222-2222-222222222222'
    $spId = '33333333-3333-3333-3333-333333333333'
    $hop1GroupId = '44444444-4444-4444-4444-444444444444'
    $dirRoleId = '55555555-5555-5555-5555-555555555555'
    $pimGroupId = '66666666-6666-6666-6666-666666666666'
    $subscriptionId = '77777777-7777-7777-7777-777777777777'
    $mgRoleGuid = '88888888-8888-8888-8888-888888888888'
    $rgRoleGuid = '99999999-9999-9999-9999-999999999999'
    $tfGroupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $tier1GroupId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $azureMgGroupId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $azureRgGroupId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $groupUserId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $azureUserId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    $mgScope = '/providers/Microsoft.Management/managementGroups/mg-platform'
    $subScope = '/subscriptions/' + $subscriptionId
    $rgScope = $subScope + '/resourceGroups/rg-identity'
    $individualIds = @($userId, $spId, $groupUserId, $azureUserId)

    $global:PimRoutes = New-Object System.Collections.ArrayList
    $global:PimRequests = New-Object System.Collections.ArrayList
    $global:PimUnexpected = New-Object System.Collections.ArrayList

    # ---- fixtures -----------------------------------------------------------

    function New-TestResponse {
        param([int]$Status = 200, [object]$Json = $null, [string]$Text = '')
        $content = $Text
        if ($null -ne $Json) { $content = ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        return @{ StatusCode = $Status; Content = $content; Headers = @{} }
    }

    # A route answers with Response, or with each Sequence entry in turn (the
    # last one repeats). -First puts the route ahead of the tenant's own. A
    # response with a Throw key makes Invoke-HttpCore throw that text, as a
    # request that got no response does.
    function Add-TestRoute {
        param([string]$Method = 'GET', [string]$Like, [hashtable]$Response, [string]$BodyLike = '', [hashtable[]]$Sequence = @(), [switch]$First)
        $queue = New-Object System.Collections.ArrayList
        foreach ($item in $Sequence) { [void]$queue.Add($item) }
        $route = @{ Method = $Method; Like = $Like; Response = $Response; BodyLike = $BodyLike; Queue = $queue }
        if ($First) { $global:PimRoutes.Insert(0, $route) }
        else { [void]$global:PimRoutes.Add($route) }
    }

    function New-TestDirectorySchedule {
        param([string]$Id, [string]$PrincipalId, [string]$PrincipalType, [string]$PrincipalName, [object]$EndDays = $null, [string]$ExpirationType = 'afterDateTime')
        $end = $null
        if ($null -ne $EndDays) { $end = Format-PimUtc -Value $now.AddDays([double]$EndDays) }
        return [PSCustomObject]@{
            id               = $Id
            principalId      = $PrincipalId
            roleDefinitionId = $dirRoleId
            directoryScopeId = '/'
            appScopeId       = $null
            createdUsing     = $Id
            memberType       = 'Direct'
            status           = 'Provisioned'
            scheduleInfo     = [PSCustomObject]@{
                startDateTime = (Format-PimUtc -Value $now.AddDays(-300))
                recurrence    = $null
                expiration    = [PSCustomObject]@{ type = $ExpirationType; endDateTime = $end; duration = $null }
            }
            principal        = [PSCustomObject]@{ '@odata.type' = ('#microsoft.graph.' + $PrincipalType); id = $PrincipalId; displayName = $PrincipalName }
            roleDefinition   = [PSCustomObject]@{ id = $dirRoleId; displayName = 'Security Reader' }
        }
    }

    function New-TestGroupSchedule {
        param([string]$PrincipalId, [string]$PrincipalType, [string]$PrincipalName, [double]$EndDays)
        return [PSCustomObject]@{
            id           = ('{0}_member_{1}' -f $pimGroupId, $PrincipalId)
            groupId      = $pimGroupId
            accessId     = 'member'
            principalId  = $PrincipalId
            memberType   = 'direct'
            status       = 'Provisioned'
            createdUsing = $PrincipalId
            scheduleInfo = [PSCustomObject]@{
                startDateTime = (Format-PimUtc -Value $now.AddDays(-200))
                recurrence    = $null
                expiration    = [PSCustomObject]@{ type = 'afterDateTime'; endDateTime = (Format-PimUtc -Value $now.AddDays($EndDays)); duration = $null }
            }
            principal    = [PSCustomObject]@{ '@odata.type' = ('#microsoft.graph.' + $PrincipalType); id = $PrincipalId; displayName = $PrincipalName }
        }
    }

    function New-TestArmSchedule {
        param([string]$Name, [string]$Scope, [string]$RoleGuid, [string]$PrincipalId, [string]$PrincipalType, [string]$PrincipalName, [double]$EndDays, [string]$Condition = '', [string]$MemberType = 'Direct')
        $roleDefinitionId = '{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Scope, $RoleGuid
        $properties = [ordered]@{
            scope                            = $Scope
            roleDefinitionId                 = $roleDefinitionId
            principalId                      = $PrincipalId
            principalType                    = $PrincipalType
            status                           = 'Provisioned'
            roleEligibilityScheduleRequestId = ('{0}/providers/Microsoft.Authorization/RoleEligibilityScheduleRequests/{1}' -f $Scope, $Name)
            startDateTime                    = (Format-PimUtc -Value $now.AddDays(-100))
            endDateTime                      = (Format-PimUtc -Value $now.AddDays($EndDays))
            memberType                       = $MemberType
            createdOn                        = (Format-PimUtc -Value $now.AddDays(-100))
            updatedOn                        = (Format-PimUtc -Value $now.AddDays(-100))
            expandedProperties               = [PSCustomObject]@{
                scope          = [PSCustomObject]@{ id = $Scope; displayName = ('Scope ' + $Name); type = 'resourcegroup' }
                roleDefinition = [PSCustomObject]@{ id = $roleDefinitionId; displayName = ('Role ' + $RoleGuid.Substring(0, 4)); type = 'BuiltInRole' }
                principal      = [PSCustomObject]@{ id = $PrincipalId; displayName = $PrincipalName; email = $null; type = $PrincipalType }
            }
        }
        if ($Condition) {
            $properties['condition'] = $Condition
            $properties['conditionVersion'] = '2.0'
        }
        return [PSCustomObject]@{
            properties = [PSCustomObject]$properties
            name       = $Name
            id         = ('{0}/providers/Microsoft.Authorization/RoleEligibilitySchedules/{1}' -f $Scope, $Name)
            type       = 'Microsoft.Authorization/RoleEligibilitySchedules'
        }
    }

    function New-TestGraphPolicyAssignment {
        param([string]$ScopeId, [string]$ScopeType, [string]$RoleDefinitionId, [bool]$Required, [string]$Maximum)
        return [PSCustomObject]@{
            id               = ('{0}_{1}_{2}' -f $ScopeType, $ScopeId, $RoleDefinitionId)
            policyId         = ('{0}_policy' -f $ScopeType)
            scopeId          = $ScopeId
            scopeType        = $ScopeType
            roleDefinitionId = $RoleDefinitionId
            policy           = [PSCustomObject]@{
                id    = ('{0}_policy' -f $ScopeType)
                rules = @(
                    [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'; id = 'Enablement_Admin_Eligibility'; enabledRules = @() },
                    [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'; id = 'Expiration_EndUser_Assignment'; isExpirationRequired = $true; maximumDuration = 'PT8H' },
                    [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'; id = 'Expiration_Admin_Eligibility'; isExpirationRequired = $Required; maximumDuration = $Maximum; target = [PSCustomObject]@{ caller = 'Admin'; level = 'Eligibility' } }
                )
            }
        }
    }

    function New-TestArmPolicyAssignment {
        param([string]$Scope, [string]$RoleGuid, [bool]$Required, [string]$Maximum)
        return [PSCustomObject]@{
            name       = ('policy_{0}' -f $RoleGuid)
            id         = ('{0}/providers/Microsoft.Authorization/roleManagementPolicyAssignment/policy_{1}' -f $Scope, $RoleGuid)
            type       = 'Microsoft.Authorization/RoleManagementPolicyAssignment'
            properties = [PSCustomObject]@{
                scope          = $Scope
                roleDefinitionId = ('{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $Scope, $RoleGuid)
                policyId       = ('{0}/providers/Microsoft.Authorization/roleManagementPolicies/policy' -f $Scope)
                effectiveRules = @(
                    [PSCustomObject]@{ id = 'Expiration_Admin_Assignment'; ruleType = 'RoleManagementPolicyExpirationRule'; isExpirationRequired = $true; maximumDuration = 'P1D' },
                    [PSCustomObject]@{ id = 'Expiration_Admin_Eligibility'; ruleType = 'RoleManagementPolicyExpirationRule'; isExpirationRequired = $Required; maximumDuration = $Maximum }
                )
            }
        }
    }

    # The tenant: 7 directory schedules (3 due groups, 1 due user, 1 due
    # service principal, 1 later, 1 permanent), 2 PIM for Groups schedules
    # (1 due group, 1 due user), and 3 Azure schedules below "Platform"
    # (2 due groups, 1 due user) plus one above it that must be ignored.
    function Set-TestTenant {
        param(
            [ValidateSet('Global', 'USGov')][string]$Environment = 'Global',
            [int]$DirectoryPolicyStatus = 200,
            [switch]$FailTier1Renewal
        )

        $global:PimRoutes.Clear()
        $global:PimRequests.Clear()
        $global:PimUnexpected.Clear()
        $graphBase = 'https://graph.microsoft.com'
        if ($Environment -eq 'USGov') { $graphBase = 'https://graph.microsoft.us' }

        $directoryPage1 = @(
            (New-TestDirectorySchedule -Id 'dir-ops' -PrincipalId $opsGroupId -PrincipalType 'group' -PrincipalName 'PIM Tier0 Operators' -EndDays 10),
            (New-TestDirectorySchedule -Id 'dir-user' -PrincipalId $userId -PrincipalType 'user' -PrincipalName 'Alex Example' -EndDays 5),
            (New-TestDirectorySchedule -Id 'dir-sp' -PrincipalId $spId -PrincipalType 'servicePrincipal' -PrincipalName 'Deploy Robot' -EndDays 2),
            (New-TestDirectorySchedule -Id 'dir-later' -PrincipalId $opsGroupId -PrincipalType 'group' -PrincipalName 'PIM Tier0 Operators' -EndDays 100)
        )
        $directoryPage2 = @(
            (New-TestDirectorySchedule -Id 'dir-permanent' -PrincipalId $opsGroupId -PrincipalType 'group' -PrincipalName 'PIM Tier0 Operators' -ExpirationType 'noExpiration'),
            (New-TestDirectorySchedule -Id 'dir-tier1' -PrincipalId $tier1GroupId -PrincipalType 'group' -PrincipalName 'PIM Tier1 Operators' -EndDays -3),
            (New-TestDirectorySchedule -Id 'dir-tf' -PrincipalId $tfGroupId -PrincipalType 'group' -PrincipalName 'PIM TF Readers' -EndDays 4)
        )

        # Graph reads. The page-2 route comes first: the page-1 pattern matches it too.
        Add-TestRoute -Like '*/v1.0/roleManagement/directory/roleEligibilitySchedules?$skiptoken=page2*' -Response (New-TestResponse -Json @{ value = $directoryPage2 })
        Add-TestRoute -Like '*/v1.0/roleManagement/directory/roleEligibilitySchedules?*' -Response (New-TestResponse -Json @{
                value             = $directoryPage1
                '@odata.nextLink' = ($graphBase + '/v1.0/roleManagement/directory/roleEligibilitySchedules?$skiptoken=page2')
            })
        if ($DirectoryPolicyStatus -eq 200) {
            Add-TestRoute -Like '*/v1.0/policies/roleManagementPolicyAssignments?*DirectoryRole*' -Response (New-TestResponse -Json @{ value = @(New-TestGraphPolicyAssignment -ScopeId '/' -ScopeType 'DirectoryRole' -RoleDefinitionId $dirRoleId -Required $true -Maximum 'P180D') })
        }
        else {
            Add-TestRoute -Like '*/v1.0/policies/roleManagementPolicyAssignments?*DirectoryRole*' -Response (New-TestResponse -Status $DirectoryPolicyStatus -Text '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges."}}')
        }
        Add-TestRoute -Like ('*/v1.0/policies/roleManagementPolicyAssignments?*{0}*' -f $pimGroupId) -Response (New-TestResponse -Json @{ value = @(New-TestGraphPolicyAssignment -ScopeId $pimGroupId -ScopeType 'Group' -RoleDefinitionId 'member' -Required $true -Maximum 'P365D') })
        Add-TestRoute -Like '*/v1.0/groups?*isAssignableToRole*' -Response (New-TestResponse -Json @{ value = @([PSCustomObject]@{ id = $pimGroupId; displayName = 'PIM Tier0 Admins' }) })
        Add-TestRoute -Like '*/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?*' -Response (New-TestResponse -Json @{ value = @(
                    (New-TestGroupSchedule -PrincipalId $hop1GroupId -PrincipalType 'group' -PrincipalName 'PIM Hop1 Operators' -EndDays 7),
                    (New-TestGroupSchedule -PrincipalId $groupUserId -PrincipalType 'user' -PrincipalName 'Sam Example' -EndDays 6)
                )
            })

        # Graph writes.
        if ($FailTier1Renewal) {
            Add-TestRoute -Method POST -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -BodyLike ('*{0}*' -f $tier1GroupId) -Response (New-TestResponse -Status 400 -Text '{"error":{"code":"RoleAssignmentRequestExisting","message":"A pending request already exists for this principal and role."}}')
        }
        Add-TestRoute -Method POST -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -Response (New-TestResponse -Status 201 -Json @{ id = 'req-dir'; status = 'Provisioned' })
        Add-TestRoute -Method POST -Like '*/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests' -Response (New-TestResponse -Status 201 -Json @{ id = 'req-group'; status = 'Provisioned' })
        Add-TestRoute -Method POST -Like '*/v1.0/users/*/sendMail' -Response (New-TestResponse -Status 202)

        # ARM reads.
        Add-TestRoute -Like '*/providers/Microsoft.Management/managementGroups?api-version=*' -Response (New-TestResponse -Json @{ value = @(
                    [PSCustomObject]@{ id = '/providers/Microsoft.Management/managementGroups/mg-root'; name = 'mg-root'; type = 'Microsoft.Management/managementGroups'; properties = [PSCustomObject]@{ displayName = 'Tenant Root Group' } },
                    [PSCustomObject]@{ id = $mgScope; name = 'mg-platform'; type = 'Microsoft.Management/managementGroups'; properties = [PSCustomObject]@{ displayName = 'Platform' } }
                )
            })
        Add-TestRoute -Like '*/subscriptions?api-version=*' -Response (New-TestResponse -Json @{ value = @(
                    [PSCustomObject]@{ id = $subScope; subscriptionId = $subscriptionId; displayName = 'Identity Production'; state = 'Enabled' }
                )
            })
        Add-TestRoute -Like '*/managementGroups/mg-platform/descendants?*' -Response (New-TestResponse -Json @{
                value    = @([PSCustomObject]@{ id = $subScope; type = 'Microsoft.Management/managementGroups/subscriptions'; name = $subscriptionId; properties = [PSCustomObject]@{ displayName = 'Identity Production'; parent = [PSCustomObject]@{ id = $mgScope } } })
                nextLink = $null
            })
        Add-TestRoute -Like '*/managementGroups/mg-platform/providers/Microsoft.Authorization/roleEligibilitySchedules?*' -Response (New-TestResponse -Json @{ value = @(
                    (New-TestArmSchedule -Name 'arm-mg' -Scope $mgScope -RoleGuid $mgRoleGuid -PrincipalId $azureMgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure Platform Readers' -EndDays 12),
                    (New-TestArmSchedule -Name 'arm-root' -Scope '/providers/Microsoft.Management/managementGroups/mg-root' -RoleGuid $mgRoleGuid -PrincipalId $azureMgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure Platform Readers' -EndDays 3)
                )
            })
        Add-TestRoute -Like ('*/subscriptions/{0}/providers/Microsoft.Authorization/roleEligibilitySchedules?*' -f $subscriptionId) -Response (New-TestResponse -Json @{ value = @(
                    (New-TestArmSchedule -Name 'arm-rg' -Scope $rgScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure App Contributors' -EndDays 1 -Condition "@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:ContainerName] StringEqualsIgnoreCase 'app'"),
                    (New-TestArmSchedule -Name 'arm-inherited' -Scope $mgScope -RoleGuid $mgRoleGuid -PrincipalId $azureMgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure Platform Readers' -EndDays 12 -MemberType 'Inherited'),
                    (New-TestArmSchedule -Name 'arm-user' -Scope $subScope -RoleGuid $rgRoleGuid -PrincipalId $azureUserId -PrincipalType 'User' -PrincipalName 'Jo Example' -EndDays 9)
                )
            })
        Add-TestRoute -Like '*/managementGroups/mg-platform/providers/Microsoft.Authorization/roleManagementPolicyAssignments?*' -Response (New-TestResponse -Json @{ value = @(
                    (New-TestArmPolicyAssignment -Scope $mgScope -RoleGuid $dirRoleId -Required $true -Maximum 'P15D'),
                    (New-TestArmPolicyAssignment -Scope $mgScope -RoleGuid $mgRoleGuid -Required $false -Maximum 'P180D')
                )
            })
        Add-TestRoute -Like '*/resourceGroups/rg-identity/providers/Microsoft.Authorization/roleManagementPolicyAssignments?*' -Response (New-TestResponse -Json @{ value = @(
                    (New-TestArmPolicyAssignment -Scope $rgScope -RoleGuid $rgRoleGuid -Required $true -Maximum 'P90D')
                )
            })

        # ARM writes.
        Add-TestRoute -Method PUT -Like '*/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/*' -Response (New-TestResponse -Status 201 -Json @{ properties = @{ status = 'Provisioned' } })
    }

    function Get-TestWrites {
        return @($global:PimRequests | Where-Object { $_.Method -ne 'GET' })
    }

    function Get-TestBodies {
        param([string]$Like)
        foreach ($request in @($global:PimRequests | Where-Object { $_.Method -ne 'GET' -and $_.Uri -like $Like })) {
            ConvertFrom-Json -InputObject $request.Body
        }
    }

    Mock Invoke-HttpCore {
        [void]$global:PimRequests.Add([PSCustomObject]@{ Method = $Method; Uri = $Uri; Body = [string]$Body; Headers = $Headers })
        foreach ($route in $global:PimRoutes) {
            if ($route.Method -ne $Method -or $Uri -notlike $route.Like) { continue }
            if ($route.BodyLike -and ([string]$Body) -notlike $route.BodyLike) { continue }
            $chosen = $route.Response
            if ($route.Queue.Count -gt 1) {
                $chosen = $route.Queue[0]
                $route.Queue.RemoveAt(0)
            }
            elseif ($route.Queue.Count -eq 1) { $chosen = $route.Queue[0] }
            if ($null -ne $chosen -and $chosen.ContainsKey('Throw')) { throw [string]$chosen.Throw }
            return $chosen
        }
        [void]$global:PimUnexpected.Add(('{0} {1}' -f $Method, $Uri))
        return @{ StatusCode = 404; Content = '{"error":{"code":"NotMocked","message":"No test route for this request."}}'; Headers = @{} }
    }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }

    function New-TestCandidate {
        param(
            [string]$PrincipalType = 'Group',
            [string]$Name = 'PIM Ops',
            [object]$EndDays = 10,
            [string]$Status = 'Provisioned',
            [string]$MemberType = 'Direct',
            [string]$Plane = 'Directory'
        )
        $end = $null
        if ($null -ne $EndDays) { $end = $now.AddDays([double]$EndDays) }
        return New-PimCandidate -Values @{
            Plane            = $Plane
            ScheduleId       = 'schedule-1'
            PrincipalId      = $opsGroupId
            PrincipalType    = $PrincipalType
            PrincipalName    = $Name
            RoleId           = $dirRoleId
            RoleName         = 'Security Reader'
            Scope            = '/'
            ScopeName        = '/'
            DirectoryScopeId = '/'
            GroupId          = $pimGroupId
            AccessId         = 'member'
            MemberType       = $MemberType
            Status           = $Status
            End              = $end
            HasEnd           = ($null -ne $end)
        }
    }

    function New-TestRule {
        param([bool]$Required, [string]$Maximum)
        return Get-PimEligibilityExpirationRule -Rules @([PSCustomObject]@{ id = 'Expiration_Admin_Eligibility'; isExpirationRequired = $Required; maximumDuration = $Maximum })
    }

    $window = @{ Now = $now; RenewWithinDays = 14; ExtendDays = 365; GroupPatterns = @('*') }

    # ---- pure helpers -------------------------------------------------------

    Context 'dates and durations' {
        It 'reads the ISO 8601 durations PIM policies use' {
            (ConvertFrom-IsoDuration -Value 'P365D').TotalDays | Should Be 365
            (ConvertFrom-IsoDuration -Value 'P180D').TotalDays | Should Be 180
            (ConvertFrom-IsoDuration -Value 'PT8H').TotalHours | Should Be 8
            (ConvertFrom-IsoDuration -Value 'P1DT12H').TotalHours | Should Be 36
            (ConvertFrom-IsoDuration -Value 'P2W').TotalDays | Should Be 14
            (ConvertFrom-IsoDuration -Value 'pt30m').TotalMinutes | Should Be 30
        }

        It 'reads years and months short, so a clamp is never longer than the policy' {
            (ConvertFrom-IsoDuration -Value 'P1Y').TotalDays | Should Be 365
            (ConvertFrom-IsoDuration -Value 'P6M').TotalDays | Should Be 168
        }

        It 'returns null for anything that is not a duration' {
            ConvertFrom-IsoDuration -Value '' | Should BeNullOrEmpty
            ConvertFrom-IsoDuration -Value 'P' | Should BeNullOrEmpty
            ConvertFrom-IsoDuration -Value 'PT' | Should BeNullOrEmpty
            ConvertFrom-IsoDuration -Value '365' | Should BeNullOrEmpty
            ConvertFrom-IsoDuration -Value 'P1H' | Should BeNullOrEmpty
        }

        It 'normalises timestamps to UTC whatever shape they arrive in' {
            (ConvertTo-PimUtcDateTime -Value '2026-09-30T00:00:00Z') | Should Be (New-Object DateTime 2026, 9, 30, 0, 0, 0, ([DateTimeKind]::Utc))
            (ConvertTo-PimUtcDateTime -Value '2026-09-30T02:00:00+02:00') | Should Be (New-Object DateTime 2026, 9, 30, 0, 0, 0, ([DateTimeKind]::Utc))
            (ConvertTo-PimUtcDateTime -Value (New-Object DateTime 2026, 9, 30, 0, 0, 0)).Kind | Should Be 'Utc'
            (ConvertTo-PimUtcDateTime -Value ([DateTimeOffset]::new(2026, 9, 30, 1, 0, 0, [TimeSpan]::FromHours(1)))) | Should Be (New-Object DateTime 2026, 9, 30, 0, 0, 0, ([DateTimeKind]::Utc))
            ConvertTo-PimUtcDateTime -Value $null | Should BeNullOrEmpty
            ConvertTo-PimUtcDateTime -Value 'not a date' | Should BeNullOrEmpty
        }

        It 'formats request timestamps the way Graph and ARM accept them' {
            Format-PimUtc -Value $now | Should Be '2026-09-16T06:00:00Z'
            Format-PimUtc -Value (New-Object DateTime 2026, 1, 2, 3, 4, 5) | Should Be '2026-01-02T03:04:05Z'
        }

        It 'reads the end of afterDateTime, afterDuration, and noExpiration schedules' {
            $at = Get-PimScheduleWindow -ScheduleInfo ([PSCustomObject]@{ startDateTime = '2026-01-01T00:00:00Z'; expiration = [PSCustomObject]@{ type = 'afterDateTime'; endDateTime = '2026-10-01T00:00:00Z' } })
            $at.HasEnd | Should Be $true
            $at.End | Should Be (New-Object DateTime 2026, 10, 1, 0, 0, 0, ([DateTimeKind]::Utc))

            $after = Get-PimScheduleWindow -ScheduleInfo ([PSCustomObject]@{ startDateTime = '2026-01-01T00:00:00Z'; expiration = [PSCustomObject]@{ type = 'afterDuration'; endDateTime = $null; duration = 'P30D' } })
            $after.End | Should Be (New-Object DateTime 2026, 1, 31, 0, 0, 0, ([DateTimeKind]::Utc))

            $never = Get-PimScheduleWindow -ScheduleInfo ([PSCustomObject]@{ startDateTime = '2026-01-01T00:00:00Z'; expiration = [PSCustomObject]@{ type = 'noExpiration'; endDateTime = '2026-10-01T00:00:00Z' } })
            $never.HasEnd | Should Be $false
            $never.End | Should BeNullOrEmpty

            (Get-PimScheduleWindow -ScheduleInfo $null).HasEnd | Should Be $false
        }
    }

    Context 'principals and patterns' {
        It 'classifies Graph principals by @odata.type and ARM principals by principalType' {
            Get-PimPrincipalType -Principal ([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.group' }) | Should Be 'Group'
            Get-PimPrincipalType -Principal ([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.user' }) | Should Be 'User'
            Get-PimPrincipalType -Principal ([PSCustomObject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal' }) | Should Be 'ServicePrincipal'
            Get-PimPrincipalType -DeclaredType 'Group' | Should Be 'Group'
            Get-PimPrincipalType -DeclaredType 'ForeignGroup' | Should Be 'ForeignGroup'
            Get-PimPrincipalType -DeclaredType 'User' | Should Be 'User'
        }

        It 'never calls an unreadable principal a group' {
            Get-PimPrincipalType -Principal $null | Should Be 'Unknown'
            Get-PimPrincipalType -Principal ([PSCustomObject]@{ id = $opsGroupId }) | Should Be 'Unknown'
            Get-PimPrincipalType -DeclaredType 'microsoft.graph.orgContact' | Should Be 'Other'
        }

        It 'includes every group with the default pattern' {
            Test-PimPrincipalNameAllowed -Name 'Anything At All' -Patterns @('*') | Should Be $true
            Test-PimPrincipalNameAllowed -Name '' -Patterns @('*') | Should Be $true
            Test-PimPrincipalNameAllowed -Name 'Anything' -Patterns @() | Should Be $true
            Test-PimPrincipalNameAllowed -Name 'Anything' -Patterns $null | Should Be $true
        }

        It 'applies include patterns case-insensitively' {
            Test-PimPrincipalNameAllowed -Name 'pim tier0 operators' -Patterns @('PIM *') | Should Be $true
            Test-PimPrincipalNameAllowed -Name 'Helpdesk' -Patterns @('PIM *', 'SEC *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name 'SEC Readers' -Patterns @('PIM *', 'SEC *') | Should Be $true
        }

        It 'lets an exclusion win over an inclusion' {
            Test-PimPrincipalNameAllowed -Name 'PIM TF Readers' -Patterns @('PIM *', '!PIM TF *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name 'PIM Tier0 Operators' -Patterns @('PIM *', '!PIM TF *') | Should Be $true
            Test-PimPrincipalNameAllowed -Name 'Other' -Patterns @('!PIM TF *') | Should Be $true
            Test-PimPrincipalNameAllowed -Name 'PIM TF Readers' -Patterns @('!pim tf *') | Should Be $false
        }

        It 'takes the schedule parameter as one string, as Automation passes it' {
            $parsed = @(ConvertTo-PimGroupNamePatternList -Value 'PIM *;!PIM TF *')
            $parsed.Count | Should Be 2
            Test-PimPrincipalNameAllowed -Name 'PIM TF Readers' -Patterns $parsed | Should Be $false
            @(ConvertTo-PimGroupNamePatternList -Value '["PIM *","!PIM TF *"]').Count | Should Be 2
            @(ConvertTo-PimGroupNamePatternList -Value '"*"') -join '|' | Should Be '*'
        }

        It 'fails closed on a group with no readable name unless every name is allowed' {
            Test-PimPrincipalNameAllowed -Name '' -Patterns @('*', '!PIM TF *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name '   ' -Patterns @('*', '!PIM TF *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name $null -Patterns @('!PIM TF *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name '' -Patterns @('PIM *') | Should Be $false
            Test-PimPrincipalNameAllowed -Name '' -Patterns @('PIM *', '*') | Should Be $true
            Test-PimPrincipalNameAllowed -Name $null -Patterns $null | Should Be $true
            (Split-PimGroupNamePattern -Patterns @('*', '!PIM TF *')).MatchesAll | Should Be $false
            (Split-PimGroupNamePattern -Patterns @('**')).MatchesAll | Should Be $true
            (Split-PimGroupNamePattern -Patterns @('PIM *')).MatchesAll | Should Be $false
            (Split-PimGroupNamePattern -Patterns @()).MatchesAll | Should Be $true
            @((Split-PimGroupNamePattern -Patterns @('!PIM TF *')).Includes) -join '|' | Should Be '*'
        }

        It 'reads square brackets, backticks, and regex characters as literal text' {
            $patterns = @(ConvertTo-PimGroupNamePatternList -Value '*;!PIM TF [legacy] *')
            Test-PimPrincipalNameAllowed -Name 'PIM TF [legacy] Readers' -Patterns $patterns | Should Be $false
            Test-PimPrincipalNameAllowed -Name 'pim tf [LEGACY] readers' -Patterns $patterns | Should Be $false
            # As a -like character class, [legacy] would have matched this one instead.
            Test-PimPrincipalNameAllowed -Name 'PIM TF l Readers' -Patterns $patterns | Should Be $true
            Test-PimNamePatternMatch -Name 'PIM [a]' -Pattern 'PIM [a]' | Should Be $true
            Test-PimNamePatternMatch -Name 'PIM a' -Pattern 'PIM [a]' | Should Be $false
            Test-PimNamePatternMatch -Name 'Ops `1' -Pattern 'Ops `1' | Should Be $true
            Test-PimNamePatternMatch -Name 'Ops 1' -Pattern 'Ops `1' | Should Be $false
            Test-PimNamePatternMatch -Name 'PIM (a).b+$' -Pattern 'PIM (a).b+$' | Should Be $true
            Test-PimNamePatternMatch -Name 'PIM (a)Xb+$' -Pattern 'PIM (a).b+$' | Should Be $false
            @(ConvertTo-PimGroupNamePatternList -Value '["[legacy] *"]') -join '|' | Should Be '[legacy] *'
        }

        It 'matches the whole name, with * for any run and ? for one character' {
            Test-PimNamePatternMatch -Name 'PIM T1' -Pattern 'PIM T?' | Should Be $true
            Test-PimNamePatternMatch -Name 'PIM T12' -Pattern 'PIM T?' | Should Be $false
            Test-PimNamePatternMatch -Name 'PIM Ops' -Pattern 'PIM' | Should Be $false
            Test-PimNamePatternMatch -Name 'Team PIM Ops' -Pattern 'PIM *' | Should Be $false
            Test-PimNamePatternMatch -Name '' -Pattern '*' | Should Be $true
        }

        It 'refuses a pattern value that holds no usable pattern' {
            { ConvertTo-PimGroupNamePatternList -Value '!' } | Should Throw 'excludes nothing'
            { ConvertTo-PimGroupNamePatternList -Value 'PIM *; ! ' } | Should Throw 'excludes nothing'
            { ConvertTo-PimGroupNamePatternList -Value '["PIM *","!"]' } | Should Throw 'excludes nothing'
            { ConvertTo-PimGroupNamePatternList -Value '[]' } | Should Throw 'holds no pattern'
            { ConvertTo-PimGroupNamePatternList -Value '[""]' } | Should Throw 'holds no pattern'
            { ConvertTo-PimGroupNamePatternList -Value ' ; , ' } | Should Throw 'holds no pattern'
            { Split-PimGroupNamePattern -Patterns @('*', '!') } | Should Throw 'excludes nothing'
            { Test-PimPrincipalNameAllowed -Name 'Anything' -Patterns @('!') } | Should Throw 'excludes nothing'
        }

        It 'reads a blank pattern value as every group' {
            @(ConvertTo-PimGroupNamePatternList -Value '') -join '|' | Should Be '*'
            @(ConvertTo-PimGroupNamePatternList -Value '   ') -join '|' | Should Be '*'
            @(ConvertTo-PimGroupNamePatternList -Value $null) -join '|' | Should Be '*'
        }
    }

    Context 'policy expiration rule' {
        It 'finds Expiration_Admin_Eligibility among the other rules' {
            $assignment = New-TestGraphPolicyAssignment -ScopeId '/' -ScopeType 'DirectoryRole' -RoleDefinitionId $dirRoleId -Required $true -Maximum 'P180D'
            $rule = Get-PimEligibilityExpirationRule -Rules $assignment.policy.rules
            $rule.IsExpirationRequired | Should Be $true
            $rule.MaximumDuration.TotalDays | Should Be 180
            $rule.MaximumDurationText | Should Be 'P180D'
        }

        It 'reads the ARM effectiveRules shape' {
            $assignment = New-TestArmPolicyAssignment -Scope $rgScope -RoleGuid $rgRoleGuid -Required $false -Maximum 'P90D'
            $rule = Get-PimEligibilityExpirationRule -Rules $assignment.properties.effectiveRules
            $rule.IsExpirationRequired | Should Be $false
            $rule.MaximumDuration.TotalDays | Should Be 90
        }

        It 'reads isExpirationRequired given as text without treating "false" as true' {
            (Get-PimEligibilityExpirationRule -Rules @([PSCustomObject]@{ id = 'Expiration_Admin_Eligibility'; isExpirationRequired = 'false'; maximumDuration = 'P1D' })).IsExpirationRequired | Should Be $false
            (Get-PimEligibilityExpirationRule -Rules @([PSCustomObject]@{ id = 'Expiration_Admin_Eligibility'; isExpirationRequired = 'true'; maximumDuration = 'P1D' })).IsExpirationRequired | Should Be $true
        }

        It 'returns null when the rule is absent, and a null maximum when it is unreadable' {
            Get-PimEligibilityExpirationRule -Rules @([PSCustomObject]@{ id = 'Expiration_Admin_Assignment'; isExpirationRequired = $true; maximumDuration = 'P1D' }) | Should BeNullOrEmpty
            Get-PimEligibilityExpirationRule -Rules @() | Should BeNullOrEmpty
            Get-PimEligibilityExpirationRule -Rules $null | Should BeNullOrEmpty
            (New-TestRule -Required $true -Maximum 'forever').MaximumDuration | Should BeNullOrEmpty
        }
    }

    Context 'renewal decision' {
        It 'leaves an eligibility alone until it is inside the window' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 14.01) @window
            $d.Decision | Should Be 'NotDue'
            $d.Due | Should Be $false
            $d.NeedsPolicy | Should Be $false
        }

        It 'asks for the policy exactly at the window boundary' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 14) @window
            $d.Due | Should Be $true
            $d.NeedsPolicy | Should Be $true
            $d.Decision | Should Be 'Skip'
        }

        It 'extends a group for ExtendDays when the policy allows permanent eligibility' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 10) @window -Rule (New-TestRule -Required $false -Maximum 'P180D') -RuleKnown $true
            $d.Decision | Should Be 'Extend'
            $d.RequestedStart | Should Be $now
            $d.RequestedEnd | Should Be $now.AddDays(365)
            $d.DaysLeft | Should Be 10
        }

        It 'clamps the request to the policy maximum when expiration is required' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 10) @window -Rule (New-TestRule -Required $true -Maximum 'P180D') -RuleKnown $true
            $d.Decision | Should Be 'Extend'
            $d.RequestedEnd | Should Be $now.AddDays(180)
            $d.Reason | Should Match 'clamped to the policy maximum P180D'
            $d.MaximumDuration | Should Be 'P180D'
        }

        It 'does not stretch the request when the policy maximum is longer than ExtendDays' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 10) @window -Rule (New-TestRule -Required $true -Maximum 'P400D') -RuleKnown $true
            $d.RequestedEnd | Should Be $now.AddDays(365)
            $d.Reason | Should Not Match 'clamped'
        }

        It 'renews a group eligibility that ended inside the window' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays -3) @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $d.Decision | Should Be 'Renew'
            $d.Reason | Should Match 'ended'
            $boundary = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays -14) @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $boundary.Decision | Should Be 'Renew'
        }

        It 'leaves an eligibility that ended before the window to a person' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays -14.01) @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Due | Should Be $false
            $d.Reason | Should Match 'decision for a person'
        }

        It 'never renews a user, a service principal, or an unknown principal' {
            foreach ($type in @('User', 'ServicePrincipal', 'Unknown', 'ForeignGroup', 'Other')) {
                $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -PrincipalType $type -Name 'PIM Looks Like A Group') @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
                $d.Decision | Should Be 'Review'
                $d.Due | Should Be $true
                $d.NeedsPolicy | Should Be $false
                $d.RequestedEnd | Should BeNullOrEmpty
            }
        }

        It 'reports an expired user eligibility inside the window for review too' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -PrincipalType 'User' -EndDays -2) @window
            $d.Decision | Should Be 'Review'
            $d.Reason | Should Match 'user eligibility ended'
        }

        It 'excludes a group the pattern leaves out, before reading its policy' {
            $patterns = @{ Now = $now; RenewWithinDays = 14; ExtendDays = 365; GroupPatterns = @('PIM *', '!PIM TF *') }
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -Name 'PIM TF Readers') @patterns
            $d.Decision | Should Be 'Excluded'
            $d.NeedsPolicy | Should Be $false
        }

        It 'skips a group with no readable name when the pattern excludes anything' {
            $rule = New-TestRule -Required $false -Maximum 'P365D'
            $patterns = @{ Now = $now; RenewWithinDays = 14; ExtendDays = 365; GroupPatterns = @('*', '!PIM TF *') }
            foreach ($blank in @('', '  ')) {
                $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -Name $blank) @patterns -Rule $rule -RuleKnown $true
                $d.Decision | Should Be 'Skip'
                $d.Due | Should Be $true
                $d.NeedsPolicy | Should Be $false
                $d.RequestedEnd | Should BeNullOrEmpty
                $d.Reason | Should Match 'display name could not be read'
            }
            $first = Get-PimRenewalDecision -Candidate (New-TestCandidate -Name '') @patterns
            $first.NeedsPolicy | Should Be $false
            $first.Decision | Should Be 'Skip'

            # An Azure schedule with no expandedProperties.principal has no name.
            $schedule = New-TestArmSchedule -Name 'x' -Scope $rgScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'PIM TF Azure' -EndDays 1
            $schedule.properties.expandedProperties.principal = $null
            $unnamed = ConvertFrom-PimAzureSchedule -Schedule $schedule
            $unnamed.PrincipalName | Should Be ''
            $unnamed.PrincipalType | Should Be 'Group'
            (Get-PimRenewalDecision -Candidate $unnamed @patterns -Rule $rule -RuleKnown $true).Decision | Should Be 'Skip'
            (Get-PimRenewalDecision -Candidate $unnamed @window -Rule $rule -RuleKnown $true).Decision | Should Be 'Extend'
        }

        It 'excludes a group whose name holds square brackets' {
            $patterns = @{ Now = $now; RenewWithinDays = 14; ExtendDays = 365; GroupPatterns = @('*', '!PIM TF [legacy] *') }
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -Name 'PIM TF [legacy] Readers') @patterns -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $d.Decision | Should Be 'Excluded'
            $d.RequestedEnd | Should BeNullOrEmpty
        }

        It 'skips a directory schedule with neither a directory scope nor an app scope' {
            $candidate = New-TestCandidate
            $candidate.DirectoryScopeId = ''
            $candidate.AppScopeId = ''
            $d = Get-PimRenewalDecision -Candidate $candidate @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Due | Should Be $true
            $d.Reason | Should Match 'no directoryScopeId or appScopeId'
            (Get-PimRenewalDecision -Candidate $candidate @window).NeedsPolicy | Should Be $false
            # Groups and Azure schedules have no directory scope, and are not affected.
            $group = New-TestCandidate -Plane 'Group' -MemberType 'direct'
            $group.DirectoryScopeId = ''
            (Get-PimRenewalDecision -Candidate $group @window).NeedsPolicy | Should Be $true
        }

        It 'does not renew blind when the policy could not be read' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule $null -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Due | Should Be $true
            $d.Reason | Should Match 'could not be read'
        }

        It 'skips when the policy requires expiration but its maximum is unreadable' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule (New-TestRule -Required $true -Maximum 'forever') -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Reason | Should Match 'not readable'
        }

        It 'skips when the policy maximum would not move the end date' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 10) @window -Rule (New-TestRule -Required $true -Maximum 'P7D') -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Due | Should Be $true
            $d.Reason | Should Match 'would not move the end date'
        }

        It 'skips a permanent eligibility whatever the policy says' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays $null) @window -Rule (New-TestRule -Required $false -Maximum 'P365D') -RuleKnown $true
            $d.Decision | Should Be 'Skip'
            $d.Due | Should Be $false
            $d.Reason | Should Match 'permanent'
        }

        It 'skips schedules that are not provisioned or not direct' {
            (Get-PimRenewalDecision -Candidate (New-TestCandidate -Status 'PendingProvisioning') @window).Reason | Should Match 'status'
            (Get-PimRenewalDecision -Candidate (New-TestCandidate -Status 'Revoked') @window).Decision | Should Be 'Skip'
            (Get-PimRenewalDecision -Candidate (New-TestCandidate -MemberType 'Inherited') @window).Reason | Should Match 'memberType is Inherited'
            (Get-PimRenewalDecision -Candidate (New-TestCandidate -MemberType 'Group') @window).Decision | Should Be 'Skip'
            (Get-PimRenewalDecision -Candidate (New-TestCandidate -MemberType 'direct' -Plane 'Group') @window).NeedsPolicy | Should Be $true
        }

        It 'starts the request on a whole second' {
            $clock = $now.AddMilliseconds(789)
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate -EndDays 10) -Now $clock -RenewWithinDays 14 -ExtendDays 30 -GroupPatterns @('*') -Rule (New-TestRule -Required $false -Maximum 'P1D') -RuleKnown $true
            $d.RequestedStart | Should Be $now
            $d.RequestedEnd | Should Be $now.AddDays(30)
        }
    }

    Context 'request bodies' {
        $rule = New-TestRule -Required $false -Maximum 'P365D'

        It 'builds the directory adminExtend body' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule $rule -RuleKnown $true
            $body = New-PimDirectoryRequestBody -Decision $d -Justification 'why'
            $body.action | Should Be 'adminExtend'
            $body.principalId | Should Be $opsGroupId
            $body.roleDefinitionId | Should Be $dirRoleId
            $body.directoryScopeId | Should Be '/'
            $body.Contains('appScopeId') | Should Be $false
            $body.justification | Should Be 'why'
            $body.scheduleInfo.startDateTime | Should Be '2026-09-16T06:00:00Z'
            $body.scheduleInfo.expiration.type | Should Be 'afterDateTime'
            $body.scheduleInfo.expiration.endDateTime | Should Be '2027-09-16T06:00:00Z'
        }

        It 'uses adminRenew for an expired eligibility and appScopeId when there is no directory scope' {
            $candidate = New-TestCandidate -EndDays -1
            $candidate.DirectoryScopeId = ''
            $candidate.AppScopeId = '/'
            $d = Get-PimRenewalDecision -Candidate $candidate @window -Rule $rule -RuleKnown $true
            $body = New-PimDirectoryRequestBody -Decision $d -Justification 'why'
            $body.action | Should Be 'adminRenew'
            $body.appScopeId | Should Be '/'
            $body.Contains('directoryScopeId') | Should Be $false
        }

        It 'never defaults a directory request to the tenant-wide scope' {
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule $rule -RuleKnown $true
            $d.Decision | Should Be 'Extend'
            $d.Candidate.DirectoryScopeId = ''
            $d.Candidate.AppScopeId = ''
            { New-PimDirectoryRequestBody -Decision $d -Justification 'why' } | Should Throw 'no directoryScopeId or appScopeId'

            $schedule = New-TestDirectorySchedule -Id 'dir-noscope' -PrincipalId $opsGroupId -PrincipalType 'group' -PrincipalName 'PIM Tier0 Operators' -EndDays 3
            $schedule.directoryScopeId = $null
            $candidate = ConvertFrom-PimDirectorySchedule -Schedule $schedule
            $candidate.Scope | Should Be ''
            (Get-PimRenewalDecision -Candidate $candidate @window -Rule $rule -RuleKnown $true).Decision | Should Be 'Skip'
        }

        It 'builds the PIM for Groups body' {
            $candidate = New-TestCandidate -Plane 'Group' -MemberType 'direct'
            $d = Get-PimRenewalDecision -Candidate $candidate @window -Rule $rule -RuleKnown $true
            $body = New-PimGroupRequestBody -Decision $d -Justification 'why'
            $body.accessId | Should Be 'member'
            $body.groupId | Should Be $pimGroupId
            $body.principalId | Should Be $opsGroupId
            $body.action | Should Be 'adminExtend'
            $body.scheduleInfo.expiration.type | Should Be 'afterDateTime'
            $json = ConvertTo-Json -InputObject $body -Depth 10 -Compress
            $json | Should Match '"action":"adminExtend"'
        }

        It 'builds the ARM body and carries the ABAC condition forward' {
            $candidate = ConvertFrom-PimAzureSchedule -Schedule (New-TestArmSchedule -Name 'x' -Scope $rgScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure App Contributors' -EndDays -1 -Condition 'cond')
            $d = Get-PimRenewalDecision -Candidate $candidate @window -Rule $rule -RuleKnown $true
            $body = New-PimAzureRequestBody -Decision $d -Justification 'why'
            $body.properties.requestType | Should Be 'AdminRenew'
            $body.properties.principalId | Should Be $azureRgGroupId
            $body.properties.roleDefinitionId | Should Be ('{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $rgScope, $rgRoleGuid)
            $body.properties.scheduleInfo.expiration.type | Should Be 'AfterDateTime'
            $body.properties.condition | Should Be 'cond'
            $body.properties.conditionVersion | Should Be '2.0'
        }

        It 'sends no condition when the eligibility has none' {
            $candidate = ConvertFrom-PimAzureSchedule -Schedule (New-TestArmSchedule -Name 'x' -Scope $subScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'G' -EndDays 1)
            $d = Get-PimRenewalDecision -Candidate $candidate @window -Rule $rule -RuleKnown $true
            $body = New-PimAzureRequestBody -Decision $d -Justification 'why'
            $body.properties.requestType | Should Be 'AdminExtend'
            $body.properties.Contains('condition') | Should Be $false
            $body.properties.Contains('conditionVersion') | Should Be $false
        }

        It 'addresses the ARM request at the eligibility scope' {
            $name = $runId
            New-PimAzureRequestUri -Scope $mgScope -RequestName $name | Should Be ('providers/Microsoft.Management/managementGroups/mg-platform/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{0}' -f $name)
            New-PimAzureRequestUri -Scope ($rgScope + '/') -RequestName $name | Should Be ('subscriptions/{0}/resourceGroups/rg-identity/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/{1}' -f $subscriptionId, $name)
            { New-PimAzureRequestUri -Scope $subScope -RequestName 'not-a-guid' } | Should Throw
        }

        It 'names the runbook and the run in the justification' {
            $text = New-PimRenewalJustification -Decision Extend -RunId $runId -RenewWithinDays 14
            $text | Should Match 'Invoke-PimEligibilityRenewal'
            $text | Should Match $runId
            $text | Should Match 'extension'
            (New-PimRenewalJustification -Decision Renew -RunId $runId -RenewWithinDays 14) | Should Match 'renewal'
            $text.Length | Should BeLessThan 500
        }

        It 'refuses to send a request for anything but a group, without calling the service' {
            Set-TestTenant
            Initialize-RunContext -RunbookName 'Invoke-PimEligibilityRenewal' -RunId $runId -AccessToken $tokens -DryRun $false
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule $rule -RuleKnown $true
            $d.Candidate.PrincipalType = 'User'
            { Invoke-PimRenewalRequest -Decision $d -Justification 'why' } | Should Throw 'only groups are renewed'
            $global:PimRequests.Count | Should Be 0
        }

        It 'counts only the statuses that mean in effect as done' {
            foreach ($status in @('Provisioned', 'Granted', 'ScheduleCreated')) { Get-PimRequestState -Status $status | Should Be 'Done' }
            foreach ($status in @('PendingApproval', 'PendingAdminDecision', 'PendingProvisioning', 'PendingScheduleCreation', 'Accepted', 'AdminApproved', 'SomethingNew', '')) { Get-PimRequestState -Status $status | Should Be 'Pending' }
            Get-PimRequestState -Status $null | Should Be 'Pending'
            foreach ($status in @('Denied', 'Failed', 'Canceled', 'Revoked', 'AdminDenied', 'TimedOut', 'Invalid', 'FailedAsResourceIsLocked')) { Get-PimRequestState -Status $status | Should Be 'Failed' }
        }

        It 'puts every count a reader must act on in the digest subject' {
            New-PimRenewalDigestSubject -Renewed 6 -Failed 0 -NeedDecision 4 | Should Be 'PIM eligibility renewal: 6 renewed, 0 failed, 4 need a decision'
            New-PimRenewalDigestSubject -Renewed 0 -Failed 0 -NeedDecision 0 -ReadFailures 1 | Should Be 'PIM eligibility renewal: 0 renewed, 0 failed, 0 need a decision, 1 could not be read'
            New-PimRenewalDigestSubject -Renewed 5 -Pending 1 -Failed 2 -NeedDecision 4 -ReadFailures 3 | Should Be 'PIM eligibility renewal: 5 renewed, 1 pending, 2 failed, 4 need a decision, 3 could not be read'
        }

        It 'lists reads that failed first in the digest, encoded' {
            $failure = [PSCustomObject]@{ Action = 'ReadSchedules'; Target = 'Azure scope "R&D <prod>"'; Detail = 'HTTP 403' }
            $html = New-PimRenewalDigestHtml -ReadFailures @($failure) -Renewals @() -Reviews @() -Skipped @() -RunId $runId -RenewWithinDays 14
            $html | Should Match 'Could not be read \(not scanned'
            $html | Should Match 'R&amp;D &lt;prod&gt;'
            $html.IndexOf('Could not be read') | Should BeLessThan $html.IndexOf('Group eligibilities extended or renewed')
            $clean = New-PimRenewalDigestHtml -Renewals @() -Reviews @() -Skipped @() -RunId $runId -RenewWithinDays 14
            $clean.Contains('Could not be read') | Should Be $false
        }

        It 'treats a denied request as a failure' {
            Set-TestTenant
            $global:PimRoutes.Clear()
            Add-TestRoute -Method POST -Like '*/roleEligibilityScheduleRequests' -Response (New-TestResponse -Status 201 -Json @{ id = 'r'; status = 'Denied' })
            Initialize-RunContext -RunbookName 'Invoke-PimEligibilityRenewal' -RunId $runId -AccessToken $tokens -DryRun $false
            $d = Get-PimRenewalDecision -Candidate (New-TestCandidate) @window -Rule $rule -RuleKnown $true
            { Invoke-PimRenewalRequest -Decision $d -Justification 'why' } | Should Throw 'status Denied'
            $global:PimRequests.Count | Should Be 1
        }
    }

    Context 'Azure scope helpers' {
        It 'reads the mg: and sub: prefixes and flags a GUID' {
            $mg = Split-PimAzureScopeName -Name 'mg:Platform'
            $mg.Kind | Should Be 'ManagementGroup'
            $mg.Value | Should Be 'Platform'
            $sub = Split-PimAzureScopeName -Name ' SUB: Identity Production '
            $sub.Kind | Should Be 'Subscription'
            $sub.Value | Should Be 'Identity Production'
            $auto = Split-PimAzureScopeName -Name $subscriptionId
            $auto.Kind | Should Be 'Auto'
            $auto.IsGuid | Should Be $true
            (Split-PimAzureScopeName -Name 'Platform').IsGuid | Should Be $false
            { Split-PimAzureScopeName -Name 'mg:' } | Should Throw 'no name after the prefix'
        }

        It 'keeps resource group schedules under a subscription and nothing else' {
            Test-PimScopeWithin -Scope $rgScope -TargetScope $subScope -TargetKind Subscription | Should Be $true
            Test-PimScopeWithin -Scope $subScope -TargetScope ($subScope + '/') -TargetKind Subscription | Should Be $true
            Test-PimScopeWithin -Scope $subScope.ToUpperInvariant() -TargetScope $subScope -TargetKind Subscription | Should Be $true
            Test-PimScopeWithin -Scope '/subscriptions/1000' -TargetScope '/subscriptions/1' -TargetKind Subscription | Should Be $false
            Test-PimScopeWithin -Scope $mgScope -TargetScope $subScope -TargetKind Subscription | Should Be $false
            Test-PimScopeWithin -Scope '' -TargetScope $subScope -TargetKind Subscription | Should Be $false
        }

        It 'keeps only the management group itself for a management group target' {
            Test-PimScopeWithin -Scope $mgScope -TargetScope $mgScope -TargetKind ManagementGroup | Should Be $true
            Test-PimScopeWithin -Scope '/providers/Microsoft.Management/managementGroups/mg-root' -TargetScope $mgScope -TargetKind ManagementGroup | Should Be $false
            Test-PimScopeWithin -Scope ($mgScope + '-child') -TargetScope $mgScope -TargetKind ManagementGroup | Should Be $false
        }

        It 'matches ARM roles by the GUID at the end of the definition id' {
            Get-PimArmRoleGuid -RoleDefinitionId ('{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $subScope, $rgRoleGuid.ToUpperInvariant()) | Should Be $rgRoleGuid
            Get-PimArmRoleGuid -RoleDefinitionId '' | Should Be ''
        }

        It 'maps an ARM schedule to a candidate' {
            $c = ConvertFrom-PimAzureSchedule -Schedule (New-TestArmSchedule -Name 'arm-rg' -Scope $rgScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'PIM Azure App Contributors' -EndDays 1 -Condition 'cond')
            $c.Plane | Should Be 'Azure'
            $c.PrincipalType | Should Be 'Group'
            $c.PrincipalName | Should Be 'PIM Azure App Contributors'
            $c.Scope | Should Be $rgScope
            $c.ScopeName | Should Be 'Scope arm-rg'
            $c.MemberType | Should Be 'Direct'
            $c.HasEnd | Should Be $true
            $c.End | Should Be $now.AddDays(1)
            $c.Condition | Should Be 'cond'
            $c.ScheduleId | Should Match 'RoleEligibilitySchedules/arm-rg$'
        }

        It 'treats an ARM schedule without an end date as permanent' {
            $schedule = New-TestArmSchedule -Name 'arm-perm' -Scope $subScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'G' -EndDays 1
            $schedule.properties.endDateTime = $null
            $c = ConvertFrom-PimAzureSchedule -Schedule $schedule
            $c.HasEnd | Should Be $false
            (Get-PimRenewalDecision -Candidate $c @window).Reason | Should Match 'permanent'
        }
    }

    # ---- the run, against the mocked tenant ---------------------------------

    Context 'run with a mocked tenant' {
        # The Azure plane is opt-in, so every full-tenant run switches it on.
        $common = @{ IncludeAzureResources = $true; AzureScopeNames = 'Platform'; AccessToken = $tokens; RunId = $runId; Now = $now }
        $rgRequestLike = '*/resourceGroups/rg-identity/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/*'
        $gatewayTimeout = @{ StatusCode = 504; Content = '{"error":{"code":"GatewayTimeout","message":"The gateway did not receive a response in time."}}'; Headers = @{} }

        It 'plans every due group renewal and writes nothing in a dry run' {
            Set-TestTenant
            $report = Join-Path -Path $TestDrive -ChildPath 'out\dry\pim.csv'
            $s = Invoke-PimEligibilityRenewalRun @common -ReportPath $report

            $global:PimUnexpected.Count | Should Be 0
            @(Get-TestWrites).Count | Should Be 0
            $s.Runbook | Should Be 'Invoke-PimEligibilityRenewal'
            $s.RunId | Should Be $runId
            $s.DryRun | Should Be $true
            $s.SchedulesScanned | Should Be 12
            $s.DirectorySchedules | Should Be 7
            $s.GroupSchedules | Should Be 2
            $s.AzureSchedules | Should Be 3
            $s.GroupsScanned | Should Be 1
            $s.AzureScopesScanned | Should Be 2
            $s.PlannedRenewals | Should Be 6
            $s.Planned | Should Be 6
            $s.Done | Should Be 0
            $s.Failed | Should Be 0
            $s.Counts.ExtendEligibility.Planned | Should Be 5
            $s.Counts.RenewEligibility.Planned | Should Be 1
            $s.ReviewCount | Should Be 4
            $s.Counts.ReviewEligibility.Skipped | Should Be 4
            $s.NotDueCount | Should Be 1
            $s.DueCount | Should Be 10
            $s.Renewed | Should Be 0
            $s.FollowUp | Should Be ''
            $s.DigestSent | Should Be $false
            $s.Errors | Should Be 0
            @($s.NeedsDecision).Count | Should Be 4
            foreach ($id in $individualIds) { @($s.NeedsDecision | Where-Object { $_.PrincipalId -eq $id }).Count | Should Be 1 }
            @($s.Renewals | Where-Object { $individualIds -contains $_.PrincipalId }).Count | Should Be 0
            @($s.Renewals | Where-Object { $_.Outcome -ne 'Planned' }).Count | Should Be 0

            Test-Path -Path $report | Should Be $true
            $rows = @(Import-Csv -Path $report)
            $rows.Count | Should Be 12
            @($rows | Where-Object { $_.Decision -eq 'Review' -and $_.Outcome -eq 'NeedsDecision' }).Count | Should Be 4
            @($rows | Where-Object { $_.Decision -eq 'Extend' -and $_.Outcome -eq 'Planned' }).Count | Should Be 5
        }

        It 'reads each policy once, and only for roles with a group renewal to make' {
            Set-TestTenant
            Invoke-PimEligibilityRenewalRun @common | Out-Null
            @($global:PimRequests | Where-Object { $_.Uri -like '*roleManagementPolicyAssignments*DirectoryRole*' }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Uri -like ('*roleManagementPolicyAssignments*{0}*' -f $pimGroupId) }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Uri -like '*/managementGroups/mg-platform/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01' }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Uri -like '*/resourceGroups/rg-identity/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01' }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Uri -like ('*/subscriptions/{0}/providers/Microsoft.Authorization/roleManagementPolicyAssignments*' -f $subscriptionId) }).Count | Should Be 0
        }

        It 'sends the documented list requests' {
            Set-TestTenant
            Invoke-PimEligibilityRenewalRun @common | Out-Null
            $uris = @($global:PimRequests | ForEach-Object { $_.Uri })
            ($uris -contains 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?$expand=principal,roleDefinition') | Should Be $true
            # .NET Framework leaves quotes and parentheses unescaped and .NET escapes them;
            # Graph takes either, so the expected text is built with the same call.
            $groupFilter = [Uri]::EscapeDataString(("groupId eq '{0}'" -f $pimGroupId))
            ($uris -contains ('https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilitySchedules?$filter={0}&$expand=principal' -f $groupFilter)) | Should Be $true
            ($uris -contains 'https://management.azure.com/providers/Microsoft.Management/managementGroups/mg-platform/descendants?api-version=2020-05-01') | Should Be $true
            ($uris -contains 'https://management.azure.com/providers/Microsoft.Management/managementGroups/mg-platform/providers/Microsoft.Authorization/roleEligibilitySchedules?$filter=atScope()&api-version=2020-10-01') | Should Be $true
            ($uris -contains ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleEligibilitySchedules?api-version=2020-10-01' -f $subscriptionId)) | Should Be $true
            $groupsCall = @($global:PimRequests | Where-Object { $_.Uri -like '*/v1.0/groups?*' })[0]
            $groupsCall.Headers['ConsistencyLevel'] | Should Be 'eventual'
            $groupsCall.Uri | Should Match 'isAssignableToRole%20eq%20true'
            $policyCall = @($global:PimRequests | Where-Object { $_.Uri -like '*roleManagementPolicyAssignments*DirectoryRole*' })[0]
            $expectedFilter = [Uri]::EscapeDataString(("scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '{0}'" -f $dirRoleId))
            $expectedExpand = [Uri]::EscapeDataString('policy($expand=rules)')
            $policyCall.Uri | Should Be ('https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?$filter={0}&$expand={1}' -f $expectedFilter, $expectedExpand)
            $groupPolicyFilter = [Uri]::EscapeDataString(("scopeId eq '{0}' and scopeType eq 'Group' and roleDefinitionId eq 'member'" -f $pimGroupId))
            ($uris -contains ('https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?$filter={0}&$expand={1}' -f $groupPolicyFilter, $expectedExpand)) | Should Be $true
        }

        It 'renews only groups, with policy-clamped end dates, when live' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false

            $global:PimUnexpected.Count | Should Be 0
            $writes = @(Get-TestWrites)
            $writes.Count | Should Be 6
            foreach ($write in $writes) {
                foreach ($id in $individualIds) { $write.Body.Contains($id) | Should Be $false }
            }

            $directory = @(Get-TestBodies -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests')
            $directory.Count | Should Be 3
            $ops = @($directory | Where-Object { $_.principalId -eq $opsGroupId })[0]
            $ops.action | Should Be 'adminExtend'
            $ops.roleDefinitionId | Should Be $dirRoleId
            $ops.directoryScopeId | Should Be '/'
            $ops.justification | Should Match $runId
            $ops.scheduleInfo.expiration.type | Should Be 'afterDateTime'
            (ConvertTo-PimUtcDateTime -Value $ops.scheduleInfo.startDateTime) | Should Be $now
            (ConvertTo-PimUtcDateTime -Value $ops.scheduleInfo.expiration.endDateTime) | Should Be $now.AddDays(180)
            $tier1 = @($directory | Where-Object { $_.principalId -eq $tier1GroupId })[0]
            $tier1.action | Should Be 'adminRenew'
            (ConvertTo-PimUtcDateTime -Value $tier1.scheduleInfo.expiration.endDateTime) | Should Be $now.AddDays(180)

            $groups = @(Get-TestBodies -Like '*/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests')
            $groups.Count | Should Be 1
            $groups[0].accessId | Should Be 'member'
            $groups[0].groupId | Should Be $pimGroupId
            $groups[0].principalId | Should Be $hop1GroupId
            $groups[0].action | Should Be 'adminExtend'
            (ConvertTo-PimUtcDateTime -Value $groups[0].scheduleInfo.expiration.endDateTime) | Should Be $now.AddDays(365)

            $arm = @($writes | Where-Object { $_.Method -eq 'PUT' })
            $arm.Count | Should Be 2
            $mgPut = @($arm | Where-Object { $_.Uri -like '*/managementGroups/mg-platform/*' })[0]
            $mgPut.Uri | Should Match '^https://management\.azure\.com/providers/Microsoft\.Management/managementGroups/mg-platform/providers/Microsoft\.Authorization/roleEligibilityScheduleRequests/[0-9a-f-]{36}\?api-version=2020-10-01$'
            $mgBody = ConvertFrom-Json -InputObject $mgPut.Body
            $mgBody.properties.requestType | Should Be 'AdminExtend'
            $mgBody.properties.principalId | Should Be $azureMgGroupId
            $mgBody.properties.scheduleInfo.expiration.type | Should Be 'AfterDateTime'
            (ConvertTo-PimUtcDateTime -Value $mgBody.properties.scheduleInfo.expiration.endDateTime) | Should Be $now.AddDays(365)
            $mgBody.properties.PSObject.Properties['condition'] | Should BeNullOrEmpty

            $rgPut = @($arm | Where-Object { $_.Uri -like '*/resourceGroups/rg-identity/*' })[0]
            $rgPut.Uri | Should Match ('^https://management\.azure\.com/subscriptions/{0}/resourceGroups/rg-identity/providers/Microsoft\.Authorization/roleEligibilityScheduleRequests/[0-9a-f-]{{36}}\?api-version=2020-10-01$' -f $subscriptionId)
            $rgBody = ConvertFrom-Json -InputObject $rgPut.Body
            $rgBody.properties.principalId | Should Be $azureRgGroupId
            $rgBody.properties.roleDefinitionId | Should Be ('{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $rgScope, $rgRoleGuid)
            (ConvertTo-PimUtcDateTime -Value $rgBody.properties.scheduleInfo.expiration.endDateTime) | Should Be $now.AddDays(90)
            $rgBody.properties.condition | Should Match 'StringEqualsIgnoreCase'
            $rgBody.properties.conditionVersion | Should Be '2.0'

            # Compared as booleans, so a failure never prints a bearer value.
            foreach ($write in $writes) {
                if ($write.Method -eq 'PUT') { (($write.Headers['Authorization'] -eq ('Bearer ' + $armToken))) | Should Be $true }
                else { (($write.Headers['Authorization'] -eq ('Bearer ' + $graphToken))) | Should Be $true }
            }

            $s.DryRun | Should Be $false
            $s.Done | Should Be 6
            $s.Renewed | Should Be 6
            $s.Failed | Should Be 0
            $s.Counts.ExtendEligibility.Done | Should Be 5
            $s.Counts.RenewEligibility.Done | Should Be 1
            $s.FollowUp | Should Match 'refresh-only'
            $s.FollowUp | Should Match 'Export-PimEligibilityImports\.ps1'
        }

        It 'records a failed renewal and carries on with the rest' {
            Set-TestTenant -FailTier1Renewal
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null
            @(Get-TestWrites).Count | Should Be 6
            $s.Done | Should Be 5
            $s.Failed | Should Be 1
            $s.Renewed | Should Be 5
            $s.Errors | Should Be 1
            $s.Counts.RenewEligibility.Failed | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'HTTP 400'
            @($s.Failures)[0].Detail | Should Match 'pending request already exists'
            @($s.Failures)[0].Target | Should Match 'PIM Tier1 Operators'
            @($s.Renewals | Where-Object { $_.Outcome -eq 'Failed' }).Count | Should Be 1
        }

        It 'stops before any write when the breaker trips' {
            Set-TestTenant
            { Invoke-PimEligibilityRenewalRun @common -DryRun $false -MaxRenewalsPerRun 5 -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 2>$null } | Should Throw 'Circuit breaker tripped: PIM eligibility renewals: 6 planned, cap is 5. Nothing was changed.'
            @(Get-TestWrites).Count | Should Be 0
        }

        It 'evaluates the breaker in a dry run too, and passes at the cap' {
            Set-TestTenant
            { Invoke-PimEligibilityRenewalRun @common -MaxRenewalsPerRun 0 2>$null } | Should Throw 'Circuit breaker tripped'
            $s = Invoke-PimEligibilityRenewalRun @common -MaxRenewalsPerRun 6
            $s.PlannedRenewals | Should Be 6
        }

        It 'leaves groups excluded by the pattern alone' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -PrincipalGroupNamePattern '*;!PIM TF *'
            $s.PlannedRenewals | Should Be 5
            $s.ExcludedCount | Should Be 1
            $s.Counts.ExcludedEligibility.Skipped | Should Be 1
            @(Get-TestBodies -Like '*/roleEligibilityScheduleRequests' | Where-Object { $_.principalId -eq $tfGroupId }).Count | Should Be 0
            @(Get-TestWrites).Count | Should Be 5
        }

        It 'renews only the groups an include pattern names' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun @common -PrincipalGroupNamePattern '["PIM Hop1*"]'
            $s.PlannedRenewals | Should Be 1
            $s.ExcludedCount | Should Be 5
            $s.PrincipalGroupNamePattern | Should Be 'PIM Hop1*'
            @($s.Renewals)[0].PrincipalId | Should Be $hop1GroupId
            @($global:PimRequests | Where-Object { $_.Uri -like '*roleManagementPolicyAssignments*' }).Count | Should Be 1
        }

        It 'skips the roles whose policy cannot be read and renews the rest' {
            Set-TestTenant -DirectoryPolicyStatus 403
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false
            $s.PlannedRenewals | Should Be 3
            $s.SkippedDueCount | Should Be 3
            $s.Counts.SkipEligibility.Skipped | Should Be 3
            $s.Warnings | Should BeGreaterThan 3
            @($global:PimRequests | Where-Object { $_.Uri -like '*roleManagementPolicyAssignments*DirectoryRole*' }).Count | Should Be 1
            @(Get-TestWrites | Where-Object { $_.Uri -like '*/roleManagement/directory/*' }).Count | Should Be 0
            @(Get-TestWrites).Count | Should Be 3
        }

        It 'mails the digest when live' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -Recipients '["iam@corp.example.com","pim-owners@corp.example.com"]' -SenderMailbox 'iam-noreply@corp.example.com'
            $mail = @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })
            $mail.Count | Should Be 1
            $mail[0].Uri | Should Be 'https://graph.microsoft.com/v1.0/users/iam-noreply%40corp.example.com/sendMail'
            $message = (ConvertFrom-Json -InputObject $mail[0].Body).message
            @($message.toRecipients).Count | Should Be 2
            $message.subject | Should Be 'PIM eligibility renewal: 6 renewed, 0 failed, 4 need a decision'
            $message.body.contentType | Should Be 'HTML'
            $message.body.content | Should Match 'Alex Example'
            $message.body.content | Should Match 'need a decision'
            $message.body.content | Should Match 'refresh-only'
            $s.DigestSent | Should Be $true
            $s.Counts.SendDigest.Done | Should Be 1
            $s.Done | Should Be 7
        }

        It 'only logs the digest in a dry run' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun @common -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com'
            @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' }).Count | Should Be 0
            $s.DigestSent | Should Be $false
            $s.Counts.SendDigest.Planned | Should Be 1
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Would send the renewal digest to iam@corp.example.com.' }).Count | Should Be 1
        }

        It 'sends no digest when nothing is due' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun -AccessToken $tokens -RunId $runId -Now $now.AddDays(-200) -IncludeAzureResources $false -IncludeGroups $false -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com'
            $s.DueCount | Should Be 0
            @(Get-TestWrites).Count | Should Be 0
            $s.DigestSent | Should Be $false
        }

        It 'scans a subscription named with the sub: prefix, without descendants' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun -IncludeAzureResources $true -AzureScopeNames 'sub:Identity Production' -IncludeDirectoryRoles $false -IncludeGroups $false -AccessToken $tokens -RunId $runId -Now $now
            $s.AzureScopesScanned | Should Be 1
            $s.AzureSchedules | Should Be 2
            $s.PlannedRenewals | Should Be 1
            $s.ReviewCount | Should Be 1
            @($global:PimRequests | Where-Object { $_.Uri -like '*descendants*' -or $_.Uri -like '*managementGroups?api-version*' }).Count | Should Be 0
        }

        It 'records an Azure scope name that matches nothing and carries on' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun -IncludeAzureResources $true -AzureScopeNames 'Nowhere' -AccessToken $tokens -RunId $runId -Now $now 2>$null
            $s.Failed | Should Be 1
            $s.Counts.ReadSchedules.Failed | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'matched no management group'
            $s.PlannedRenewals | Should Be 4
            $s.AzureScopesScanned | Should Be 0
        }

        It 'warns and skips the Azure plane when it is on but no scope is named' {
            Set-TestTenant
            $s = Invoke-PimEligibilityRenewalRun -IncludeAzureResources $true -AccessToken $tokens -RunId $runId -Now $now
            $s.AzureScopesScanned | Should Be 0
            $s.PlannedRenewals | Should Be 4
            @($global:PimRequests | Where-Object { $_.Uri -like 'https://management.azure.com/*' }).Count | Should Be 0
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*AzureScopeNames is empty*' }).Count | Should Be 1
        }

        It 'leaves the Azure plane off by default, and says so when scopes were named' {
            Set-TestTenant
            # A Graph-only token string: the default run must never ask for an ARM token.
            $quiet = Invoke-PimEligibilityRenewalRun -AccessToken 'graph-only-token-0000' -RunId $runId -Now $now
            $quiet.AzureScopesScanned | Should Be 0
            $quiet.AzureSchedules | Should Be 0
            $quiet.PlannedRenewals | Should Be 4
            $quiet.Errors | Should Be 0
            $quiet.ReviewCount | Should Be 3
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*AzureScopeNames*' }).Count | Should Be 0
            @($global:PimRequests | Where-Object { $_.Uri -like 'https://management.azure.com/*' }).Count | Should Be 0

            Set-TestTenant
            $named = Invoke-PimEligibilityRenewalRun -AzureScopeNames 'mg:mg-platform;sub:Identity Production' -AccessToken $tokens -RunId $runId -Now $now
            $named.AzureScopesScanned | Should Be 0
            $named.PlannedRenewals | Should Be 4
            @($global:PimRequests | Where-Object { $_.Uri -like 'https://management.azure.com/*' }).Count | Should Be 0
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'AzureScopeNames names 2 scope(s) but IncludeAzureResources is false*' }).Count | Should Be 1
        }

        It 'uses the US Government endpoints' {
            Set-TestTenant -Environment USGov
            $s = Invoke-PimEligibilityRenewalRun @common -Environment USGov -DryRun $false
            $global:PimUnexpected.Count | Should Be 0
            $s.Environment | Should Be 'USGov'
            $s.Done | Should Be 6
            @($global:PimRequests | Where-Object { $_.Uri -notlike 'https://graph.microsoft.us/v1.0/*' -and $_.Uri -notlike 'https://management.usgovcloudapi.net/*' }).Count | Should Be 0
        }

        It 'never writes a token to the log, the summary, the digest, or the report, even when the service echoes one' {
            # Assertions use Contains and booleans, so a failure prints no token.
            Set-TestTenant
            $echo = '{"error":{"code":"InvalidRequest","message":"Rejected: the caller sent Bearer ' + $graphToken + ' with access_token=' + $graphToken + ' and ' + $armToken + '"}}'
            Add-TestRoute -First -Method POST -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -BodyLike ('*{0}*' -f $tier1GroupId) -Response (New-TestResponse -Status 400 -Text $echo)
            $report = Join-Path -Path $TestDrive -ChildPath 'out\token\pim.csv'
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' -ReportPath $report 2>$null
            $s.Failed | Should Be 1
            $secrets = @($graphToken, $armToken, 'eyJ')

            $detail = [string]@($s.Failures)[0].Detail
            $detail.Contains('[redacted') | Should Be $true
            foreach ($secret in $secrets) { $detail.Contains($secret) | Should Be $false }

            $row = @($s.Renewals | Where-Object { $_.PrincipalId -eq $tier1GroupId })[0]
            ([string]$row.Error).Contains('[redacted') | Should Be $true
            foreach ($secret in $secrets) { ([string]$row.Error).Contains($secret) | Should Be $false }

            $logText = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
            $logText.Contains('[redacted') | Should Be $true
            foreach ($secret in $secrets) { $logText.Contains($secret) | Should Be $false }

            $mail = @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })
            $mail.Count | Should Be 1
            $mailBody = [string](ConvertFrom-Json -InputObject $mail[0].Body).message.body.content
            $mailBody.Contains('[redacted') | Should Be $true
            foreach ($secret in $secrets) { $mailBody.Contains($secret) | Should Be $false }

            $csv = [System.IO.File]::ReadAllText($report)
            $csv.Contains('[redacted') | Should Be $true
            foreach ($secret in $secrets) { $csv.Contains($secret) | Should Be $false }

            $summaryText = ConvertTo-Json -InputObject $s -Depth 10
            foreach ($secret in $secrets) { $summaryText.Contains($secret) | Should Be $false }
            @($global:PimRequests | Where-Object { $_.Body.Contains($graphToken) -or $_.Body.Contains($armToken) }).Count | Should Be 0
            (Get-RunContext).HasSuppliedToken | Should Be $true
        }

        It 'mails the read failures, with the count in the subject, when a plane could not be read' {
            Set-TestTenant
            Add-TestRoute -First -Like '*/v1.0/roleManagement/directory/roleEligibilitySchedules?*' -Response (New-TestResponse -Status 403 -Text '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}')
            $s = Invoke-PimEligibilityRenewalRun -IncludeGroups $false -IncludeAzureResources $false -AccessToken $tokens -RunId $runId -Now $now -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 2>$null
            $s.Failed | Should Be 1
            $s.ReadFailures | Should Be 1
            $s.DirectorySchedules | Should Be 0
            $s.PlannedRenewals | Should Be 0
            $s.DigestSent | Should Be $true
            $mail = @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })
            $mail.Count | Should Be 1
            $message = (ConvertFrom-Json -InputObject $mail[0].Body).message
            $message.subject | Should Be 'PIM eligibility renewal: 0 renewed, 0 failed, 0 need a decision, 1 could not be read'
            $message.body.content | Should Match 'Could not be read \(not scanned[^<]*\) \(1\)</h3>'
            $message.body.content | Should Match 'directory role eligibility schedules'
            $message.body.content | Should Match 'HTTP 403'
            $message.body.content | Should Match 'Insufficient privileges'
        }

        It 'lists a failed read ahead of the renewals that did happen' {
            Set-TestTenant
            Add-TestRoute -First -Like '*/v1.0/roleManagement/directory/roleEligibilitySchedules?*' -Response (New-TestResponse -Status 403 -Text '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges."}}')
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 2>$null
            $s.Renewed | Should Be 3
            $s.ReadFailures | Should Be 1
            $message = (ConvertFrom-Json -InputObject @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })[0].Body).message
            $message.subject | Should Be 'PIM eligibility renewal: 3 renewed, 0 failed, 2 need a decision, 1 could not be read'
            $content = [string]$message.body.content
            $content.IndexOf('Could not be read') | Should BeLessThan $content.IndexOf('Group eligibilities extended or renewed')
        }

        It 'keeps scanning the groups that resolved when a GroupScopeNames entry does not' {
            Set-TestTenant
            Add-TestRoute -Like '*/v1.0/groups?*displayName*Helpdesk*' -Response (New-TestResponse -Json @{ value = @([PSCustomObject]@{ id = $tier1GroupId; displayName = 'PIM Helpdesk Operators' }) })
            Add-TestRoute -Like '*/v1.0/groups?*displayName*Missing*' -Response (New-TestResponse -Json @{ value = @() })
            Add-TestRoute -First -Like ('*/identityGovernance/privilegedAccess/group/eligibilitySchedules?*{0}*' -f $tier1GroupId) -Response (New-TestResponse -Json @{ value = @() })
            $s = Invoke-PimEligibilityRenewalRun -GroupScopeNames 'PIM Missing Group;PIM Helpdesk Operators' -IncludeDirectoryRoles $false -IncludeAzureResources $false -AccessToken $tokens -RunId $runId -Now $now 2>$null
            $global:PimUnexpected.Count | Should Be 0
            $s.GroupsScanned | Should Be 2
            $s.GroupSchedules | Should Be 2
            $s.PlannedRenewals | Should Be 1
            $s.ReadFailures | Should Be 1
            $s.Counts.ReadSchedules.Failed | Should Be 1
            @($s.Failures)[0].Target | Should Be 'GroupScopeNames entry "PIM Missing Group"'
            @($s.Failures)[0].Detail | Should Match 'was not found'
            @($global:PimRequests | Where-Object { $_.Uri -like ('*/eligibilitySchedules?*{0}*' -f $tier1GroupId) }).Count | Should Be 1
        }

        It 'still scans the named groups when the role-assignable query fails' {
            Set-TestTenant
            Add-TestRoute -First -Like '*/v1.0/groups?*isAssignableToRole*' -Response (New-TestResponse -Status 403 -Text '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges."}}')
            Add-TestRoute -Like '*/v1.0/groups?*displayName*Helpdesk*' -Response (New-TestResponse -Json @{ value = @([PSCustomObject]@{ id = $pimGroupId; displayName = 'PIM Helpdesk Operators' }) })
            $s = Invoke-PimEligibilityRenewalRun -GroupScopeNames '["PIM Helpdesk Operators"]' -IncludeDirectoryRoles $false -IncludeAzureResources $false -AccessToken $tokens -RunId $runId -Now $now 2>$null
            $s.GroupsScanned | Should Be 1
            $s.GroupSchedules | Should Be 2
            $s.PlannedRenewals | Should Be 1
            $s.ReadFailures | Should Be 1
            @($s.Failures)[0].Target | Should Match 'role-assignable groups'
            @($s.Failures)[0].Detail | Should Match 'HTTP 403'
        }

        It 'sends a renewal POST once when the service answers 5xx, and says it may have been applied' {
            Set-TestTenant
            Add-TestRoute -First -Method POST -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -BodyLike ('*{0}*' -f $tier1GroupId) -Response $gatewayTimeout
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 2>$null 3>$null
            @(Get-TestWrites | Where-Object { $_.Body -like ('*{0}*' -f $tier1GroupId) }).Count | Should Be 1
            @(Get-TestWrites | Where-Object { $_.Uri -notlike '*/sendMail' }).Count | Should Be 6
            @($global:PimRequests | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like '*roleEligibilityScheduleRequests*' }).Count | Should Be 0
            $s.Failed | Should Be 1
            $s.Renewed | Should Be 5
            $s.RenewalFailures | Should Be 1
            $s.UncertainRenewals | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'HTTP 504 after 1 attempt'
            @($s.Failures)[0].Detail | Should Match 'POST is not repeated automatically after a server error or a lost response because it may already have been applied'
            $row = @($s.Renewals | Where-Object { $_.PrincipalId -eq $tier1GroupId })[0]
            $row.Outcome | Should Be 'Failed'
            $row.MayHaveBeenApplied | Should Be $true
            $row.Error | Should Match 'check the target before sending it again'
            @($s.Renewals | Where-Object { $_.MayHaveBeenApplied }).Count | Should Be 1
            $s.FollowUp | Should Match '^5 eligibility schedule\(s\) were renewed'
            $s.FollowUp | Should Match '1 failed renewal request\(s\) got a server error or no response and may have been applied'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '1 failed renewal request(s)*may have been applied*' }).Count | Should Be 1
            $message = (ConvertFrom-Json -InputObject @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })[0].Body).message
            $message.subject | Should Be 'PIM eligibility renewal: 5 renewed, 1 failed, 4 need a decision'
            $message.body.content | Should Match 'May have been applied: '
        }

        It 'sends a renewal POST once when no response came back' {
            Set-TestTenant
            Add-TestRoute -First -Method POST -Like '*/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests' -Response @{ Throw = 'The operation has timed out.' }
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null 3>$null
            @(Get-TestWrites | Where-Object { $_.Uri -like '*/group/eligibilityScheduleRequests' }).Count | Should Be 1
            $s.Failed | Should Be 1
            $s.Renewed | Should Be 5
            $s.UncertainRenewals | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'failed without an HTTP response after 1 attempt'
            @($s.Failures)[0].Detail | Should Match 'may already have been applied'
            @($s.Renewals | Where-Object { $_.PrincipalId -eq $hop1GroupId })[0].MayHaveBeenApplied | Should Be $true
        }

        It 'does not flag a plainly refused renewal as possibly applied' {
            Set-TestTenant -FailTier1Renewal
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null
            $s.RenewalFailures | Should Be 1
            $s.UncertainRenewals | Should Be 0
            @($s.Renewals | Where-Object { $_.MayHaveBeenApplied }).Count | Should Be 0
            $s.FollowUp | Should Not Match 'may have been applied'
            @($s.Failures)[0].Detail | Should Not Match 'may already have been applied'
        }

        It 'retries a renewal POST that was throttled' {
            Set-TestTenant
            $throttled = New-TestResponse -Status 429 -Text '{"error":{"code":"TooManyRequests","message":"Too many requests."}}'
            $accepted = New-TestResponse -Status 201 -Json @{ id = 'req-group'; status = 'Provisioned' }
            Add-TestRoute -First -Method POST -Like '*/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleRequests' -Sequence @($throttled, $accepted)
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 3>$null
            @(Get-TestWrites | Where-Object { $_.Uri -like '*/group/eligibilityScheduleRequests' }).Count | Should Be 2
            $s.Renewed | Should Be 6
            $s.Failed | Should Be 0
            $s.UncertainRenewals | Should Be 0
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'Graph POST */group/eligibilityScheduleRequests returned HTTP 429; retrying*attempt 1 of 5*' }).Count | Should Be 1
        }

        It 'reads an ARM request back by name when its PUT kept failing, and takes the recorded status' {
            Set-TestTenant
            Add-TestRoute -First -Method PUT -Like $rgRequestLike -Response $gatewayTimeout
            Add-TestRoute -First -Like $rgRequestLike -Response (New-TestResponse -Json @{ name = 'read-back'; properties = @{ status = 'Provisioned'; requestType = 'AdminExtend' } })
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 3>$null
            $global:PimUnexpected.Count | Should Be 0
            $puts = @(Get-TestWrites | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like $rgRequestLike })
            $puts.Count | Should Be 5
            @($puts | Select-Object -ExpandProperty Uri -Unique).Count | Should Be 1
            $reads = @($global:PimRequests | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like $rgRequestLike })
            $reads.Count | Should Be 1
            $reads[0].Uri | Should Be $puts[0].Uri
            $s.Renewed | Should Be 6
            $s.Failed | Should Be 0
            $s.UncertainRenewals | Should Be 0
            $row = @($s.Renewals | Where-Object { $_.PrincipalId -eq $azureRgGroupId })[0]
            $row.Outcome | Should Be 'Done'
            $row.RequestStatus | Should Be 'Provisioned'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like ('ARM PUT of eligibility request * at {0} failed (HTTP 504 after 5 attempt(s)), but PIM has the request with status "Provisioned"*' -f $rgScope) }).Count | Should Be 1
        }

        It 'reads an ARM request back after a lost response, and fails plainly when PIM never created it' {
            Set-TestTenant
            Add-TestRoute -First -Method PUT -Like $rgRequestLike -Response @{ Throw = 'Unable to connect to the remote server.' }
            Add-TestRoute -First -Like $rgRequestLike -Response (New-TestResponse -Status 404 -Text '{"error":{"code":"RoleEligibilityScheduleRequestNotFound","message":"Not found."}}')
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null 3>$null
            @(Get-TestWrites | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like $rgRequestLike }).Count | Should Be 5
            @($global:PimRequests | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like $rgRequestLike }).Count | Should Be 1
            $s.Failed | Should Be 1
            $s.Renewed | Should Be 5
            $s.UncertainRenewals | Should Be 0
            @($s.Failures)[0].Detail | Should Match 'Arm PUT .* failed without an HTTP response after 5 attempt'
            @($s.Failures)[0].Detail | Should Not Match 'may have been applied'
            $s.FollowUp | Should Not Match 'may have been applied'
        }

        It 'marks an ARM renewal as possibly applied when the request cannot be read back either' {
            Set-TestTenant
            Add-TestRoute -First -Method PUT -Like $rgRequestLike -Response $gatewayTimeout
            Add-TestRoute -First -Like $rgRequestLike -Response (New-TestResponse -Status 403 -Text '{"error":{"code":"AuthorizationFailed","message":"No read access."}}')
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null 3>$null
            $s.Failed | Should Be 1
            $s.UncertainRenewals | Should Be 1
            $row = @($s.Renewals | Where-Object { $_.PrincipalId -eq $azureRgGroupId })[0]
            $row.Outcome | Should Be 'Failed'
            $row.MayHaveBeenApplied | Should Be $true
            $row.Error | Should Match 'HTTP 504 after 5 attempt'
            $row.Error | Should Match 'reading it back by name failed too \(HTTP 403 AuthorizationFailed\)\. Check the eligibility in PIM before sending it again\.$'
            @($s.Failures)[0].Detail | Should Be $row.Error
            $s.FollowUp | Should Match '1 failed renewal request\(s\)'
        }

        It 'takes a failed status from an ARM request it read back' {
            Set-TestTenant
            Add-TestRoute -First -Method PUT -Like $rgRequestLike -Response $gatewayTimeout
            Add-TestRoute -First -Like $rgRequestLike -Response (New-TestResponse -Json @{ name = 'read-back'; properties = @{ status = 'Denied' } })
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null 3>$null
            $s.Failed | Should Be 1
            $s.UncertainRenewals | Should Be 0
            @($s.Renewals | Where-Object { $_.PrincipalId -eq $azureRgGroupId })[0].Error | Should Match 'status Denied'
        }

        It 'does not read an ARM request back when the first PUT was refused' {
            Set-TestTenant
            Add-TestRoute -First -Method PUT -Like $rgRequestLike -Response (New-TestResponse -Status 400 -Text '{"error":{"code":"InvalidRequest","message":"Justification is required."}}')
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false 2>$null
            @(Get-TestWrites | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like $rgRequestLike }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like '*roleEligibilityScheduleRequests*' }).Count | Should Be 0
            $s.Failed | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'HTTP 400 after 1 attempt'
            $s.UncertainRenewals | Should Be 0
        }

        It 'reports a request that PIM has not applied yet as pending, not renewed' {
            Set-TestTenant
            Add-TestRoute -First -Method POST -Like '*/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -BodyLike ('*{0}*' -f $opsGroupId) -Response (New-TestResponse -Status 201 -Json @{ id = 'req-dir-ops'; status = 'PendingApproval' })
            Add-TestRoute -First -Method PUT -Like '*/resourceGroups/rg-identity/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/*' -Response (New-TestResponse -Status 201 -Json @{ properties = @{ status = 'Accepted' } })
            $s = Invoke-PimEligibilityRenewalRun @common -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 3>$null
            @(Get-TestWrites | Where-Object { $_.Uri -notlike '*/sendMail' }).Count | Should Be 6
            $s.Renewed | Should Be 4
            $s.Pending | Should Be 2
            $s.Failed | Should Be 0
            $s.Counts.ExtendEligibility.Done | Should Be 5
            $s.FollowUp | Should Match '^4 eligibility schedule'
            $ops = @($s.Renewals | Where-Object { $_.PrincipalId -eq $opsGroupId })[0]
            $ops.Outcome | Should Be 'Pending'
            $ops.RequestStatus | Should Be 'PendingApproval'
            $rg = @($s.Renewals | Where-Object { $_.PrincipalId -eq $azureRgGroupId })[0]
            $rg.Outcome | Should Be 'Pending'
            $rg.RequestStatus | Should Be 'Accepted'
            @($s.Renewals | Where-Object { $_.Outcome -eq 'Done' }).Count | Should Be 4
            $message = (ConvertFrom-Json -InputObject @($global:PimRequests | Where-Object { $_.Uri -like '*/sendMail' })[0].Body).message
            $message.subject | Should Be 'PIM eligibility renewal: 4 renewed, 2 pending, 0 failed, 4 need a decision'
            $message.body.content | Should Match 'PendingApproval'
            $message.body.content | Should Match 'has not applied it'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*status PendingApproval*' }).Count | Should Be 1
        }

        It 'does not renew a group with no readable name when the pattern excludes something' {
            Set-TestTenant
            $unnamed = New-TestArmSchedule -Name 'arm-unnamed' -Scope $rgScope -RoleGuid $rgRoleGuid -PrincipalId $azureRgGroupId -PrincipalType 'Group' -PrincipalName 'unused' -EndDays 1
            $unnamed.properties.expandedProperties.principal = $null
            Add-TestRoute -First -Like ('*/subscriptions/{0}/providers/Microsoft.Authorization/roleEligibilitySchedules?*' -f $subscriptionId) -Response (New-TestResponse -Json @{ value = @($unnamed) })
            $scan = @{ IncludeAzureResources = $true; AzureScopeNames = 'sub:Identity Production'; IncludeDirectoryRoles = $false; IncludeGroups = $false; AccessToken = $tokens; RunId = $runId; Now = $now }

            $s = Invoke-PimEligibilityRenewalRun @scan -DryRun $false -PrincipalGroupNamePattern '*;!PIM TF *' 3>$null
            @(Get-TestWrites).Count | Should Be 0
            $s.PlannedRenewals | Should Be 0
            $s.SkippedDueCount | Should Be 1
            $s.Counts.SkipEligibility.Skipped | Should Be 1
            @($s.Items | Where-Object { $_.Action -eq 'SkipEligibility' })[0].Detail | Should Match 'display name could not be read'
            @($global:PimRequests | Where-Object { $_.Uri -like '*roleManagementPolicyAssignments*' }).Count | Should Be 0

            $all = Invoke-PimEligibilityRenewalRun @scan -PrincipalGroupNamePattern '*'
            $all.PlannedRenewals | Should Be 1
        }

        It 'refuses bad parameters before reading anything' {
            Set-TestTenant
            { Invoke-PimEligibilityRenewalRun @common -Recipients 'iam@corp.example.com' } | Should Throw 'SenderMailbox'
            { Invoke-PimEligibilityRenewalRun @common -Recipients 'not-an-address' -SenderMailbox 'iam-noreply@corp.example.com' } | Should Throw 'not a mail address'
            { Invoke-PimEligibilityRenewalRun -IncludeDirectoryRoles $false -IncludeGroups $false -IncludeAzureResources $false -AzureScopeNames 'Platform' -AccessToken $tokens -RunId $runId -Now $now } | Should Throw 'nothing to renew'
            { Invoke-PimEligibilityRenewalRun -IncludeDirectoryRoles $false -IncludeGroups $false -AccessToken $tokens -RunId $runId -Now $now } | Should Throw 'nothing to renew'
            { Invoke-PimEligibilityRenewalRun -AzureScopeNames '["Platform",' -AccessToken $tokens -RunId $runId -Now $now } | Should Throw 'AzureScopeNames looks like a JSON array'
            { Invoke-PimEligibilityRenewalRun @common -RenewWithinDays 0 } | Should Throw
            { Invoke-PimEligibilityRenewalRun @common -PrincipalGroupNamePattern '!' } | Should Throw 'excludes nothing'
            { Invoke-PimEligibilityRenewalRun @common -PrincipalGroupNamePattern '[]' } | Should Throw 'holds no pattern'
            { Invoke-PimEligibilityRenewalRun @common -PrincipalGroupNamePattern ';' } | Should Throw 'holds no pattern'
            $global:PimRequests.Count | Should Be 0
        }
    }

    # ---- the inline contract ------------------------------------------------

    Context 'runbook contract' {
        $begin = '# INLINE_LIBRARY_BEGIN'
        $end = '# INLINE_LIBRARY_END'
        $runbookText = [System.IO.File]::ReadAllText($runbook)
        $libraryText = [System.IO.File]::ReadAllText($library)
        $tokensOut = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($runbookText, [ref]$tokensOut, [ref]$parseErrors)

        It 'parses, is ASCII, and has no byte order mark' {
            @($parseErrors).Count | Should Be 0
            $bytes = [System.IO.File]::ReadAllBytes($runbook)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            $runbookText.Contains([string][char]0x2013) | Should Be $false
            $runbookText.Contains([string][char]0x2014) | Should Be $false
        }

        It 'carries each marker exactly once, around the dot-source line, at column 0' {
            $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
            $block = $begin + "`n" + ". (Join-Path -Path `$PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')" + "`n" + $end
            $runbookText.Replace("`r`n", "`n").Contains("`n" + $block + "`n") | Should Be $true
            $moduleText = [System.IO.File]::ReadAllText($runbooksModule)
            $moduleText.Contains(('library_begin = "{0}"' -f $begin)) | Should Be $true
            $moduleText.Contains(('library_end   = "{0}"' -f $end)) | Should Be $true
        }

        It 'declares only bool, int, and string parameters, with DryRun on by default' {
            $parameters = @($ast.ParamBlock.Parameters)
            $parameters.Count | Should Be 17
            $badTypes = @($parameters | Where-Object { @('System.Boolean', 'System.Int32', 'System.String') -notcontains $_.StaticType.FullName } | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($badTypes -join ', ') | Should Be ''
            $dryRun = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' })[0]
            $dryRun.StaticType.FullName | Should Be 'System.Boolean'
            $dryRun.DefaultValue.Extent.Text | Should Be '$true'
            # The Azure plane is opt-in, in the entry point and in the run function.
            $azure = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IncludeAzureResources' })[0]
            $azure.StaticType.FullName | Should Be 'System.Boolean'
            $azure.DefaultValue.Extent.Text | Should Be '$false'
            $runFunction = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PimEligibilityRenewalRun' }, $true))[0]
            $runAzure = @($runFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IncludeAzureResources' })[0]
            $runAzure.DefaultValue.Extent.Text | Should Be '$false'
            foreach ($name in @('Environment', 'ClientId', 'AccessToken', 'RunId', 'AzureScopeNames', 'Recipients', 'PrincipalGroupNamePattern')) {
                @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name -and $_.StaticType.FullName -eq 'System.String' }).Count | Should Be 1
            }
        }

        It 'documents every parameter and shows a local run with -AccessToken' {
            foreach ($parameter in @($ast.ParamBlock.Parameters)) {
                $runbookText.Contains('.PARAMETER ' + $parameter.Name.VariablePath.UserPath) | Should Be $true
            }
            $help = $ast.GetHelpContent()
            $help.Synopsis | Should Not BeNullOrEmpty
            @($help.Examples | Where-Object { $_ -match '-AccessToken \$token' }).Count | Should BeGreaterThan 0
            $runbookText | Should Match 'Export-PimEligibilityImports\.ps1'
            $runbookText | Should Match 'refresh-only'
            # Local examples may show a JSON array; the schedule example must not.
            @($help.Examples | Where-Object { $_ -match 'job schedule' -and $_ -match "'\[" }).Count | Should Be 0
        }

        It 'states the Azure roles the corp cell grants, never User Access Administrator, and calls the write permissions tier 0' {
            $help = [string]$ast.GetHelpContent().Description
            $help | Should Match 'Reader\s+eligibility schedules'
            $help | Should Match 'PIM Policy and Eligibility Operator\s+custom role'
            $help | Should Match 'roleEligibilityScheduleRequests/write'
            $help | Should Match 'Never User Access Administrator or Owner\.'
            # Every mention of User Access Administrator is inside that refusal.
            $mentions = @([regex]::Matches($help, 'User Access Administrator')).Count
            $mentions | Should Be 1
            $help | Should Match 'These write permissions are tier 0\.'
            $help | Should Match 'RoleEligibilitySchedule\.ReadWrite\.Directory does\s+the same'
            $help | Should Match 'PrivilegedEligibilitySchedule\.ReadWrite\.AzureADGroup for membership'
            $help | Should Match 'code controls in this file, not platform\s+controls'
            $help | Should Match 'daily at 03:30 UTC'
            # The corp cell does not hold the eligibility role, and the header
            # must not claim it does.
            $help | Should Match 'Nothing in that cell holds PIM Policy and Eligibility Operator'
            $help | Should Not Match 'the corp cell assigns both at the'
            $cellPath = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'
            $cellText = [System.IO.File]::ReadAllText($cellPath)
            $pimTier = [regex]::Match($cellText, '(?ms)^    pim = \{(?<body>.*?)^    \}')
            $pimTier.Success | Should Be $true
            $assignedRoles = @([regex]::Matches($pimTier.Groups['body'].Value, 'role_name\s*=\s*"(?<role>[^"]+)"') | ForEach-Object { $_.Groups['role'].Value })
            ($assignedRoles -contains 'PIM Policy and Eligibility Operator') | Should Be $false
            ($assignedRoles -join ', ') | Should Be 'Reader, PIM Policy Operator'
        }

        It 'shows a stack cell entry that matches the corp cell, in the semicolon list form' {
            $cellPath = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'
            $cellText = [System.IO.File]::ReadAllText($cellPath).Replace("`r`n", "`n")
            $helpText = $runbookText.Replace("`r`n", "`n")
            $entryPattern = '(?s)\n[ ]*pim-eligibility-renewal = \{\n(?<head>.*?)\n[ ]*parameters = \{\n(?<body>.*?)\n[ ]*\}\n'
            $sample = [regex]::Match($helpText, $entryPattern)
            $cell = [regex]::Match($cellText, $entryPattern)
            $sample.Success | Should Be $true
            $cell.Success | Should Be $true

            $scheduleKeyPattern = 'schedule_key\s*=\s*"(?<key>[^"]+)"'
            $sampleSchedule = [regex]::Match($sample.Groups['head'].Value, $scheduleKeyPattern).Groups['key'].Value
            $sampleSchedule | Should Be 'daily-0330-utc'
            $sampleSchedule | Should Be ([regex]::Match($cell.Groups['head'].Value, $scheduleKeyPattern).Groups['key'].Value)
            $cellText.Contains(("`n    {0} = {{`n      name        = ""{0}""" -f $sampleSchedule)) | Should Be $true
            $cellText | Should Match ('start_time\s*=\s*"[0-9-]+T03:30:00Z"')

            $keyPattern = '(?m)^[ ]*(?<key>[a-z]+)[ ]*='
            $sampleKeys = @([regex]::Matches($sample.Groups['body'].Value, $keyPattern) | ForEach-Object { $_.Groups['key'].Value })
            $cellKeys = @([regex]::Matches($cell.Groups['body'].Value, $keyPattern) | ForEach-Object { $_.Groups['key'].Value })
            $sampleKeys.Count | Should BeGreaterThan 5
            $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() })
            foreach ($key in $sampleKeys) {
                ($cellKeys -contains $key) | Should Be $true
                ($parameterNames -contains $key) | Should Be $true
            }
            foreach ($key in @('includeazureresources', 'azurescopenames', 'principalgroupnamepattern', 'recipients')) { ($sampleKeys -contains $key) | Should Be $true }
            # The Azure plane is the Owner-equivalent switch, so the sample
            # shows what the cell ships, not the opt-in form.
            $planePattern = 'includeazureresources\s*=\s*"(?<value>[a-z]+)"'
            $samplePlane = [regex]::Match($sample.Groups['body'].Value, $planePattern).Groups['value'].Value
            $samplePlane | Should Be 'false'
            $samplePlane | Should Be ([regex]::Match($cell.Groups['body'].Value, $planePattern).Groups['value'].Value)
            $helpText | Should Match 'Setting includeazureresources to "true" is not a one-line\s+change'
            $helpText | Should Not Match 'the Azure\s+plane is switched on here'
            # And it names the tier it runs as, as the cell does.
            $identityPattern = 'identity_key\s*=\s*"(?<key>[^"]+)"'
            $sampleIdentity = [regex]::Match($sample.Groups['head'].Value, $identityPattern).Groups['key'].Value
            $sampleIdentity | Should Be 'pim'
            $sampleIdentity | Should Be ([regex]::Match($cell.Groups['head'].Value, $identityPattern).Groups['key'].Value)
            $sample.Groups['body'].Value | Should Match 'principalgroupnamepattern\s*=\s*join\(";",'
            $sample.Groups['body'].Value | Should Match 'azurescopenames\s*=\s*join\(";",'
            $sample.Groups['body'].Value | Should Match 'recipients\s*=\s*join\(";",'
            $sample.Value.Contains('jsonencode') | Should Be $false
            $sample.Value.Contains('\"') | Should Be $false
            $sample.Value.Contains('["[') | Should Be $false
        }

        It 'sends every write through the library without opting a POST into repeats' {
            $cloudCalls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-CloudRequest' }, $true))
            $cloudCalls.Count | Should BeGreaterThan 0
            $optedIn = @($cloudCalls | Where-Object { @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'RetryNonIdempotent' }).Count -gt 0 })
            $optedIn.Count | Should Be 0
            $maxAttempts = @($cloudCalls | Where-Object { @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'MaxAttempts' }).Count -gt 0 })
            $maxAttempts.Count | Should Be 0
            $posts = @($cloudCalls | Where-Object { $_.Extent.Text -match '-Method POST' })
            $posts.Count | Should Be 2
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PimGraphPost' }, $true)).Count | Should Be 0
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and @('Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-HttpCore', 'Invoke-RunbookHttp') -contains $node.GetCommandName() }, $true)).Count | Should Be 0
        }

        It 'defines no function the library defines, and documents every function' {
            $libraryTokens = $null
            $libraryErrors = $null
            $libraryAst = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$libraryTokens, [ref]$libraryErrors)
            @($libraryErrors).Count | Should Be 0
            $libraryNames = @($libraryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            # Not pinned to the library's exact count, which grows; this only
            # proves the parse found the library's functions.
            $libraryNames.Count | Should BeGreaterThan 40
            ($libraryNames -contains 'Invoke-CloudRequest') | Should Be $true
            ($libraryNames -contains 'Get-AutomationStringVariable') | Should Be $true
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            $clashes = @($functions | Where-Object { $libraryNames -contains $_.Name } | ForEach-Object { $_.Name })
            ($clashes -join ', ') | Should Be ''
            $missingHelp = @($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name })
            ($missingHelp -join ', ') | Should Be ''
        }

        It 'avoids Write-Host, $input, switches, and string-array parameters' {
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Host' }, $true)).Count | Should Be 0
            @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'input' }, $true)).Count | Should Be 0
            @($ast.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [switch] -or $_.StaticType -eq [string[]] }).Count | Should Be 0
            $runbookText | Should Match ([regex]::Escape("if (`$MyInvocation.InvocationName -ne '.')"))
        }

        It 'runs from disk with the dot-source between the markers' {
            $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'repo\automation\runbooks'
            $libDir = Join-Path -Path $TestDrive -ChildPath 'repo\automation\lib'
            New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
            $copy = Join-Path -Path $runbooksDir -ChildPath 'Invoke-PimEligibilityRenewal.ps1'
            Copy-Item -Path $runbook -Destination $copy

            # Directory and groups off, Azure on with no scope: a full run with no HTTP.
            $summary = & $copy -IncludeDirectoryRoles $false -IncludeGroups $false -IncludeAzureResources $true -AccessToken 'local-disk-token-0000' -RunId $runId 3>$null 4>$null
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Invoke-PimEligibilityRenewal'
            $summary.RunId | Should Be $runId
            $summary.DryRun | Should Be $true
            $summary.Environment | Should Be 'Global'
            $summary.Planned | Should Be 0
            $summary.Warnings | Should Be 1
            $summary.SchedulesScanned | Should Be 0
        }

        It 'runs when assembled the way Terraform inlines library_path' {
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail

            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $assembled.Contains('function Get-PimRenewalDecision') | Should Be $true
            $assembledTokens = $null
            $assembledErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$assembledTokens, [ref]$assembledErrors) | Out-Null
            @($assembledErrors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-PimEligibilityRenewal.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))
            $summary = & $published -IncludeDirectoryRoles $false -IncludeGroups $false -IncludeAzureResources $true -Environment USGov -AccessToken 'published-token-0000' -RunId $runId 3>$null 4>$null
            @($summary).Count | Should Be 1
            $summary.Runbook | Should Be 'Invoke-PimEligibilityRenewal'
            $summary.Environment | Should Be 'USGov'
            $summary.DryRun | Should Be $true
            $summary.Planned | Should Be 0
        }

        It 'refuses to run the assembled runbook with every plane off, the Azure one by default' {
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-PimEligibilityRenewalOff.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, ($head + $begin + "`n" + $libraryText + "`n" + $end + $tail), (New-Object System.Text.UTF8Encoding($false)))
            { & $published -IncludeDirectoryRoles $false -IncludeGroups $false -AccessToken 'published-token-0000' 3>$null 4>$null } | Should Throw 'nothing to renew'
            { & $published -IncludeDirectoryRoles $false -IncludeGroups $false -IncludeAzureResources $false -AzureScopeNames 'mg:mg-example-root' -AccessToken 'published-token-0000' 3>$null 4>$null } | Should Throw 'nothing to renew'
        }
    }
}

Remove-Variable -Name PimRoutes, PimRequests, PimUnexpected -Scope Global -ErrorAction SilentlyContinue
