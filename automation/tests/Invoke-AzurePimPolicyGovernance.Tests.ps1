# Pester tests for automation/runbooks/Invoke-AzurePimPolicyGovernance.ps1.
#
# Written in the Pester 3/4 assertion syntax ("Should Be") because Windows
# PowerShell 5.1 ships Pester 3.4.0. The runbook is dot-sourced, which loads
# its functions without running it, and its INLINE_LIBRARY block loads
# automation/lib/Runbook.Common.ps1 from disk exactly as a workstation run
# does. Every HTTP request goes through the library's Invoke-HttpCore, which is
# mocked here with a small router of canned ARM and Graph responses shaped
# like the learn.microsoft.com examples for roleEligibilityScheduleInstances,
# roleManagementPolicyAssignments, roleManagementPolicies, management group
# descendants, and sendMail. Nothing here touches a tenant or waits. The
# comparison is tested in both baseline modes (minimum, the default, never
# loosens a policy; exact is opt-in), together with the fail-closed paths for
# unreadable role names, scope-qualified "pairs" entries, and policies that use
# an authentication context. The baseline source is tested through the
# library's test hook, $script:RunbookAutomationVariables, which stands in for
# the Automation account's variables: BaselineJson wins over the variable,
# the variable wins over the built-in defaults, and text that parameter
# binding made of an object ("@{...}") is refused. Reset-Http gives every
# test an empty PimPolicy_AzureBaseline variable, so a run without
# BaselineJson holds the built-in defaults. The last context checks the
# runbook file against the inline contract and runs it the way Terraform
# publishes it.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$automationRoot = Split-Path -Parent $here
$repoRoot = Split-Path -Parent $automationRoot
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Invoke-AzurePimPolicyGovernance.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'
$runbooksModule = Join-Path -Path $repoRoot -ChildPath 'modules\azure\automation-runbooks\main.tf'
$pimStackVariables = Join-Path -Path $repoRoot -ChildPath 'stacks\azure-pim-governance\variables.tf'
$pimModuleVariables = Join-Path -Path $repoRoot -ChildPath 'modules\azure\pim-role-policy\variables.tf'

Describe 'Invoke-AzurePimPolicyGovernance' {
    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    . $runbook -ScopeNames 'sub:Not Used' -AccessToken 'dot-source-token-0000'
    $global:PimLogCountAfterLoad = @(Get-RunLogEntries).Count
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    # Fake values only. GUIDs are all-same-digit on purpose.
    $global:PimArmToken = 'eyJ0eXAiOiJKV1QifQ.armpayload00000000000.armsignature00000'
    $global:PimGraphToken = 'eyJ0eXAiOiJKV1QifQ.graphpayload0000000000.graphsignature000'
    $global:PimTokens = ConvertTo-Json -InputObject @{ Arm = $global:PimArmToken; Graph = $global:PimGraphToken } -Compress
    $runId = '00000000-0000-0000-0000-000000000000'
    $principalA = '11111111-1111-1111-1111-111111111111'
    $approverId = '22222222-2222-2222-2222-222222222222'
    $subA = '33333333-3333-3333-3333-333333333333'
    $subB = '44444444-4444-4444-4444-444444444444'
    $subC = '55555555-5555-5555-5555-555555555555'
    $ownerGuid = '66666666-6666-6666-6666-666666666666'
    $contributorGuid = '77777777-7777-7777-7777-777777777777'
    $readerGuid = '88888888-8888-8888-8888-888888888888'
    $principalB = '99999999-9999-9999-9999-999999999999'
    $platformApproverId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $arm = 'https://management.azure.com'
    $mgPlatform = '/providers/Microsoft.Management/managementGroups/mg-platform'
    $mgWorkloads = '/providers/Microsoft.Management/managementGroups/mg-workloads'
    $mgRoot = '/providers/Microsoft.Management/managementGroups/mg-root'
    $scopeA = "/subscriptions/$subA"
    $scopeB = "/subscriptions/$subB"
    $rgApp = "/subscriptions/$subB/resourceGroups/rg-app"
    $global:PimBaseline = '{"roles":{"Owner":{"activation_maximum_duration":"PT1H","require_approval":true},"Reader":{"report_only":true}}}'

    # -----------------------------------------------------------------------
    # HTTP router. Later routes win, so a test overrides the standard tenant
    # by adding a route. A call with no route is recorded and fails.
    # -----------------------------------------------------------------------

    $global:PimRoutes = New-Object System.Collections.ArrayList
    $global:PimRequests = New-Object System.Collections.ArrayList
    $global:PimUnexpected = New-Object System.Collections.ArrayList

    function Add-Route {
        param(
            [string]$Method = 'GET',
            [string]$Uri = '',
            [string]$Pattern = '',
            [int]$Status = 200,
            [object]$Json = $null,
            [string]$Text = ''
        )
        $content = $Text
        if ($null -ne $Json) { $content = ConvertTo-Json -InputObject $Json -Depth 30 -Compress }
        $global:PimRoutes.Insert(0, @{ Method = $Method; Uri = $Uri; Pattern = $Pattern; Status = $Status; Content = $content })
    }

    function Reset-Http {
        $global:PimRoutes.Clear()
        $global:PimRequests.Clear()
        $global:PimUnexpected.Clear()
        Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '' }
    }

    # The library's stand-in for the Automation account's variables.
    function Set-BaselineVariables {
        param([AllowNull()][object]$Values)
        $script:RunbookAutomationVariables = $Values
    }

    function Get-Requests {
        param([string]$Method = '', [string]$Like = '*')
        return @($global:PimRequests | Where-Object { ($Method -eq '' -or $_.Method -eq $Method) -and $_.Uri -like $Like })
    }

    Mock Invoke-HttpCore {
        [void]$global:PimRequests.Add([PSCustomObject]@{ Method = $Method; Uri = $Uri; Body = [string]$Body; Headers = $Headers })
        foreach ($route in $global:PimRoutes) {
            if ($route.Method -ne $Method) { continue }
            $hit = $false
            if ($route.Uri) { $hit = $route.Uri.Equals($Uri, [StringComparison]::OrdinalIgnoreCase) }
            elseif ($route.Pattern) { $hit = ($Uri -match $route.Pattern) }
            if ($hit) { return @{ StatusCode = $route.Status; Content = $route.Content; Headers = @{} } }
        }
        [void]$global:PimUnexpected.Add(('{0} {1}' -f $Method, $Uri))
        return @{ StatusCode = 404; Content = '{"error":{"code":"NoRoute","message":"No test route."}}'; Headers = @{} }
    }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }

    # -----------------------------------------------------------------------
    # Fixtures shaped like the learn.microsoft.com examples.
    # -----------------------------------------------------------------------

    function ConvertTo-Live {
        param([object]$Value)
        return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30 -Compress))
    }

    function New-TargetShape {
        param([string]$Caller, [string]$Level)
        return @{ caller = $Caller; operations = @('All'); level = $Level; targetObjects = $null; inheritableSettings = $null; enforcedSettings = $null }
    }

    function New-Rules {
        param(
            [string]$Duration = 'PT4H',
            [string[]]$Enabled = @('MultiFactorAuthentication', 'Justification'),
            [bool]$ApprovalRequired = $false,
            [string[]]$Approvers = @(),
            [int]$TimeoutDays = 3,
            [string[]]$SecondStageApprovers = @(),
            [bool]$AuthContext = $false,
            [switch]$WithoutExpiration
        )
        $approverObjects = @()
        foreach ($a in $Approvers) { $approverObjects += @{ id = $a; description = 'existing approvers'; isBackup = $false; userType = 'Group' } }
        $stages = @(@{ approvalStageTimeOutInDays = $TimeoutDays; isApproverJustificationRequired = $true; escalationTimeInMinutes = 0; primaryApprovers = $approverObjects; isEscalationEnabled = $false; escalationApprovers = $null })
        $approvalMode = 'SingleStage'
        if ($SecondStageApprovers.Count -gt 0) {
            $secondObjects = @()
            foreach ($a in $SecondStageApprovers) { $secondObjects += @{ id = $a; description = 'second stage'; isBackup = $false; userType = 'Group' } }
            $stages += @{ approvalStageTimeOutInDays = 2; isApproverJustificationRequired = $true; escalationTimeInMinutes = 0; primaryApprovers = $secondObjects; isEscalationEnabled = $false; escalationApprovers = $null }
            $approvalMode = 'Serial'
        }
        $claim = ''
        if ($AuthContext) { $claim = 'c1' }
        $rules = @(
            @{ id = 'Expiration_Admin_Eligibility'; ruleType = 'RoleManagementPolicyExpirationRule'; isExpirationRequired = $true; maximumDuration = 'P365D'; target = (New-TargetShape -Caller 'Admin' -Level 'Eligibility') },
            @{ id = 'Notification_Admin_Admin_Eligibility'; ruleType = 'RoleManagementPolicyNotificationRule'; notificationType = 'Email'; recipientType = 'Admin'; isDefaultRecipientsEnabled = $false; notificationLevel = 'Critical'; notificationRecipients = @('secops@corp.example.com'); target = (New-TargetShape -Caller 'Admin' -Level 'Eligibility') },
            @{
                id       = 'Approval_EndUser_Assignment'
                ruleType = 'RoleManagementPolicyApprovalRule'
                setting  = @{
                    isApprovalRequired               = $ApprovalRequired
                    isApprovalRequiredForExtension   = $false
                    isRequestorJustificationRequired = $true
                    approvalMode                     = $approvalMode
                    approvalStages                   = $stages
                }
                target   = (New-TargetShape -Caller 'EndUser' -Level 'Assignment')
            },
            @{ id = 'AuthenticationContext_EndUser_Assignment'; ruleType = 'RoleManagementPolicyAuthenticationContextRule'; isEnabled = $AuthContext; claimValue = $claim; target = (New-TargetShape -Caller 'EndUser' -Level 'Assignment') },
            @{ id = 'Enablement_EndUser_Assignment'; ruleType = 'RoleManagementPolicyEnablementRule'; enabledRules = $Enabled; target = (New-TargetShape -Caller 'EndUser' -Level 'Assignment') }
        )
        if (-not $WithoutExpiration) {
            $rules += @{ id = 'Expiration_EndUser_Assignment'; ruleType = 'RoleManagementPolicyExpirationRule'; isExpirationRequired = $true; maximumDuration = $Duration; target = (New-TargetShape -Caller 'EndUser' -Level 'Assignment') }
        }
        return $rules
    }

    function New-LiveRules {
        param([hashtable]$Options = @{})
        return @(New-Rules @Options | ForEach-Object { ConvertTo-Live -Value $_ })
    }

    function New-Settings {
        param(
            [string]$Duration = 'PT4H',
            [bool]$Mfa = $true,
            [bool]$Justification = $true,
            [bool]$Ticket = $false,
            [bool]$Approval = $false,
            [string[]]$ApproverIds = @(),
            [string[]]$ApproverNames = @()
        )
        return [PSCustomObject]@{
            ActivationMaximumDuration        = $Duration
            RequireMultiFactorAuthentication = $Mfa
            RequireJustification             = $Justification
            RequireTicketInfo                = $Ticket
            RequireApproval                  = $Approval
            ApproverGroupNames               = $ApproverNames
            ApproverGroupIds                 = $ApproverIds
            ReportOnly                       = $false
            Source                           = 'test'
        }
    }

    function New-Instance {
        param(
            [string]$Name,
            [string]$Scope,
            [string]$RoleGuid,
            [string]$RoleName,
            [string]$PrincipalId = '11111111-1111-1111-1111-111111111111',
            [string]$MemberType = 'Direct',
            [string]$RolePrefix = '',
            [switch]$NoExpanded
        )
        $prefix = $RolePrefix
        if (-not $prefix) { $prefix = $Scope }
        $roleId = '{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $prefix, $RoleGuid
        $instance = @{
            id         = ('{0}/providers/Microsoft.Authorization/RoleEligibilityScheduleInstances/{1}' -f $Scope, $Name)
            name       = $Name
            type       = 'Microsoft.Authorization/RoleEligibilityScheduleInstances'
            properties = @{
                scope                     = $Scope
                roleDefinitionId          = $roleId
                principalId               = $PrincipalId
                principalType             = 'Group'
                status                    = 'Provisioned'
                roleEligibilityScheduleId = ('{0}/providers/Microsoft.Authorization/RoleEligibilitySchedules/{1}' -f $Scope, $Name)
                memberType                = $MemberType
                expandedProperties        = @{
                    scope          = @{ id = $Scope; displayName = 'Example scope'; type = 'subscription' }
                    roleDefinition = @{ id = $roleId; displayName = $RoleName; type = 'BuiltInRole' }
                    principal      = @{ id = $PrincipalId; displayName = 'Example Group'; type = 'Group' }
                }
            }
        }
        if ($NoExpanded) { $instance.properties.Remove('expandedProperties') }
        return $instance
    }

    function New-Assignment {
        param([string]$Scope, [string]$RoleGuid, [string]$RoleName, [string]$PolicyName, [string]$RolePrefix = '', [switch]$NoRoleName)
        $prefix = $RolePrefix
        if (-not $prefix) { $prefix = $Scope }
        $policyId = '{0}/providers/Microsoft.Authorization/roleManagementPolicies/{1}' -f $Scope, $PolicyName
        $roleId = '{0}/providers/Microsoft.Authorization/roleDefinitions/{1}' -f $prefix, $RoleGuid
        $assignment = @{
            id         = ('{0}/providers/Microsoft.Authorization/roleManagementPolicyAssignment/{1}_{2}' -f $Scope, $PolicyName, $RoleGuid)
            name       = ('{0}_{1}' -f $PolicyName, $RoleGuid)
            type       = 'Microsoft.Authorization/RoleManagementPolicyAssignment'
            properties = @{
                scope                      = $Scope
                roleDefinitionId           = $roleId
                policyId                   = $policyId
                effectiveRules             = @()
                policyAssignmentProperties = @{
                    scope          = @{ id = $Scope; displayName = 'Example scope'; type = 'subscription' }
                    roleDefinition = @{ id = $roleId; displayName = $RoleName; type = 'BuiltInRole' }
                    policy         = @{ id = $policyId; lastModifiedBy = @{ displayName = 'Admin' }; lastModifiedDateTime = $null }
                }
            }
        }
        if ($NoRoleName) { $assignment.properties.Remove('policyAssignmentProperties') }
        return $assignment
    }

    function New-Policy {
        param([string]$Scope, [string]$Name, [object[]]$Rules)
        return @{
            id         = ('{0}/providers/Microsoft.Authorization/roleManagementPolicies/{1}' -f $Scope, $Name)
            name       = $Name
            type       = 'Microsoft.Authorization/RoleManagementPolicies'
            properties = @{ scope = $Scope; displayName = $null; isOrganizationDefault = $false; rules = $Rules; effectiveRules = $Rules }
        }
    }

    function Get-PolicyUri {
        param([string]$Scope, [string]$Name)
        return ('{0}{1}/providers/Microsoft.Authorization/roleManagementPolicies/{2}?api-version=2020-10-01' -f $arm, $Scope, $Name)
    }

    function Get-ListUri {
        param([string]$Scope)
        return ('{0}{1}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01' -f $arm, $Scope)
    }

    function Get-AssignmentPattern {
        param([string]$Scope, [string]$RoleGuid)
        return ('^' + [regex]::Escape(('{0}{1}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?$filter=' -f $arm, $Scope)) + '[^&]*' + $RoleGuid + '[^&]*&api-version=2020-10-01$')
    }

    function Add-PolicyRoutes {
        param([string]$Scope, [string]$RoleGuid, [string]$RoleName, [string]$PolicyName, [object[]]$Rules, [string]$RolePrefix = '', [switch]$NoRoleName)
        Add-Route -Pattern (Get-AssignmentPattern -Scope $Scope -RoleGuid $RoleGuid) -Json @{ value = @((New-Assignment -Scope $Scope -RoleGuid $RoleGuid -RoleName $RoleName -PolicyName $PolicyName -RolePrefix $RolePrefix -NoRoleName:$NoRoleName)) }
        Add-Route -Uri (Get-PolicyUri -Scope $Scope -Name $PolicyName) -Json (New-Policy -Scope $Scope -Name $PolicyName -Rules $Rules)
        Add-Route -Method PATCH -Uri (Get-PolicyUri -Scope $Scope -Name $PolicyName) -Json (New-Policy -Scope $Scope -Name $PolicyName -Rules $Rules)
    }

    # The standard tenant:
    #   mg-root > mg-platform > { subscription A, mg-workloads > subscription B }
    #   Owner eligible at mg-platform      policy-owner       PT8H, approval off   -> drift (Owner override: PT1H + approval)
    #   Contributor eligible at A (x2)     policy-contrib-a   PT240M               -> compliant
    #   Contributor eligible at rg-app     policy-contrib-rg  Justification+Ticketing -> drift (enablement)
    #   Reader eligible at A               policy-reader-a    PT24H                -> drift, report_only
    #   plus an inherited instance and a Direct instance at mg-root, both ignored.
    function Set-StandardTenant {
        Reset-Http
        # .NET Framework leaves the quotes unescaped, .NET on PowerShell 7 escapes them.
        Add-Route -Pattern "^https://graph\.microsoft\.com/v1\.0/groups\?\`$filter=displayName%20eq%20(%27|')PIM%20Approvers(%27|')&" -Json @{ value = @(@{ id = $approverId; displayName = 'PIM Approvers' }) }
        Add-Route -Pattern "^https://graph\.microsoft\.com/v1\.0/groups\?\`$filter=displayName%20eq%20(%27|')Platform%20Approvers(%27|')&" -Json @{ value = @(@{ id = $platformApproverId; displayName = 'Platform Approvers' }) }
        Add-Route -Method POST -Uri 'https://graph.microsoft.com/v1.0/users/iam-noreply%40corp.example.com/sendMail' -Status 202 -Text ''

        Add-Route -Uri "$arm/providers/Microsoft.Management/managementGroups?api-version=2020-05-01" -Json @{
            value = @(
                @{ id = $mgRoot; type = 'Microsoft.Management/managementGroups'; name = 'mg-root'; properties = @{ displayName = 'Tenant Root' } },
                @{ id = $mgPlatform; type = 'Microsoft.Management/managementGroups'; name = 'mg-platform'; properties = @{ displayName = 'Platform' } },
                @{ id = $mgWorkloads; type = 'Microsoft.Management/managementGroups'; name = 'mg-workloads'; properties = @{ displayName = 'Workloads' } }
            )
        }
        Add-Route -Uri "$arm/subscriptions?api-version=2022-12-01" -Json @{
            value = @(
                @{ id = $scopeA; subscriptionId = $subA; displayName = 'Identity Production'; state = 'Enabled' },
                @{ id = $scopeB; subscriptionId = $subB; displayName = 'Workloads'; state = 'Enabled' },
                @{ id = "/subscriptions/$subC"; subscriptionId = $subC; displayName = 'Sandbox'; state = 'Enabled' }
            )
        }
        Add-Route -Uri "$arm$mgPlatform/descendants?api-version=2020-05-01" -Json @{
            value    = @(
                @{ id = $mgWorkloads; type = 'Microsoft.Management/managementGroups'; name = 'mg-workloads'; properties = @{ displayName = 'Workloads'; parent = @{ id = $mgPlatform } } },
                @{ id = $scopeB; type = 'Microsoft.Management/managementGroups/subscriptions'; name = $subB; properties = @{ displayName = 'Workloads'; parent = @{ id = $mgWorkloads } } },
                @{ id = $scopeA; type = '/subscriptions'; name = $subA; properties = @{ displayName = 'Identity Production'; parent = @{ id = $mgPlatform } } }
            )
            nextLink = $null
        }

        Add-Route -Uri (Get-ListUri -Scope $mgPlatform) -Json @{
            value = @(
                (New-Instance -Name 'inst-owner' -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -RolePrefix ''),
                (New-Instance -Name 'inst-contrib-a1' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor'),
                (New-Instance -Name 'inst-inherited' -Scope $mgRoot -RoleGuid $contributorGuid -RoleName 'Contributor' -MemberType 'Inherited'),
                (New-Instance -Name 'inst-root-owner' -Scope $mgRoot -RoleGuid $ownerGuid -RoleName 'Owner')
            )
        }
        Add-Route -Uri (Get-ListUri -Scope $mgWorkloads) -Json @{
            value = @((New-Instance -Name 'inst-contrib-rg' -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -RolePrefix $scopeB))
        }
        Add-Route -Uri (Get-ListUri -Scope $scopeA) -Json @{
            value    = @(
                (New-Instance -Name 'inst-contrib-a1' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor'),
                (New-Instance -Name 'inst-contrib-a2' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor' -PrincipalId $principalB),
                (New-Instance -Name 'inst-reader' -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader'),
                (New-Instance -Name 'inst-owner-inherited' -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -MemberType 'Inherited')
            )
            nextLink = $null
        }
        Add-Route -Uri (Get-ListUri -Scope $scopeB) -Json @{
            value = @((New-Instance -Name 'inst-contrib-rg' -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -RolePrefix $scopeB))
        }

        Add-PolicyRoutes -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner' -RolePrefix '' -Rules (New-Rules -Duration 'PT8H')
        Add-PolicyRoutes -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-a' -Rules (New-Rules -Duration 'PT240M')
        Add-PolicyRoutes -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg' -RolePrefix $scopeB -Rules (New-Rules -Enabled @('Justification', 'Ticketing'))
        Add-PolicyRoutes -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'policy-reader-a' -Rules (New-Rules -Duration 'PT24H')
    }

    function Invoke-StandardRun {
        param(
            [bool]$DryRun = $true,
            [int]$Max = 25,
            [string]$ReportPath = '',
            [string]$Recipients = 'iam@corp.example.com',
            [string]$ScopeNames = 'Platform',
            [string]$Baseline = $global:PimBaseline
        )
        return (Invoke-AzurePimPolicyGovernanceRun -ScopeNames $ScopeNames -BaselineJson $Baseline -ApproverGroupName 'PIM Approvers' `
                -Recipients $Recipients -SenderMailbox 'iam-noreply@corp.example.com' -MaxPolicyUpdatesPerRun $Max -ReportPath $ReportPath `
                -DryRun $DryRun -AccessToken $global:PimTokens -RunId $runId 2>$null)
    }

    function Get-MailPayload {
        $mail = @(Get-Requests -Method POST -Like '*sendMail')
        if ($mail.Count -eq 0) { return $null }
        return (ConvertFrom-Json -InputObject $mail[0].Body)
    }

    Context 'loading' {
        It 'does not run the entry point when dot-sourced' {
            $global:PimLogCountAfterLoad | Should Be 0
        }
    }

    Context 'baseline' {
        It 'defaults to exactly the stacks/azure-pim-governance and pim-role-policy defaults' {
            $defaults = Get-PimDefaultBaseline
            foreach ($file in @($pimStackVariables, $pimModuleVariables)) {
                $tf = [System.IO.File]::ReadAllText($file)
                foreach ($name in @('activation_maximum_duration', 'require_multifactor_authentication', 'require_justification', 'require_ticket_info', 'require_approval')) {
                    ($tf -match ('(?s)variable\s+"' + $name + '"\s*\{.*?\bdefault\s*=\s*("?[^"\r\n]*"?)')) | Should Be $true
                    $tfDefault = $Matches[1].Trim().Trim('"')
                    $value = $defaults[$name]
                    if ($value -is [bool]) { $value = Format-PimBool -Value $value }
                    $value | Should Be $tfDefault
                }
            }
        }

        It 'uses the built-in baseline when BaselineJson is empty' {
            $b = ConvertFrom-PimBaselineJson -Json '   '
            $b.Defaults['activation_maximum_duration'] | Should Be 'PT4H'
            $b.Roles.Count | Should Be 0
            $b.Source | Should Match '^built-in stack defaults: activation=PT4H mfa=true justification=true ticket=false approval=false'
            $s = Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner'
            $s.RequireMultiFactorAuthentication | Should Be $true
            $s.RequireJustification | Should Be $true
            $s.RequireTicketInfo | Should Be $false
            $s.RequireApproval | Should Be $false
            $s.ReportOnly | Should Be $false
            $s.Source | Should Be 'defaults'
        }

        It 'applies a partial defaults object and keeps the rest' {
            $b = ConvertFrom-PimBaselineJson -Json '{"defaults":{"activation_maximum_duration":"pt2h","require_ticket_info":true}}'
            $s = Get-PimEffectiveSettings -Baseline $b
            $s.ActivationMaximumDuration | Should Be 'PT2H'
            $s.RequireTicketInfo | Should Be $true
            $s.RequireMultiFactorAuthentication | Should Be $true
        }

        It 'applies a role override by display name, case-insensitively, over the defaults' {
            $b = ConvertFrom-PimBaselineJson -Json $global:PimBaseline
            $owner = Get-PimEffectiveSettings -Baseline $b -RoleName 'owner'
            $owner.ActivationMaximumDuration | Should Be 'PT1H'
            $owner.RequireApproval | Should Be $true
            $owner.RequireJustification | Should Be $true
            $owner.Source | Should Be 'roles."owner"'
            $reader = Get-PimEffectiveSettings -Baseline $b -RoleName 'Reader'
            $reader.ReportOnly | Should Be $true
            $reader.ActivationMaximumDuration | Should Be 'PT4H'
            (Get-PimEffectiveSettings -Baseline $b -RoleName 'Contributor').Source | Should Be 'defaults'
            (Get-PimEffectiveSettings -Baseline $b -RoleName '').ActivationMaximumDuration | Should Be 'PT4H'
        }

        It 'refuses unknown keys, including a misspelt flag and report_only in defaults' {
            { ConvertFrom-PimBaselineJson -Json '{"default":{}}' } | Should Throw 'unknown top-level key "default"'
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"require_aproval":true}}' } | Should Throw 'unknown key "require_aproval"'
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"report_only":true}}' } | Should Throw 'unknown key "report_only"'
            { ConvertFrom-PimBaselineJson -Json '{"roles":{"Owner":{"maximum_duration":"PT1H"}}}' } | Should Throw 'roles."Owner" has an unknown key'
        }

        It 'refuses durations the pim-role-policy module refuses' {
            foreach ($bad in @('4h', 'PT', 'P1D', 'PT4S', 'PT4H30', '')) {
                $json = '{"defaults":{"activation_maximum_duration":"' + $bad + '"}}'
                { ConvertFrom-PimBaselineJson -Json $json } | Should Throw 'must be an ISO 8601 time duration'
            }
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"activation_maximum_duration":4}}' } | Should Throw 'must be an ISO 8601 time duration'
            (Get-PimEffectiveSettings -Baseline (ConvertFrom-PimBaselineJson -Json '{"defaults":{"activation_maximum_duration":"PT1H30M"}}')).ActivationMaximumDuration | Should Be 'PT1H30M'
        }

        It 'refuses flags that are not JSON booleans, and malformed documents' {
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"require_approval":"true"}}' } | Should Throw 'require_approval must be true or false'
            { ConvertFrom-PimBaselineJson -Json '{"defaults":' } | Should Throw 'does not parse as JSON'
            { ConvertFrom-PimBaselineJson -Json '["PT4H"]' } | Should Throw 'must be a JSON object'
            { ConvertFrom-PimBaselineJson -Json '{"roles":["Owner"]}' } | Should Throw 'keyed by role display name'
            { ConvertFrom-PimBaselineJson -Json '{"defaults":"PT4H"}' } | Should Throw 'defaults must be a JSON object'
        }

        It 'knows when an approver group is required' {
            Test-PimBaselineRequiresApprover -Baseline (ConvertFrom-PimBaselineJson -Json '') | Should Be $false
            Test-PimBaselineRequiresApprover -Baseline (ConvertFrom-PimBaselineJson -Json '{"roles":{"Reader":{"report_only":true}}}') | Should Be $false
            Test-PimBaselineRequiresApprover -Baseline (ConvertFrom-PimBaselineJson -Json $global:PimBaseline) | Should Be $true
            Test-PimBaselineRequiresApprover -Baseline (ConvertFrom-PimBaselineJson -Json '{"defaults":{"require_approval":true}}') | Should Be $true
            Test-PimBaselineRequiresApprover -Baseline (ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S"},"activation":{"require_approval":true}}]}') | Should Be $true
        }

        It 'defaults to mode minimum, accepts exact, and refuses anything else' {
            (ConvertFrom-PimBaselineJson -Json '').Mode | Should Be 'minimum'
            (ConvertFrom-PimBaselineJson -Json '{"roles":{}}').Mode | Should Be 'minimum'
            $exact = ConvertFrom-PimBaselineJson -Json '{"mode":"EXACT"}'
            $exact.Mode | Should Be 'exact'
            $exact.Source | Should Match '; mode exact; 0 role override\(s\), 0 pair override\(s\)$'
            (ConvertFrom-PimBaselineJson -Json '{"mode":null}').Mode | Should Be 'minimum'
            { ConvertFrom-PimBaselineJson -Json '{"mode":"strict"}' } | Should Throw '"mode" "strict" is not valid'
            { ConvertFrom-PimBaselineJson -Json '{"mode":true}' } | Should Throw 'must be "minimum" or "exact"'
        }

        It 'treats null as unset, as jsonencode() writes unset optional attributes' {
            $b = ConvertFrom-PimBaselineJson -Json '{"defaults":{"activation_maximum_duration":null,"require_approval":null},"roles":{"Owner":{"require_justification":null,"report_only":null}}}'
            $b.Defaults['activation_maximum_duration'] | Should Be 'PT4H'
            $b.Roles['Owner'].Count | Should Be 0
            (Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner').ReportOnly | Should Be $false
        }

        It 'reads pairs in the var.policies map shape, ignoring the rules it does not govern' {
            $json = '{"pairs":{"owner-at-root":{"role_name":"Owner","scope":{"type":"management_group","name":"Tenant Root"},"activation":{"maximum_duration":"PT1H","require_multifactor_authentication":null,"require_justification":null,"require_ticket_info":null,"require_approval":true,"approver_groups":["Root Approvers","root approvers"]},"eligible_assignment_rules":{"expiration_required":null,"expire_after":"P365D"},"active_assignment_rules":{}},"contrib-at-app":{"role_name":"Contributor","scope":{"type":"resource_group","name":"rg-app","subscription":"Workloads"}}}}'
            $b = ConvertFrom-PimBaselineJson -Json $json
            $b.HasOverrides | Should Be $true
            @($b.PairEntries).Count | Should Be 2
            $root = @($b.PairEntries)[0]
            $root.Label | Should Be 'pairs."owner-at-root"'
            $root.RoleName | Should Be 'Owner'
            $root.ScopeType | Should Be 'management_group'
            $root.ScopeName | Should Be 'Tenant Root'
            $root.ReportOnly | Should Be $false
            (@($root.Values.Keys | Sort-Object) -join ',') | Should Be 'activation_maximum_duration,approver_groups,require_approval'
            $root.Values['activation_maximum_duration'] | Should Be 'PT1H'
            (@($root.Values['approver_groups']) -join ',') | Should Be 'Root Approvers'
            $app = @($b.PairEntries)[1]
            $app.ScopeType | Should Be 'resource_group'
            $app.ScopeSubscription | Should Be 'Workloads'
            $app.Values.Count | Should Be 0
            $b.Source | Should Match '0 role override\(s\), 2 pair override\(s\)$'
        }

        It 'reads pairs as an array, and pairs_report_only makes every entry report-only' {
            $b = ConvertFrom-PimBaselineJson -Json '{"pairs_report_only":true,"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S"},"report_only":false}]}'
            @($b.PairEntries)[0].Label | Should Be 'pairs[0]'
            @($b.PairEntries)[0].ReportOnly | Should Be $true
            $b.PairsReportOnly | Should Be $true
        }

        It 'refuses incomplete or malformed pair entries' {
            $scope = '"scope":{"type":"subscription","name":"S"}'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":"Owner"}' } | Should Throw '"pairs" must be a JSON array'
            { ConvertFrom-PimBaselineJson -Json ('{"pairs":[{' + $scope + '}]}') } | Should Throw 'pairs[0].role_name must be a role display name'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner"}]}' } | Should Throw 'pairs[0].scope must be an object'
            { ConvertFrom-PimBaselineJson -Json ('{"pairs":[{"role_name":"Owner",' + $scope + ',"roles":{}}]}') } | Should Throw 'pairs[0] has an unknown key "roles"'
            { ConvertFrom-PimBaselineJson -Json ('{"pairs":[{"role_name":"Owner",' + $scope + ',"activation":{"activation_maximum_duration":"PT1H"}}]}') } | Should Throw 'pairs[0].activation has an unknown key "activation_maximum_duration"'
            { ConvertFrom-PimBaselineJson -Json ('{"pairs":[{"role_name":"Owner",' + $scope + ',"activation":{"maximum_duration":"1h"}}]}') } | Should Throw 'pairs[0].activation.maximum_duration must be an ISO 8601 time duration'
            { ConvertFrom-PimBaselineJson -Json ('{"pairs":[{"role_name":"Owner",' + $scope + ',"report_only":"yes"}]}') } | Should Throw 'report_only must be true or false'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"tenant","name":"S"}}]}' } | Should Throw 'scope.type must be'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":" "}}]}' } | Should Throw 'scope.name must be set'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S","id":"x"}}]}' } | Should Throw 'scope has an unknown key "id"'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"resource_group","name":"rg"}}]}' } | Should Throw 'scope needs "subscription"'
            { ConvertFrom-PimBaselineJson -Json '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S","subscription":"S"}}]}' } | Should Throw 'applies to a resource_group scope only'
            { ConvertFrom-PimBaselineJson -Json '{"pairs_report_only":"true"}' } | Should Throw '"pairs_report_only" must be true or false'
        }

        It 'validates approver_groups wherever they appear' {
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"approver_groups":"PIM Approvers"}}' } | Should Throw 'defaults.approver_groups must be a JSON array'
            { ConvertFrom-PimBaselineJson -Json '{"roles":{"Owner":{"approver_groups":["ok",""]}}}' } | Should Throw 'must hold non-empty group display names'
            { ConvertFrom-PimBaselineJson -Json '{"roles":{"Owner":{"approver_groups":[{"name":"x"}]}}}' } | Should Throw 'must hold non-empty group display names'
            $b = ConvertFrom-PimBaselineJson -Json '{"defaults":{"approver_groups":["PIM Approvers","Second Approvers"]}}' -DefaultApproverGroupName 'pim approvers'
            (@($b.Defaults['approver_groups']) -join ',') | Should Be 'PIM Approvers,Second Approvers'
            { ConvertFrom-PimBaselineJson -Json '{"defaults":{"approver_groups":["Second Approvers"]}}' -DefaultApproverGroupName 'PIM Approvers' } | Should Throw 'is not one of BaselineJson defaults.approver_groups'
            (@((ConvertFrom-PimBaselineJson -Json '' -DefaultApproverGroupName ' PIM Approvers ').Defaults['approver_groups']) -join ',') | Should Be 'PIM Approvers'
            @((ConvertFrom-PimBaselineJson -Json '').Defaults['approver_groups']).Count | Should Be 0
        }

        It 'requires an approver group wherever approval is required, after inheritance' {
            { Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json '{"defaults":{"require_approval":true}}') } | Should Throw 'requires approval for defaults but names no approver group there: ApproverGroupName is empty'
            { Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json '{"defaults":{"require_approval":true,"approver_groups":[]}}') } | Should Throw 'defaults.approver_groups is empty'
            { Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json $global:PimBaseline) } | Should Throw 'requires approval for roles."Owner"'
            Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json $global:PimBaseline -DefaultApproverGroupName 'PIM Approvers')
            $pairOwn = '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S"},"activation":{"require_approval":true,"approver_groups":[]}}]}'
            { Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json $pairOwn -DefaultApproverGroupName 'PIM Approvers') } | Should Throw 'requires approval for pairs[0] but its approver_groups is empty'
            $pairNamed = '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S"},"activation":{"require_approval":true,"approver_groups":["Platform Approvers"]}}]}'
            Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json $pairNamed)
            $offWithoutGroups = '{"defaults":{"require_approval":true,"approver_groups":["PIM Approvers"]},"roles":{"Reader":{"require_approval":false,"approver_groups":[]}}}'
            Assert-PimBaselineApprovers -Baseline (ConvertFrom-PimBaselineJson -Json $offWithoutGroups)
            $names = @(Get-PimApproverGroupNames -Baseline (ConvertFrom-PimBaselineJson -Json $pairNamed -DefaultApproverGroupName 'PIM Approvers'))
            ($names -join ',') | Should Be 'PIM Approvers,Platform Approvers'
        }

        It 'holds a pair to its own entry over the role entry, inheriting the defaults and not the role' {
            $json = '{"defaults":{"require_ticket_info":true},"roles":{"Owner":{"activation_maximum_duration":"PT2H","require_justification":false}},"pairs":[{"role_name":"owner","scope":{"type":"subscription","name":"S"},"activation":{"maximum_duration":"PT1H","require_approval":true,"approver_groups":["Platform Approvers"]},"report_only":true}]}'
            $b = ConvertFrom-PimBaselineJson -Json $json -DefaultApproverGroupName 'PIM Approvers'
            $entry = @($b.PairEntries)[0]
            $entry.Scope = $scopeA
            $b.Pairs[(Get-PimPairOverrideKey -Scope $scopeA -RoleName 'Owner')] = $entry
            $pinned = @{ 'pim approvers' = $approverId; 'platform approvers' = $platformApproverId }

            $declared = Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner' -Scope ($scopeA.ToUpperInvariant() + '/') -ApproverGroupIds $pinned
            $declared.Source | Should Be 'pairs[0]'
            $declared.ActivationMaximumDuration | Should Be 'PT1H'
            $declared.RequireJustification | Should Be $true
            $declared.RequireTicketInfo | Should Be $true
            $declared.RequireApproval | Should Be $true
            $declared.ReportOnly | Should Be $true
            (@($declared.ApproverGroupNames) -join ',') | Should Be 'Platform Approvers'
            (@($declared.ApproverGroupIds) -join ',') | Should Be $platformApproverId

            $elsewhere = Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner' -Scope $scopeB -ApproverGroupIds $pinned
            $elsewhere.Source | Should Be 'roles."Owner"'
            $elsewhere.ActivationMaximumDuration | Should Be 'PT2H'
            $elsewhere.RequireJustification | Should Be $false
            $elsewhere.ReportOnly | Should Be $false
            (@($elsewhere.ApproverGroupIds) -join ',') | Should Be $approverId

            (Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner').Source | Should Be 'roles."Owner"'
            (Get-PimEffectiveSettings -Baseline $b -RoleName 'Reader' -Scope $scopeA).Source | Should Be 'defaults'
            { Get-PimEffectiveSettings -Baseline $b -RoleName 'Owner' -Scope $scopeA -ApproverGroupIds @{ 'pim approvers' = $approverId } } | Should Throw 'Approver group "Platform Approvers" was not resolved'
        }
    }

    Context 'scope references and containment' {
        It 'reads mg: and sub: prefixes and leaves other names to both lookups' {
            (ConvertTo-PimScopeReference -Value ' mg:Platform ').Kind | Should Be 'ManagementGroup'
            (ConvertTo-PimScopeReference -Value 'managementGroup: Platform').Name | Should Be 'Platform'
            (ConvertTo-PimScopeReference -Value 'SUB:Identity Production').Kind | Should Be 'Subscription'
            (ConvertTo-PimScopeReference -Value 'subscription:Identity Production').Name | Should Be 'Identity Production'
            $any = ConvertTo-PimScopeReference -Value 'Identity Production'
            $any.Kind | Should Be 'Any'
            $any.Name | Should Be 'Identity Production'
            { ConvertTo-PimScopeReference -Value 'mg: ' } | Should Throw 'has no name'
        }

        It 'normalises scopes for comparison' {
            ConvertTo-PimScopeKey -Scope 'Subscriptions/ABC/' | Should Be '/subscriptions/abc'
            ConvertTo-PimScopeKey -Scope '' | Should Be ''
        }

        It 'contains everything under a swept subscription and nothing beside it' {
            $allowed = @([PSCustomObject]@{ Scope = '/subscriptions/1'; Kind = 'Subscription' })
            Test-PimScopeInSweep -Scope '/subscriptions/1' -Allowed $allowed | Should Be $true
            Test-PimScopeInSweep -Scope '/SUBSCRIPTIONS/1/resourceGroups/rg/providers/Microsoft.Web/sites/app' -Allowed $allowed | Should Be $true
            Test-PimScopeInSweep -Scope '/subscriptions/12' -Allowed $allowed | Should Be $false
            Test-PimScopeInSweep -Scope '/providers/Microsoft.Management/managementGroups/mg' -Allowed $allowed | Should Be $false
            Test-PimScopeInSweep -Scope '' -Allowed $allowed | Should Be $false
        }

        It 'matches a management group entry only exactly' {
            $allowed = @([PSCustomObject]@{ Scope = $mgPlatform; Kind = 'ManagementGroup' })
            Test-PimScopeInSweep -Scope ($mgPlatform.ToUpperInvariant() + '/') -Allowed $allowed | Should Be $true
            Test-PimScopeInSweep -Scope ($mgPlatform + '-2') -Allowed $allowed | Should Be $false
            Test-PimScopeInSweep -Scope $mgRoot -Allowed $allowed | Should Be $false
            Test-PimScopeInSweep -Scope $scopeA -Allowed $allowed | Should Be $false
        }

        It 'turns management group descendants into swept scopes' {
            $sub = ConvertTo-PimDescendantScope -Entry (ConvertTo-Live @{ id = $scopeA; type = '/subscriptions'; name = $subA })
            $sub.Kind | Should Be 'Subscription'
            $sub.Scope | Should Be $scopeA
            (ConvertTo-PimDescendantScope -Entry (ConvertTo-Live @{ type = 'Microsoft.Management/managementGroups/subscriptions'; name = $subB })).Scope | Should Be $scopeB
            $mg = ConvertTo-PimDescendantScope -Entry (ConvertTo-Live @{ id = $mgWorkloads; type = 'Microsoft.Management/managementGroups'; name = 'mg-workloads' })
            $mg.Kind | Should Be 'ManagementGroup'
            $mg.Scope | Should Be $mgWorkloads
            ConvertTo-PimDescendantScope -Entry (ConvertTo-Live @{ type = 'Microsoft.Resources/resourceGroups'; name = 'rg' }) | Should BeNullOrEmpty
            ConvertTo-PimDescendantScope -Entry (ConvertTo-Live @{ type = '/subscriptions'; name = '../x' }) | Should BeNullOrEmpty
        }

        It 'reads the role GUID from every role definition id form' {
            Get-PimRoleDefinitionGuid -RoleDefinitionId "/providers/Microsoft.Authorization/roleDefinitions/$ownerGuid" | Should Be $ownerGuid
            Get-PimRoleDefinitionGuid -RoleDefinitionId "$scopeA/providers/Microsoft.Authorization/roleDefinitions/$ownerGuid" | Should Be $ownerGuid
            Get-PimRoleDefinitionGuid -RoleDefinitionId "$mgPlatform/providers/microsoft.authorization/roledefinitions/$readerGuid/" | Should Be $readerGuid
            Get-PimRoleDefinitionGuid -RoleDefinitionId 'Contributor' | Should Be ''
            Get-PimRoleDefinitionGuid -RoleDefinitionId '' | Should Be ''
        }
    }

    Context 'pair reduction' {
        It 'keeps Direct instances inside the sweep, keyed on their own scope, counted once' {
            $state = New-PimPairState
            $allowed = @([PSCustomObject]@{ Scope = $mgPlatform; Kind = 'ManagementGroup' }, [PSCustomObject]@{ Scope = $scopeA; Kind = 'Subscription' })
            $first = @(
                (ConvertTo-Live (New-Instance -Name 'i1' -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner')),
                (ConvertTo-Live (New-Instance -Name 'i2' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor')),
                (ConvertTo-Live (New-Instance -Name 'i3' -Scope $mgRoot -RoleGuid $ownerGuid -RoleName 'Owner')),
                (ConvertTo-Live (New-Instance -Name 'i4' -Scope $mgRoot -RoleGuid $ownerGuid -RoleName 'Owner' -MemberType 'Inherited')),
                (ConvertTo-Live (New-Instance -Name 'i5' -Scope "$scopeA/resourceGroups/rg" -RoleGuid $contributorGuid -RoleName 'Contributor' -MemberType 'Group'))
            )
            Add-PimEligibilityPairs -State $state -Instances $first -Allowed $allowed | Should Be 2

            $second = @(
                (ConvertTo-Live (New-Instance -Name 'i2' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor')),
                (ConvertTo-Live (New-Instance -Name 'i6' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor' -PrincipalId $principalB -RolePrefix '')),
                (ConvertTo-Live (New-Instance -Name 'i7' -Scope "$scopeA/resourceGroups/rg" -RoleGuid $contributorGuid -RoleName 'Contributor' -RolePrefix $scopeA))
            )
            Add-PimEligibilityPairs -State $state -Instances $second -Allowed $allowed | Should Be 1

            $state.Read | Should Be 8
            $state.Direct | Should Be 4
            $state.Ignored | Should Be 3
            $state.Pairs.Count | Should Be 3
            $pairA = $state.Pairs[(ConvertTo-PimScopeKey -Scope $scopeA) + '|' + $contributorGuid]
            $pairA.Eligibilities | Should Be 2
            $pairA.Principals.Count | Should Be 2
            $pairA.RoleName | Should Be 'Contributor'
            $pairA.Scope | Should Be $scopeA
            $state.Pairs.Contains((ConvertTo-PimScopeKey -Scope "$scopeA/resourceGroups/rg") + '|' + $contributorGuid) | Should Be $true
        }

        It 'ignores instances without a readable scope or role' {
            $state = New-PimPairState
            $allowed = @([PSCustomObject]@{ Scope = $scopeA; Kind = 'Subscription' })
            $broken = ConvertTo-Live @{ id = 'x'; properties = @{ scope = $scopeA; roleDefinitionId = 'not-a-role'; memberType = 'Direct' } }
            $noScope = ConvertTo-Live @{ id = 'y'; properties = @{ roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$ownerGuid"; memberType = 'Direct' } }
            Add-PimEligibilityPairs -State $state -Instances @($broken, $noScope, $null) -Allowed $allowed | Should Be 0
            $state.Ignored | Should Be 2
        }
    }

    Context 'policy assignment selection and policy ids' {
        $assignments = @(
            (ConvertTo-Live (New-Assignment -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'p-reader')),
            (ConvertTo-Live (New-Assignment -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'p-contrib' -RolePrefix '')),
            (ConvertTo-Live (New-Assignment -Scope "$scopeA/resourceGroups/rg" -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'p-contrib-rg'))
        )

        It 'picks the assignment for the scope and role whatever the role id prefix' {
            $found = Select-PimPolicyAssignment -Assignments $assignments -Scope ($scopeA + '/') -RoleGuid $contributorGuid.ToUpperInvariant()
            $found.properties.policyId | Should Be "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/p-contrib"
        }

        It 'does not take a policy from another scope' {
            Select-PimPolicyAssignment -Assignments @($assignments[0], $assignments[1]) -Scope "$scopeA/resourceGroups/rg" -RoleGuid $contributorGuid | Should BeNullOrEmpty
            Select-PimPolicyAssignment -Assignments @() -Scope $scopeA -RoleGuid $contributorGuid | Should BeNullOrEmpty
        }

        It 'refuses two assignments for one pair' {
            { Select-PimPolicyAssignment -Assignments @($assignments[1], $assignments[1]) -Scope $scopeA -RoleGuid $contributorGuid } | Should Throw 'expected exactly one'
        }

        It 'only accepts a policy id directly at the pair scope' {
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/$ownerGuid" -Scope $scopeA | Should Be $true
            Test-PimPolicyIdAtScope -PolicyId "$mgPlatform/providers/Microsoft.Authorization/roleManagementPolicies/policy-owner" -Scope $mgPlatform | Should Be $true
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/p1" -Scope "$scopeA/resourceGroups/rg" | Should Be $false
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/resourceGroups/rg/providers/Microsoft.Authorization/roleManagementPolicies/p1" -Scope $scopeA | Should Be $false
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/../p1" -Scope $scopeA | Should Be $false
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/p1?x=1" -Scope $scopeA | Should Be $false
            Test-PimPolicyIdAtScope -PolicyId "$scopeA/providers/Microsoft.Authorization/roleManagementPolicies/p1/extra" -Scope $scopeA | Should Be $false
            Test-PimPolicyIdAtScope -PolicyId '' -Scope $scopeA | Should Be $false
        }
    }

    Context 'drift comparison' {
        It 'finds nothing on a policy that matches the baseline' {
            @(Compare-PimPolicyRules -Rules (New-LiveRules) -Settings (New-Settings)).Count | Should Be 0
        }

        It 'compares the activation window as a duration' {
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT240M' }) -Settings (New-Settings)).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT240M' }) -Settings (New-Settings) -Mode exact).Count | Should Be 0
            $drift = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT8H' }) -Settings (New-Settings))
            $drift.Count | Should Be 1
            $drift[0].RuleId | Should Be 'Expiration_EndUser_Assignment'
            $drift[0].Field | Should Be 'maximumDuration'
            $drift[0].Current | Should Be 'PT8H'
            $drift[0].Desired | Should Be 'PT4H'
            $drift[0].Blocked | Should Be ''
        }

        It 'minimum mode: a shorter activation window is compliant; exact mode: it is drift' {
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT1H' }) -Settings (New-Settings)).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT1H' }) -Settings (New-Settings) -Mode minimum).Count | Should Be 0
            $exact = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT1H' }) -Settings (New-Settings) -Mode exact)
            $exact.Count | Should Be 1
            $exact[0].Current | Should Be 'PT1H'
            $exact[0].Desired | Should Be 'PT4H'
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'P1D' }) -Settings (New-Settings -Duration 'PT24H')).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'garbage' }) -Settings (New-Settings)).Count | Should Be 1
        }

        It 'treats a missing expiration rule as drift' {
            $drift = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ WithoutExpiration = $true }) -Settings (New-Settings))
            $drift.Count | Should Be 1
            $drift[0].Current | Should Be '(not set)'
        }

        It 'checks each governed enablement value on its own and ignores the rest' {
            $drift = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Enabled = @('Justification', 'Ticketing') }) -Settings (New-Settings))
            (@($drift | ForEach-Object { $_.Field }) -join ',') | Should Be 'enabledRules.MultiFactorAuthentication'
            $drift[0].Current | Should Be 'false'
            $drift[0].Desired | Should Be 'true'
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Enabled = @('Justification', 'MultiFactorAuthentication', 'SomeFutureRule') }) -Settings (New-Settings)).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Enabled = @() }) -Settings (New-Settings -Mfa $false -Justification $false)).Count | Should Be 0
        }

        It 'minimum mode: extra enablement requirements are compliant; exact mode: each is drift' {
            $rules = New-LiveRules @{ Enabled = @('Justification', 'MultiFactorAuthentication', 'Ticketing') }
            @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings -Mfa $false -Justification $false)).Count | Should Be 0
            $exact = @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings) -Mode exact)
            (@($exact | ForEach-Object { $_.Field }) -join ',') | Should Be 'enabledRules.Ticketing'
            $exact[0].Current | Should Be 'true'
            $exact[0].Desired | Should Be 'false'
            $both = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Enabled = @('Justification', 'Ticketing') }) -Settings (New-Settings) -Mode exact)
            (@($both | ForEach-Object { $_.Field }) -join ',') | Should Be 'enabledRules.MultiFactorAuthentication,enabledRules.Ticketing'
        }

        It 'never asks for MFA next to an authentication context, in either mode' {
            $rules = New-LiveRules @{ Enabled = @('Justification'); AuthContext = $true }
            foreach ($mode in @('minimum', 'exact')) {
                $drift = @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings) -Mode $mode)
                $drift.Count | Should Be 1
                $drift[0].Field | Should Be 'enabledRules.MultiFactorAuthentication'
                $drift[0].Blocked | Should Match '^AuthenticationContext_EndUser_Assignment is on'
                Get-PimBlockedReason -Drift $drift | Should Match 'MultiFactorAuthentication is never added'
                Format-PimDriftText -Drift $drift | Should Match '\(not patched: AuthenticationContext_EndUser_Assignment is on'
            }
            @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings -Mfa $false)).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ AuthContext = $true }) -Settings (New-Settings)).Count | Should Be 0
            $other = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Enabled = @('MultiFactorAuthentication'); AuthContext = $false }) -Settings (New-Settings))
            $other[0].Blocked | Should Be ''
            Get-PimBlockedReason -Drift $other | Should Be ''
        }

        It 'requires approval by exactly the pinned group when the baseline asks for it' {
            $want = New-Settings -Approval $true
            $off = @(Compare-PimPolicyRules -Rules (New-LiveRules) -Settings $want -ApproverGroupId $approverId)
            (@($off | ForEach-Object { $_.Field }) -join ',') | Should Be 'setting.isApprovalRequired,setting.approvalStages.primaryApprovers'
            $off[1].Current | Should Be '(none)'
            $off[1].Desired | Should Be $approverId

            $wrong = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA) }) -Settings $want -ApproverGroupId $approverId)
            $wrong.Count | Should Be 1
            $wrong[0].Current | Should Be $principalA

            $extra = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($approverId, $principalB) }) -Settings $want -ApproverGroupId $approverId)
            $extra.Count | Should Be 1

            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($approverId.ToUpperInvariant()) }) -Settings $want -ApproverGroupId $approverId).Count | Should Be 0
        }

        It 'compares the first stage with every named approver group, in any order' {
            $want = New-Settings -Approval $true -ApproverIds @($approverId, $platformApproverId) -ApproverNames @('PIM Approvers', 'Platform Approvers')
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($platformApproverId, $approverId) }) -Settings $want).Count | Should Be 0
            $partial = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($approverId) }) -Settings $want)
            $partial.Count | Should Be 1
            $partial[0].Desired | Should Be ((@($approverId, $platformApproverId) | Sort-Object) -join ',')
            # Settings ids win over the fallback id.
            @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($platformApproverId, $approverId) }) -Settings $want -ApproverGroupId $principalA).Count | Should Be 0
            # The right group in the second stage only does not count.
            $second = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA); SecondStageApprovers = @($approverId) }) -Settings (New-Settings -Approval $true) -ApproverGroupId $approverId)
            $second.Count | Should Be 1
            $second[0].Field | Should Be 'setting.approvalStages.primaryApprovers'
        }

        It 'minimum mode: approval the baseline does not ask for is compliant, whoever the approvers are' {
            $rules = New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA) }
            @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings)).Count | Should Be 0
            @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings) -Mode minimum).Count | Should Be 0
        }

        It 'exact mode: approval the baseline does not ask for is drift' {
            $drift = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA) }) -Settings (New-Settings) -Mode exact)
            $drift.Count | Should Be 1
            $drift[0].Field | Should Be 'setting.isApprovalRequired'
            $drift[0].Current | Should Be 'true'
            $drift[0].Desired | Should Be 'false'
        }

        It 'minimum mode: extra approval stages are compliant; exact mode: they are drift' {
            $rules = New-LiveRules @{ ApprovalRequired = $true; Approvers = @($approverId); SecondStageApprovers = @($principalB) }
            $want = New-Settings -Approval $true
            @(Compare-PimPolicyRules -Rules $rules -Settings $want -ApproverGroupId $approverId).Count | Should Be 0
            $exact = @(Compare-PimPolicyRules -Rules $rules -Settings $want -ApproverGroupId $approverId -Mode exact)
            $exact.Count | Should Be 1
            $exact[0].Field | Should Be 'setting.approvalStages'
            $exact[0].Current | Should Be '2 stages'
            $exact[0].Desired | Should Be '1 stage'
        }

        It 'refuses to require approval without a pinned group' {
            { Compare-PimPolicyRules -Rules (New-LiveRules) -Settings (New-Settings -Approval $true) } | Should Throw 'no approver group id is pinned'
        }

        It 'formats drift as one line' {
            $drift = @(Compare-PimPolicyRules -Rules (New-LiveRules @{ Duration = 'PT8H' }) -Settings (New-Settings))
            Format-PimDriftText -Drift $drift | Should Be 'Expiration_EndUser_Assignment maximumDuration: PT8H -> PT4H'
        }
    }

    Context 'PATCH body' {
        It 'is empty when nothing drifted' {
            New-PimPolicyPatchBody -Rules (New-LiveRules) -Settings (New-Settings) -Drift @() | Should BeNullOrEmpty
        }

        It 'carries only the drifted rules, in a fixed order, copied from the live rules' {
            $rules = New-LiveRules @{ Duration = 'PT8H'; Enabled = @('Justification', 'SomeFutureRule') }
            $settings = New-Settings -Duration 'PT2H'
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift
            $sent = @($body.properties.rules)
            (@($sent | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Enablement_EndUser_Assignment'
            $sent[0].maximumDuration | Should Be 'PT2H'
            $sent[0].isExpirationRequired | Should Be $true
            $sent[0].ruleType | Should Be 'RoleManagementPolicyExpirationRule'
            $sent[0].target.caller | Should Be 'EndUser'
            $sent[0].target.level | Should Be 'Assignment'
            (@($sent[1].enabledRules) -join ',') | Should Be 'Justification,SomeFutureRule,MultiFactorAuthentication'
            (Get-PimRuleById -Rules $rules -RuleId 'Expiration_EndUser_Assignment').maximumDuration | Should Be 'PT8H'
        }

        It 'minimum mode: an enablement patch keeps every live entry and only adds' {
            $rules = New-LiveRules @{ Enabled = @('Justification', 'Ticketing', 'SomeFutureRule') }
            $settings = New-Settings -Justification $false
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -Mode minimum
            (@(@($body.properties.rules)[0].enabledRules) -join ',') | Should Be 'Justification,Ticketing,SomeFutureRule,MultiFactorAuthentication'
        }

        It 'exact mode: an enablement patch replaces the governed values and keeps the rest' {
            $rules = New-LiveRules @{ Duration = 'PT8H'; Enabled = @('Justification', 'Ticketing', 'SomeFutureRule') }
            $settings = New-Settings -Duration 'PT2H'
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -Mode exact)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -Mode exact
            $sent = @($body.properties.rules)
            (@($sent | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Enablement_EndUser_Assignment'
            (@($sent[1].enabledRules) -join ',') | Should Be 'SomeFutureRule,MultiFactorAuthentication,Justification'
        }

        It 'refuses to build a patch for drift that must only be reported' {
            $rules = New-LiveRules @{ Duration = 'PT8H'; Enabled = @('Justification'); AuthContext = $true }
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings (New-Settings))
            $drift.Count | Should Be 2
            { New-PimPolicyPatchBody -Rules $rules -Settings (New-Settings) -Drift $drift } | Should Throw 'must not be patched'
            { New-PimPolicyPatchBody -Rules $rules -Settings (New-Settings) -Drift $drift -Mode exact } | Should Throw 'AuthenticationContext_EndUser_Assignment is on'
        }

        It 'minimum mode: an approval patch keeps later stages and the approval mode' {
            $rules = New-LiveRules @{ ApprovalRequired = $false; Approvers = @($principalA); SecondStageApprovers = @($principalB) }
            $settings = New-Settings -Approval $true -ApproverIds @($approverId, $platformApproverId) -ApproverNames @('PIM Approvers', 'Platform Approvers')
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings)
            (@($drift | ForEach-Object { $_.Field }) -join ',') | Should Be 'setting.isApprovalRequired,setting.approvalStages.primaryApprovers'
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift
            $setting = @($body.properties.rules)[0].setting
            $setting.isApprovalRequired | Should Be $true
            $setting.approvalMode | Should Be 'Serial'
            $stages = @($setting.approvalStages)
            $stages.Count | Should Be 2
            (@($stages[0].primaryApprovers | ForEach-Object { $_.id }) -join ',') | Should Be ('{0},{1}' -f $approverId, $platformApproverId)
            (@($stages[0].primaryApprovers | ForEach-Object { $_.description }) -join ',') | Should Be 'PIM Approvers,Platform Approvers'
            @($stages[0].primaryApprovers)[1].userType | Should Be 'Group'
            $stages[0].approvalStageTimeOutInDays | Should Be 3
            @($stages[1].primaryApprovers)[0].id | Should Be $principalB
        }

        It 'exact mode: an approval patch leaves exactly one stage' {
            $rules = New-LiveRules @{ ApprovalRequired = $true; Approvers = @($approverId); SecondStageApprovers = @($principalB) }
            $settings = New-Settings -Approval $true
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -ApproverGroupId $approverId -Mode exact)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -ApproverGroupId $approverId -ApproverGroupName 'PIM Approvers' -Mode exact
            $setting = @($body.properties.rules)[0].setting
            @($setting.approvalStages).Count | Should Be 1
            $setting.approvalMode | Should Be 'SingleStage'
            @(@($setting.approvalStages)[0].primaryApprovers)[0].id | Should Be $approverId
        }

        It 'minimum mode: an approval rule update never turns approval off' {
            $rule = Get-PimRuleById -Rules (New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA) }) -RuleId 'Approval_EndUser_Assignment'
            (New-PimRuleUpdate -RuleId 'Approval_EndUser_Assignment' -CurrentRule $rule -Settings (New-Settings)).setting.isApprovalRequired | Should Be $true
            (New-PimRuleUpdate -RuleId 'Approval_EndUser_Assignment' -CurrentRule $rule -Settings (New-Settings) -Mode exact).setting.isApprovalRequired | Should Be $false
        }

        It 'sets the pinned approver on the existing stage and keeps its other settings' {
            $rules = New-LiveRules @{ ApprovalRequired = $false; Approvers = @($principalA); TimeoutDays = 3 }
            $settings = New-Settings -Approval $true
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -ApproverGroupId $approverId)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -ApproverGroupId $approverId -ApproverGroupName 'PIM Approvers'
            $sent = @($body.properties.rules)
            $sent.Count | Should Be 1
            $setting = $sent[0].setting
            $setting.isApprovalRequired | Should Be $true
            $setting.approvalMode | Should Be 'SingleStage'
            $setting.isRequestorJustificationRequired | Should Be $true
            @($setting.approvalStages).Count | Should Be 1
            $stage = @($setting.approvalStages)[0]
            $stage.approvalStageTimeOutInDays | Should Be 3
            $stage.isApproverJustificationRequired | Should Be $true
            @($stage.primaryApprovers).Count | Should Be 1
            @($stage.primaryApprovers)[0].id | Should Be $approverId
            @($stage.primaryApprovers)[0].userType | Should Be 'Group'
            @($stage.primaryApprovers)[0].isBackup | Should Be $false
            @($stage.primaryApprovers)[0].description | Should Be 'PIM Approvers'
        }

        It 'exact mode: turns approval off without touching the stages' {
            $rules = New-LiveRules @{ ApprovalRequired = $true; Approvers = @($principalA) }
            $settings = New-Settings
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -Mode exact)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -Mode exact
            $setting = @($body.properties.rules)[0].setting
            $setting.isApprovalRequired | Should Be $false
            @(@($setting.approvalStages)[0].primaryApprovers)[0].id | Should Be $principalA
        }

        It 'builds a governed rule from scratch when the policy lacks it' {
            $settings = New-Settings -Approval $true
            $drift = @(Compare-PimPolicyRules -Rules @() -Settings $settings -ApproverGroupId $approverId)
            $body = New-PimPolicyPatchBody -Rules @() -Settings $settings -Drift $drift -ApproverGroupId $approverId -ApproverGroupName 'PIM Approvers'
            $sent = @($body.properties.rules)
            (@($sent | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Enablement_EndUser_Assignment,Approval_EndUser_Assignment'
            $sent[0].maximumDuration | Should Be 'PT4H'
            (@($sent[1].enabledRules) -join ',') | Should Be 'MultiFactorAuthentication,Justification'
            $sent[2].ruleType | Should Be 'RoleManagementPolicyApprovalRule'
            @(@($sent[2].setting.approvalStages)[0].primaryApprovers)[0].id | Should Be $approverId
            (@($sent[2].target.operations) -join ',') | Should Be 'All'
        }

        It 'serialises one-element lists as JSON arrays, as Invoke-CloudRequest sends them' {
            $rules = New-LiveRules @{ Enabled = @() }
            $settings = New-Settings -Justification $false -Approval $true
            $drift = @(Compare-PimPolicyRules -Rules $rules -Settings $settings -ApproverGroupId $approverId)
            $body = New-PimPolicyPatchBody -Rules $rules -Settings $settings -Drift $drift -ApproverGroupId $approverId -ApproverGroupName 'PIM Approvers'
            $json = ConvertTo-Json -InputObject $body -Depth 20 -Compress
            $json | Should Match '"enabledRules":\["MultiFactorAuthentication"\]'
            $json | Should Match '"primaryApprovers":\[\{'
            $json | Should Match '"approvalStages":\[\{'
            $json | Should Match '"operations":\["All"\]'
            $json | Should Match '^\{"properties":\{"rules":\[\{'
            $json | Should Not Match '"Count":'
        }
    }

    Context 'report and digest' {
        $evaluations = @(
            [PSCustomObject]@{ Scope = $scopeA; RoleName = 'Owner <admins>'; RoleDefinitionId = 'r1'; PolicyId = 'p1'; Principals = 2; Eligibilities = 3; BaselineSource = 'defaults'; Status = 'Drift'; Outcome = 'Done'; Detail = ''; Drift = @((New-PimDriftItem -RuleId 'Expiration_EndUser_Assignment' -Field 'maximumDuration' -Current 'PT8H' -Desired 'PT4H')) },
            [PSCustomObject]@{ Scope = $scopeB; RoleName = 'Reader'; RoleDefinitionId = 'r2'; PolicyId = 'p2'; Principals = 1; Eligibilities = 1; BaselineSource = 'roles."Reader"'; Status = 'DriftReportOnly'; Outcome = 'Skipped'; Detail = ''; Drift = @((New-PimDriftItem -RuleId 'Enablement_EndUser_Assignment' -Field 'enabledRules.Ticketing' -Current 'true' -Desired 'false')) },
            [PSCustomObject]@{ Scope = $scopeB; RoleName = 'Contributor'; RoleDefinitionId = 'r3'; PolicyId = 'p3'; Principals = 1; Eligibilities = 1; BaselineSource = 'defaults'; Status = 'Compliant'; Outcome = 'None'; Detail = ''; Drift = @() }
        )
        $failures = @([PSCustomObject]@{ Action = 'ListEligibilities'; Target = $rgApp; Outcome = 'Failed'; Detail = 'Arm GET failed with HTTP 403 & more' })

        It 'lists drift field by field, handling, and failures, HTML-encoded' {
            $html = New-PimDigestHtml -Evaluations $evaluations -Failures $failures -RunId $runId -DryRun $false -PairsScanned 3
            $html | Should Match '3 \(scope, role\) pair\(s\) evaluated, 2 with drift, 1 failure\(s\)'
            $html | Should Match 'Owner &lt;admins&gt;'
            $html | Should Not Match 'Owner <admins>'
            $html | Should Match '>patched<'
            $html | Should Match 'reported only \(report_only\)'
            $html | Should Match 'HTTP 403 &amp; more'
            $html | Should Match $runId
            $html | Should Not Match 'Contributor'
            $html | Should Match 'Baseline mode: minimum'
            (New-PimDigestHtml -Evaluations $evaluations -RunId $runId -DryRun $true) | Should Match 'dry run: nothing was changed'
        }

        It 'says why a pair was only reported, and marks the item that must not be patched' {
            $held = [PSCustomObject]@{ Scope = $scopeA; RoleName = 'Owner'; Status = 'DriftReportOnly'; Outcome = 'Skipped'; ReportReason = 'authentication context'; Drift = @((New-PimDriftItem -RuleId 'Enablement_EndUser_Assignment' -Field 'enabledRules.MultiFactorAuthentication' -Current 'false' -Desired 'true' -Blocked 'AuthenticationContext_EndUser_Assignment is on'), (New-PimDriftItem -RuleId 'Expiration_EndUser_Assignment' -Field 'maximumDuration' -Current 'PT8H' -Desired 'PT4H')) }
            Get-PimDriftHandling -Evaluation $held | Should Be 'reported only (authentication context)'
            Get-PimDriftHandling -Evaluation $evaluations[1] | Should Be 'reported only (report_only)'
            Get-PimDriftHandling -Evaluation $evaluations[0] | Should Be 'patched'
            Get-PimDriftHandling -Evaluation ([PSCustomObject]@{ Status = 'Drift'; Outcome = 'Planned' }) | Should Be 'would be patched'
            $html = New-PimDigestHtml -Evaluations @($held) -RunId $runId -DryRun $false -PairsScanned 1 -BaselineMode exact
            $html | Should Match '>not patched: AuthenticationContext_EndUser_Assignment is on<'
            $html | Should Match '>reported only \(authentication context\)<'
            $html | Should Match 'Baseline mode: exact'
        }

        It 'writes one row per pair plus one per failed scope' {
            $rows = @(ConvertTo-PimReportRows -Evaluations $evaluations -ScopeFailures $failures)
            $rows.Count | Should Be 4
            $rows[0].DriftedRules | Should Be 'Expiration_EndUser_Assignment'
            $rows[0].Drift | Should Be 'Expiration_EndUser_Assignment maximumDuration: PT8H -> PT4H'
            $rows[0].ScopeLevel | Should Be 'Subscription'
            $rows[2].DriftedRules | Should Be ''
            $rows[3].Status | Should Be 'Failed'
            $rows[3].Scope | Should Be $rgApp
            $rows[3].ScopeLevel | Should Be 'BelowSubscription'
            $rows[3].Detail | Should Match '^ListEligibilities: '
        }

        It 'writes a header-only CSV with the same columns as a full report' {
            $path = Join-Path -Path $TestDrive -ChildPath 'empty\report.csv'
            Write-PimReport -Path $path -Rows @()
            $headerLine = ([System.IO.File]::ReadAllText($path)).Trim()
            $headerLine | Should Match '^"Scope","ScopeLevel","RoleName"'
            $full = Join-Path -Path $TestDrive -ChildPath 'full\report.csv'
            Write-PimReport -Path $full -Rows @(ConvertTo-PimReportRows -Evaluations $evaluations -ScopeFailures $failures)
            $fullHeader = @([System.IO.File]::ReadAllLines($full))[0]
            $fullHeader | Should Be $headerLine
        }

        It 'writes to a relative path under the PowerShell location, not the process directory' {
            $root = Join-Path -Path $TestDrive -ChildPath 'relative-root'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            ([Environment]::CurrentDirectory).TrimEnd('\') | Should Not Be $root.TrimEnd('\')
            Push-Location -Path $root
            try {
                Write-PimReport -Path '.\out\empty.csv' -Rows @()
                Write-PimReport -Path 'out2\full.csv' -Rows @(ConvertTo-PimReportRows -Evaluations $evaluations)
            }
            finally {
                Pop-Location
            }
            Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'out\empty.csv') | Should Be $true
            @(Import-Csv -Path (Join-Path -Path $root -ChildPath 'out2\full.csv')).Count | Should Be 3
            Test-Path -LiteralPath (Join-Path -Path ([Environment]::CurrentDirectory) -ChildPath 'out\empty.csv') | Should Be $false
        }

        It 'classifies scope levels' {
            Get-PimScopeLevel -Scope $mgPlatform | Should Be 'ManagementGroup'
            Get-PimScopeLevel -Scope ($scopeA + '/') | Should Be 'Subscription'
            Get-PimScopeLevel -Scope $rgApp | Should Be 'BelowSubscription'
            Get-PimScopeLevel -Scope "$rgApp/providers/Microsoft.Web/sites/app" | Should Be 'BelowSubscription'
            Get-PimScopeLevel -Scope '/' | Should Be 'Other'
            Get-PimScopeLevel -Scope '' | Should Be 'Other'
        }
    }

    Context 'run with a mocked tenant' {
        It 'dry run: reads everything, plans exactly the drifted policies, and writes nothing' {
            Set-StandardTenant
            $s = Invoke-StandardRun -DryRun $true
            @($s).Count | Should Be 1
            $global:PimUnexpected.Count | Should Be 0
            $global:PimRequests.Count | Should BeGreaterThan 10
            @($global:PimRequests | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
            $s.Runbook | Should Be 'Invoke-AzurePimPolicyGovernance'
            $s.RunId | Should Be $runId
            $s.DryRun | Should Be $true
            $s.ScopesListed | Should Be 4
            $s.EligibilitiesRead | Should Be 10
            $s.DirectEligibilities | Should Be 5
            $s.EligibilitiesIgnored | Should Be 3
            $s.PairsFound | Should Be 4
            $s.PairsAtManagementGroup | Should Be 1
            $s.PairsAtSubscription | Should Be 2
            $s.PairsBelowSubscription | Should Be 1
            $s.PairsCompliant | Should Be 1
            $s.PairsDrifted | Should Be 2
            $s.PairsReportOnly | Should Be 1
            $s.PairsAuthContextOnly | Should Be 0
            $s.PairsFailed | Should Be 0
            $s.PolicyUpdatesPlanned | Should Be 2
            $s.Counts.UpdatePolicy.Planned | Should Be 2
            $s.Counts.ReportDrift.Skipped | Should Be 1
            $s.Counts.SendDigest.Planned | Should Be 1
            $s.FailureCount | Should Be 0
            $s.DigestSent | Should Be $false
            $s.ApproverGroupId | Should Be $approverId
            $s.ApproverGroups | Should Be 'PIM Approvers'
            $s.Baseline | Should Match '^BaselineJson: activation=PT4H'
            $s.BaselineMode | Should Be 'minimum'
            $s.RoleOverrides | Should Be 2
            $s.RoleOverridesUnmatched | Should Be 0
            $s.PairOverrides | Should Be 0
            $s.Warnings | Should Be 1
            $actions = @(Get-RunLogEntries -Level Action | ForEach-Object { $_.Message })
            @($actions | Where-Object { $_ -like 'Would patch Expiration_EndUser_Assignment, Approval_EndUser_Assignment on the Owner policy at*' }).Count | Should Be 1
            @($actions | Where-Object { $_ -like 'Would patch Enablement_EndUser_Assignment on the Contributor policy at*rg-app*' }).Count | Should Be 1
            @($actions | Where-Object { $_ -like 'Would send the drift digest to iam@corp.example.com*' }).Count | Should Be 1
        }

        It 'lists every descendant scope once, without a filter, and never above the named group' {
            Set-StandardTenant
            Invoke-StandardRun -DryRun $true | Out-Null
            $lists = @(Get-Requests -Method GET -Like '*/roleEligibilityScheduleInstances*' | ForEach-Object { $_.Uri })
            $lists.Count | Should Be 4
            ($lists -join ' ') | Should Not Match 'filter'
            ($lists -join ' ') | Should Not Match 'mg-root'
            ($lists -contains (Get-ListUri -Scope $mgPlatform)) | Should Be $true
            ($lists -contains (Get-ListUri -Scope $mgWorkloads)) | Should Be $true
            ($lists -contains (Get-ListUri -Scope $scopeA)) | Should Be $true
            ($lists -contains (Get-ListUri -Scope $scopeB)) | Should Be $true
            @(Get-Requests -Method GET -Like '*mg-root*').Count | Should Be 0
        }

        It 'tries the roleDefinitionId filter first (undocumented for assignments; results checked on the client)' {
            Set-StandardTenant
            Invoke-StandardRun -DryRun $true | Out-Null
            $request = @(Get-Requests -Method GET -Like "*$rgApp/providers/Microsoft.Authorization/roleManagementPolicyAssignments*")
            $request.Count | Should Be 1
            $decoded = [Uri]::UnescapeDataString($request[0].Uri)
            $decoded.Contains(("`$filter=roleDefinitionId eq '{0}/providers/Microsoft.Authorization/roleDefinitions/{1}'" -f $rgApp, $contributorGuid)) | Should Be $true
            $request[0].Uri | Should Match '&api-version=2020-10-01$'
        }

        It 'live: patches only the drifted rules of the drifted policies and mails one digest' {
            Set-StandardTenant
            $s = Invoke-StandardRun -DryRun $false
            $global:PimUnexpected.Count | Should Be 0
            $patches = @(Get-Requests -Method PATCH)
            $patches.Count | Should Be 2

            $ownerPatch = @($patches | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') })
            $ownerPatch.Count | Should Be 1
            $ownerPatch[0].Headers['Authorization'] | Should Be ('Bearer ' + $global:PimArmToken)
            $ownerBody = ConvertFrom-Json -InputObject $ownerPatch[0].Body
            $ownerRules = @($ownerBody.properties.rules)
            (@($ownerRules | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Approval_EndUser_Assignment'
            $ownerRules[0].maximumDuration | Should Be 'PT1H'
            $ownerRules[1].setting.isApprovalRequired | Should Be $true
            $ownerStage = @($ownerRules[1].setting.approvalStages)[0]
            $ownerStage.approvalStageTimeOutInDays | Should Be 3
            @($ownerStage.primaryApprovers).Count | Should Be 1
            @($ownerStage.primaryApprovers)[0].id | Should Be $approverId
            $ownerPatch[0].Body | Should Match '"primaryApprovers":\[\{'
            $ownerPatch[0].Body | Should Not Match 'Notification_'

            $rgPatch = @($patches | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $rgApp -Name 'policy-contrib-rg') })
            $rgPatch.Count | Should Be 1
            $rgRules = @((ConvertFrom-Json -InputObject $rgPatch[0].Body).properties.rules)
            $rgRules.Count | Should Be 1
            $rgRules[0].id | Should Be 'Enablement_EndUser_Assignment'
            # Minimum mode: the live Ticketing requirement is stricter and stays.
            (@($rgRules[0].enabledRules) -join ',') | Should Be 'Justification,Ticketing,MultiFactorAuthentication'

            @($patches | Where-Object { $_.Uri -like '*policy-contrib-a?*' -or $_.Uri -like '*policy-reader-a*' }).Count | Should Be 0

            $mail = @(Get-Requests -Method POST)
            $mail.Count | Should Be 1
            $mail[0].Headers['Authorization'] | Should Be ('Bearer ' + $global:PimGraphToken)
            $payload = Get-MailPayload
            $payload.saveToSentItems | Should Be $false
            @($payload.message.toRecipients)[0].emailAddress.address | Should Be 'iam@corp.example.com'
            $payload.message.subject | Should Be 'Azure PIM policy governance: 3 drifted pair(s), 0 failure(s)'
            $payload.message.body.content | Should Match '>patched<'
            $payload.message.body.content | Should Match 'reported only'

            $s.DryRun | Should Be $false
            $s.Counts.UpdatePolicy.Done | Should Be 2
            $s.Counts.SendDigest.Done | Should Be 1
            $s.Done | Should Be 3
            $s.Failed | Should Be 0
            $s.DigestSent | Should Be $true
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Done: patch*' }).Count | Should Be 2
        }

        It 'writes one CSV row per pair with its status and outcome' {
            Set-StandardTenant
            $path = Join-Path -Path $TestDrive -ChildPath 'live\pim-policies.csv'
            $s = Invoke-StandardRun -DryRun $false -ReportPath $path
            $s.ReportPath | Should Be $path
            $rows = @(Import-Csv -Path $path)
            $rows.Count | Should Be 4
            $owner = @($rows | Where-Object { $_.RoleName -eq 'Owner' })[0]
            $owner.Status | Should Be 'Drift'
            $owner.Outcome | Should Be 'Done'
            $owner.DriftedRules | Should Be 'Expiration_EndUser_Assignment;Approval_EndUser_Assignment'
            $owner.PolicyId | Should Be "$mgPlatform/providers/Microsoft.Authorization/roleManagementPolicies/policy-owner"
            $owner.Baseline | Should Be 'roles."Owner"'
            $contributorA = @($rows | Where-Object { $_.Scope -eq $scopeA -and $_.RoleName -eq 'Contributor' })[0]
            $contributorA.Status | Should Be 'Compliant'
            $contributorA.Outcome | Should Be 'None'
            $contributorA.Principals | Should Be '2'
            $contributorA.Eligibilities | Should Be '2'
            $reader = @($rows | Where-Object { $_.RoleName -eq 'Reader' })[0]
            $reader.Status | Should Be 'DriftReportOnly'
            $reader.Outcome | Should Be 'Skipped'
        }

        It 'records a 403 on one listing as a Failed row and carries on' {
            Set-StandardTenant
            Add-Route -Uri (Get-ListUri -Scope $scopeB) -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'The client does not have authorization to perform this action.' } }
            $s = Invoke-StandardRun -DryRun $false
            @(Get-Requests -Like (Get-ListUri -Scope $scopeB)).Count | Should Be 1
            $s.ScopeListFailures | Should Be 1
            $s.FailureCount | Should Be 1
            @($s.Failures)[0].Action | Should Be 'ListEligibilities'
            @($s.Failures)[0].Target | Should Be $scopeB
            @($s.Failures)[0].Detail | Should Match 'HTTP 403'
            $s.PairsFound | Should Be 4
            $s.Counts.UpdatePolicy.Done | Should Be 2
            $s.DigestSent | Should Be $true
            (Get-MailPayload).message.subject | Should Be 'Azure PIM policy governance: 3 drifted pair(s), 1 failure(s)'
            (Get-MailPayload).message.body.content | Should Match 'AuthorizationFailed'
        }

        It 'records a 403 on a PATCH as Failed and still patches the next policy' {
            Set-StandardTenant
            Add-Route -Method PATCH -Uri (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'No roleManagementPolicies/write here.' } }
            $path = Join-Path -Path $TestDrive -ChildPath 'patch403\pim.csv'
            $s = Invoke-StandardRun -DryRun $false -ReportPath $path
            @(Get-Requests -Method PATCH).Count | Should Be 2
            $s.Counts.UpdatePolicy.Failed | Should Be 1
            $s.Counts.UpdatePolicy.Done | Should Be 1
            @($s.Failures)[0].Target | Should Be "Owner at $mgPlatform"
            @($s.Failures)[0].Detail | Should Match 'HTTP 403'
            $s.Errors | Should Be 1
            $owner = @(Import-Csv -Path $path | Where-Object { $_.RoleName -eq 'Owner' })[0]
            $owner.Outcome | Should Be 'Failed'
            $owner.Detail | Should Match 'HTTP 403'
            (Get-MailPayload).message.body.content | Should Match 'patch failed'
        }

        It 'records a 403 on a policy read as a Failed row and patches nothing for that pair' {
            Set-StandardTenant
            Add-Route -Uri (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'No read.' } }
            $s = Invoke-StandardRun -DryRun $false
            $s.PairsFailed | Should Be 1
            $s.Counts.ReadPolicy.Failed | Should Be 1
            @(Get-Requests -Method PATCH).Count | Should Be 1
            @(Get-Requests -Method PATCH)[0].Uri | Should Be (Get-PolicyUri -Scope $rgApp -Name 'policy-contrib-rg')
        }

        It 'leaves a policy alone when its id is not at the pair scope' {
            Set-StandardTenant
            $assignment = New-Assignment -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg'
            $assignment.properties.policyId = "$scopeB/providers/Microsoft.Authorization/roleManagementPolicies/policy-sub-b"
            Add-Route -Pattern (Get-AssignmentPattern -Scope $rgApp -RoleGuid $contributorGuid) -Json @{ value = @($assignment) }
            $s = Invoke-StandardRun -DryRun $false
            $s.Counts.ReadPolicy.Failed | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'not a role management policy at this scope'
            @(Get-Requests -Like '*policy-sub-b*').Count | Should Be 0
        }

        It 'trips the breaker before any write, and still writes the report' {
            Set-StandardTenant
            $path = Join-Path -Path $TestDrive -ChildPath 'breaker\pim.csv'
            { Invoke-StandardRun -DryRun $false -Max 1 -ReportPath $path } | Should Throw 'Circuit breaker tripped: PIM policy updates: 2 planned, cap is 1. Nothing was changed.'
            @(Get-Requests -Method PATCH).Count | Should Be 0
            @(Get-Requests -Method POST).Count | Should Be 0
            $rows = @(Import-Csv -Path $path)
            @($rows | Where-Object { $_.Outcome -eq 'Blocked' }).Count | Should Be 2
        }

        It 'evaluates the breaker in a dry run too, and passes at the cap' {
            Set-StandardTenant
            { Invoke-StandardRun -DryRun $true -Max 1 } | Should Throw 'Circuit breaker tripped'
            $global:PimRequests.Count | Should BeGreaterThan 10
            @($global:PimRequests | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
            Set-StandardTenant
            (Invoke-StandardRun -DryRun $true -Max 2).PolicyUpdatesPlanned | Should Be 2
        }

        It 'sends no digest when nothing drifted and nothing failed' {
            Set-StandardTenant
            Add-PolicyRoutes -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner' -Rules (New-Rules -Duration 'PT60M' -ApprovalRequired $true -Approvers @($approverId))
            Add-PolicyRoutes -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg' -RolePrefix $scopeB -Rules (New-Rules)
            Add-PolicyRoutes -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'policy-reader-a' -Rules (New-Rules)
            $s = Invoke-StandardRun -DryRun $false
            @(Get-Requests -Method PATCH).Count | Should Be 0
            @(Get-Requests -Method POST).Count | Should Be 0
            $s.PairsCompliant | Should Be 4
            $s.DigestSent | Should Be $false
            $s.Planned + $s.Done + $s.Failed + $s.Skipped | Should Be 0
        }

        It 'reports drift without mailing when there are no recipients' {
            Set-StandardTenant
            $s = Invoke-StandardRun -DryRun $false -Recipients ''
            @(Get-Requests -Method POST).Count | Should Be 0
            $s.Counts.UpdatePolicy.Done | Should Be 2
            $s.DigestSent | Should Be $false
        }

        It 'falls back to the full assignment list when the filter finds nothing' {
            Set-StandardTenant
            Add-Route -Pattern (Get-AssignmentPattern -Scope $rgApp -RoleGuid $contributorGuid) -Json @{ value = @() }
            $all = "$arm$rgApp/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01"
            Add-Route -Uri $all -Json @{
                value    = @(
                    (New-Assignment -Scope $rgApp -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'policy-reader-rg'),
                    (New-Assignment -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg')
                )
                nextLink = $null
            }
            $s = Invoke-StandardRun -DryRun $true
            @(Get-Requests -Like $all).Count | Should Be 1
            $s.PairsDrifted | Should Be 2
            $s.FailureCount | Should Be 0
        }

        It 'falls back to the full assignment list when the service refuses the filter' {
            Set-StandardTenant
            Add-Route -Pattern (Get-AssignmentPattern -Scope $rgApp -RoleGuid $contributorGuid) -Status 400 -Json @{ error = @{ code = 'InvalidFilter'; message = 'The filter is not supported.' } }
            $all = "$arm$rgApp/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01"
            Add-Route -Uri $all -Json @{ value = @((New-Assignment -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg')) }
            $s = Invoke-StandardRun -DryRun $true
            @(Get-Requests -Like $all).Count | Should Be 1
            $s.PairsDrifted | Should Be 2
            $s.FailureCount | Should Be 0
        }

        It 'records a pair with no policy assignment as Failed' {
            Set-StandardTenant
            Add-Route -Pattern (Get-AssignmentPattern -Scope $rgApp -RoleGuid $contributorGuid) -Json @{ value = @() }
            Add-Route -Uri "$arm$rgApp/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=2020-10-01" -Json @{ value = @() }
            $s = Invoke-StandardRun -DryRun $true
            $s.PairsFailed | Should Be 1
            @($s.Failures)[0].Detail | Should Match 'No role management policy assignment'
            $s.PolicyUpdatesPlanned | Should Be 1
        }

        It 'sweeps one subscription by sub: prefix without reading management groups' {
            Set-StandardTenant
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames '["sub:Workloads"]' -AccessToken $global:PimTokens -RunId $runId 2>$null
            $global:PimUnexpected.Count | Should Be 0
            @(Get-Requests -Like '*Microsoft.Management*').Count | Should Be 0
            @(Get-Requests -Like 'https://graph.microsoft.com/*').Count | Should Be 0
            $s.ScopesListed | Should Be 1
            $s.PairsFound | Should Be 1
            $s.PairsDrifted | Should Be 1
            $s.Baseline | Should Match '^built-in stack defaults'
            $s.Counts.UpdatePolicy.Planned | Should Be 1
            $s.ScopeNames | Should Be 'sub:Workloads'
        }

        It 'refuses a name that matches both a management group and a subscription' {
            Set-StandardTenant
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Workloads' -AccessToken $global:PimTokens 2>$null } | Should Throw 'matches both management group'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0
        }

        It 'refuses a name that is neither' {
            Set-StandardTenant
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Nowhere' -AccessToken $global:PimTokens 2>$null } | Should Throw 'is neither a management group nor a subscription'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'mg:Identity Production' -AccessToken $global:PimTokens 2>$null } | Should Throw 'was not found'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0
        }

        It 'stops on an HTTP error while resolving an unprefixed name' {
            Set-StandardTenant
            Add-Route -Uri "$arm/providers/Microsoft.Management/managementGroups?api-version=2020-05-01" -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'No management group read.' } }
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Identity Production' -AccessToken $global:PimTokens 2>$null } | Should Throw 'HTTP 403'
        }

        It 'sweeps the group itself when its descendants cannot be read' {
            Set-StandardTenant
            Add-Route -Uri "$arm$mgPlatform/descendants?api-version=2020-05-01" -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'No descendants read.' } }
            $s = Invoke-StandardRun -DryRun $true -ScopeNames 'mg:Platform'
            $s.ScopesListed | Should Be 1
            $s.Counts.ListDescendants.Failed | Should Be 1
            # Only the group itself can be proven to be in the sweep, so the
            # subscription-level instance in its listing is ignored.
            $s.PairsFound | Should Be 1
            $s.EligibilitiesIgnored | Should Be 3
            $s.PolicyUpdatesPlanned | Should Be 1
        }

        It 'refuses bad input before any call' {
            Reset-Http
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineJson '{"defaults":{"require_approval":true}}' -AccessToken $global:PimTokens } | Should Throw 'ApproverGroupName is empty'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineJson '{"defaults":{"require_aproval":true}}' -AccessToken $global:PimTokens } | Should Throw 'unknown key'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -Recipients 'iam@corp.example.com' -AccessToken $global:PimTokens } | Should Throw 'SenderMailbox must be a mailbox address'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -Recipients 'not an address' -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken $global:PimTokens } | Should Throw 'is not a mail address'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames ' ; , ' -AccessToken $global:PimTokens } | Should Throw 'ScopeNames is empty'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames '["mg:"]' -AccessToken $global:PimTokens } | Should Throw 'has no name'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames '[{"name":"Platform"}]' -AccessToken $global:PimTokens } | Should Throw 'ScopeNames must be a JSON array of strings'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineJson '{"pairs":[{"role_name":"Owner"}]}' -AccessToken $global:PimTokens } | Should Throw 'pairs[0].scope must be an object'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineJson '{"mode":"loose"}' -AccessToken $global:PimTokens } | Should Throw 'is not valid'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -ApproverGroupName 'PIM Approvers' -BaselineJson '{"defaults":{"approver_groups":["Other"]}}' -AccessToken $global:PimTokens } | Should Throw 'is not one of BaselineJson defaults.approver_groups'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -ApproverGroupName 'PIM Approvers' -BaselineJson '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"S"},"activation":{"require_approval":true,"approver_groups":[]}}]}' -AccessToken $global:PimTokens } | Should Throw 'its approver_groups is empty'
            $global:PimRequests.Count | Should Be 0
        }

        It 'refuses a comma or semicolon list that mixes prefixed and unprefixed names' {
            Reset-Http
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Example, Production;mg:Platform' -AccessToken $global:PimTokens 2>$null } | Should Throw 'mixes prefixed and unprefixed entries'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames '"sub:Example, Production;mg:Platform"' -AccessToken $global:PimTokens 2>$null } | Should Throw '"Production"'
            $global:PimRequests.Count | Should Be 0
            Test-PimJsonArrayText -Text ' ["sub:Example, Production"] ' | Should Be $true
            Test-PimJsonArrayText -Text '"[\"mg:Platform\"]"' | Should Be $true
            Test-PimJsonArrayText -Text 'sub:Example, Production' | Should Be $false
            Test-PimJsonArrayText -Text '' | Should Be $false
        }

        It 'keeps a comma inside a name in the JSON array form, and accepts an all-prefixed list' {
            Set-StandardTenant
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames '["sub:Example, Production","mg:Platform"]' -AccessToken $global:PimTokens 2>$null } | Should Throw 'Subscription "Example, Production" was not found'
            Set-StandardTenant
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'mg:Platform; sub:Workloads' -AccessToken $global:PimTokens -RunId $runId 2>$null
            $global:PimUnexpected.Count | Should Be 0
            $s.ScopeNames | Should Be 'mg:Platform; sub:Workloads'
            $s.PairsFound | Should Be 4
        }

        It 'holds one role at two scopes to its two declared pairs, and its other pairs to "roles"' {
            Set-StandardTenant
            Add-Route -Uri (Get-ListUri -Scope $scopeA) -Json @{
                value = @(
                    (New-Instance -Name 'inst-contrib-a1' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor'),
                    (New-Instance -Name 'inst-reader' -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader'),
                    (New-Instance -Name 'inst-owner-a' -Scope $scopeA -RoleGuid $ownerGuid -RoleName 'Owner')
                )
            }
            Add-Route -Uri (Get-ListUri -Scope $scopeB) -Json @{
                value = @(
                    (New-Instance -Name 'inst-contrib-rg' -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -RolePrefix $scopeB),
                    (New-Instance -Name 'inst-owner-b' -Scope $scopeB -RoleGuid $ownerGuid -RoleName 'Owner')
                )
            }
            Add-PolicyRoutes -Scope $scopeA -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner-a' -Rules (New-Rules -Duration 'PT8H')
            Add-PolicyRoutes -Scope $scopeB -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner-b' -Rules (New-Rules -Duration 'PT3H')
            # The shape jsonencode() gives for the PIM governance cell's policies map.
            $baseline = ConvertTo-Json -Depth 10 -Compress -InputObject @{
                roles = @{ Owner = @{ activation_maximum_duration = 'PT2H' }; Reader = @{ report_only = $true } }
                pairs = @{
                    'owner-at-platform' = @{ role_name = 'Owner'; scope = @{ type = 'management_group'; name = 'Platform' }; activation = @{ maximum_duration = 'PT1H'; require_approval = $true; approver_groups = @('Platform Approvers', 'PIM Approvers') }; eligible_assignment_rules = @{ expire_after = 'P365D' } }
                    'owner-at-identity' = @{ role_name = 'Owner'; scope = @{ type = 'subscription'; name = 'Identity Production' }; activation = @{ maximum_duration = $null; require_approval = $null } }
                    'owner-elsewhere'   = @{ role_name = 'Owner'; scope = @{ type = 'subscription'; name = 'Not Readable' } }
                    'contrib-at-app'    = @{ role_name = 'Contributor'; scope = @{ type = 'resource_group'; name = 'rg-app'; subscription = 'Workloads' }; report_only = $true }
                }
            }
            $path = Join-Path -Path $TestDrive -ChildPath 'pairs\pim.csv'
            $s = Invoke-StandardRun -DryRun $false -Baseline $baseline -ReportPath $path
            $global:PimUnexpected.Count | Should Be 0
            $s.PairsFound | Should Be 6
            $s.PairOverrides | Should Be 4
            $s.PairOverridesResolved | Should Be 3
            $s.PairOverridesMatched | Should Be 3
            $s.RoleOverridesUnmatched | Should Be 0
            $s.ApproverGroups | Should Be 'PIM Approvers; Platform Approvers'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'BaselineJson pairs."owner-elsewhere" (Owner at subscription "Not Readable") was dropped*' }).Count | Should Be 1

            $patches = @(Get-Requests -Method PATCH)
            $patches.Count | Should Be 3
            $s.Counts.UpdatePolicy.Done | Should Be 3
            $s.Counts.ReportDrift.Skipped | Should Be 2

            $platform = @($patches | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') })
            $platformRules = @((ConvertFrom-Json -InputObject $platform[0].Body).properties.rules)
            (@($platformRules | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Approval_EndUser_Assignment'
            $platformRules[0].maximumDuration | Should Be 'PT1H'
            $platformApprovers = @(@($platformRules[1].setting.approvalStages)[0].primaryApprovers)
            (@($platformApprovers | ForEach-Object { $_.id }) -join ',') | Should Be ('{0},{1}' -f $platformApproverId, $approverId)
            (@($platformApprovers | ForEach-Object { $_.description }) -join ',') | Should Be 'Platform Approvers,PIM Approvers'

            # Declared at the identity subscription with no activation values:
            # the stack defaults, not roles."Owner".
            $identity = @($patches | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $scopeA -Name 'policy-owner-a') })
            $identityRules = @((ConvertFrom-Json -InputObject $identity[0].Body).properties.rules)
            $identityRules.Count | Should Be 1
            $identityRules[0].maximumDuration | Should Be 'PT4H'

            # Not declared: roles."Owner".
            $undeclared = @($patches | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $scopeB -Name 'policy-owner-b') })
            $undeclaredRules = @((ConvertFrom-Json -InputObject $undeclared[0].Body).properties.rules)
            $undeclaredRules.Count | Should Be 1
            $undeclaredRules[0].maximumDuration | Should Be 'PT2H'

            @($patches | Where-Object { $_.Uri -like '*policy-contrib-rg*' -or $_.Uri -like '*policy-reader-a*' }).Count | Should Be 0
            $rows = @(Import-Csv -Path $path)
            (@($rows | Where-Object { $_.Scope -eq $mgPlatform })[0]).Baseline | Should Be 'pairs."owner-at-platform"'
            (@($rows | Where-Object { $_.Scope -eq $scopeA -and $_.RoleName -eq 'Owner' })[0]).Baseline | Should Be 'pairs."owner-at-identity"'
            (@($rows | Where-Object { $_.Scope -eq $scopeB -and $_.RoleName -eq 'Owner' })[0]).Baseline | Should Be 'roles."Owner"'
            $app = @($rows | Where-Object { $_.Scope -eq $rgApp })[0]
            $app.Baseline | Should Be 'pairs."contrib-at-app"'
            $app.Status | Should Be 'DriftReportOnly'
            $app.ScopeLevel | Should Be 'BelowSubscription'
            $app.Mode | Should Be 'minimum'
        }

        It 'leaves every declared pair to Terraform with pairs_report_only' {
            Set-StandardTenant
            $baseline = '{"pairs_report_only":true,"roles":{"Reader":{"report_only":true}},"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"Platform"},"activation":{"maximum_duration":"PT1H"}}]}'
            $s = Invoke-StandardRun -DryRun $false -Baseline $baseline
            @(Get-Requests -Method PATCH | Where-Object { $_.Uri -like '*policy-owner*' }).Count | Should Be 0
            @(Get-Requests -Method PATCH).Count | Should Be 1
            $s.PairsReportOnly | Should Be 2
            $s.PairOverridesMatched | Should Be 1
        }

        It 'stops before reading PIM data when a pair entry is ambiguous or its lookup fails' {
            Set-StandardTenant
            $twice = '{"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"Platform"}},{"role_name":"owner","scope":{"type":"management_group","name":"platform"}}]}'
            { Invoke-StandardRun -DryRun $true -Baseline $twice -ScopeNames 'mg:Platform' } | Should Throw 'both name role "owner"'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0

            # A management group named by its id: Terraform matches display
            # names only, so the declaration cannot be the one it applies.
            Set-StandardTenant
            $byId = '{"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"mg-platform"}}]}'
            { Invoke-StandardRun -DryRun $true -Baseline $byId -ScopeNames 'mg:Platform' } | Should Throw '(Owner at management_group "mg-platform"): "mg-platform" is no management group''s display name, but it is the id of the management group whose display name is "Platform"'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0

            Set-StandardTenant
            Add-Route -Uri "$arm/subscriptions?api-version=2022-12-01" -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = 'No subscription read.' } }
            $bySubscription = '{"pairs":[{"role_name":"Owner","scope":{"type":"subscription","name":"Identity Production"}}]}'
            { Invoke-StandardRun -DryRun $true -Baseline $bySubscription -ScopeNames 'mg:Platform' } | Should Throw 'BaselineJson pairs[0] (Owner at subscription "Identity Production")'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0
        }

        It 'matches a management group pair by display name only, like the Terraform module, reading the list once' {
            Set-StandardTenant
            $groupsUri = "$arm/providers/Microsoft.Management/managementGroups?api-version=2020-05-01"
            $two = '{"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"platform"}},{"role_name":"Reader","scope":{"type":"management_group","name":" Workloads "}},{"role_name":"Reader","scope":{"type":"management_group","name":"Gone"}}]}'
            $s = Invoke-StandardRun -DryRun $true -Baseline $two -ScopeNames 'sub:Workloads'
            $global:PimUnexpected.Count | Should Be 0
            @(Get-Requests -Method GET -Like $groupsUri).Count | Should Be 1
            $s.PairOverrides | Should Be 3
            $s.PairOverridesResolved | Should Be 2
            $s.PairOverridesMatched | Should Be 0
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like '*(Owner at management_group "platform") is /providers/Microsoft.Management/managementGroups/mg-platform.' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like '*(Reader at management_group "Workloads") is /providers/Microsoft.Management/managementGroups/mg-workloads.' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*(Reader at management_group "Gone") was dropped because its scope was not found*Management group with display name "Gone" was not found among the 3 management group(s)*' }).Count | Should Be 1

            # The list is read again in the next run.
            Set-StandardTenant
            Invoke-StandardRun -DryRun $true -Baseline $two -ScopeNames 'sub:Workloads' | Out-Null
            @(Get-Requests -Method GET -Like $groupsUri).Count | Should Be 1
        }

        It 'stops when a management group pair display name is not unique, or its id is not valid' {
            Set-StandardTenant
            Add-Route -Uri "$arm/providers/Microsoft.Management/managementGroups?api-version=2020-05-01" -Json @{
                value = @(
                    @{ id = $mgPlatform; name = 'mg-platform'; properties = @{ displayName = 'Platform' } },
                    @{ id = '/providers/Microsoft.Management/managementGroups/mg-platform-2'; name = 'mg-platform-2'; properties = @{ displayName = 'PLATFORM' } },
                    @{ id = '/providers/Microsoft.Management/managementGroups/bad.'; name = 'bad.'; properties = @{ displayName = 'Bad Id' } }
                )
            }
            $duplicate = '{"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"Platform"}}]}'
            { Invoke-StandardRun -DryRun $true -Baseline $duplicate -ScopeNames 'sub:Workloads' } | Should Throw 'Management group display name "Platform" is not unique (2 matches: mg-platform, mg-platform-2)'
            $badId = '{"pairs":[{"role_name":"Owner","scope":{"type":"management_group","name":"Bad Id"}}]}'
            { Invoke-StandardRun -DryRun $true -Baseline $badId -ScopeNames 'sub:Workloads' } | Should Throw 'matched an entry whose id "bad." is not a valid management group id'
            @(Get-Requests -Like '*roleEligibilityScheduleInstances*').Count | Should Be 0
        }

        It 'fails closed when the role name cannot be read and the baseline has overrides' {
            Set-StandardTenant
            Add-Route -Uri (Get-ListUri -Scope $mgPlatform) -Json @{
                value = @(
                    (New-Instance -Name 'inst-owner' -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -NoExpanded),
                    (New-Instance -Name 'inst-contrib-a1' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor')
                )
            }
            Add-Route -Uri (Get-ListUri -Scope $scopeA) -Json @{
                value = @(
                    (New-Instance -Name 'inst-contrib-a1' -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor'),
                    (New-Instance -Name 'inst-reader' -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -NoExpanded)
                )
            }
            Add-PolicyRoutes -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner' -Rules (New-Rules -Duration 'PT8H') -NoRoleName
            Add-PolicyRoutes -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'policy-reader-a' -Rules (New-Rules -Duration 'PT24H') -NoRoleName
            # BaselineJson has Owner {PT1H, approval} and Reader {report_only}:
            # neither may fall back to the defaults.
            $s = Invoke-StandardRun -DryRun $false
            $s.PairsFound | Should Be 4
            $s.PairsFailed | Should Be 2
            $s.Counts.ReadPolicy.Failed | Should Be 2
            @($s.Failures | Where-Object { $_.Detail -like '*role display name could not be read*' }).Count | Should Be 2
            $patches = @(Get-Requests -Method PATCH)
            $patches.Count | Should Be 1
            $patches[0].Uri | Should Be (Get-PolicyUri -Scope $rgApp -Name 'policy-contrib-rg')
            @(Get-Requests -Method GET -Like (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner')).Count | Should Be 0
            @(Get-Requests -Method GET -Like (Get-PolicyUri -Scope $scopeA -Name 'policy-reader-a')).Count | Should Be 0
            $s.RoleOverridesUnmatched | Should Be 2
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'BaselineJson roles."Owner" matched no role*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message -like 'Could not evaluate (role name not read) (66666666-*' }).Count | Should Be 1
        }

        It 'holds a nameless pair to the defaults when the baseline has no overrides' {
            Set-StandardTenant
            Add-Route -Uri (Get-ListUri -Scope $scopeB) -Json @{ value = @((New-Instance -Name 'inst-contrib-rg' -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -RolePrefix $scopeB -NoExpanded)) }
            Add-PolicyRoutes -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg' -RolePrefix $scopeB -Rules (New-Rules -Enabled @('Justification')) -NoRoleName
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Workloads' -AccessToken $global:PimTokens -RunId $runId 2>$null
            $s.PairsFailed | Should Be 0
            $s.PairsDrifted | Should Be 1
            @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like "Would patch Enablement_EndUser_Assignment on the role $contributorGuid policy at*" }).Count | Should Be 1
        }

        It 'takes the role name from the policy assignment when the eligibility has no expandedProperties' {
            Set-StandardTenant
            Add-Route -Uri (Get-ListUri -Scope $mgPlatform) -Json @{
                value = @((New-Instance -Name 'inst-owner' -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -NoExpanded))
            }
            $path = Join-Path -Path $TestDrive -ChildPath 'fallback\pim.csv'
            $s = Invoke-StandardRun -DryRun $false -ReportPath $path
            $s.PairsFailed | Should Be 0
            $owner = @(Import-Csv -Path $path | Where-Object { $_.Scope -eq $mgPlatform })[0]
            $owner.RoleName | Should Be 'Owner'
            $owner.Baseline | Should Be 'roles."Owner"'
            $ownerPatch = @(Get-Requests -Method PATCH | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') })
            $ownerPatch.Count | Should Be 1
            $body = ConvertFrom-Json -InputObject $ownerPatch[0].Body
            @($body.properties.rules)[0].maximumDuration | Should Be 'PT1H'
            @($body.properties.rules)[1].setting.isApprovalRequired | Should Be $true
        }

        It 'warns about a "roles" key that matches no role in the sweep' {
            Set-StandardTenant
            $s = Invoke-StandardRun -DryRun $true -Baseline '{"roles":{"Ownr":{"activation_maximum_duration":"PT1H"},"Reader":{"report_only":true}}}'
            $s.RoleOverridesUnmatched | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'BaselineJson roles."Ownr" matched no role with a direct eligibility in the sweep*' }).Count | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'BaselineJson roles."Reader"*' }).Count | Should Be 0
        }

        It 'minimum mode never loosens a stricter policy; exact mode does, only when asked' {
            Set-StandardTenant
            $strict = New-Rules -Duration 'PT1H' -Enabled @('MultiFactorAuthentication', 'Justification', 'Ticketing') -ApprovalRequired $true -Approvers @($principalA)
            Add-PolicyRoutes -Scope $mgPlatform -RoleGuid $ownerGuid -RoleName 'Owner' -PolicyName 'policy-owner' -Rules $strict
            Add-PolicyRoutes -Scope $scopeA -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-a' -Rules $strict
            Add-PolicyRoutes -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg' -RolePrefix $scopeB -Rules $strict
            Add-PolicyRoutes -Scope $scopeA -RoleGuid $readerGuid -RoleName 'Reader' -PolicyName 'policy-reader-a' -Rules $strict
            $s = Invoke-StandardRun -DryRun $false -Baseline ''
            @(Get-Requests -Method PATCH).Count | Should Be 0
            $s.PairsCompliant | Should Be 4
            $s.BaselineMode | Should Be 'minimum'

            $global:PimRequests.Clear()
            $e = Invoke-StandardRun -DryRun $false -Baseline '{"mode":"exact"}'
            $e.BaselineMode | Should Be 'exact'
            $patches = @(Get-Requests -Method PATCH)
            $patches.Count | Should Be 4
            $rules = @((ConvertFrom-Json -InputObject $patches[0].Body).properties.rules)
            (@($rules | ForEach-Object { $_.id }) -join ',') | Should Be 'Expiration_EndUser_Assignment,Enablement_EndUser_Assignment,Approval_EndUser_Assignment'
            $rules[0].maximumDuration | Should Be 'PT4H'
            (@($rules[1].enabledRules) -join ',') | Should Be 'MultiFactorAuthentication,Justification'
            $rules[2].setting.isApprovalRequired | Should Be $false
        }

        It 'reports, and never patches, a policy that uses an authentication context' {
            Set-StandardTenant
            Add-PolicyRoutes -Scope $rgApp -RoleGuid $contributorGuid -RoleName 'Contributor' -PolicyName 'policy-contrib-rg' -RolePrefix $scopeB -Rules (New-Rules -Duration 'PT8H' -Enabled @('Justification') -AuthContext $true)
            $path = Join-Path -Path $TestDrive -ChildPath 'authctx\pim.csv'
            foreach ($baseline in @($global:PimBaseline, $global:PimBaseline.Replace('{"roles"', '{"mode":"exact","roles"'))) {
                $global:PimRequests.Clear()
                $s = Invoke-StandardRun -DryRun $false -Baseline $baseline -ReportPath $path
                $patches = @(Get-Requests -Method PATCH)
                $patches.Count | Should Be 1
                $patches[0].Uri | Should Be (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner')
                $s.PairsAuthContextOnly | Should Be 1
                $s.PairsReportOnly | Should Be 2
                $s.Counts.ReportDrift.Skipped | Should Be 2
                $app = @(Import-Csv -Path $path | Where-Object { $_.Scope -eq $rgApp })[0]
                $app.Status | Should Be 'DriftReportOnly'
                $app.Outcome | Should Be 'Skipped'
                $app.Detail | Should Match '^not patched: AuthenticationContext_EndUser_Assignment is on'
                $app.Drift | Should Match 'maximumDuration: PT8H -> PT4H'
                (Get-MailPayload).message.body.content | Should Match 'reported only \(authentication context\)'
            }
            $s.BaselineMode | Should Be 'exact'
        }

        It 'never writes a token to the log, the summary, or the report' {
            Set-StandardTenant
            Add-Route -Method PATCH -Uri (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') -Status 403 -Json @{ error = @{ code = 'AuthorizationFailed'; message = ('Token ' + $global:PimArmToken + ' may not write.') } }
            $path = Join-Path -Path $TestDrive -ChildPath 'tokens\pim.csv'
            $s = Invoke-StandardRun -DryRun $false -ReportPath $path
            $log = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
            $log.Contains($global:PimArmToken) | Should Be $false
            $log.Contains($global:PimGraphToken) | Should Be $false
            $log | Should Match 'caller-supplied token'
            $json = ConvertTo-Json -InputObject $s -Depth 10
            $json.Contains($global:PimArmToken) | Should Be $false
            $json.Contains($global:PimGraphToken) | Should Be $false
            ([System.IO.File]::ReadAllText($path)).Contains($global:PimArmToken) | Should Be $false
            $mailText = (@(Get-Requests -Method POST) | ForEach-Object { $_.Body }) -join ''
            $mailText.Contains($global:PimArmToken) | Should Be $false
            (@($s.Failures)[0].Detail) | Should Match 'redacted'
        }

        It 'uses the US Government endpoints when asked' {
            Reset-Http
            Add-Route -Uri 'https://management.usgovcloudapi.net/subscriptions?api-version=2022-12-01' -Json @{ value = @(@{ id = "/subscriptions/$subC"; subscriptionId = $subC; displayName = 'Sandbox'; state = 'Enabled' }) }
            Add-Route -Uri "https://management.usgovcloudapi.net/subscriptions/$subC/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01" -Json @{ value = @() }
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Sandbox' -Environment USGov -AccessToken $global:PimTokens -RunId $runId 2>$null
            $global:PimUnexpected.Count | Should Be 0
            $s.Environment | Should Be 'USGov'
            $s.PairsFound | Should Be 0
            @($global:PimRequests | Where-Object { $_.Uri -notlike 'https://management.usgovcloudapi.net/*' }).Count | Should Be 0
        }
    }

    Context 'baseline source: BaselineJson, then the Automation variable, then the defaults' {
        # Owner held to PT2H, Reader report-only; needs no approver group.
        $variableBaseline = '{"roles":{"Owner":{"activation_maximum_duration":"PT2H"},"Reader":{"report_only":true}}}'
        $convertedObject = '@{roles=; pairs=System.Object[]; mode=minimum}'

        function Get-OwnerPlan {
            return @(Get-RunLogEntries -Level Action | Where-Object { $_.Message -like 'Would patch *on the Owner policy at*' } | ForEach-Object { $_.Message })
        }

        It 'takes BaselineJson and does not read the variable' {
            Reset-Http
            # The variable is missing: reading it would throw.
            Set-BaselineVariables -Values @{}
            $picked = Resolve-PimBaselineText -BaselineJson $global:PimBaseline -VariableName 'PimPolicy_AzureBaseline'
            $picked.Text | Should BeExactly $global:PimBaseline
            $picked.Origin | Should Be 'BaselineJson'
            $picked.FromVariable | Should Be $false
            $picked.VariableName | Should Be 'PimPolicy_AzureBaseline'
        }

        It 'reads the named variable when BaselineJson is blank, and never logs its value' {
            Reset-Http
            Set-BaselineVariables -Values @{ pimpolicy_azurebaseline = $variableBaseline; Other = '{"mode":"exact"}' }
            Initialize-RunContext -RunbookName 'Invoke-AzurePimPolicyGovernance' -RunId $runId -AccessToken $global:PimTokens -DryRun $true
            $picked = Resolve-PimBaselineText -BaselineJson "  `r`n " -VariableName ' PimPolicy_AzureBaseline '
            $picked.Text | Should BeExactly $variableBaseline
            $picked.Origin | Should Be 'Automation variable "PimPolicy_AzureBaseline"'
            $picked.FromVariable | Should Be $true
            (Resolve-PimBaselineText -BaselineJson '' -VariableName 'Other').Text | Should BeExactly '{"mode":"exact"}'
            $log = (@(Get-RunLogEntries) | ForEach-Object { $_.Message }) -join "`n"
            $log | Should Match 'Baseline from Automation variable "PimPolicy_AzureBaseline" \(\d+ characters\)'
            $log.Contains('PT2H') | Should Be $false
            $log.Contains('report_only') | Should Be $false
        }

        It 'uses the built-in defaults when both are empty, or when the variable is empty, and logs which' {
            Reset-Http
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $variableBaseline; Blank = "   " }
            Initialize-RunContext -RunbookName 'Invoke-AzurePimPolicyGovernance' -RunId $runId -AccessToken $global:PimTokens -DryRun $true
            $none = Resolve-PimBaselineText -BaselineJson '' -VariableName ''
            $none.Text | Should Be ''
            $none.FromVariable | Should Be $false
            $none.Origin | Should Match '^built-in stack defaults'
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -eq 'BaselineJson and BaselineVariableName are both empty, so every pair is held to the built-in stack defaults.' }).Count | Should Be 1

            $blank = Resolve-PimBaselineText -BaselineJson $null -VariableName 'Blank'
            $blank.Text | Should Be ''
            $blank.FromVariable | Should Be $true
            $blank.Origin | Should Be 'built-in stack defaults (Automation variable "Blank" is empty)'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like 'BaselineJson is empty and Automation variable "Blank" is empty*built-in stack defaults*' }).Count | Should Be 1
            (ConvertFrom-PimBaselineJson -Json $blank.Text -Origin $blank.Origin).Source | Should Match '^built-in stack defaults \(Automation variable "Blank" is empty\): activation=PT4H'
        }

        It 'stops when the variable is missing, and says how to run locally' {
            Reset-Http
            Set-BaselineVariables -Values @{ Other = $variableBaseline }
            $message = ''
            try { Resolve-PimBaselineText -BaselineJson '' -VariableName 'PimPolicy_AzureBaseline' } catch { $message = $_.Exception.Message }
            $message | Should Match '^BaselineJson is empty, so the baseline is read from Automation variable "PimPolicy_AzureBaseline", and that failed: Automation variable "PimPolicy_AzureBaseline" is not in the local variable table'
            $message.Contains("pass BaselineVariableName '' to hold every pair to the built-in defaults") | Should Be $true
            $message.Contains('-BaselineJson (Get-Content -Raw -Path .\baseline.json)') | Should Be $true
        }

        It 'stops outside Azure Automation when no variable table is given' {
            Reset-Http
            Set-BaselineVariables -Values $null
            try {
                (Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
                { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Workloads' -AccessToken $global:PimTokens -RunId $runId 2>$null } | Should Throw 'can only be read inside Azure Automation'
                { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'sub:Workloads' -AccessToken $global:PimTokens -RunId $runId 2>$null } | Should Throw 'For a local run, pass the baseline with -BaselineJson'
                $global:PimRequests.Count | Should Be 0
            }
            finally { Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '' } }
        }

        It 'refuses a baseline that parameter binding turned into "@{...}" or "System.Object[]", before any call' {
            Reset-Http
            foreach ($value in @($convertedObject, 'System.Object[]', ' System.Collections.Hashtable')) {
                $message = ''
                try { Invoke-StandardRun -DryRun $true -Baseline $value } catch { $message = $_.Exception.Message }
                $message | Should Match '^BaselineJson starts with "(@\{|System\.Object|System\.Collections\.)", which is how PowerShell writes an object converted to a string'
                $message | Should Match 'parameter binding converted the result to a string'
                $message | Should Match 'supply it through the Automation string variable named by BaselineVariableName \("PimPolicy_AzureBaseline"\)'
                $message | Should Match 'leave BaselineJson empty'
            }
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineJson $convertedObject -BaselineVariableName 'PimPolicy_Custom' -AccessToken $global:PimTokens } | Should Throw 'named by BaselineVariableName ("PimPolicy_Custom")'
            { ConvertFrom-PimBaselineJson -Json $convertedObject } | Should Throw 'BaselineJson starts with "@{"'
            $global:PimRequests.Count | Should Be 0
        }

        It 'refuses a variable whose value is text made of an object, before any call' {
            Reset-Http
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $convertedObject }
            $message = ''
            try { Invoke-StandardRun -DryRun $true -Baseline '' } catch { $message = $_.Exception.Message }
            $message | Should Match '^Automation variable "PimPolicy_AzureBaseline" starts with "@\{"'
            $message | Should Match 'converted from an object to a string before it was stored'
            $message | Should Match 'Store the baseline JSON text itself in the variable'
            $global:PimRequests.Count | Should Be 0
        }

        It 'passes JSON that merely contains "@{" or "System.Object", and refuses converted lists' {
            Assert-PimTextNotConverted -Value '{"roles":{"@{odd}":{"report_only":true}}}' -Label 'BaselineJson' -Remedy 'x'
            Assert-PimTextNotConverted -Value '' -Label 'BaselineJson' -Remedy 'x'
            Assert-PimTextNotConverted -Value $null -Label 'BaselineJson' -Remedy 'x'
            Assert-PimTextNotConverted -Value 'mg:System.Objects' -Label 'ScopeNames' -Remedy 'x'
            { Assert-PimTextNotConverted -Value 'system.object[]' -Label 'X' -Remedy 'x' } | Should Not Throw
            Reset-Http
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'System.Object[]' -BaselineVariableName '' -AccessToken $global:PimTokens } | Should Throw 'ScopeNames starts with "System.Object"'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'System.Object[]' -BaselineVariableName '' -AccessToken $global:PimTokens } | Should Throw 'such as "mg:Platform;sub:Identity Production", never as a JSON array'
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'mg:Platform' -Recipients '@{address=iam@corp.example.com}' -SenderMailbox 'iam-noreply@corp.example.com' -BaselineVariableName '' -AccessToken $global:PimTokens } | Should Throw 'Recipients starts with "@{"'
            $global:PimRequests.Count | Should Be 0
        }

        It 'run: BaselineJson wins over the variable' {
            Set-StandardTenant
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $variableBaseline }
            $s = Invoke-StandardRun -DryRun $true
            $s.Baseline | Should Match '^BaselineJson: '
            $s.BaselineFromVariable | Should Be $false
            $s.BaselineVariableName | Should Be 'PimPolicy_AzureBaseline'
            $plan = @(Get-OwnerPlan)
            $plan.Count | Should Be 1
            $plan[0] | Should Match 'maximumDuration: PT8H -> PT1H'
        }

        It 'run: the variable wins over the built-in defaults when BaselineJson is empty' {
            Set-StandardTenant
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $variableBaseline }
            $s = Invoke-StandardRun -DryRun $true -Baseline ''
            $global:PimUnexpected.Count | Should Be 0
            $s.Baseline | Should Match '^Automation variable "PimPolicy_AzureBaseline": activation=PT4H .*; 2 role override\(s\), 0 pair override\(s\)$'
            $s.BaselineFromVariable | Should Be $true
            $s.RoleOverrides | Should Be 2
            $s.PairsReportOnly | Should Be 1
            $s.PolicyUpdatesPlanned | Should Be 2
            $plan = @(Get-OwnerPlan)
            $plan.Count | Should Be 1
            $plan[0] | Should Match 'maximumDuration: PT8H -> PT2H\)\.$'
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message -like 'Settings: *Baseline=`[Automation variable "PimPolicy_AzureBaseline": *' }).Count | Should Be 1
            @($global:PimRequests | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        }

        It 'run: reads the variable BaselineVariableName names' {
            Set-StandardTenant
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '{"mode":"exact"}'; PimPolicy_Custom = $variableBaseline }
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineVariableName 'PimPolicy_Custom' -AccessToken $global:PimTokens -RunId $runId 2>$null
            $s.Baseline | Should Match '^Automation variable "PimPolicy_Custom": .*mode minimum'
            $s.BaselineVariableName | Should Be 'PimPolicy_Custom'
            (@(Get-OwnerPlan))[0] | Should Match 'PT8H -> PT2H'
        }

        It 'run: the built-in defaults apply when BaselineVariableName is empty, even with a variable present' {
            Set-StandardTenant
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $variableBaseline }
            $s = Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -BaselineVariableName '' -AccessToken $global:PimTokens -RunId $runId 2>$null
            $s.Baseline | Should Match '^built-in stack defaults \(no BaselineJson, no BaselineVariableName\): activation=PT4H'
            $s.BaselineFromVariable | Should Be $false
            $s.BaselineVariableName | Should Be ''
            $s.RoleOverrides | Should Be 0
            (@(Get-OwnerPlan))[0] | Should Match 'PT8H -> PT4H'
        }

        It 'run: an empty variable holds every pair to the built-in defaults, with a warning' {
            Set-StandardTenant
            $s = Invoke-StandardRun -DryRun $true -Baseline ''
            $s.Baseline | Should Match '^built-in stack defaults \(Automation variable "PimPolicy_AzureBaseline" is empty\)'
            $s.BaselineFromVariable | Should Be $true
            (@(Get-OwnerPlan))[0] | Should Match 'PT8H -> PT4H'
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message -like '*Automation variable "PimPolicy_AzureBaseline" is empty*' }).Count | Should Be 1
        }

        It 'run: stops before any call when the variable is missing or holds a bad baseline' {
            Set-StandardTenant
            Set-BaselineVariables -Values @{ Other = $variableBaseline }
            { Invoke-StandardRun -DryRun $true -Baseline '' } | Should Throw 'Automation variable "PimPolicy_AzureBaseline" is not in the local variable table'

            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '{"defaults":' }
            { Invoke-StandardRun -DryRun $true -Baseline '' } | Should Throw 'The baseline in Automation variable "PimPolicy_AzureBaseline" is not valid: BaselineJson does not parse as JSON'

            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '{"defaults":{"require_approval":true}}' }
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -AccessToken $global:PimTokens } | Should Throw 'The baseline in Automation variable "PimPolicy_AzureBaseline" is not valid: '
            { Invoke-AzurePimPolicyGovernanceRun -ScopeNames 'Platform' -AccessToken $global:PimTokens } | Should Throw 'ApproverGroupName is empty'

            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = 42 }
            { Invoke-StandardRun -DryRun $true -Baseline '' } | Should Throw 'holds a Int32, not a string'
            $global:PimRequests.Count | Should Be 0

            # A bad BaselineJson is reported as it always was, without the variable prefix.
            $message = ''
            try { Invoke-StandardRun -DryRun $true -Baseline '{"defaults":' } catch { $message = $_.Exception.Message }
            $message | Should Match '^BaselineJson does not parse as JSON'
        }

        It 'run: an empty BaselineJson with a variable baseline still sweeps the declared pairs' {
            Set-StandardTenant
            $pairsBaseline = '{"pairs":{"owner-at-platform":{"role_name":"Owner","scope":{"type":"management_group","name":"Platform"},"activation":{"maximum_duration":"PT1H","require_approval":true,"approver_groups":["Platform Approvers"]}}}}'
            Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = $pairsBaseline }
            $s = Invoke-StandardRun -DryRun $false -Baseline '' -Recipients ''
            $global:PimUnexpected.Count | Should Be 0
            $s.PairOverridesResolved | Should Be 1
            $s.PairOverridesMatched | Should Be 1
            $owner = @(Get-Requests -Method PATCH | Where-Object { $_.Uri -eq (Get-PolicyUri -Scope $mgPlatform -Name 'policy-owner') })
            $owner.Count | Should Be 1
            $rules = @((ConvertFrom-Json -InputObject $owner[0].Body).properties.rules)
            $rules[0].maximumDuration | Should Be 'PT1H'
            (@(@($rules[1].setting.approvalStages)[0].primaryApprovers) | ForEach-Object { $_.id }) | Should Be $platformApproverId
        }
    }

    Context 'runbook file and inline contract' {
        $begin = '# INLINE_LIBRARY_' + 'BEGIN'
        $end = '# INLINE_LIBRARY_' + 'END'
        $runbookText = [System.IO.File]::ReadAllText($runbook)
        $libraryText = [System.IO.File]::ReadAllText($library)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($runbookText, [ref]$tokens, [ref]$errors)

        It 'is ASCII without a byte order mark and parses cleanly' {
            $bytes = [System.IO.File]::ReadAllBytes($runbook)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            @($errors).Count | Should Be 0
        }

        It 'carries the INLINE_LIBRARY block exactly once, at column 0, after the preferences' {
            $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
            $normalised = $runbookText.Replace("`r`n", "`n")
            $block = $begin + "`n" + ". (Join-Path -Path `$PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')" + "`n" + $end + "`n"
            $normalised.Contains("`n" + $block) | Should Be $true
            $blockAt = $normalised.IndexOf($block)
            $normalised.IndexOf("`$ErrorActionPreference = 'Stop'") | Should BeLessThan $blockAt
            $normalised.IndexOf("`$VerbosePreference = 'Continue'") | Should BeLessThan $blockAt
            $normalised.IndexOf('param(') | Should BeLessThan $blockAt
        }

        It 'uses the same marker strings as the runbooks module' {
            $moduleText = [System.IO.File]::ReadAllText($runbooksModule)
            $moduleText.Contains(('library_begin = "{0}"' -f $begin)) | Should Be $true
            $moduleText.Contains(('library_end   = "{0}"' -f $end)) | Should Be $true
        }

        It 'declares schedule-safe parameters with DryRun on by default' {
            $parameters = @($ast.ParamBlock.Parameters)
            $names = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($names -join ',') | Should Be 'ScopeNames,BaselineJson,BaselineVariableName,ApproverGroupName,Recipients,SenderMailbox,MaxPolicyUpdatesPerRun,ReportPath,DryRun,Environment,ClientId,AccessToken,RunId'
            foreach ($p in $parameters) {
                @([string], [int], [bool]) -contains $p.StaticType | Should Be $true
            }
            $dryRun = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' })[0]
            $dryRun.StaticType | Should Be ([bool])
            $dryRun.DefaultValue.Extent.Text | Should Be '$true'
            $max = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MaxPolicyUpdatesPerRun' })[0]
            $max.DefaultValue.Extent.Text | Should Be '25'
            $environment = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Environment' })[0]
            $environment.DefaultValue.Extent.Text | Should Be "'Global'"
            $variableName = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BaselineVariableName' })[0]
            $variableName.StaticType | Should Be ([string])
            $variableName.DefaultValue.Extent.Text | Should Be "'PimPolicy_AzureBaseline'"
            $script:PimDefaultBaselineVariableName | Should BeExactly 'PimPolicy_AzureBaseline'
            $baselineJson = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BaselineJson' })[0]
            $baselineJson.DefaultValue.Extent.Text | Should Be "''"
        }

        It 'passes BaselineVariableName from the entry point to the run function, with the same default' {
            $calls =@($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-AzurePimPolicyGovernanceRun' }, $true))
            $calls.Count | Should Be 1
            $calls[0].Extent.Text | Should Match '-BaselineVariableName \$BaselineVariableName '
            $run = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AzurePimPolicyGovernanceRun' }, $true))[0]
            $runParameter = @($run.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BaselineVariableName' })[0]
            $runParameter.DefaultValue.Extent.Text | Should Be '$script:PimDefaultBaselineVariableName'
        }

        It 'documents every parameter and shows a local run with -AccessToken' {
            $help = $ast.GetHelpContent()
            $help | Should Not BeNullOrEmpty
            [string]::IsNullOrWhiteSpace($help.Synopsis) | Should Be $false
            foreach ($p in @($ast.ParamBlock.Parameters)) {
                $key = $p.Name.VariablePath.UserPath.ToUpperInvariant()
                $help.Parameters.ContainsKey($key) | Should Be $true
                [string]::IsNullOrWhiteSpace($help.Parameters[$key]) | Should Be $false
            }
            @($help.Examples | Where-Object { $_ -match '-AccessToken \$' }).Count | Should BeGreaterThan 0
            $help.Description | Should Match 'stacks/azure-pim-governance'
            $help.Description | Should Match 'Safety model'
            $help.Description | Should Match 'Mail\.Send'
            $help.Description | Should Match 'roleManagementPolicies/write'
            $help.Description | Should Match 'In mode "minimum", the default, the baseline is a floor'
            $help.Description | Should Match 'Unverified: coverage below a subscription'
            $help.Description | Should Match 'PairsBelowSubscription'
            $help.Description | Should Match 'A\s+dry run sends no mail'
            $help.Description | Should Not Match 'read the digests'
            $help.Parameters['BASELINEJSON'] | Should Match '"pairs"'
            $help.Parameters['BASELINEJSON'] | Should Match 'for local runs and tests'
            $help.Parameters['BASELINEJSON'] | Should Match 'Never\s+set it in a job schedule'
            $help.Parameters['BASELINEVARIABLENAME'] | Should Match 'PimPolicy_AzureBaseline'
            $help.Parameters['BASELINEVARIABLENAME'] | Should Match 'Precedence: BaselineJson, then this\s+variable, then the built-in defaults'
            $help.Parameters['SCOPENAMES'] | Should Match 'separated by\s+semicolons'
            $help.Parameters['SCOPENAMES'] | Should Match 'JSON array\s+form'
            $help.Parameters['SCOPENAMES'] | Should Match 'Never put the JSON array form in a schedule'
            $help.Parameters['RECIPIENTS'] | Should Match 'separated by\s+semicolons'
            $help.Parameters['RECIPIENTS'] | Should Match 'for local runs only'
        }

        It 'states the corp schedule, the PIM tier permissions, and a stack sample without JSON parameters' {
            $help = $ast.GetHelpContent()
            $description = $help.Description
            $description | Should Match 'daily at 05:00 UTC on its daily-0500-utc schedule'
            $runbookText.Contains('0600') | Should Be $false
            $description | Should Match 'PIM tier identity'
            $description | Should Match 'Reader'
            $description | Should Match 'PIM Policy Operator'
            $description | Should Match 'tenants/azure/corp/azure-rbac-roles'
            # The header names the role the corp cell actually assigns to the
            # pim tier, and says the wider one is not for this tier.
            $cellText = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'))
            $pimTier = [regex]::Match($cellText, '(?ms)^    pim = \{(?<body>.*?)^    \}')
            $pimTier.Success | Should Be $true
            $assignedRoles = @([regex]::Matches($pimTier.Groups['body'].Value, 'role_name\s*=\s*"(?<role>[^"]+)"') | ForEach-Object { $_.Groups['role'].Value })
            ($assignedRoles -join ', ') | Should Be 'Reader, PIM Policy Operator'
            foreach ($role in $assignedRoles) { $description.Contains($role) | Should Be $true }
            $description | Should Match 'do not assign it to\s+this runbook''s tier'
            $description | Should Not Match 'The role''s roleEligibilityScheduleRequests actions are for'
            $description | Should Match 'Do not grant Owner, User Access Administrator, or Role Based Access\s+Control Administrator'
            $description | Should Not Match 'also work'
            $description | Should Not Match 'PIM Policy Governance Writer'
            @([regex]::Matches($runbookText, 'User Access Administrator')).Count | Should Be 1
            $description | Should Match 'PimPolicy_AzureBaseline'

            $notes = [string]$help.Notes
            $notes | Should Match 'schedule_key = "daily-0500-utc"'
            $notes | Should Match 'scopenames\s+= join\(";", \["mg:mg-example-root"\]\)'
            $notes | Should Match 'recipients\s+= join\(";", \["iam@corp\.example\.com"\]\)'
            $notes | Should Match 'baselinevariablename\s+= "PimPolicy_AzureBaseline"'
            $notes | Should Match 'PimPolicy_AzureBaseline = "policies/azure/'
            $notes | Should Not Match 'jsonencode'
            $notes | Should Not Match 'baselinejson\s*='
            $runbookText | Should Not Match 'daily-0600'
            # The sample's baseline file is a valid baseline document.
            $jsonStart = $notes.IndexOf('with a baseline file such as:')
            $jsonStart | Should BeGreaterThan 0
            $jsonText = $notes.Substring($jsonStart)
            $jsonText = $jsonText.Substring($jsonText.IndexOf('{'))
            $jsonText = $jsonText.Substring(0, $jsonText.IndexOf('The stack adds'))
            $sample = ConvertFrom-PimBaselineJson -Json $jsonText
            $sample.Mode | Should Be 'minimum'
            @($sample.PairEntries).Count | Should Be 1
            @($sample.PairEntries)[0].ScopeType | Should Be 'management_group'
            Assert-PimBaselineApprovers -Baseline $sample
        }

        It 'never marks the digest subject as a dry run, because a dry run sends nothing' {
            $runbookText.Contains("'(dry run)'") | Should Be $false
            $runbookText.Contains("' (dry run)'") | Should Be $false
        }

        It 'defines no function the library defines, and documents every function it does define' {
            $libraryAst = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$null, [ref]$null)
            $libraryNames = @($libraryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            $libraryNames.Count | Should BeGreaterThan 40
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            $functions.Count | Should BeGreaterThan 20
            $clashes = @($functions | Where-Object { $libraryNames -contains $_.Name } | ForEach-Object { $_.Name })
            ($clashes -join ', ') | Should Be ''
            $missing = @($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name })
            ($missing -join ', ') | Should Be ''
        }

        It 'avoids Write-Host, $input, and unwrapped list calls' {
            $hosts = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Host' }, $true))
            $hosts.Count | Should Be 0
            $inputs = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'input' }, $true))
            $inputs.Count | Should Be 0

            $listCommands = @('ConvertTo-StringList', 'Get-TransitiveGroupMemberIds', 'Get-ManagementGroupDescendantSubscriptions', 'Get-RunLogEntries', 'Get-PimList', 'Get-PimApproverIds', 'Get-PimEligibilityInstances', 'Compare-PimPolicyRules', 'ConvertTo-PimReportRows', 'Get-PimBaselineEntryList', 'Get-PimApproverGroupNames', 'Get-PimDesiredApprovers')
            $isListCall = {
                param($node)
                if (-not ($node -is [System.Management.Automation.Language.CommandAst])) { return $false }
                $name = $node.GetCommandName()
                if ($listCommands -contains $name) { return $true }
                if ($name -eq 'Invoke-CloudRequest') {
                    return (@($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'AllPages' }).Count -gt 0)
                }
                return $false
            }.GetNewClosure()
            $calls = @($ast.FindAll($isListCall, $true))
            $calls.Count | Should BeGreaterThan 5
            $unwrapped = @()
            foreach ($call in $calls) {
                $parent = $call.Parent
                $wrapped = $false
                for ($i = 0; $i -lt 3 -and $null -ne $parent; $i++) {
                    if ($parent -is [System.Management.Automation.Language.ArrayExpressionAst]) { $wrapped = $true; break }
                    $parent = $parent.Parent
                }
                if (-not $wrapped) { $unwrapped += ('{0} (line {1})' -f $call.GetCommandName(), $call.Extent.StartLineNumber) }
            }
            ($unwrapped -join ', ') | Should Be ''
        }

        It 'starts the run with Initialize-RunContext and ends it with Complete-RunSummary' {
            $run = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AzurePimPolicyGovernanceRun' }, $true))[0]
            $statements = @($run.Body.EndBlock.Statements)
            $statements[0].Extent.Text | Should Match '^Initialize-RunContext -RunbookName ''Invoke-AzurePimPolicyGovernance'' -RunId \$RunId -Environment \$Environment -ClientId \$ClientId -AccessToken \$AccessToken -DryRun \$DryRun$'
            $statements[1].Extent.Text | Should Be '$summary = New-RunSummary'
            $statements[-1].Extent.Text | Should Be 'return (Complete-RunSummary -Summary $summary -Extra $extra)'
            $runText = $run.Extent.Text
            $runText.IndexOf('Test-CircuitBreaker') | Should BeLessThan $runText.IndexOf("-Action 'UpdatePolicy'")
            $runbookText | Should Match "(?m)^if \(\`$MyInvocation\.InvocationName -ne '\.'\) \{"
        }

        It 'runs from disk and stops on bad input before any call' {
            { & $runbook -ScopeNames 'sub:Example' -BaselineJson '{"defaults":' -AccessToken 'local-disk-token-0000' 4>$null 3>$null } | Should Throw 'BaselineJson does not parse as JSON'
        }

        It 'runs when assembled the way Terraform inlines library_path' {
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail

            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $assembledErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$null, [ref]$assembledErrors) | Out-Null
            @($assembledErrors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-AzurePimPolicyGovernance.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))
            { & $published -ScopeNames '["mg:Platform"]' -Environment USGov -BaselineJson '{"roles":{"Owner":{"require_approval":true}}}' -AccessToken 'published-token-0000' 4>$null 3>$null } | Should Throw 'ApproverGroupName is empty'
            { & $published -ScopeNames 'mg:Platform' -MaxPolicyUpdatesPerRun -1 -AccessToken 'published-token-0000' 4>$null 3>$null } | Should Throw
            { & $published -ScopeNames 'mg:Platform' -BaselineJson '@{mode=minimum}' -AccessToken 'published-token-0000' 4>$null 3>$null } | Should Throw 'parameter binding converted the result to a string'
            # No variable table and no sandbox cmdlet: the default variable
            # name is read and fails before any call.
            Set-BaselineVariables -Values $null
            try {
                (Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
                { & $published -ScopeNames 'mg:Platform' -AccessToken 'published-token-0000' 4>$null 3>$null } | Should Throw 'read from Automation variable "PimPolicy_AzureBaseline"'
                { & $runbook -ScopeNames 'mg:Platform' -AccessToken 'local-disk-token-0000' 4>$null 3>$null } | Should Throw 'can only be read inside Azure Automation'
            }
            finally { Set-BaselineVariables -Values @{ PimPolicy_AzureBaseline = '' } }
        }
    }

    # Leave the library's test hook as the library defines it.
    Set-BaselineVariables -Values $null
}
