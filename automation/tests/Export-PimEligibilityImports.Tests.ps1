# Pester tests for scripts/Export-PimEligibilityImports.ps1.
#
# Pester 3/4 assertion syntax. The script is dot-sourced and its two data
# sources (Invoke-ArmGetAll, Invoke-GraphGetAll) are mocked with the shapes
# the ARM and Graph APIs document. The corp tenant cells in this repository
# are used as the "existing cell" inputs so key reuse is exercised against
# real files.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script = Join-Path -Path $repoRoot -ChildPath 'scripts\Export-PimEligibilityImports.ps1'
$azureCell = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-pim-governance\terragrunt.hcl'
$entraCell = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\entra-pim-governance\terragrunt.hcl'

Describe 'Export-PimEligibilityImports' {
    . $script -SkipAzure -SkipEntra -ArmAccessToken 'arm-token' -GraphAccessToken 'graph-token'
    $WarningPreference = 'SilentlyContinue'
    Mock Write-Host { }

    $subId = '11111111-1111-1111-1111-111111111111'
    $subScope = "/subscriptions/$subId"
    $mgScope = '/providers/Microsoft.Management/managementGroups/mg-example-root'
    $contributorGuid = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    $readerGuid = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    $cloudEngineersId = '22222222-2222-2222-2222-222222222222'
    $dataPlatformId = '33333333-3333-3333-3333-333333333333'
    $someUserId = '44444444-4444-4444-4444-444444444444'
    $pimGlobalAdminsId = '55555555-5555-5555-5555-555555555555'
    $pimHelpdeskId = '66666666-6666-6666-6666-666666666666'
    $gaTemplate = '62e90394-69f5-4237-9190-012177145e10'
    $helpdeskTemplate = '729827e3-9c14-49f7-bb1b-9608f156bbb8'

    function New-ArmInstance {
        param([string]$Scope, [string]$RoleGuid, [string]$RoleName, [string]$PrincipalId, [string]$PrincipalType, [string]$PrincipalName, [string]$ScopeType, [string]$ScopeDisplayName, [object]$End = '2027-03-01T00:00:00Z', [string]$MemberType = 'Direct')
        return [PSCustomObject]@{
            id         = "$Scope/providers/Microsoft.Authorization/RoleEligibilityScheduleInstances/aaaa"
            name       = 'aaaa'
            properties = [PSCustomObject]@{
                scope                     = $Scope
                roleDefinitionId          = "$Scope/providers/Microsoft.Authorization/roleDefinitions/$RoleGuid"
                principalId               = $PrincipalId
                principalType             = $PrincipalType
                status                    = 'Provisioned'
                memberType                = $MemberType
                startDateTime             = '2026-03-01T00:00:00Z'
                endDateTime               = $End
                roleEligibilityScheduleId = "$Scope/providers/Microsoft.Authorization/RoleEligibilitySchedules/bbbb"
                expandedProperties        = [PSCustomObject]@{
                    scope          = [PSCustomObject]@{ id = $Scope; displayName = $ScopeDisplayName; type = $ScopeType }
                    roleDefinition = [PSCustomObject]@{ id = "$Scope/providers/Microsoft.Authorization/roleDefinitions/$RoleGuid"; displayName = $RoleName; type = 'BuiltInRole' }
                    principal      = [PSCustomObject]@{ id = $PrincipalId; displayName = $PrincipalName; type = $PrincipalType }
                }
            }
        }
    }

    Mock Invoke-ArmGetAll {
        if ($Path -like 'providers/Microsoft.Management/managementGroups[?]*') {
            return @([PSCustomObject]@{ id = $mgScope; name = 'mg-example-root'; properties = [PSCustomObject]@{ displayName = 'mg-example-root' } })
        }
        if ($Path -like 'subscriptions[?]*') {
            return @([PSCustomObject]@{ id = $subScope; subscriptionId = $subId; displayName = 'sub-example-prod' })
        }
        if ($Path -like "$subScope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances*") {
            return @(
                (New-ArmInstance -Scope $subScope -RoleGuid $contributorGuid -RoleName 'Contributor' -PrincipalId $cloudEngineersId -PrincipalType 'Group' -PrincipalName 'Cloud Engineers' -ScopeType 'subscription' -ScopeDisplayName 'sub-example-prod' -End '2026-08-28T00:00:00Z'),
                (New-ArmInstance -Scope $subScope -RoleGuid $readerGuid -RoleName 'Reader' -PrincipalId $dataPlatformId -PrincipalType 'Group' -PrincipalName 'Data Platform' -ScopeType 'subscription' -ScopeDisplayName 'sub-example-prod' -End $null),
                (New-ArmInstance -Scope $subScope -RoleGuid $readerGuid -RoleName 'Reader' -PrincipalId $someUserId -PrincipalType 'User' -PrincipalName 'Some Person' -ScopeType 'subscription' -ScopeDisplayName 'sub-example-prod'),
                (New-ArmInstance -Scope $mgScope -RoleGuid $readerGuid -RoleName 'Reader' -PrincipalId $dataPlatformId -PrincipalType 'Group' -PrincipalName 'Inherited Group' -ScopeType 'managementgroup' -ScopeDisplayName 'mg-example-root' -MemberType 'Inherited')
            )
        }
        if ($Path -like "$mgScope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances*") {
            return @()
        }
        return @()
    }

    Mock Invoke-GraphGetAll {
        if ($Path -like 'roleManagement/directory/roleEligibilityScheduleInstances*') {
            return @(
                [PSCustomObject]@{
                    id = 'i1'; principalId = $pimGlobalAdminsId; roleDefinitionId = $gaTemplate; directoryScopeId = '/'; memberType = 'Direct'; roleEligibilityScheduleId = 'sched-ga'; endDateTime = $null
                    principal = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.group'; id = $pimGlobalAdminsId; displayName = 'PIM Global Administrators' }
                    roleDefinition = [PSCustomObject]@{ id = $gaTemplate; displayName = 'Global Administrator' }
                },
                [PSCustomObject]@{
                    id = 'i2'; principalId = $pimHelpdeskId; roleDefinitionId = $helpdeskTemplate; directoryScopeId = '/'; memberType = 'Direct'; roleEligibilityScheduleId = 'sched-hd'; endDateTime = '2027-01-01T00:00:00Z'
                    principal = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.group'; id = $pimHelpdeskId; displayName = 'PIM Helpdesk Administrators' }
                    roleDefinition = [PSCustomObject]@{ id = $helpdeskTemplate; displayName = 'Helpdesk Administrator' }
                },
                [PSCustomObject]@{
                    id = 'i3'; principalId = $someUserId; roleDefinitionId = $gaTemplate; directoryScopeId = '/'; memberType = 'Direct'; roleEligibilityScheduleId = 'sched-user'; endDateTime = $null
                    principal = [PSCustomObject]@{ '@odata.type' = '#microsoft.graph.user'; id = $someUserId; displayName = 'Some Person' }
                    roleDefinition = [PSCustomObject]@{ id = $gaTemplate; displayName = 'Global Administrator' }
                }
            )
        }
        if ($Path -like 'roleManagement/directory/roleEligibilityScheduleRequests*sched-ga*') {
            return @([PSCustomObject]@{ id = 'req-ga'; action = 'adminAssign'; status = 'Provisioned'; createdDateTime = '2026-01-01T00:00:00Z' })
        }
        if ($Path -like 'roleManagement/directory/roleEligibilityScheduleRequests*') {
            return @()
        }
        return @()
    }

    Context 'existing cell parsing' {
        It 'reads every eligibility key from the corp azure cell' {
            $keys = Get-AzureCellKeys -Path $azureCell
            $keys.Count | Should Be 6
            $keys['subscription/sub-example-prod|contributor|cloud engineers'] | Should Be 'cloud-engineers-contributor-prod'
            $keys['management_group/mg-example-root|owner|break glass owners'] | Should Be 'break-glass-owner-at-root'
        }

        It 'reads every directory role eligibility key from the corp entra cell' {
            $keys = Get-EntraCellKeys -Path $entraCell
            $keys.Count | Should Be 3
            $keys['global administrator|pim global administrators|/'] | Should Be 'global-admin'
        }
    }

    Context 'end-to-end with mocked APIs' {
        $out = Join-Path -Path $TestDrive -ChildPath 'out'
        $summary = Invoke-PimEligibilityExport -ManagementGroupNames @('mg-example-root') -SubscriptionNames @('sub-example-prod') -OutputDirectory $out `
            -AzureCellPath $azureCell -EntraCellPath $entraCell -ArmAccessToken 'arm-token' -GraphAccessToken 'graph-token'
        $azureImports = Get-Content -Path (Join-Path -Path $out -ChildPath 'azure-pim-governance\imports.tf') -Raw
        $azureValues = Get-Content -Path (Join-Path -Path $out -ChildPath 'azure-pim-governance\values.skeleton.hcl') -Raw
        $entraImports = Get-Content -Path (Join-Path -Path $out -ChildPath 'entra-pim-governance\imports.tf') -Raw
        $entraValues = Get-Content -Path (Join-Path -Path $out -ChildPath 'entra-pim-governance\values.skeleton.hcl') -Raw

        It 'emits the azurerm composite import ID scope|roleDefinitionId|principalId' {
            $expected = '  id = "{0}|{0}/providers/Microsoft.Authorization/roleDefinitions/{1}|{2}"' -f $subScope, $contributorGuid, $cloudEngineersId
            $azureImports.Contains($expected) | Should Be $true
        }

        It 'reuses the key already in the cell for a known (scope, role, group)' {
            $azureImports.Contains('to = module.pim_eligible_assignment.azurerm_pim_eligible_role_assignment.this["cloud-engineers-contributor-prod"]') | Should Be $true
            $azureValues.Contains('# cloud-engineers-contributor-prod: already in the cell; import only.') | Should Be $true
        }

        It 'generates a group-role-scope key for an unknown eligibility and a skeleton entry for it' {
            $azureImports.Contains('this["data-platform-reader-sub-example-prod"]') | Should Be $true
            $azureValues.Contains('"data-platform-reader-sub-example-prod" = {') | Should Be $true
            $azureValues.Contains('group_display_name = "Data Platform"') | Should Be $true
            $azureValues.Contains('scope              = { type = "subscription", name = "sub-example-prod" }') | Should Be $true
            $azureValues.Contains('expiration         = { permanent = true }') | Should Be $true
        }

        It 'skips user principals and inherited instances with a comment' {
            $azureImports.Contains('# Skipped: User principal Some Person') | Should Be $true
            $azureImports.Contains('Inherited Group') | Should Be $false
            $summary.AzureImports | Should Be 2
            $summary.AzureSkipped | Should Be 1
            $summary.AzureNewEntries | Should Be 1
        }

        It 'emits an Entra import by the resolved schedule request id, reusing the cell key' {
            $entraImports.Contains('to = module.eligibility.azuread_directory_role_eligibility_schedule_request.this["global-admin"]') | Should Be $true
            $entraImports.Contains('id = "req-ga"') | Should Be $true
        }

        It 'comments out the block when no request can be resolved, with a generated key' {
            $entraImports.Contains('# No provisioning request found for schedule sched-hd') | Should Be $true
            $entraImports.Contains('#   to = module.eligibility.azuread_directory_role_eligibility_schedule_request.this["helpdesk-administrator"]') | Should Be $true
            $entraValues.Contains('"helpdesk-administrator" = {') | Should Be $true
            $entraValues.Contains('group_display_name = "PIM Helpdesk Administrators"') | Should Be $true
            $summary.EntraImports | Should Be 1
            $summary.EntraUnresolved | Should Be 1
            $summary.EntraSkipped | Should Be 1
        }

        It 'never writes a Graph or ARM token into an output file' {
            $azureImports.Contains('arm-token') | Should Be $false
            $entraImports.Contains('graph-token') | Should Be $false
        }
    }

    Context 'guards' {
        It 'refuses to read Azure with no scope named' {
            { Invoke-PimEligibilityExport -SkipEntra $true -OutputDirectory $TestDrive -ArmAccessToken 'arm-token' } | Should Throw
        }

        It 'selects the US Government endpoints' {
            $e = Get-CloudEndpoints -Environment 'USGov'
            $e.Arm | Should Be 'https://management.usgovcloudapi.net'
            $e.Graph | Should Be 'https://graph.microsoft.us'
        }
    }
}
