# Pester tests for automation/runbooks/Invoke-EntraPimPolicyDrift.ps1.
#
# Pester 3/4 assertion syntax ("Should Be"), because Windows PowerShell 5.1
# ships Pester 3.4.0. The runbook is dot-sourced, which loads
# automation/lib/Runbook.Common.ps1 through its INLINE_LIBRARY block and skips
# the entry point. Every HTTP request goes through the library's
# Invoke-HttpCore, which is mocked with a small router that answers with the
# JSON shapes documented for policies/roleManagementPolicyAssignments,
# roleManagement/directory/roleDefinitions, groups, the rule PATCH, and
# sendMail. The baseline variable is supplied through the library's
# $script:RunbookAutomationVariables hook or a global stand-in for the
# sandbox's Get-AutomationVariable, which each test removes again. The last
# context runs the runbook file itself, from disk and assembled the way
# modules/azure/automation-runbooks inlines the library, against a mocked
# Invoke-WebRequest. Nothing here leaves the machine.

$thisTestFile = $MyInvocation.MyCommand.Path
$here = Split-Path -Parent $thisTestFile
$automationRoot = Split-Path -Parent $here
$runbook = Join-Path -Path $automationRoot -ChildPath 'runbooks\Invoke-EntraPimPolicyDrift.ps1'
$library = Join-Path -Path $automationRoot -ChildPath 'lib\Runbook.Common.ps1'

Describe 'Invoke-EntraPimPolicyDrift' {
    . $runbook
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'

    Remove-Item -Path Env:\IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\IDENTITY_HEADER -ErrorAction SilentlyContinue

    # Fake values only. GUIDs are all-same-digit on purpose.
    $token = 'eyJ0eXAiOiJKV1QifQ.pimpayload00000000000.pimsignature0000000'
    $runId = '00000000-0000-0000-0000-000000000000'
    $tenantPart = '00000000-0000-0000-0000-000000000000'
    $globalAdminId = '11111111-1111-1111-1111-111111111111'
    $securityAdminId = '22222222-2222-2222-2222-222222222222'
    $customRoleId = '33333333-3333-3333-3333-333333333333'
    $approverGroupId = '44444444-4444-4444-4444-444444444444'
    $pimGroupId = '55555555-5555-5555-5555-555555555555'
    $userId = '66666666-6666-6666-6666-666666666666'
    $otherGroupId = '77777777-7777-7777-7777-777777777777'
    $policyA = 'DirectoryRole_{0}_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -f $tenantPart
    $policyB = 'DirectoryRole_{0}_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -f $tenantPart
    $policyC = 'DirectoryRole_{0}_cccccccc-cccc-cccc-cccc-cccccccccccc' -f $tenantPart
    $policyMember = 'Group_{0}_dddddddd-dddd-dddd-dddd-dddddddddddd' -f $pimGroupId
    $policyOwner = 'Group_{0}_eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' -f $pimGroupId
    $mfa = 'MultiFactorAuthentication'

    # -----------------------------------------------------------------------
    # Builders for documented shapes.
    # -----------------------------------------------------------------------

    function ConvertTo-TestLive {
        param([object]$Value)
        return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30))
    }

    function New-TestGroupApprover {
        param([string]$Id)
        return @{ '@odata.type' = '#microsoft.graph.groupMembers'; groupId = $Id; description = 'approvers' }
    }

    function New-TestUserApprover {
        param([string]$Id)
        return @{ '@odata.type' = '#microsoft.graph.singleUser'; userId = $Id }
    }

    function New-TestRules {
        param(
            [string]$Duration = 'PT4H',
            [bool]$ExpirationRequired = $true,
            [string[]]$Enabled = @('MultiFactorAuthentication', 'Justification'),
            [bool]$ApprovalRequired = $false,
            [object[]]$Approvers = @(),
            [int]$Stages = 1,
            [bool]$AuthContext = $false,
            [string]$ClaimValue = '',
            [string]$ApprovalMode = 'SingleStage',
            [bool]$ForExtension = $false,
            [int]$StageTimeout = 1,
            [object[]]$LaterApprovers = $null
        )
        $endUser = @{ caller = 'EndUser'; operations = @('all'); level = 'Assignment'; inheritableSettings = @(); enforcedSettings = @() }
        $admin = @{ caller = 'Admin'; operations = @('all'); level = 'Eligibility'; inheritableSettings = @(); enforcedSettings = @() }
        $stageList = @()
        for ($i = 0; $i -lt $Stages; $i++) {
            $stageApprovers = @($Approvers)
            if ($i -gt 0 -and $null -ne $LaterApprovers) { $stageApprovers = @($LaterApprovers) }
            $stageList += @{ approvalStageTimeOutInDays = $StageTimeout; isApproverJustificationRequired = $true; escalationTimeInMinutes = 0; isEscalationEnabled = $false; primaryApprovers = $stageApprovers; escalationApprovers = @() }
        }
        $claim = $null
        if ($ClaimValue.Length -gt 0) { $claim = $ClaimValue }
        return @(
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'; id = 'Expiration_Admin_Eligibility'; isExpirationRequired = $false; maximumDuration = 'P365D'; target = $admin },
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'; id = 'Expiration_EndUser_Assignment'; isExpirationRequired = $ExpirationRequired; maximumDuration = $Duration; target = $endUser },
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyEnablementRule'; id = 'Enablement_EndUser_Assignment'; enabledRules = @($Enabled); target = $endUser },
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule'; id = 'Approval_EndUser_Assignment'; target = $endUser; setting = @{ isApprovalRequired = $ApprovalRequired; isApprovalRequiredForExtension = $ForExtension; isRequestorJustificationRequired = $true; approvalMode = $ApprovalMode; approvalStages = $stageList } },
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyAuthenticationContextRule'; id = 'AuthenticationContext_EndUser_Assignment'; isEnabled = $AuthContext; claimValue = $claim; target = $endUser },
            @{ '@odata.type' = '#microsoft.graph.unifiedRoleManagementPolicyNotificationRule'; id = 'Notification_Admin_EndUser_Assignment'; notificationType = 'Email'; recipientType = 'Admin'; notificationLevel = 'All'; isDefaultRecipientsEnabled = $true; notificationRecipients = @(); target = $endUser }
        )
    }

    function Get-TestLiveRules {
        param([hashtable]$Options = @{})
        $rules = New-TestRules @Options
        return , @((ConvertTo-TestLive -Value @{ rules = $rules }).rules)
    }

    function Get-TestLiveRule {
        param([string]$RuleId, [hashtable]$Options = @{})
        return (Get-PimRuleById -Rules (Get-TestLiveRules -Options $Options) -RuleId $RuleId)
    }

    function New-TestAssignment {
        param(
            [string]$RoleDefinitionId,
            [string]$PolicyId,
            [string]$ScopeId = '/',
            [string]$ScopeType = 'DirectoryRole',
            [hashtable]$Options = @{}
        )
        return @{
            id               = '{0}_{1}' -f $PolicyId, $RoleDefinitionId
            policyId         = $PolicyId
            scopeId          = $ScopeId
            scopeType        = $ScopeType
            roleDefinitionId = $RoleDefinitionId
            policy           = @{
                id                    = $PolicyId
                displayName           = $ScopeType
                description           = $ScopeType
                isOrganizationDefault = $false
                scopeId               = $ScopeId
                scopeType             = $ScopeType
                lastModifiedDateTime  = $null
                rules                 = @(New-TestRules @Options)
            }
        }
    }

    function New-TestResponse {
        param([int]$Status = 200, [object]$Json = $null, [string]$Text = '')
        $content = $Text
        if ($null -ne $Json) { $content = ConvertTo-Json -InputObject $Json -Depth 30 -Compress }
        return @{ StatusCode = $Status; Content = $content; Headers = @{} }
    }

    $roleDefinitions = @(
        @{ id = $globalAdminId; templateId = $globalAdminId; displayName = 'Global Administrator'; isBuiltIn = $true; isEnabled = $true },
        @{ id = $securityAdminId; templateId = $securityAdminId; displayName = 'Security Administrator'; isBuiltIn = $true; isEnabled = $true },
        @{ id = $customRoleId; templateId = $customRoleId; displayName = 'Helpdesk Tier 2'; isBuiltIn = $false; isEnabled = $true }
    )

    # Global Administrator compliant; Security Administrator drifted on
    # duration and requirements; the custom role stricter than the baseline;
    # plus a duplicate of the first assignment.
    function Get-TestDirectoryAssignments {
        return @(
            (New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA),
            (New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Duration = 'PT8H'; Enabled = @('Justification') }),
            (New-TestAssignment -RoleDefinitionId $customRoleId -PolicyId $policyC -Options @{ Duration = 'PT2H'; Enabled = @('MultiFactorAuthentication', 'Justification', 'Ticketing') }),
            (New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA)
        )
    }

    function Get-TestGroupAssignments {
        return @(
            (New-TestAssignment -RoleDefinitionId 'member' -PolicyId $policyMember -ScopeId $pimGroupId -ScopeType 'Group' -Options @{ Duration = 'PT8H' }),
            (New-TestAssignment -RoleDefinitionId 'owner' -PolicyId $policyOwner -ScopeId $pimGroupId -ScopeType 'Group')
        )
    }

    # -----------------------------------------------------------------------
    # Mocked tenant. Routes are matched in order on method and the decoded
    # URI; extra routes passed by a test are tried first.
    # -----------------------------------------------------------------------

    $global:PimTestRequests = New-Object System.Collections.ArrayList
    $global:PimTestRoutes = New-Object System.Collections.ArrayList
    $global:PimTestRouter = {
        param($RequestMethod, $RequestUri, $RequestBody)
        $bodyText = ''
        if ($RequestBody -is [byte[]]) { $bodyText = [System.Text.Encoding]::UTF8.GetString($RequestBody) }
        elseif ($null -ne $RequestBody) { $bodyText = [string]$RequestBody }
        $decoded = [Uri]::UnescapeDataString([string]$RequestUri)
        $methodText = ([string]$RequestMethod).ToUpperInvariant()
        [void]$global:PimTestRequests.Add([PSCustomObject]@{ Method = $methodText; Uri = $decoded; Body = $bodyText; Host = ([Uri][string]$RequestUri).Host })
        foreach ($route in $global:PimTestRoutes) {
            if ($methodText -eq $route.Method -and $decoded -like $route.Pattern) {
                $response = $route.Response
                if ($response -is [scriptblock]) { $response = & $response $decoded $bodyText }
                return $response
            }
        }
        throw ('Unexpected request in test: {0} {1}' -f $methodText, $decoded)
    }

    function Set-TestTenant {
        param(
            [object[]]$DirectoryAssignments = @(Get-TestDirectoryAssignments),
            [object[]]$GroupAssignments = @(Get-TestGroupAssignments),
            [object[]]$ApproverMembers = @(@{ '@odata.type' = '#microsoft.graph.user'; id = $userId }),
            [object[]]$Routes = @()
        )
        $global:PimTestRequests.Clear()
        $global:PimTestRoutes.Clear()
        foreach ($route in $Routes) { [void]$global:PimTestRoutes.Add($route) }
        $directoryResponse = New-TestResponse -Json @{ '@odata.context' = 'https://graph.microsoft.com/v1.0/$metadata#policies/roleManagementPolicyAssignments(policy(rules()))'; value = @($DirectoryAssignments) }
        $groupResponse = New-TestResponse -Json @{ value = @($GroupAssignments) }
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = '*/v1.0/roleManagement/directory/roleDefinitions'; Response = (New-TestResponse -Json @{ value = $roleDefinitions }) })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = "*/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"; Response = $directoryResponse })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = ("*/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '{0}' and scopeType eq 'Group'&`$expand=policy(`$expand=rules)" -f $pimGroupId); Response = $groupResponse })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = "*/v1.0/groups?`$filter=displayName eq 'PIM Approvers'*"; Response = (New-TestResponse -Json @{ value = @(@{ id = $approverGroupId; displayName = 'PIM Approvers' }) }) })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = ("*/v1.0/groups/{0}/transitiveMembers/microsoft.graph.user?`$select=id&`$top=999&`$count=true" -f $approverGroupId); Response = (New-TestResponse -Json @{ '@odata.count' = @($ApproverMembers).Count; value = @($ApproverMembers) }) })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = "*/v1.0/groups?`$filter=displayName eq 'PIM Tier 0 Operators'*"; Response = (New-TestResponse -Json @{ value = @(@{ id = $pimGroupId; displayName = 'PIM Tier 0 Operators' }) }) })
        [void]$global:PimTestRoutes.Add(@{ Method = 'GET'; Pattern = "*/v1.0/groups?`$filter=displayName eq *"; Response = (New-TestResponse -Json @{ value = @() }) })
        [void]$global:PimTestRoutes.Add(@{ Method = 'PATCH'; Pattern = '*/v1.0/policies/roleManagementPolicies/*/rules/*'; Response = { param($uri, $body) New-TestResponse -Status 200 -Text $body } })
        [void]$global:PimTestRoutes.Add(@{ Method = 'POST'; Pattern = '*/v1.0/users/*/sendMail'; Response = (New-TestResponse -Status 202) })
    }

    function Get-TestRequests {
        param([string]$Method = '', [string]$Like = '*')
        return @($global:PimTestRequests | Where-Object { ($Method -eq '' -or $_.Method -eq $Method) -and $_.Uri -like $Like })
    }

    function Invoke-TestRun {
        param([hashtable]$Parameters = @{})
        # BaselineVariableName is blank unless a test sets it, so a run uses
        # BaselineJson or the built-in baseline and never needs a variable.
        $arguments = @{
            AccessToken          = $token
            RunId                = $runId
            DryRun               = $true
            Recipients           = 'iam@corp.example.com'
            SenderMailbox        = 'iam-noreply@corp.example.com'
            BaselineVariableName = ''
        }
        foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
        return (Invoke-EntraPimPolicyDriftRun @arguments 2>$null 3>$null)
    }

    # A stand-in for the Automation sandbox's internal Get-AutomationVariable.
    # Tests that install it remove it again in a finally block.
    function Set-TestSandboxVariable {
        param([string]$Value)
        Remove-TestSandboxVariable
        $global:PimTestVariableValue = $Value
        $global:PimTestVariableCalls = New-Object System.Collections.ArrayList
        function global:Get-AutomationVariable {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$Name)
            [void]$global:PimTestVariableCalls.Add($Name)
            return $global:PimTestVariableValue
        }
    }

    function Remove-TestSandboxVariable {
        $guard = 0
        while ($guard -lt 5 -and (Get-Command -Name Get-AutomationVariable -CommandType Function -ErrorAction SilentlyContinue)) {
            Remove-Item -Path Function:\Get-AutomationVariable -ErrorAction SilentlyContinue
            $guard++
        }
        Remove-Variable -Name PimTestVariableValue -Scope Global -ErrorAction SilentlyContinue
    }

    Mock Invoke-HttpCore { return (& $global:PimTestRouter $Method $Uri $Body) }
    Mock Start-Sleep { }
    Mock Test-AzAccountsAvailable { return $false }
    Remove-TestSandboxVariable
    $script:RunbookAutomationVariables = $null

    # -----------------------------------------------------------------------
    # Pure functions.
    # -----------------------------------------------------------------------

    Context 'baseline parsing' {
        It 'treats an empty value and {} as the built-in baseline' {
            foreach ($value in @('', '{}', '  ')) {
                $b = ConvertTo-PimBaseline -Json $value
                $b.Mode | Should Be 'minimum'
                $b.Defaults.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(4))
                ($b.Defaults.ActivationRequirements -join ',') | Should Be 'MultiFactorAuthentication,Justification'
                $b.Defaults.RequireApproval | Should Be $false
                $b.Roles.Count | Should Be 0
                $b.Groups.Count | Should Be 0
            }
        }

        It 'ships an empty BaselineJson and the PimPolicy_EntraBaseline variable name, in the script and the run function' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($runbook, [ref]$tokens, [ref]$errors)
            $run = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EntraPimPolicyDriftRun' }, $true))[0]
            $defaultOf = {
                param($Parameters, $Name)
                $match = @($Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
                if ($match.Count -ne 1) { return ('(found {0} parameters named {1})' -f $match.Count, $Name) }
                return [string]$match[0].DefaultValue.SafeGetValue()
            }
            $lists = @(@(, @($ast.ParamBlock.Parameters)) + @(, @($run.Body.ParamBlock.Parameters)))
            $lists.Count | Should Be 2
            foreach ($parameters in $lists) {
                @($parameters).Count | Should BeGreaterThan 10
                (& $defaultOf $parameters 'BaselineJson') | Should BeExactly ''
                (& $defaultOf $parameters 'BaselineVariableName') | Should BeExactly 'PimPolicy_EntraBaseline'
            }
        }

        It 'keeps the authentication context from counting as MFA unless the baseline says so' {
            (ConvertTo-PimBaseline -Json '').Defaults.AuthenticationContextSatisfiesMfa | Should Be $false
            $b = ConvertTo-PimBaseline -Json '{"defaults":{"authenticationContextSatisfiesMfa":true},"roles":{"Global Administrator":{"authenticationContextSatisfiesMfa":false},"Security Administrator":{"maximumActivationDuration":"PT2H"}}}'
            $b.Defaults.AuthenticationContextSatisfiesMfa | Should Be $true
            (Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Global Administrator').AuthenticationContextSatisfiesMfa | Should Be $false
            (Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Security Administrator').AuthenticationContextSatisfiesMfa | Should Be $true
            (Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Helpdesk Tier 2').AuthenticationContextSatisfiesMfa | Should Be $true
            $g = ConvertTo-PimBaseline -Json '{"groups":{"PIM Tier 0 Operators":{"authenticationContextSatisfiesMfa":true}}}'
            (Get-PimEffectiveSettings -Baseline $g -Kind Group -Name 'PIM Tier 0 Operators').AuthenticationContextSatisfiesMfa | Should Be $true
            (Get-PimEffectiveSettings -Baseline $g -Kind Role -Name 'PIM Tier 0 Operators').AuthenticationContextSatisfiesMfa | Should Be $false
            { ConvertTo-PimBaseline -Json '{"defaults":{"authenticationContextSatisfiesMfa":"yes"}}' } | Should Throw 'BaselineJson defaults.authenticationContextSatisfiesMfa must be true or false'
            { ConvertTo-PimBaseline -Json '{"roles":{"X":{"authContextSatisfiesMfa":true}}}' } | Should Throw 'unknown key "authContextSatisfiesMfa"'
        }

        It 'names the source of the baseline in every message' {
            $source = 'Automation variable "PimPolicy_EntraBaseline"'
            { ConvertTo-PimBaseline -Json '{"roles":{"X":{"requireAproval":true}}}' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" roles."X" has an unknown key "requireAproval"'
            { ConvertTo-PimBaseline -Json '{"defaults":' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" does not parse as JSON'
            { ConvertTo-PimBaseline -Json '{"role":{}}' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" has an unknown top-level key "role"'
            { ConvertTo-PimBaseline -Json '{"mode":"strict"}' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" mode "strict" is not valid'
            { ConvertTo-PimBaseline -Json '"\x"' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" looks like a quoted JSON string'
            { ConvertTo-PimBaseline -Json '{"defaults":{"requireApproval":true}}' -Source $source } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" defaults requires approval'
            { ConvertTo-PimBaseline -Json '{"defaults":{"requireApproval":true}}' } | Should Throw 'BaselineJson defaults requires approval'
            (ConvertTo-PimBaseline -Json '{}' -Source $source).Source | Should Be $source
            (ConvertTo-PimBaseline -Json '').Source | Should Be 'BaselineJson'
        }

        It 'refuses a converted PowerShell object from either source' {
            foreach ($converted in @('@{mode=minimum; roles=}', '  @{}', 'System.Collections.Hashtable')) {
                { ConvertTo-PimBaseline -Json $converted } | Should Throw 'BaselineJson arrived as a converted object, not as JSON text.'
                { ConvertTo-PimBaseline -Json $converted -Source 'Automation variable "PimPolicy_EntraBaseline"' } | Should Throw 'Automation variable "PimPolicy_EntraBaseline" arrived as a converted object'
            }
        }

        It 'unwraps a baseline passed as a quoted JSON string' {
            $wrapped = ConvertTo-Json -InputObject '{"defaults":{"maximumActivationDuration":"PT2H"}}' -Compress
            (ConvertTo-PimBaseline -Json $wrapped).Defaults.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(2))
        }

        It 'merges an override over the defaults and looks names up case-insensitively' {
            $b = ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":["Justification","MultiFactorAuthentication","justification"]},"roles":{"Global Administrator":{"maximumActivationDuration":"PT2H"}}}'
            ($b.Defaults.ActivationRequirements -join ',') | Should Be 'Justification,MultiFactorAuthentication'
            $ga = Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'global administrator'
            $ga.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(2))
            ($ga.ActivationRequirements -join ',') | Should Be 'Justification,MultiFactorAuthentication'
            $other = Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Security Administrator'
            $other.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(4))
            (Get-PimEffectiveSettings -Baseline $b -Kind Group -Name 'Global Administrator').MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(4))
        }

        It 'rejects an unknown key in an override, so a typo cannot fall back to the defaults' {
            { ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":{"requireAproval":true}}}' } | Should Throw 'unknown key "requireAproval"'
        }

        It 'rejects an unknown top-level key' {
            { ConvertTo-PimBaseline -Json '{"role":{}}' } | Should Throw 'unknown top-level key "role"'
        }

        It 'accepts whole-minute durations from PT1H to PT24H and nothing else' {
            (ConvertTo-PimBaseline -Json '{"defaults":{"maximumActivationDuration":"PT1H"}}').Defaults.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(1))
            (ConvertTo-PimBaseline -Json '{"defaults":{"maximumActivationDuration":"PT24H"}}').Defaults.MaximumActivationDuration | Should Be ([TimeSpan]::FromHours(24))
            (ConvertTo-PimBaseline -Json '{"defaults":{"maximumActivationDuration":"PT90M"}}').Defaults.MaximumActivationDuration | Should Be ([TimeSpan]::FromMinutes(90))
            foreach ($bad in @('PT25H', 'PT30M', 'P2D', '4 hours', 'PT1H0M30S', '')) {
                { ConvertTo-PimBaseline -Json ('{{"defaults":{{"maximumActivationDuration":"{0}"}}}}' -f $bad) } | Should Throw 'maximumActivationDuration'
            }
            { ConvertTo-PimBaseline -Json '{"defaults":{"maximumActivationDuration":4}}' } | Should Throw 'maximumActivationDuration'
        }

        It 'rejects unknown activation requirements and a non-array value' {
            { ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":["Mfa"]}}' } | Should Throw 'allowed values are'
            { ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":"Justification"}}' } | Should Throw 'must be a JSON array'
            { ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":{"a":1}}}' } | Should Throw 'must be a JSON array'
            { ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":[1]}}' } | Should Throw 'strings only'
            (ConvertTo-PimBaseline -Json '{"defaults":{"activationRequirements":[]},"mode":"exact"}').Defaults.ActivationRequirements.Count | Should Be 0
        }

        It 'requires booleans for requireApproval and exclude' {
            { ConvertTo-PimBaseline -Json '{"defaults":{"requireApproval":"yes"}}' } | Should Throw 'requireApproval must be true or false'
            { ConvertTo-PimBaseline -Json '{"roles":{"X":{"exclude":1}}}' } | Should Throw 'exclude must be true or false'
        }

        It 'refuses approval without an approver group and takes the fallback when given' {
            { ConvertTo-PimBaseline -Json '{"defaults":{"requireApproval":true}}' } | Should Throw 'requires approval but no approver group is named'
            { ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":{"requireApproval":true}}}' } | Should Throw 'roles."Global Administrator" requires approval'
            $b = ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":{"requireApproval":true},"Security Administrator":{"requireApproval":true,"approverGroupName":"SecOps Approvers"},"Helpdesk Tier 2":{"requireApproval":true,"exclude":true,"approverGroupName":"Unused"}}}' -ApproverGroupName 'PIM Approvers'
            (Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Global Administrator').ApproverGroupName | Should Be 'PIM Approvers'
            (Get-PimEffectiveSettings -Baseline $b -Kind Role -Name 'Security Administrator').ApproverGroupName | Should Be 'SecOps Approvers'
            $names = @(Get-PimApproverGroupNames -Baseline $b)
            ($names -join '|') | Should Be 'PIM Approvers|SecOps Approvers'
        }

        It 'allows exclude only in overrides' {
            { ConvertTo-PimBaseline -Json '{"defaults":{"exclude":true}}' } | Should Throw 'only valid in a role or group override'
            (Get-PimEffectiveSettings -Baseline (ConvertTo-PimBaseline -Json '{"groups":{"PIM Tier 0 Operators":{"exclude":true}}}') -Kind Group -Name 'PIM Tier 0 Operators').Exclude | Should Be $true
        }

        It 'validates the mode' {
            (ConvertTo-PimBaseline -Json '{"mode":"EXACT"}').Mode | Should Be 'exact'
            { ConvertTo-PimBaseline -Json '{"mode":"strict"}' } | Should Throw 'mode "strict" is not valid'
            { ConvertTo-PimBaseline -Json '{"mode":1}' } | Should Throw 'mode must be a string'
        }

        It 'rejects malformed or non-object JSON with a clear message' {
            { ConvertTo-PimBaseline -Json '{"defaults":' } | Should Throw 'does not parse as JSON'
            { ConvertTo-PimBaseline -Json '[1,2]' } | Should Throw 'must be a JSON object'
            { ConvertTo-PimBaseline -Json '{"roles":"Global Administrator"}' } | Should Throw 'roles must be a JSON object'
            { ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":"PT2H"}}' } | Should Throw 'must be a JSON object'
            { ConvertTo-PimBaseline -Json '@{mode=minimum}' } | Should Throw 'converted object'
        }

        It 'rejects a name listed twice, by its own check and by the JSON parser' {
            # Keys that differ only in surrounding space parse, and reach the
            # runbook's duplicate check after trimming.
            { ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":{}," Global Administrator":{}}}' } | Should Throw 'roles names "Global Administrator" more than once'
            { ConvertTo-PimBaseline -Json '{"groups":{"PIM Tier 0 Operators":{},"PIM Tier 0 Operators ":{}}}' } | Should Throw 'groups names "PIM Tier 0 Operators" more than once'
            # Keys that differ only in case never get that far: ConvertFrom-Json
            # refuses them, and the runbook reports a parse error.
            { ConvertTo-PimBaseline -Json '{"roles":{"Global Administrator":{},"global administrator":{}}}' } | Should Throw 'does not parse as JSON'
        }

        It 'takes a non-blank BaselineJson first and then reads no variable' {
            try {
                # An empty table would make any variable read throw.
                $script:RunbookAutomationVariables = @{}
                $r = Resolve-PimBaselineText -BaselineJson '{"mode":"exact"}' -BaselineVariableName 'PimPolicy_EntraBaseline'
                $r.Source | Should Be 'BaselineJson'
                $r.Text | Should BeExactly '{"mode":"exact"}'
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'reads the Automation variable when BaselineJson is blank, and returns its text unchanged' {
            $stored = "{`n  ""roles"": { ""Security Administrator"": { ""exclude"": true } }`n}"
            try {
                $script:RunbookAutomationVariables = @{ PimPolicy_EntraBaseline = $stored }
                foreach ($blank in @('', '   ', $null)) {
                    $r = Resolve-PimBaselineText -BaselineJson $blank -BaselineVariableName 'PimPolicy_EntraBaseline'
                    $r.Source | Should Be 'Automation variable "PimPolicy_EntraBaseline"'
                    $r.Text | Should BeExactly $stored
                }
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'uses the built-in baseline when both BaselineJson and BaselineVariableName are blank' {
            try {
                $script:RunbookAutomationVariables = @{}
                foreach ($blank in @('', '  ', $null)) {
                    $r = Resolve-PimBaselineText -BaselineJson '' -BaselineVariableName $blank
                    $r.Source | Should Be 'the built-in baseline'
                    $r.Text | Should BeExactly ''
                }
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'stops when the variable cannot be read, and says how to run on a workstation' {
            try {
                $script:RunbookAutomationVariables = @{ PimPolicy_EntraBaseline = '   ' }
                { Resolve-PimBaselineText -BaselineVariableName 'PimPolicy_EntraBaseline' } | Should Throw 'Could not read the baseline from Automation variable "PimPolicy_EntraBaseline": Automation variable "PimPolicy_EntraBaseline" is empty.'
                $script:RunbookAutomationVariables = $null
                Remove-TestSandboxVariable
                $message = ''
                try { Resolve-PimBaselineText -BaselineVariableName 'PimPolicy_EntraBaseline' | Out-Null } catch { $message = $_.Exception.Message }
                $message | Should Match 'can only be read inside Azure Automation'
                $message.Contains("On a workstation pass -BaselineJson with the baseline text, or -BaselineVariableName '' for the built-in baseline.") | Should Be $true
                { Resolve-PimBaselineText -BaselineVariableName 'Pim/Baseline' } | Should Throw 'is not a valid Automation variable name'
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'tells a JSON object from wrapped scalars, arrays, and dictionaries' {
            Test-PimJsonObject -Value (ConvertFrom-Json -InputObject '{"a":1}') | Should Be $true
            Test-PimJsonObject -Value (Write-Output 'text') | Should Be $false
            Test-PimJsonObject -Value ([psobject]'text') | Should Be $false
            Test-PimJsonObject -Value @(1, 2) | Should Be $false
            Test-PimJsonObject -Value @{ a = 1 } | Should Be $false
            Test-PimJsonObject -Value $null | Should Be $false
        }
    }

    Context 'durations, names, and URIs' {
        It 'writes durations in hours and minutes' {
            ConvertTo-PimDurationText -Duration ([TimeSpan]::FromMinutes(105)) | Should Be 'PT1H45M'
            ConvertTo-PimDurationText -Duration ([TimeSpan]::FromHours(24)) | Should Be 'PT24H'
            ConvertTo-PimDurationText -Duration ([TimeSpan]::FromMinutes(30)) | Should Be 'PT30M'
        }

        It 'reads ISO 8601 durations and returns null for anything else' {
            ConvertFrom-PimDuration -Value 'PT240M' | Should Be ([TimeSpan]::FromHours(4))
            ConvertFrom-PimDuration -Value 'P365D' | Should Be ([TimeSpan]::FromDays(365))
            ConvertFrom-PimDuration -Value 'eight hours' | Should BeNullOrEmpty
            ConvertFrom-PimDuration -Value $null | Should BeNullOrEmpty
        }

        It 'canonicalises activation requirement names' {
            ConvertTo-PimRequirementName -Value ' multifactorauthentication ' | Should Be 'MultiFactorAuthentication'
            ConvertTo-PimRequirementName -Value 'Something' | Should Be 'Something'
        }

        It 'builds the documented list query for both scopes' {
            [Uri]::UnescapeDataString((New-PimAssignmentsUri -ScopeId '/' -ScopeType DirectoryRole)) | Should Be "policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"
            [Uri]::UnescapeDataString((New-PimAssignmentsUri -ScopeId $pimGroupId -ScopeType Group)) | Should Be ("policies/roleManagementPolicyAssignments?`$filter=scopeId eq '{0}' and scopeType eq 'Group'&`$expand=policy(`$expand=rules)" -f $pimGroupId)
            (New-PimAssignmentsUri -ScopeId '/' -ScopeType DirectoryRole).Contains(' ') | Should Be $false
        }

        It 'maps role ids and template ids to display names' {
            $map = Get-PimRoleNameMap -RoleDefinitions @(
                (ConvertTo-TestLive -Value @{ id = $customRoleId; templateId = $otherGroupId; displayName = 'Helpdesk Tier 2' }),
                (ConvertTo-TestLive -Value @{ id = $globalAdminId; displayName = 'Global Administrator' })
            )
            $map[$customRoleId] | Should Be 'Helpdesk Tier 2'
            $map[$otherGroupId] | Should Be 'Helpdesk Tier 2'
            $map[$globalAdminId.ToUpperInvariant()] | Should Be 'Global Administrator'
            $map.Count | Should Be 3
        }

        It 'drops duplicate assignments by role definition and scope, keeping order' {
            $raw = @(
                (ConvertTo-TestLive -Value @{ roleDefinitionId = 'a'; scopeId = '/'; policyId = 'p1' }),
                (ConvertTo-TestLive -Value @{ roleDefinitionId = 'b'; scopeId = '/'; policyId = 'p2' }),
                (ConvertTo-TestLive -Value @{ roleDefinitionId = 'A'; scopeId = '/'; policyId = 'p3' }),
                (ConvertTo-TestLive -Value @{ roleDefinitionId = 'a'; scopeId = 'g1'; policyId = 'p4' }),
                $null
            )
            $unique = @(Select-UniquePimAssignment -Assignments $raw)
            ($unique | ForEach-Object { $_.policyId }) -join ',' | Should Be 'p1,p2,p4'
            @(Select-UniquePimAssignment -Assignments @()).Count | Should Be 0
        }
    }

    Context 'expiration rule' {
        $four = [TimeSpan]::FromHours(4)

        It 'compares durations as time, in both modes' {
            $rule = Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ Duration = 'PT240M' }
            (Compare-PimExpirationRule -Rule $rule -DesiredDuration $four -Mode minimum).Status | Should Be 'Compliant'
            (Compare-PimExpirationRule -Rule $rule -DesiredDuration $four -Mode exact).Status | Should Be 'Compliant'
        }

        It 'plans the documented PATCH body when activation lasts longer' {
            $r = Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ Duration = 'PT8H' }) -DesiredDuration $four
            $r.Status | Should Be 'Drift'
            $r.Live | Should Be 'PT8H'
            $r.Desired | Should Be 'PT4H'
            $json = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress)
            $json.'@odata.type' | Should Be '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'
            $json.id | Should Be 'Expiration_EndUser_Assignment'
            $json.isExpirationRequired | Should Be $true
            $json.maximumDuration | Should Be 'PT4H'
            $json.target.caller | Should Be 'EndUser'
            $json.target.level | Should Be 'Assignment'
            (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress).Contains('"operations":["All"]') | Should Be $true
        }

        It 'accepts a shorter activation in minimum mode only' {
            $rule = Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ Duration = 'PT2H' }
            (Compare-PimExpirationRule -Rule $rule -DesiredDuration $four -Mode minimum).Status | Should Be 'Compliant'
            (Compare-PimExpirationRule -Rule $rule -DesiredDuration $four -Mode exact).Status | Should Be 'Drift'
        }

        It 'treats a non-expiring activation and an unreadable duration as drift' {
            (Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ ExpirationRequired = $false }) -DesiredDuration $four).Status | Should Be 'Drift'
            $r = Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ Duration = 'eight hours' }) -DesiredDuration $four
            $r.Status | Should Be 'Drift'
            $r.Detail | Should Match 'cannot be read'
        }

        It 'keeps a shorter stored duration when it turns expiry on in minimum mode, and never lengthens one' {
            $short = Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ ExpirationRequired = $false; Duration = 'PT2H' }
            $minimum = Compare-PimExpirationRule -Rule $short -DesiredDuration $four -Mode minimum
            $minimum.Status | Should Be 'Drift'
            $minimum.Live | Should Be 'PT2H, expiration not required'
            $minimum.Desired | Should Be 'PT4H'
            $minimum.Detail | Should Be 'activation is not required to expire; the patch turns expiration on and keeps the shorter stored PT2H'
            $minimum.Body.isExpirationRequired | Should Be $true
            $minimum.Body.maximumDuration | Should Be 'PT2H'
            $minutes = Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ ExpirationRequired = $false; Duration = 'PT90M' }) -DesiredDuration $four -Mode minimum
            $minutes.Body.maximumDuration | Should Be 'PT1H30M'

            # Exact mode writes the baseline.
            $exact = Compare-PimExpirationRule -Rule $short -DesiredDuration $four -Mode exact
            $exact.Body.maximumDuration | Should Be 'PT4H'
            $exact.Detail | Should Be 'activation is not required to expire'

            # Longer, equal, below the admin center minimum, fractional, or unreadable: the baseline.
            foreach ($stored in @('PT8H', 'PT4H', 'PT30M', 'PT1H30M15S', 'eight hours', '')) {
                $r = Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ ExpirationRequired = $false; Duration = $stored }) -DesiredDuration $four -Mode minimum
                $r.Status | Should Be 'Drift'
                $r.Body.isExpirationRequired | Should Be $true
                $r.Body.maximumDuration | Should Be 'PT4H'
            }

            # A required rule that is too long is still patched to the baseline.
            (Compare-PimExpirationRule -Rule (Get-TestLiveRule -RuleId 'Expiration_EndUser_Assignment' -Options @{ Duration = 'PT8H' }) -DesiredDuration $four -Mode minimum).Body.maximumDuration | Should Be 'PT4H'
        }

        It 'reports a missing rule as an error, never as a patch' {
            $r = Compare-PimExpirationRule -Rule $null -DesiredDuration $four
            $r.Status | Should Be 'Error'
            $r.Body | Should BeNullOrEmpty
        }
    }

    Context 'enablement rule' {
        $baseline = @('MultiFactorAuthentication', 'Justification')

        It 'accepts extra requirements in minimum mode and flags them in exact mode' {
            $rule = Get-TestLiveRule -RuleId 'Enablement_EndUser_Assignment' -Options @{ Enabled = @('MultiFactorAuthentication', 'Justification', 'Ticketing') }
            $minimum = Compare-PimEnablementRule -Rule $rule -DesiredRules $baseline -Mode minimum
            $minimum.Status | Should Be 'Compliant'
            $minimum.Detail | Should Match 'Ticketing'
            $exact = Compare-PimEnablementRule -Rule $rule -DesiredRules $baseline -Mode exact
            $exact.Status | Should Be 'Drift'
            ($exact.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification'
        }

        It 'adds a missing requirement and keeps the stricter extras in minimum mode' {
            $rule = Get-TestLiveRule -RuleId 'Enablement_EndUser_Assignment' -Options @{ Enabled = @('justification', 'TICKETING') }
            $r = Compare-PimEnablementRule -Rule $rule -DesiredRules $baseline -Mode minimum
            $r.Status | Should Be 'Drift'
            $r.Detail | Should Be 'missing MultiFactorAuthentication'
            ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification,Ticketing'
            $json = ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress
            $json.Contains('"@odata.type":"#microsoft.graph.unifiedRoleManagementPolicyEnablementRule"') | Should Be $true
            $json.Contains('"id":"Enablement_EndUser_Assignment"') | Should Be $true
        }

        It 'serialises a one-item and an empty list as JSON arrays' {
            $one = Compare-PimEnablementRule -Rule (Get-TestLiveRule -RuleId 'Enablement_EndUser_Assignment' -Options @{ Enabled = @() }) -DesiredRules @('Justification') -Mode exact
            (ConvertTo-Json -InputObject $one.Body -Depth 20 -Compress).Contains('"enabledRules":["Justification"]') | Should Be $true
            $none = Compare-PimEnablementRule -Rule (Get-TestLiveRule -RuleId 'Enablement_EndUser_Assignment' -Options @{ Enabled = @('Justification') }) -DesiredRules @() -Mode exact
            $none.Status | Should Be 'Drift'
            (ConvertTo-Json -InputObject $none.Body -Depth 20 -Compress).Contains('"enabledRules":[]') | Should Be $true
            (Compare-PimEnablementRule -Rule (Get-TestLiveRule -RuleId 'Enablement_EndUser_Assignment' -Options @{ Enabled = @('Justification') }) -DesiredRules @() -Mode minimum).Status | Should Be 'Compliant'
        }

        It 'does not count an enabled authentication context as MFA by default, and patches MFA in next to it' {
            $rules = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }
            $enablement = Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment'
            $context = Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment'
            $expectedDetail = 'missing MultiFactorAuthentication; authentication context c1 is enabled but counts as MFA only when the baseline sets authenticationContextSatisfiesMfa; Graph may refuse MFA next to a context'
            foreach ($mode in @('minimum', 'exact')) {
                foreach ($r in @(
                        (Compare-PimEnablementRule -Rule $enablement -AuthenticationContextRule $context -DesiredRules $baseline -Mode $mode),
                        (Compare-PimEnablementRule -Rule $enablement -AuthenticationContextRule $context -DesiredRules $baseline -Mode $mode -AuthenticationContextSatisfiesMfa $false))) {
                    $r.Status | Should Be 'Drift'
                    $r.Notice | Should Be ''
                    $r.Live | Should Be 'Justification (authentication context c1 enabled)'
                    $r.Desired | Should Be 'MultiFactorAuthentication, Justification'
                    $r.Detail | Should Be $expectedDetail
                    ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification'
                }
            }

            # An empty claimValue is not an error with the key off: the MFA floor applies as usual.
            $blank = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $true }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $blank -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $blank -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline
            $r.Status | Should Be 'Drift'
            $r.Detail | Should Match 'an authentication context with an empty claimValue is enabled but counts as MFA only when'
            ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification'

            # A rule that already has MFA next to the context is compliant with the key off.
            $both = Get-TestLiveRules -Options @{ Enabled = @($mfa, 'Justification'); AuthContext = $true; ClaimValue = 'c1' }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $both -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $both -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline -Mode exact
            $r.Status | Should Be 'Compliant'
            $r.Detail | Should Be ''

            # A missing requirement other than MFA does not mention the context.
            $noTicket = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $both -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $both -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules @($mfa, 'Ticketing')
            $noTicket.Detail | Should Be 'missing Ticketing'
        }

        It 'with authenticationContextSatisfiesMfa, counts MFA as met by an enabled authentication context, never adds it, and says so' {
            $rules = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }
            $context = Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment'
            $enablement = Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment'
            $exact = Compare-PimEnablementRule -Rule $enablement -AuthenticationContextRule $context -DesiredRules $baseline -Mode exact -AuthenticationContextSatisfiesMfa $true
            $exact.Status | Should Be 'Compliant'
            $exact.Detail | Should Be 'MFA delegated to authentication context c1'
            $exact.Notice | Should Be 'MFA delegated to authentication context c1'
            $exact.Live | Should Be 'Justification (authentication context c1 enabled)'
            $exact.Desired | Should Be 'Justification (MFA met by authentication context)'

            $rules = Get-TestLiveRules -Options @{ Enabled = @(); AuthContext = $true; ClaimValue = 'c1' }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline -AuthenticationContextSatisfiesMfa $true
            $r.Status | Should Be 'Drift'
            ($r.Body.enabledRules -join ',') | Should Be 'Justification'
            $r.Detail | Should Be 'missing Justification; MFA delegated to authentication context c1'
            $r.Notice | Should Be 'MFA delegated to authentication context c1'

            # The key has no effect when the context rule is off.
            $off = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $false; ClaimValue = 'c1' }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $off -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $off -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline -AuthenticationContextSatisfiesMfa $true
            $r.Status | Should Be 'Drift'
            $r.Detail | Should Be 'missing MultiFactorAuthentication'
            ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification'
        }

        It 'raises no notice when the baseline does not ask for MFA or the rule already has it' {
            foreach ($accept in @($true, $false)) {
                $rules = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }
                $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules @('Justification') -Mode exact -AuthenticationContextSatisfiesMfa $accept
                $r.Status | Should Be 'Compliant'
                $r.Notice | Should Be ''
                $rules = Get-TestLiveRules -Options @{ Enabled = @($mfa, 'Justification'); AuthContext = $true; ClaimValue = 'c1' }
                $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline -Mode exact -AuthenticationContextSatisfiesMfa $accept
                $r.Status | Should Be 'Compliant'
                $r.Notice | Should Be ''
                $r.Detail | Should Be ''
            }
        }

        It 'keeps a live MFA next to an enabled authentication context when it patches another requirement' {
            # Regression: the patch used to be built from the baseline minus MFA,
            # so adding Ticketing silently dropped a live MFA requirement.
            $rules = Get-TestLiveRules -Options @{ Enabled = @($mfa, 'Justification'); AuthContext = $true; ClaimValue = 'c1' }
            $enablement = Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment'
            $context = Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment'
            $withTicket = @($mfa, 'Justification', 'Ticketing')
            foreach ($accept in @($true, $false)) {
                foreach ($mode in @('minimum', 'exact')) {
                    $r = Compare-PimEnablementRule -Rule $enablement -AuthenticationContextRule $context -DesiredRules $withTicket -Mode $mode -AuthenticationContextSatisfiesMfa $accept
                    $r.Status | Should Be 'Drift'
                    $r.Detail | Should Be 'missing Ticketing'
                    ($r.Body.enabledRules -contains $mfa) | Should Be $true
                    ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification,Ticketing'
                }
                # Exact mode with a baseline that leaves MFA out still keeps the live MFA next to the context.
                $r = Compare-PimEnablementRule -Rule $enablement -AuthenticationContextRule $context -DesiredRules @('Justification', 'Ticketing') -Mode exact -AuthenticationContextSatisfiesMfa $accept
                ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification,Ticketing'
            }
        }

        It 'never removes a live value in minimum mode' {
            $rules = Get-TestLiveRules -Options @{ Enabled = @('Ticketing', $mfa); AuthContext = $true; ClaimValue = 'c1' }
            foreach ($accept in @($true, $false)) {
                $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules @('Justification') -Mode minimum -AuthenticationContextSatisfiesMfa $accept
                $r.Status | Should Be 'Drift'
                ($r.Body.enabledRules -join ',') | Should Be 'MultiFactorAuthentication,Justification,Ticketing'
            }
        }

        It 'with authenticationContextSatisfiesMfa, reports an enabled authentication context with no claim value as an error, not as met' {
            $rules = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $true }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline -Mode minimum -AuthenticationContextSatisfiesMfa $true
            $r.Status | Should Be 'Error'
            $r.Body | Should BeNullOrEmpty
            $r.Detail | Should Match 'claimValue is empty'
            $r.Live | Should Be 'Justification (authentication context enabled, claimValue empty)'
        }

        It 'requires MFA when the authentication context rule is present but off' {
            $rules = Get-TestLiveRules -Options @{ Enabled = @('Justification'); AuthContext = $false }
            $r = Compare-PimEnablementRule -Rule (Get-PimRuleById -Rules $rules -RuleId 'Enablement_EndUser_Assignment') -AuthenticationContextRule (Get-PimRuleById -Rules $rules -RuleId 'AuthenticationContext_EndUser_Assignment') -DesiredRules $baseline
            $r.Status | Should Be 'Drift'
            ($r.Body.enabledRules -contains $mfa) | Should Be $true
        }

        It 'reports a missing rule as an error' {
            (Compare-PimEnablementRule -Rule $null -DesiredRules $baseline).Status | Should Be 'Error'
        }
    }

    Context 'approval rule' {
        It 'turns approval on with the baseline group as the only approver' {
            $rule = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment'
            $r = Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -ApproverGroupName 'PIM Approvers'
            $r.Status | Should Be 'Drift'
            $r.Live | Should Be 'not required'
            $json = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress)
            $json.'@odata.type' | Should Be '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule'
            $json.id | Should Be 'Approval_EndUser_Assignment'
            $json.setting.isApprovalRequired | Should Be $true
            $json.setting.approvalMode | Should Be 'SingleStage'
            @($json.setting.approvalStages).Count | Should Be 1
            @($json.setting.approvalStages)[0].primaryApprovers[0].'@odata.type' | Should Be '#microsoft.graph.groupMembers'
            @($json.setting.approvalStages)[0].primaryApprovers[0].groupId | Should Be $approverGroupId
            (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress).Contains('"primaryApprovers":[{') | Should Be $true
        }

        It 'is compliant when the first stage approver is exactly the baseline group, in any case' {
            $rule = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true; Approvers = @((New-TestGroupApprover -Id $approverGroupId.ToUpperInvariant())) }
            (Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -Mode exact).Status | Should Be 'Compliant'
        }

        It 'treats extra or different approvers as drift' {
            $withUser = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true; Approvers = @((New-TestGroupApprover -Id $approverGroupId), (New-TestUserApprover -Id $userId)) }
            (Compare-PimApprovalRule -Rule $withUser -RequireApproval $true -ApproverGroupId $approverGroupId).Status | Should Be 'Drift'
            $otherGroup = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true; Approvers = @((New-TestGroupApprover -Id $otherGroupId)) }
            (Compare-PimApprovalRule -Rule $otherGroup -RequireApproval $true -ApproverGroupId $approverGroupId).Status | Should Be 'Drift'
            $noApprovers = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true }
            (Compare-PimApprovalRule -Rule $noApprovers -RequireApproval $true -ApproverGroupId $approverGroupId).Status | Should Be 'Drift'
        }

        It 'accepts extra stages in minimum mode only' {
            $rule = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true; Approvers = @((New-TestGroupApprover -Id $approverGroupId)); Stages = 2 }
            (Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -Mode minimum).Status | Should Be 'Compliant'
            (Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -Mode exact).Status | Should Be 'Drift'
        }

        It 'replaces only the first stage approvers in minimum mode and keeps the rest of the live setting' {
            # Regression: the patch used to replace the whole setting with one
            # SingleStage stage, dropping later stages and approval on extension.
            $options = @{ ApprovalRequired = $true; Approvers = @((New-TestGroupApprover -Id $otherGroupId)); Stages = 2; ApprovalMode = 'Serial'; ForExtension = $true; StageTimeout = 3; LaterApprovers = @((New-TestUserApprover -Id $userId)) }
            $rule = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options $options
            $r = Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -ApproverGroupName 'PIM Approvers' -Mode minimum
            $r.Status | Should Be 'Drift'
            $json = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress)
            $json.'@odata.type' | Should Be '#microsoft.graph.unifiedRoleManagementPolicyApprovalRule'
            $json.setting.isApprovalRequired | Should Be $true
            $json.setting.approvalMode | Should Be 'Serial'
            $json.setting.isApprovalRequiredForExtension | Should Be $true
            $stages = @($json.setting.approvalStages)
            $stages.Count | Should Be 2
            $stages[0].approvalStageTimeOutInDays | Should Be 3
            $stages[0].isApproverJustificationRequired | Should Be $true
            @($stages[0].primaryApprovers).Count | Should Be 1
            @($stages[0].primaryApprovers)[0].groupId | Should Be $approverGroupId
            @($stages[0].primaryApprovers)[0].'@odata.type' | Should Be '#microsoft.graph.groupMembers'
            @($stages[1].primaryApprovers)[0].userId | Should Be $userId
            $stages[1].approvalStageTimeOutInDays | Should Be 3
            (ConvertTo-Json -InputObject $r.Body -Depth 20 -Compress).Contains('"primaryApprovers":[{') | Should Be $true
            # The live rule object is not modified by building the patch.
            @(@($rule.setting.approvalStages)[0].primaryApprovers)[0].groupId | Should Be $otherGroupId

            # Exact mode writes the one-stage baseline, and still keeps approval on extension.
            $exact = Compare-PimApprovalRule -Rule $rule -RequireApproval $true -ApproverGroupId $approverGroupId -Mode exact
            $exactJson = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $exact.Body -Depth 20 -Compress)
            $exactJson.setting.approvalMode | Should Be 'SingleStage'
            @($exactJson.setting.approvalStages).Count | Should Be 1
            $exactJson.setting.isApprovalRequiredForExtension | Should Be $true

            # Turning approval on from off writes a fresh single stage, and keeps approval on extension.
            $off = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $false; Approvers = @((New-TestUserApprover -Id $userId)); Stages = 2; ApprovalMode = 'Serial'; ForExtension = $true }
            $on = Compare-PimApprovalRule -Rule $off -RequireApproval $true -ApproverGroupId $approverGroupId -Mode minimum
            $onJson = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $on.Body -Depth 20 -Compress)
            $onJson.setting.isApprovalRequired | Should Be $true
            $onJson.setting.approvalMode | Should Be 'SingleStage'
            @($onJson.setting.approvalStages).Count | Should Be 1
            @(@($onJson.setting.approvalStages)[0].primaryApprovers)[0].groupId | Should Be $approverGroupId
            $onJson.setting.isApprovalRequiredForExtension | Should Be $true
        }

        It 'never removes approval in minimum mode, and keeps the approvers when exact mode does' {
            $rule = Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment' -Options @{ ApprovalRequired = $true; Approvers = @((New-TestUserApprover -Id $userId)) }
            $minimum = Compare-PimApprovalRule -Rule $rule -RequireApproval $false -Mode minimum
            $minimum.Status | Should Be 'Compliant'
            $minimum.Body | Should BeNullOrEmpty
            $exact = Compare-PimApprovalRule -Rule $rule -RequireApproval $false -Mode exact
            $exact.Status | Should Be 'Drift'
            $json = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $exact.Body -Depth 20 -Compress)
            $json.setting.isApprovalRequired | Should Be $false
            @($json.setting.approvalStages)[0].primaryApprovers[0].userId | Should Be $userId
        }

        It 'is compliant when neither side requires approval' {
            (Compare-PimApprovalRule -Rule (Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment') -RequireApproval $false -Mode exact).Status | Should Be 'Compliant'
        }

        It 'refuses to plan approval without an approver group id' {
            { Compare-PimApprovalRule -Rule (Get-TestLiveRule -RuleId 'Approval_EndUser_Assignment') -RequireApproval $true -ApproverGroupId '' } | Should Throw 'no approver group id'
            { New-PimApprovalRuleBody -Required $true } | Should Throw 'needs an approver group id'
        }

        It 'lists approver keys by type, sorted' {
            $stage = ConvertTo-TestLive -Value @{ primaryApprovers = @((New-TestUserApprover -Id $userId), (New-TestGroupApprover -Id $approverGroupId), @{ '@odata.type' = '#microsoft.graph.requestorManager'; managerLevel = 1 }) }
            $ids = Get-PimApproverIds -Stage $stage
            ($ids -join ',') | Should Be ('group:{0},other:microsoft.graph.requestorManager,user:{1}' -f $approverGroupId, $userId)
            (Get-PimApproverIds -Stage $null).Count | Should Be 0
        }
    }

    Context 'policy rows, digest, and report' {
        $settings = (ConvertTo-PimBaseline -Json '').Defaults

        It 'gives one row per checked rule with the policy and scope' {
            $assignment = ConvertTo-TestLive -Value (New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Duration = 'PT8H' })
            $rows = @(Get-PimPolicyDrift -Assignment $assignment -ScopeType DirectoryRole -TargetName 'Security Administrator' -Settings $settings)
            $rows.Count | Should Be 3
            ($rows | ForEach-Object { $_.RuleId }) -join ',' | Should Be 'Expiration_EndUser_Assignment,Enablement_EndUser_Assignment,Approval_EndUser_Assignment'
            ($rows | ForEach-Object { $_.Status }) -join ',' | Should Be 'Drift,Compliant,Compliant'
            $rows[0].PolicyId | Should Be $policyB
            $rows[0].ScopeId | Should Be '/'
            $rows[0].RoleDefinitionId | Should Be $securityAdminId
            $rows[0].Outcome | Should Be ''
            $rows[1].Outcome | Should Be 'Compliant'
        }

        It 'gives one Excluded row for an excluded policy' {
            $excluded = (ConvertTo-PimBaseline -Json '{"roles":{"Security Administrator":{"exclude":true}}}').Roles['security administrator'].Settings
            $assignment = ConvertTo-TestLive -Value (New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Duration = 'PT8H' })
            $rows = @(Get-PimPolicyDrift -Assignment $assignment -ScopeType DirectoryRole -TargetName 'Security Administrator' -Settings $excluded)
            $rows.Count | Should Be 1
            $rows[0].Status | Should Be 'Excluded'
            $rows[0].Body | Should BeNullOrEmpty
        }

        It 'gives Error rows when the policy was not expanded' {
            $assignment = ConvertTo-TestLive -Value @{ roleDefinitionId = $securityAdminId; scopeId = '/'; policyId = $policyB }
            $rows = @(Get-PimPolicyDrift -Assignment $assignment -ScopeType DirectoryRole -TargetName 'Security Administrator' -Settings $settings)
            $rows.Count | Should Be 3
            @($rows | Where-Object { $_.Status -eq 'Error' }).Count | Should Be 3
        }

        It 'encodes tenant data in the digest and lists failures and notes' {
            $row = [PSCustomObject]@{ ScopeType = 'DirectoryRole'; Target = 'Role <script>'; RuleId = 'Expiration_EndUser_Assignment'; Status = 'Drift'; Outcome = 'Planned'; Live = 'PT8H'; Desired = 'PT4H'; Detail = 'a & b' }
            $failure = [PSCustomObject]@{ Action = 'PatchRule'; Target = 'p/r'; Detail = 'HTTP 403 "denied"' }
            $html = New-PimDriftDigestHtml -Rows @($row) -Failures @($failure) -Notes @('groups skipped') -DryRun $true -Mode minimum -RunId $runId
            $html.Contains('<script>') | Should Be $false
            $html.Contains('Role &lt;script&gt;') | Should Be $true
            $html.Contains('a &amp; b') | Should Be $true
            $html.Contains('HTTP 403 &quot;denied&quot;') | Should Be $true
            $html.Contains('groups skipped') | Should Be $true
            $html.Contains('report only (DryRun)') | Should Be $true
            $html.Contains($runId) | Should Be $true
            (New-PimDriftDigestHtml -Rows @($row) -DryRun $false).Contains('patched back to the baseline') | Should Be $true
        }

        It 'writes the report without request bodies, and a header when there are no rows' {
            $path = Join-Path -Path $TestDrive -ChildPath 'report\rows.csv'
            $row = [PSCustomObject]@{ ScopeType = 'Group'; Target = 'G (member)'; RoleDefinitionId = 'member'; ScopeId = $pimGroupId; PolicyId = $policyMember; RuleId = 'Expiration_EndUser_Assignment'; Status = 'Drift'; Outcome = 'Done'; Live = 'PT8H'; Desired = 'PT4H'; Detail = 'longer'; Body = @{ secret = 'not exported' } }
            Export-PimDriftReport -Rows @($row) -Path $path
            $csv = @(Import-Csv -Path $path)
            $csv.Count | Should Be 1
            $csv[0].Outcome | Should Be 'Done'
            @($csv[0].PSObject.Properties | ForEach-Object { $_.Name }) -contains 'Body' | Should Be $false
            $empty = Join-Path -Path $TestDrive -ChildPath 'report\empty.csv'
            Export-PimDriftReport -Rows @() -Path $empty
            (Get-Content -Path $empty -TotalCount 1) | Should Match '^"ScopeType","Target",'
        }
    }

    # -----------------------------------------------------------------------
    # Whole runs against the mocked tenant.
    # -----------------------------------------------------------------------

    Context 'run against a mocked tenant' {
        It 'writes nothing in a dry run and plans the drifted rules and the digest' {
            Set-TestTenant
            $reportPath = Join-Path -Path $TestDrive -ChildPath 'dry\pim.csv'
            $summary = @(Invoke-TestRun -Parameters @{ ReportPath = $reportPath })
            $summary.Count | Should Be 1
            $s = $summary[0]
            $s.Runbook | Should Be 'Invoke-EntraPimPolicyDrift'
            $s.RunId | Should Be $runId
            $s.DryRun | Should Be $true
            $s.RolePoliciesChecked | Should Be 3
            $s.DuplicatesDropped | Should Be 1
            $s.RulesChecked | Should Be 9
            $s.RulesDrifted | Should Be 2
            $s.RulesCompliant | Should Be 7
            $s.Counts.PatchRule.Planned | Should Be 2
            $s.Counts.SendDigest.Planned | Should Be 1
            $s.Done | Should Be 0
            $s.DigestSent | Should Be $false
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
            @(Get-TestRequests -Method GET -Like '*/groups?*').Count | Should Be 0
            $csv = @(Import-Csv -Path $reportPath)
            $csv.Count | Should Be 9
            @($csv | Where-Object { $_.Outcome -eq 'Planned' }).Count | Should Be 2
            @($csv | Where-Object { $_.Status -eq 'Drift' -and $_.PolicyId -eq $policyB }).Count | Should Be 2
        }

        It 'reads the directory policies with the documented filter and expand' {
            Set-TestTenant
            Invoke-TestRun | Out-Null
            $list = @(Get-TestRequests -Method GET -Like '*roleManagementPolicyAssignments*')
            $list.Count | Should Be 1
            $list[0].Uri | Should Be "https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"
            @(Get-TestRequests -Method GET -Like 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions').Count | Should Be 1
        }

        It 'patches exactly the drifted rules with their documented bodies when live, and sends one digest' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            $patches = @(Get-TestRequests -Method PATCH)
            $patches.Count | Should Be 2
            ($patches | ForEach-Object { $_.Uri } | Sort-Object) -join ' ' | Should Be (@(
                    ('https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/{0}/rules/Enablement_EndUser_Assignment' -f $policyB),
                    ('https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/{0}/rules/Expiration_EndUser_Assignment' -f $policyB)
                ) -join ' ')
            $expiration = ConvertFrom-Json -InputObject (@($patches | Where-Object { $_.Uri -like '*Expiration_EndUser_Assignment' })[0].Body)
            $expiration.maximumDuration | Should Be 'PT4H'
            $expiration.'@odata.type' | Should Be '#microsoft.graph.unifiedRoleManagementPolicyExpirationRule'
            $enablement = ConvertFrom-Json -InputObject (@($patches | Where-Object { $_.Uri -like '*Enablement_EndUser_Assignment' })[0].Body)
            (@($enablement.enabledRules) -join ',') | Should Be 'MultiFactorAuthentication,Justification'
            $mail = @(Get-TestRequests -Method POST -Like '*/sendMail')
            $mail.Count | Should Be 1
            $mail[0].Uri | Should Be 'https://graph.microsoft.com/v1.0/users/iam-noreply@corp.example.com/sendMail'
            $message = ConvertFrom-Json -InputObject $mail[0].Body
            $message.saveToSentItems | Should Be $false
            $message.message.toRecipients[0].emailAddress.address | Should Be 'iam@corp.example.com'
            $message.message.subject | Should Be 'PIM policy drift: 2 rule(s) differ, 0 failure(s)'
            $message.message.body.content.Contains('Security Administrator') | Should Be $true
            $s.DryRun | Should Be $false
            $s.RuleUpdatesDone | Should Be 2
            $s.Counts.PatchRule.Done | Should Be 2
            $s.DigestSent | Should Be $true
            $s.FailureCount | Should Be 0
        }

        It 'accepts 204 No Content from the rule update' {
            Set-TestTenant -Routes @(@{ Method = 'PATCH'; Pattern = '*/rules/*'; Response = (New-TestResponse -Status 204) })
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            $s.RuleUpdatesDone | Should Be 2
            $s.FailureCount | Should Be 0
        }

        It 'records a 403 on one PATCH as Failed, carries on, and mails the failure' {
            $denied = New-TestResponse -Status 403 -Json @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges to complete the operation.' } }
            Set-TestTenant -Routes @(@{ Method = 'PATCH'; Pattern = '*/rules/Expiration_EndUser_Assignment'; Response = $denied })
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            @(Get-TestRequests -Method PATCH).Count | Should Be 2
            $s.RuleUpdatesFailed | Should Be 1
            $s.RuleUpdatesDone | Should Be 1
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'PatchRule'
            $s.Failures[0].Detail | Should Match 'HTTP 403'
            $s.Errors | Should BeGreaterThan 0
            $s.Warnings | Should BeGreaterThan 0
            $s.DigestSent | Should Be $true
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.subject | Should Be 'PIM policy drift: 2 rule(s) differ, 1 failure(s)'
            $message.message.body.content.Contains('RoleManagementPolicy.ReadWrite.Directory') | Should Be $true
        }

        It 'repeats a rule PATCH after a server error, because the body is the whole rule' {
            $global:PimTestPatchCalls = 0
            try {
                $flaky = {
                    param($uri, $body)
                    $global:PimTestPatchCalls++
                    if ($global:PimTestPatchCalls -eq 1) { return (New-TestResponse -Status 503 -Json @{ error = @{ code = 'ServiceUnavailable'; message = 'Try again.' } }) }
                    return (New-TestResponse -Status 200 -Text $body)
                }
                Set-TestTenant -Routes @(@{ Method = 'PATCH'; Pattern = '*/rules/Expiration_EndUser_Assignment'; Response = $flaky })
                $s = Invoke-TestRun -Parameters @{ DryRun = $false }
                @(Get-TestRequests -Method PATCH -Like '*/rules/Expiration_EndUser_Assignment').Count | Should Be 2
                $s.RuleUpdatesDone | Should Be 2
                $s.FailureCount | Should Be 0
                @(Get-TestRequests -Method POST).Count | Should Be 1
                @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.Contains('returned HTTP 503; retrying') }).Count | Should Be 1
            }
            finally { Remove-Variable -Name PimTestPatchCalls -Scope Global -ErrorAction SilentlyContinue }
        }

        It 'sends no digest when nothing drifted, even live' {
            Set-TestTenant -DirectoryAssignments @((New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA))
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
            $s.RulesDrifted | Should Be 0
            $s.DigestSent | Should Be $false
            $s.Planned | Should Be 0
            $s.Done | Should Be 0
        }

        It 'trips the breaker before any write, in live and dry runs' {
            foreach ($dry in @($false, $true)) {
                Set-TestTenant
                $reportPath = Join-Path -Path $TestDrive -ChildPath ('breaker-{0}.csv' -f $dry)
                { Invoke-TestRun -Parameters @{ DryRun = $dry; MaxRuleUpdatesPerRun = 1; ReportPath = $reportPath } } | Should Throw 'Circuit breaker tripped: PIM policy rule updates: 2 planned, cap is 1. Nothing was changed.'
                @(Get-TestRequests -Method PATCH).Count | Should Be 0
                @(Get-TestRequests -Method POST).Count | Should Be 0
                @(Import-Csv -Path $reportPath | Where-Object { $_.Outcome -eq 'NotApplied' }).Count | Should Be 2
            }
        }

        It 'passes the breaker at the cap' {
            Set-TestTenant
            (Invoke-TestRun -Parameters @{ DryRun = $false; MaxRuleUpdatesPerRun = 2 }).RuleUpdatesDone | Should Be 2
        }

        It 'checks the member and owner policies of included groups' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; IncludeGroupNames = '["PIM Tier 0 Operators"]' }
            $s.GroupPoliciesChecked | Should Be 2
            $s.GroupsSkipped | Should Be $false
            $s.RulesDrifted | Should Be 3
            $groupList = @(Get-TestRequests -Method GET -Like '*scopeType eq ''Group''*')
            $groupList.Count | Should Be 1
            $groupList[0].Uri | Should Be ("https://graph.microsoft.com/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '{0}' and scopeType eq 'Group'&`$expand=policy(`$expand=rules)" -f $pimGroupId)
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/rules/Expiration_EndUser_Assignment' -f $policyMember)).Count | Should Be 1
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/*' -f $policyOwner)).Count | Should Be 0
        }

        It 'applies a group override to both group policies' {
            # Member PT8H and owner PT6H both drift from the PT4H default, and
            # both are compliant only if the PT8H override reached each policy.
            $groupAssignments = @(
                (New-TestAssignment -RoleDefinitionId 'member' -PolicyId $policyMember -ScopeId $pimGroupId -ScopeType 'Group' -Options @{ Duration = 'PT8H' }),
                (New-TestAssignment -RoleDefinitionId 'owner' -PolicyId $policyOwner -ScopeId $pimGroupId -ScopeType 'Group' -Options @{ Duration = 'PT6H' })
            )
            Set-TestTenant -GroupAssignments $groupAssignments
            $control = Invoke-TestRun -Parameters @{ IncludeGroupNames = 'PIM Tier 0 Operators' }
            $control.RulesDrifted | Should Be 4

            Set-TestTenant -GroupAssignments $groupAssignments
            $reportPath = Join-Path -Path $TestDrive -ChildPath 'group-override.csv'
            $s = Invoke-TestRun -Parameters @{ IncludeGroupNames = 'PIM Tier 0 Operators'; BaselineJson = '{"groups":{"PIM Tier 0 Operators":{"maximumActivationDuration":"PT8H"}}}'; ReportPath = $reportPath }
            $s.GroupPoliciesChecked | Should Be 2
            $s.RulesDrifted | Should Be 2
            $groupRows = @(Import-Csv -Path $reportPath | Where-Object { $_.ScopeType -eq 'Group' })
            $groupRows.Count | Should Be 6
            @($groupRows | Where-Object { $_.Status -ne 'Compliant' }).Count | Should Be 0
            @($groupRows | Where-Object { $_.RuleId -eq 'Expiration_EndUser_Assignment' } | ForEach-Object { $_.Desired } | Sort-Object -Unique) -join ',' | Should Be 'PT8H'
        }

        It 'records a listed group with no member or owner policy as a failure and mails it' {
            Set-TestTenant -DirectoryAssignments @((New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA)) -GroupAssignments @()
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; IncludeGroupNames = 'PIM Tier 0 Operators' }
            $s.GroupPoliciesChecked | Should Be 0
            $s.RulesDrifted | Should Be 0
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'ReadGroupPolicies'
            $s.Failures[0].Target | Should Be 'PIM Tier 0 Operators'
            $s.Failures[0].Detail | Should Match 'no member or owner PIM policy'
            $s.Errors | Should BeGreaterThan 0
            $s.DigestSent | Should Be $true
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.body.content.Contains('no member or owner PIM policy') | Should Be $true
        }

        It 'stops with an error when the directory list returns no policy assignments' {
            Set-TestTenant -DirectoryAssignments @()
            { Invoke-TestRun -Parameters @{ DryRun = $false } } | Should Throw "returned no assignments (filter: scopeId eq '/' and scopeType eq 'DirectoryRole')"
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
        }

        It 'skips the group checks with a warning on 403 and keeps the directory results' {
            $denied = New-TestResponse -Status 403 -Json @{ error = @{ code = 'Forbidden'; message = 'Missing scope.' } }
            Set-TestTenant -Routes @(@{ Method = 'GET'; Pattern = '*scopeType eq ''Group''*'; Response = $denied })
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; IncludeGroupNames = 'PIM Tier 0 Operators; Another Group' }
            $s.GroupsSkipped | Should Be $true
            $s.GroupPoliciesChecked | Should Be 0
            $s.Warnings | Should BeGreaterThan 0
            $s.Counts.CheckGroupPolicies.Skipped | Should Be 1
            $s.FailureCount | Should Be 0
            $s.RuleUpdatesDone | Should Be 2
            @(Get-TestRequests -Method GET -Like '*displayName eq ''Another Group''*').Count | Should Be 0
        }

        It 'records a group that cannot be found as a failure and checks the rest' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ IncludeGroupNames = '["Missing Group","PIM Tier 0 Operators"]' }
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'ReadGroupPolicies'
            $s.GroupPoliciesChecked | Should Be 2
            $s.GroupsSkipped | Should Be $false
        }

        It 'resolves the approver group and plans approval for an overriding role' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; ApproverGroupName = 'PIM Approvers'; BaselineJson = '{"roles":{"Global Administrator":{"requireApproval":true}}}' }
            $s.RulesDrifted | Should Be 3
            $approval = @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/rules/Approval_EndUser_Assignment' -f $policyA))
            $approval.Count | Should Be 1
            $body = ConvertFrom-Json -InputObject $approval[0].Body
            $body.setting.isApprovalRequired | Should Be $true
            @($body.setting.approvalStages)[0].primaryApprovers[0].groupId | Should Be $approverGroupId
            @(Get-TestRequests -Method GET -Like '*displayName eq ''PIM Approvers''*').Count | Should Be 1
            @(Get-TestRequests -Method GET -Like ('*/groups/{0}/transitiveMembers/microsoft.graph.user*' -f $approverGroupId)).Count | Should Be 1
        }

        It 'stops before reading policies when an approver group does not exist' {
            Set-TestTenant
            { Invoke-TestRun -Parameters @{ ApproverGroupName = 'No Such Group'; BaselineJson = '{"defaults":{"requireApproval":true}}' } } | Should Throw 'Approver group "No Such Group" could not be resolved'
            @(Get-TestRequests -Like '*roleManagementPolicyAssignments*').Count | Should Be 0
        }

        It 'stops before reading policies when an approver group has no user members, in live and dry runs' {
            foreach ($dry in @($false, $true)) {
                Set-TestTenant -ApproverMembers @()
                { Invoke-TestRun -Parameters @{ DryRun = $dry; ApproverGroupName = 'PIM Approvers'; BaselineJson = '{"roles":{"Global Administrator":{"requireApproval":true}}}' } } | Should Throw ('Approver group "PIM Approvers" ({0}) has no user members' -f $approverGroupId)
                @(Get-TestRequests -Method GET -Like ('*/groups/{0}/transitiveMembers/microsoft.graph.user*' -f $approverGroupId)).Count | Should Be 1
                @(Get-TestRequests -Like '*roleManagementPolicyAssignments*').Count | Should Be 0
                @(Get-TestRequests -Like '*roleDefinitions*').Count | Should Be 0
                @(Get-TestRequests -Method PATCH).Count | Should Be 0
                @(Get-TestRequests -Method POST).Count | Should Be 0
            }
        }

        It 'fails with a permission hint when approver group members cannot be read' {
            $denied = New-TestResponse -Status 403 -Json @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges.' } }
            Set-TestTenant -Routes @(@{ Method = 'GET'; Pattern = '*/transitiveMembers/*'; Response = $denied })
            { Invoke-TestRun -Parameters @{ ApproverGroupName = 'PIM Approvers'; BaselineJson = '{"defaults":{"requireApproval":true}}' } } | Should Throw 'Group.Read.All'
            @(Get-TestRequests -Like '*roleManagementPolicyAssignments*').Count | Should Be 0
        }

        It 'records an override for a role that does not exist as a failure and mails it' {
            Set-TestTenant -DirectoryAssignments @((New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA))
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"roles":{"Global Admin":{"maximumActivationDuration":"PT1H"}}}' }
            $s.UnmatchedOverrides | Should Be 1
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'MatchOverride'
            $s.RulesDrifted | Should Be 0
            $s.DigestSent | Should Be $true
        }

        It 'skips an excluded role' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"roles":{"Security Administrator":{"exclude":true}}}' }
            $s.PoliciesExcluded | Should Be 1
            $s.RulesDrifted | Should Be 0
            $s.Counts.CheckPolicy.Skipped | Should Be 1
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
        }

        It 'flags stricter rules as drift in exact mode' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ BaselineJson = '{"mode":"exact"}' }
            $s.BaselineMode | Should Be 'exact'
            $s.RulesDrifted | Should Be 4
        }

        It 'refuses a group override for a group that is not included, before any request' {
            Set-TestTenant
            { Invoke-TestRun -Parameters @{ BaselineJson = '{"groups":{"PIM Tier 0 Operators":{"exclude":true}}}' } } | Should Throw 'not in IncludeGroupNames'
            $global:PimTestRequests.Count | Should Be 0
        }

        It 'rejects a malformed recipient or sender before any request' {
            Set-TestTenant
            { Invoke-TestRun -Parameters @{ Recipients = 'iam@corp.example.com; not-an-address' } } | Should Throw 'not a mail address'
            { Invoke-TestRun -Parameters @{ SenderMailbox = 'noreply' } } | Should Throw 'SenderMailbox "noreply" is not a mail address'
            $global:PimTestRequests.Count | Should Be 0
        }

        It 'warns instead of mailing when no recipients are set' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; Recipients = '' }
            $s.DigestSent | Should Be $false
            $s.Warnings | Should BeGreaterThan 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
            $s.RuleUpdatesDone | Should Be 2
        }

        It 'fails with a permission hint when the directory policies cannot be read' {
            $denied = New-TestResponse -Status 403 -Json @{ error = @{ code = 'Forbidden'; message = 'Denied.' } }
            Set-TestTenant -Routes @(@{ Method = 'GET'; Pattern = '*scopeType eq ''DirectoryRole''*'; Response = $denied })
            { Invoke-TestRun } | Should Throw 'RoleManagementPolicy.Read.Directory'
        }

        It 'records unreadable rules as failures without patching them, and still patches the drifted rule beside them' {
            # The approval rule is missing and the expiration rule has drifted,
            # so exactly one PATCH (expiration) proves the missing rule was skipped.
            $broken = New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Duration = 'PT8H' }
            $broken.policy.rules = @($broken.policy.rules | Where-Object { $_.id -ne 'Approval_EndUser_Assignment' })
            Set-TestTenant -DirectoryAssignments @($broken)
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            $s.RulesUnreadable | Should Be 1
            $s.RulesDrifted | Should Be 1
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'ReadRule'
            $s.Failures[0].Target | Should Be ('{0}/Approval_EndUser_Assignment' -f $policyB)
            $patches = @(Get-TestRequests -Method PATCH)
            $patches.Count | Should Be 1
            $patches[0].Uri | Should Be ('https://graph.microsoft.com/v1.0/policies/roleManagementPolicies/{0}/rules/Expiration_EndUser_Assignment' -f $policyB)
            @(Get-TestRequests -Method PATCH -Like '*Approval_EndUser_Assignment').Count | Should Be 0
            $s.RuleUpdatesDone | Should Be 1
            $s.DigestSent | Should Be $true
        }

        It 'records an accepted authentication context with no claim value as a failure and does not patch that rule' {
            $assignment = New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Enabled = @(); AuthContext = $true }
            Set-TestTenant -DirectoryAssignments @($assignment)
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"defaults":{"authenticationContextSatisfiesMfa":true}}' }
            $s.RulesUnreadable | Should Be 1
            $s.FailureCount | Should Be 1
            $s.Failures[0].Target | Should Be ('{0}/Enablement_EndUser_Assignment' -f $policyB)
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            $s.DigestSent | Should Be $true
        }

        It 'warns about MFA delegated to an authentication context and lists it in a digest' {
            # Global Administrator delegates MFA to context c1; Security
            # Administrator drifts, so a digest goes out and must carry the note.
            $assignments = @(
                (New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }),
                (New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Duration = 'PT8H' })
            )
            Set-TestTenant -DirectoryAssignments $assignments
            $reportPath = Join-Path -Path $TestDrive -ChildPath 'delegated.csv'
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; ReportPath = $reportPath; BaselineJson = '{"roles":{"Global Administrator":{"authenticationContextSatisfiesMfa":true}}}' }
            $s.RulesMfaDelegated | Should Be 1
            $s.RulesDrifted | Should Be 1
            $s.FailureCount | Should Be 0
            $s.Warnings | Should BeGreaterThan 0
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.Contains('Global Administrator') -and $_.Message.Contains('MFA delegated to authentication context c1') }).Count | Should Be 1
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/*' -f $policyA)).Count | Should Be 0
            $row = @(Import-Csv -Path $reportPath | Where-Object { $_.PolicyId -eq $policyA -and $_.RuleId -eq 'Enablement_EndUser_Assignment' })[0]
            $row.Status | Should Be 'Compliant'
            $row.Detail | Should Be 'MFA delegated to authentication context c1'
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.body.content.Contains('MFA delegated to authentication context c1') | Should Be $true
        }

        It 'sends no digest for a delegated MFA alone, but still warns' {
            Set-TestTenant -DirectoryAssignments @((New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }))
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"defaults":{"authenticationContextSatisfiesMfa":true}}' }
            $s.RulesMfaDelegated | Should Be 1
            $s.RulesDrifted | Should Be 0
            $s.DigestSent | Should Be $false
            $s.Warnings | Should BeGreaterThan 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
        }

        It 'patches MFA in next to an authentication context unless the baseline accepts the context for that role' {
            $assignments = @(
                (New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' }),
                (New-TestAssignment -RoleDefinitionId $securityAdminId -PolicyId $policyB -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c2' })
            )

            # Built-in baseline: neither context counts, so both roles get MFA beside it.
            Set-TestTenant -DirectoryAssignments $assignments
            $off = Invoke-TestRun -Parameters @{ DryRun = $false }
            $off.RulesDrifted | Should Be 2
            $off.RulesMfaDelegated | Should Be 0
            $off.RuleUpdatesDone | Should Be 2
            $patches = @(Get-TestRequests -Method PATCH)
            $patches.Count | Should Be 2
            foreach ($patch in $patches) {
                $patch.Uri | Should Match '/rules/Enablement_EndUser_Assignment$'
                (@((ConvertFrom-Json -InputObject $patch.Body).enabledRules) -join ',') | Should Be 'MultiFactorAuthentication,Justification'
            }
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.Contains('MFA delegated') }).Count | Should Be 0
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.body.content.Contains('authentication context c2 is enabled but counts as MFA only when the baseline sets authenticationContextSatisfiesMfa') | Should Be $true

            # The key on one role: only that role delegates MFA to its context.
            Set-TestTenant -DirectoryAssignments $assignments
            $one = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"roles":{"Global Administrator":{"authenticationContextSatisfiesMfa":true}}}' }
            $one.RulesDrifted | Should Be 1
            $one.RulesMfaDelegated | Should Be 1
            @(Get-TestRequests -Method PATCH).Count | Should Be 1
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/rules/Enablement_EndUser_Assignment' -f $policyB)).Count | Should Be 1
            @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.Contains('"Global Administrator"') -and $_.Message.Contains('MFA delegated to authentication context c1') }).Count | Should Be 1

            # The key in defaults: both contexts count, and nothing is written or sent.
            Set-TestTenant -DirectoryAssignments $assignments
            $all = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"defaults":{"authenticationContextSatisfiesMfa":true}}' }
            $all.RulesDrifted | Should Be 0
            $all.RulesMfaDelegated | Should Be 2
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method POST).Count | Should Be 0

            # A role override can switch the key off again under an accepting default.
            Set-TestTenant -DirectoryAssignments $assignments
            $back = Invoke-TestRun -Parameters @{ DryRun = $false; BaselineJson = '{"defaults":{"authenticationContextSatisfiesMfa":true},"roles":{"Security Administrator":{"authenticationContextSatisfiesMfa":false}}}' }
            $back.RulesDrifted | Should Be 1
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/*' -f $policyB)).Count | Should Be 1
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/*' -f $policyA)).Count | Should Be 0
        }

        It 'records a refused MFA patch next to an authentication context as a failure and mails it' {
            $refused = New-TestResponse -Status 400 -Json @{ error = @{ code = 'InvalidPolicyRule'; message = 'The policy rule is not valid.' } }
            Set-TestTenant -DirectoryAssignments @((New-TestAssignment -RoleDefinitionId $globalAdminId -PolicyId $policyA -Options @{ Enabled = @('Justification'); AuthContext = $true; ClaimValue = 'c1' })) -Routes @(@{ Method = 'PATCH'; Pattern = '*/rules/Enablement_EndUser_Assignment'; Response = $refused })
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            @(Get-TestRequests -Method PATCH).Count | Should Be 1
            $s.RuleUpdatesFailed | Should Be 1
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'PatchRule'
            $s.Failures[0].Detail | Should Match 'HTTP 400'
            $s.DigestSent | Should Be $true
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.subject | Should Be 'PIM policy drift: 1 rule(s) differ, 1 failure(s)'
        }

        It 'reads the baseline from the Automation variable by default when BaselineJson is empty' {
            Set-TestTenant
            try {
                $script:RunbookAutomationVariables = @{ PimPolicy_EntraBaseline = '{"roles":{"Security Administrator":{"exclude":true}}}' }
                # Called without BaselineVariableName, so the run function's default applies.
                $s = Invoke-EntraPimPolicyDriftRun -AccessToken $token -RunId $runId -DryRun $false -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 2>$null 3>$null
            }
            finally { $script:RunbookAutomationVariables = $null }
            $s.BaselineSource | Should Be 'Automation variable "PimPolicy_EntraBaseline"'
            $s.PoliciesExcluded | Should Be 1
            $s.RulesDrifted | Should Be 0
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-RunLogEntries -Level Info | Where-Object { $_.Message.StartsWith('Baseline from Automation variable "PimPolicy_EntraBaseline": mode=minimum ') }).Count | Should Be 1
            # The variable text itself is never logged.
            @(Get-RunLogEntries | Where-Object { $_.Message.Contains('"exclude":true') }).Count | Should Be 0
        }

        It 'prefers BaselineJson over the variable, and uses the built-in baseline when both are blank' {
            try {
                $script:RunbookAutomationVariables = @{ PimPolicy_EntraBaseline = '{"roles":{"Security Administrator":{"exclude":true}}}' }
                Set-TestTenant
                $json = Invoke-TestRun -Parameters @{ BaselineVariableName = 'PimPolicy_EntraBaseline'; BaselineJson = '{"mode":"exact"}' }
                $json.BaselineSource | Should Be 'BaselineJson'
                $json.BaselineMode | Should Be 'exact'
                $json.PoliciesExcluded | Should Be 0
                $json.RulesDrifted | Should Be 4

                Set-TestTenant
                $builtIn = Invoke-TestRun -Parameters @{ BaselineVariableName = '' }
                $builtIn.BaselineSource | Should Be 'the built-in baseline'
                $builtIn.BaselineMode | Should Be 'minimum'
                $builtIn.PoliciesExcluded | Should Be 0
                $builtIn.RulesDrifted | Should Be 2
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'stops before any request when the baseline variable is missing, empty, not a string, or not a valid baseline' {
            $cases = @(
                @{ Table = @{}; Message = 'Could not read the baseline from Automation variable "PimPolicy_EntraBaseline": Automation variable "PimPolicy_EntraBaseline" is not in' },
                @{ Table = @{ PimPolicy_EntraBaseline = '' }; Message = 'Automation variable "PimPolicy_EntraBaseline" is empty.' },
                @{ Table = @{ PimPolicy_EntraBaseline = 5 }; Message = 'holds a Int32, not a string' },
                @{ Table = @{ PimPolicy_EntraBaseline = '@{mode=minimum; roles=}' }; Message = 'Automation variable "PimPolicy_EntraBaseline" arrived as a converted object' },
                @{ Table = @{ PimPolicy_EntraBaseline = 'System.Collections.Hashtable' }; Message = 'Automation variable "PimPolicy_EntraBaseline" arrived as a converted object' },
                @{ Table = @{ PimPolicy_EntraBaseline = '{"roles":{"Global Administrator":{"requireAproval":true}}}' }; Message = 'Automation variable "PimPolicy_EntraBaseline" roles."Global Administrator" has an unknown key "requireAproval"' },
                @{ Table = @{ PimPolicy_EntraBaseline = '{"groups":{"PIM Tier 0 Operators":{"exclude":true}}}' }; Message = 'Automation variable "PimPolicy_EntraBaseline" groups."PIM Tier 0 Operators" names a group that is not in IncludeGroupNames' }
            )
            try {
                foreach ($case in $cases) {
                    $script:RunbookAutomationVariables = $case.Table
                    Set-TestTenant
                    { Invoke-TestRun -Parameters @{ DryRun = $false; BaselineVariableName = 'PimPolicy_EntraBaseline' } } | Should Throw $case.Message
                    $global:PimTestRequests.Count | Should Be 0
                }

                # Outside the sandbox with no table: a clear hint for a workstation run.
                $script:RunbookAutomationVariables = $null
                Remove-TestSandboxVariable
                Set-TestTenant
                { Invoke-TestRun -Parameters @{ BaselineVariableName = 'PimPolicy_EntraBaseline' } } | Should Throw "-BaselineVariableName '' for the built-in baseline."
                $global:PimTestRequests.Count | Should Be 0
            }
            finally { $script:RunbookAutomationVariables = $null }
        }

        It 'reads the variable through Get-AutomationVariable in the sandbox, and warns when a job gets BaselineJson' {
            try {
                Set-TestSandboxVariable -Value '{"roles":{"Security Administrator":{"exclude":true}}}'
                Set-TestTenant
                $s = Invoke-EntraPimPolicyDriftRun -AccessToken $token -RunId $runId 2>$null 3>$null
                ($global:PimTestVariableCalls -join ',') | Should Be 'PimPolicy_EntraBaseline'
                $s.BaselineSource | Should Be 'Automation variable "PimPolicy_EntraBaseline"'
                $s.PoliciesExcluded | Should Be 1
                @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.StartsWith('BaselineJson was passed') }).Count | Should Be 0

                Set-TestTenant
                $j = Invoke-TestRun -Parameters @{ BaselineVariableName = 'PimPolicy_EntraBaseline'; BaselineJson = '{}' }
                $global:PimTestVariableCalls.Count | Should Be 1
                $j.BaselineSource | Should Be 'BaselineJson'
                $j.PoliciesExcluded | Should Be 0
                $j.Warnings | Should BeGreaterThan 0
                @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.StartsWith('BaselineJson was passed to a job in Azure Automation, so the Automation string variable "PimPolicy_EntraBaseline" was not read.') }).Count | Should Be 1

                # The same warning outside the sandbox would be noise.
                Remove-TestSandboxVariable
                Set-TestTenant
                Invoke-TestRun -Parameters @{ BaselineJson = '{}' } | Out-Null
                @(Get-RunLogEntries -Level Warn | Where-Object { $_.Message.StartsWith('BaselineJson was passed') }).Count | Should Be 0
            }
            finally {
                Remove-TestSandboxVariable
                Remove-Variable -Name PimTestVariableCalls -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'takes IncludeGroupNames and Recipients as semicolon lists, the form a schedule carries' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false; IncludeGroupNames = 'PIM Tier 0 Operators;Missing Group'; Recipients = 'iam@corp.example.com;secops@corp.example.com' }
            $s.GroupPoliciesChecked | Should Be 2
            $s.FailureCount | Should Be 1
            $s.Failures[0].Action | Should Be 'ReadGroupPolicies'
            $s.Failures[0].Target | Should Be 'Missing Group'
            @(Get-TestRequests -Method GET -Like '*displayName eq ''PIM Tier 0 Operators''*').Count | Should Be 1
            @(Get-TestRequests -Method GET -Like '*displayName eq ''Missing Group''*').Count | Should Be 1
            $s.DigestSent | Should Be $true
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            (@($message.message.toRecipients | ForEach-Object { $_.emailAddress.address }) -join ',') | Should Be 'iam@corp.example.com,secops@corp.example.com'
        }

        It 'uses the US Government endpoint for every request' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ Environment = 'USGov'; DryRun = $false }
            $s.Environment | Should Be 'USGov'
            $global:PimTestRequests.Count | Should BeGreaterThan 3
            @($global:PimTestRequests | Where-Object { $_.Host -ne 'graph.microsoft.us' }).Count | Should Be 0
        }

        It 'never writes the token to the summary or the log' {
            Set-TestTenant
            $s = Invoke-TestRun -Parameters @{ DryRun = $false }
            (ConvertTo-Json -InputObject $s -Depth 10).Contains($token) | Should Be $false
            @(Get-RunLogEntries | Where-Object { $_.Message.Contains($token) }).Count | Should Be 0
            @(Get-RunLogEntries).Count | Should BeGreaterThan 5
        }
    }

    # -----------------------------------------------------------------------
    # ReportPath: checked before any request; a late write failure never
    # hides the summary or the breaker.
    # -----------------------------------------------------------------------

    Context 'report path checked up front' {
        It 'refuses a path on a drive that does not exist, before any request' {
            $freeDrive = @([char[]](81..90) | Where-Object { -not (Test-Path -LiteralPath ('{0}:\' -f $_)) })[0]
            $freeDrive | Should Not BeNullOrEmpty
            Set-TestTenant
            { Invoke-TestRun -Parameters @{ ReportPath = ('{0}:\reports\pim.csv' -f $freeDrive) } } | Should Throw ('ReportPath "{0}:\reports\pim.csv" cannot be used' -f $freeDrive)
            $global:PimTestRequests.Count | Should Be 0
        }

        It 'refuses a folder and a non-file-system path, before any request' {
            Set-TestTenant
            $folder = Join-Path -Path $TestDrive -ChildPath 'a-folder'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            { Invoke-TestRun -Parameters @{ ReportPath = $folder } } | Should Throw 'is a folder'
            { Invoke-TestRun -Parameters @{ ReportPath = 'Env:\PIM_REPORT' } } | Should Throw 'is not a file system path'
            $global:PimTestRequests.Count | Should Be 0
        }

        It 'refuses a locked file, before any request' {
            Set-TestTenant
            $locked = Join-Path -Path $TestDrive -ChildPath 'locked\pim.csv'
            New-Item -ItemType Directory -Path (Split-Path -Parent $locked) -Force | Out-Null
            Set-Content -LiteralPath $locked -Value 'previous' -Encoding ASCII
            $stream = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                { Invoke-TestRun -Parameters @{ ReportPath = $locked } } | Should Throw ('ReportPath "{0}" cannot be written' -f $locked)
            }
            finally { $stream.Dispose() }
            $global:PimTestRequests.Count | Should Be 0
            (Get-Content -LiteralPath $locked) | Should Be 'previous'
        }

        It 'creates the folder before reading and leaves no file behind when the run stops early' {
            $denied = New-TestResponse -Status 403 -Json @{ error = @{ code = 'Forbidden'; message = 'Denied.' } }
            Set-TestTenant -Routes @(@{ Method = 'GET'; Pattern = '*scopeType eq ''DirectoryRole''*'; Response = $denied })
            $path = Join-Path -Path $TestDrive -ChildPath 'early\nested\pim.csv'
            { Invoke-TestRun -Parameters @{ ReportPath = $path } } | Should Throw 'RoleManagementPolicy.Read.Directory'
            Test-Path -LiteralPath (Split-Path -Parent $path) -PathType Container | Should Be $true
            Test-Path -LiteralPath $path | Should Be $false
        }

        It 'resolves a relative path against the current location' {
            Set-TestTenant
            Push-Location -Path $TestDrive
            try {
                $s = Invoke-TestRun -Parameters @{ ReportPath = '.\relative\pim.csv' }
            }
            finally { Pop-Location }
            $expected = Join-Path -Path (Join-Path -Path $TestDrive -ChildPath 'relative') -ChildPath 'pim.csv'
            $s.ReportPath | Should Be $expected
            $s.ReportWritten | Should Be $true
            @(Import-Csv -LiteralPath $expected).Count | Should Be 9
        }
    }

    Context 'report write failing at the end' {
        Mock Export-PimDriftReport { throw 'The process cannot access the file because it is being used by another process.' }

        It 'records the failure, mails it, and still returns the summary after the writes' {
            Set-TestTenant
            $path = Join-Path -Path $TestDrive -ChildPath 'late\pim.csv'
            $s = @(Invoke-TestRun -Parameters @{ DryRun = $false; ReportPath = $path })
            $s.Count | Should Be 1
            $s[0].RuleUpdatesDone | Should Be 2
            $s[0].ReportWritten | Should Be $false
            $s[0].FailureCount | Should Be 1
            $s[0].Failures[0].Action | Should Be 'ExportReport'
            $s[0].Failures[0].Detail | Should Match 'being used by another process'
            $s[0].Counts.ExportReport.Failed | Should Be 1
            $s[0].Errors | Should BeGreaterThan 0
            $s[0].DigestSent | Should Be $true
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            $message.message.subject | Should Be 'PIM policy drift: 2 rule(s) differ, 1 failure(s)'
            $message.message.body.content.Contains('ExportReport') | Should Be $true
            Assert-MockCalled Export-PimDriftReport -Scope It -Exactly 1
        }

        It 'ends with the breaker error, not the file error, when the breaker trips' {
            Set-TestTenant
            $path = Join-Path -Path $TestDrive -ChildPath 'late\breaker.csv'
            $caught = $null
            try { Invoke-TestRun -Parameters @{ DryRun = $false; MaxRuleUpdatesPerRun = 1; ReportPath = $path } | Out-Null }
            catch { $caught = $_ }
            $caught | Should Not BeNullOrEmpty
            $caught.Exception.Message | Should Match '^Circuit breaker tripped: PIM policy rule updates: 2 planned, cap is 1\.'
            $caught.Exception.Message.Contains('another process') | Should Be $false
            Assert-MockCalled Export-PimDriftReport -Scope It -Exactly 1
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method POST).Count | Should Be 0
            @(Get-RunLogEntries -Level Error | Where-Object { $_.Message.Contains('Could not write the report') }).Count | Should Be 1
        }
    }

    # -----------------------------------------------------------------------
    # Host contract with Runbook.Common and modules/azure/automation-runbooks.
    # -----------------------------------------------------------------------

    Context 'inline contract' {
        $begin = '# INLINE_LIBRARY_' + 'BEGIN'
        $end = '# INLINE_LIBRARY_' + 'END'
        $runbookText = [System.IO.File]::ReadAllText($runbook)
        $libraryText = [System.IO.File]::ReadAllText($library)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($runbookText, [ref]$tokens, [ref]$errors)

        Mock Invoke-WebRequest {
            $result = & $global:PimTestRouter ([string]$Method) ([string]$Uri) $Body
            return [PSCustomObject]@{ StatusCode = $result.StatusCode; Content = $result.Content; Headers = @{} }
        }

        It 'has each marker exactly once, as the module validation requires' {
            $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Split([string[]]@($end), [StringSplitOptions]::None).Count | Should Be 2
            $runbookText.Contains(". (Join-Path -Path `$PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')") | Should Be $true
        }

        It 'is ASCII without a byte order mark or long dashes, and parses cleanly' {
            $bytes = [System.IO.File]::ReadAllBytes($runbook)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
            $runbookText.Contains([string][char]0x2013) | Should Be $false
            $runbookText.Contains([string][char]0x2014) | Should Be $false
            @($errors).Count | Should Be 0
            $testBytes = [System.IO.File]::ReadAllBytes($thisTestFile)
            @($testBytes | Where-Object { $_ -gt 127 }).Count | Should Be 0
        }

        It 'has no #Requires statement, which the Automation sandbox does not support' {
            $ast.ScriptRequirements | Should BeNullOrEmpty
            @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '^#requires' }).Count | Should Be 0
        }

        It 'defines no function the library defines, and gives every function help' {
            $libraryAst = [System.Management.Automation.Language.Parser]::ParseInput($libraryText, [ref]$null, [ref]$null)
            $libraryNames = @($libraryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            $libraryNames.Count | Should BeGreaterThan 30
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            $functions.Count | Should BeGreaterThan 20
            (@($functions | Where-Object { $libraryNames -contains $_.Name } | ForEach-Object { $_.Name }) -join ', ') | Should Be ''
            (@($functions | Where-Object { $null -eq $_.GetHelpContent() -or [string]::IsNullOrWhiteSpace($_.GetHelpContent().Synopsis) } | ForEach-Object { $_.Name }) -join ', ') | Should Be ''
        }

        It 'declares only bool, int, and string parameters, with DryRun on by default' {
            $parameters = @($ast.ParamBlock.Parameters)
            $names = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($required in @('DryRun', 'Environment', 'ClientId', 'AccessToken', 'RunId', 'SenderMailbox', 'BaselineVariableName', 'BaselineJson', 'IncludeGroupNames', 'ApproverGroupName', 'Recipients', 'MaxRuleUpdatesPerRun', 'ReportPath')) {
                ($names -contains $required) | Should Be $true
            }
            (@($parameters | Where-Object { @([bool], [int], [string]) -notcontains $_.StaticType } | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ', ') | Should Be ''
            $dryRun = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' })[0]
            $dryRun.DefaultValue.Extent.Text | Should Be '$true'
            $cap = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MaxRuleUpdatesPerRun' })[0]
            $cap.DefaultValue.Extent.Text | Should Be '40'
            @($parameters | Where-Object { @($_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' }).Count -gt 0 }).Count | Should Be 0
        }

        It 'documents every parameter and shows a local run with -AccessToken' {
            $help = $ast.GetHelpContent()
            $help | Should Not BeNullOrEmpty
            foreach ($parameter in @($ast.ParamBlock.Parameters)) {
                $name = $parameter.Name.VariablePath.UserPath
                $help.Parameters.ContainsKey($name.ToUpperInvariant()) | Should Be $true
            }
            @($help.Examples | Where-Object { $_ -match '-AccessToken \$token' }).Count | Should BeGreaterThan 0
            $help.Description.Contains('Recommended schedule') | Should Be $true
            $help.Description.Contains('Azure RBAC roles: none') | Should Be $true
            $help.Description.Contains('RoleManagementPolicy.ReadWrite.Directory') | Should Be $true
            $help.Description.Contains('administrative') | Should Be $true
        }

        It 'documents the schedule, the tier 0 permission, the baseline variable, and semicolon lists' {
            $help = $ast.GetHelpContent()
            $description = $help.Description
            $description.Contains('every day at 05:15') | Should Be $true
            $description.Contains('UTC (schedule daily-0515-utc)') | Should Be $true
            $runbookText.Contains('0600') | Should Be $false
            $description.Contains('RoleManagementPolicy.ReadWrite.Directory is a tier 0 permission') | Should Be $true
            $description.Contains('removing MFA') | Should Be $true
            $description.Contains('or approval from Global Administrator activation') | Should Be $true
            $description.Contains('belongs only to the PIM tier identity') | Should Be $true
            $description.Contains('authenticationContextSatisfiesMfa') | Should Be $true
            $description.Contains('PimPolicy_EntraBaseline') | Should Be $true
            $description.Contains('jsonencode') | Should Be $false
            $help.Parameters['BASELINEVARIABLENAME'].Contains('PimPolicy_EntraBaseline') | Should Be $true
            $help.Parameters['INCLUDEGROUPNAMES'].Contains('separated by') | Should Be $true
            $help.Parameters['INCLUDEGROUPNAMES'].Contains('semicolons') | Should Be $true
            $help.Parameters['RECIPIENTS'].Contains('semicolons') | Should Be $true
            # Schedule-shaped examples carry plain lists, never JSON.
            @($help.Examples | Where-Object { $_ -match "-(Recipients|IncludeGroupNames) '\[" }).Count | Should Be 0
            @($help.Examples | Where-Object { $_ -match "-BaselineVariableName ''" }).Count | Should BeGreaterThan 0
        }

        It 'avoids host-only and 7-only constructs' {
            $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            ($commands -contains 'Write-Host') | Should Be $false
            ($commands -contains 'Invoke-WebRequest') | Should Be $false
            ($commands -contains 'Invoke-RestMethod') | Should Be $false
            $inputVariables = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'input' }, $true))
            $inputVariables.Count | Should Be 0
            $runbookText.Contains("if (`$MyInvocation.InvocationName -ne '.') {") | Should Be $true

            # Ternary, ??, ??=, ?. and ?[ . PowerShell 7 tokenizes them as
            # Question* operators; 5.1 gives Generic tokens starting with '?'
            # (plus a parse error). A variable whose name holds '?' parses on
            # both but reads like ?. on 7, so it is refused too. Strings and
            # comments are separate tokens and never match.
            $sevenOnlyKinds = @('QuestionMark', 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket')
            $findSevenOnly = {
                param($TokenList)
                @($TokenList | Where-Object {
                        $kind = $_.Kind.ToString()
                        ($sevenOnlyKinds -contains $kind) -or
                        ((@('Generic', 'Identifier') -contains $kind) -and $_.Text.StartsWith('?')) -or
                        ($kind -eq 'Variable' -and $_.Text.Contains('?'))
                    } | ForEach-Object { '{0}:{1}' -f $_.Extent.StartLineNumber, $_.Text })
            }
            foreach ($sample in @('$a = $b ?? $c', '$a ??= 1', '$a = ${b}?.c', '$a = ${b}?[0]', '$a = $b ? 1 : 2', '$a = ($b) ? 1 : 2', '$a = $b?.c')) {
                $sampleTokens = $null
                [System.Management.Automation.Language.Parser]::ParseInput($sample, [ref]$sampleTokens, [ref]$null) | Out-Null
                (@(& $findSevenOnly $sampleTokens).Count -gt 0) | Should Be $true
            }
            $cleanTokens = $null
            [System.Management.Automation.Language.Parser]::ParseInput('$s = "a ?? b ?. c ? d" # e ?? f', [ref]$cleanTokens, [ref]$null) | Out-Null
            @(& $findSevenOnly $cleanTokens).Count | Should Be 0
            (@(& $findSevenOnly $tokens) -join ', ') | Should Be ''
        }

        It 'runs from disk with the dot-source between the markers' {
            $runbooksDir = Join-Path -Path $TestDrive -ChildPath 'disk\automation\runbooks'
            $libDir = Join-Path -Path $TestDrive -ChildPath 'disk\automation\lib'
            New-Item -ItemType Directory -Path $runbooksDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -Path $library -Destination (Join-Path -Path $libDir -ChildPath 'Runbook.Common.ps1')
            $diskPath = Join-Path -Path $runbooksDir -ChildPath 'Invoke-EntraPimPolicyDrift.ps1'
            Copy-Item -Path $runbook -Destination $diskPath

            Set-TestTenant
            $summary = @(& $diskPath -AccessToken $token -RunId $runId -BaselineVariableName '' -Recipients 'iam@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' 4>$null 3>$null 2>$null)
            $summary.Count | Should Be 1
            $summary[0].Runbook | Should Be 'Invoke-EntraPimPolicyDrift'
            $summary[0].RunId | Should Be $runId
            $summary[0].DryRun | Should Be $true
            $summary[0].BaselineSource | Should Be 'the built-in baseline'
            $summary[0].RulesDrifted | Should Be 2
            $summary[0].Counts.PatchRule.Planned | Should Be 2
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
            @(Get-TestRequests -Method GET).Count | Should BeGreaterThan 1
            # The script's own copy of the library transport made the calls.
            Assert-MockCalled Invoke-WebRequest -Scope It -Times 2
            Assert-MockCalled Invoke-HttpCore -Scope It -Exactly 0
        }

        It 'runs when assembled the way Terraform inlines library_path, in USGov and live' {
            # main.tf: join("", [split(begin, runbook)[0], begin, "\n", file(library), "\n", end, split(end, runbook)[1]])
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $assembled = $head + $begin + "`n" + $libraryText + "`n" + $end + $tail
            $assembled.Contains('..\lib\Runbook.Common.ps1') | Should Be $false
            $assembled.Contains('function Invoke-CloudRequest') | Should Be $true
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($assembled, [ref]$null, [ref]$parseErrors) | Out-Null
            @($parseErrors).Count | Should Be 0

            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-EntraPimPolicyDrift.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, $assembled, (New-Object System.Text.UTF8Encoding($false)))

            # The schedule's shape: plain semicolon lists, no BaselineJson, and
            # the baseline in the default Automation variable, read through the
            # sandbox's Get-AutomationVariable. The variable's group override
            # makes the member policy's PT8H compliant, so only the two
            # Security Administrator rules are patched.
            try {
                Set-TestSandboxVariable -Value '{"mode":"minimum","groups":{"PIM Tier 0 Operators":{"maximumActivationDuration":"PT8H"}}}'
                Set-TestTenant
                $summary = @(& $published -AccessToken $token -RunId $runId -Environment USGov -DryRun $false -Recipients 'iam@corp.example.com;secops@corp.example.com' -SenderMailbox 'iam-noreply@corp.example.com' -IncludeGroupNames 'PIM Tier 0 Operators' 4>$null 3>$null 2>$null)
                ($global:PimTestVariableCalls -join ',') | Should Be 'PimPolicy_EntraBaseline'
            }
            finally {
                Remove-TestSandboxVariable
                Remove-Variable -Name PimTestVariableCalls -Scope Global -ErrorAction SilentlyContinue
            }
            $summary.Count | Should Be 1
            $summary[0].Environment | Should Be 'USGov'
            $summary[0].DryRun | Should Be $false
            $summary[0].BaselineSource | Should Be 'Automation variable "PimPolicy_EntraBaseline"'
            $summary[0].GroupPoliciesChecked | Should Be 2
            $summary[0].RuleUpdatesDone | Should Be 2
            $summary[0].DigestSent | Should Be $true
            @(Get-TestRequests -Method PATCH).Count | Should Be 2
            @(Get-TestRequests -Method PATCH -Like ('*/roleManagementPolicies/{0}/*' -f $policyMember)).Count | Should Be 0
            $message = ConvertFrom-Json -InputObject (@(Get-TestRequests -Method POST)[0].Body)
            (@($message.message.toRecipients | ForEach-Object { $_.emailAddress.address }) -join ',') | Should Be 'iam@corp.example.com,secops@corp.example.com'
            @($global:PimTestRequests | Where-Object { $_.Host -ne 'graph.microsoft.us' }).Count | Should Be 0
            Assert-MockCalled Invoke-HttpCore -Scope It -Exactly 0
        }

        It 'trips the breaker in the assembled runbook before any write' {
            $head = $runbookText.Split([string[]]@($begin), [StringSplitOptions]::None)[0]
            $tail = $runbookText.Split([string[]]@($end), [StringSplitOptions]::None)[1]
            $published = Join-Path -Path $TestDrive -ChildPath 'published\Invoke-EntraPimPolicyDriftBreaker.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $published) -Force | Out-Null
            [System.IO.File]::WriteAllText($published, ($head + $begin + "`n" + $libraryText + "`n" + $end + $tail), (New-Object System.Text.UTF8Encoding($false)))
            Set-TestTenant
            { & $published -AccessToken $token -BaselineVariableName '' -DryRun $false -MaxRuleUpdatesPerRun 1 4>$null 3>$null 2>$null } | Should Throw 'Circuit breaker tripped: PIM policy rule updates: 2 planned, cap is 1.'
            @(Get-TestRequests -Method PATCH).Count | Should Be 0
        }
    }

    Remove-TestSandboxVariable
    $script:RunbookAutomationVariables = $null
    Remove-Variable -Name PimTestRequests, PimTestRoutes, PimTestRouter, PimTestVariableCalls -Scope Global -ErrorAction SilentlyContinue
}
