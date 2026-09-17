<#
    The PIM baselines and the corp automation cell, checked against each other
    and against the runbooks that read them. Offline: nothing here makes a
    request, and the only code it runs is the runbooks' own parsers.

    Why this file exists. The baselines used to be JSON inside a job schedule
    parameter, where nothing checked that they parsed, that they matched the
    PIM cells, or that a list survived the Automation service's handling of
    JSON-looking values. They are now files under policies/, published as
    Automation string variables by stacks/azure-automation, so they can be
    parsed here with the same functions the runbooks use, and the cell can be
    held to the transport rules in automation/README.md.

    Each runbook is dot-sourced inside its own script block, so the two sets
    of functions never overwrite each other and neither leaks into the rest of
    the suite.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$runbooks = Join-Path -Path $repoRoot -ChildPath 'automation\runbooks'
$azureBaselinePath = Join-Path -Path $repoRoot -ChildPath 'policies\azure\pim-governance\corp-baseline.json'
$entraBaselinePath = Join-Path -Path $repoRoot -ChildPath 'policies\entra\pim-governance\corp-baseline.json'
$automationCellPath = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-automation\terragrunt.hcl'
$azurePimCellPath = Join-Path -Path $repoRoot -ChildPath 'tenants\azure\corp\azure-pim-governance\terragrunt.hcl'

function Get-BaselineTestBlock {
    <# The text of an HCL block, from the line that opens it to its matching
       closing brace. #>
    param([string]$Text, [string]$OpeningPattern)
    $match = [regex]::Match($Text, $OpeningPattern)
    if (-not $match.Success) { return '' }
    $depth = 0
    for ($i = $match.Index; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') { $depth++ }
        elseif ($Text[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($match.Index, $i - $match.Index + 1) }
        }
    }
    return ''
}

Describe 'PIM baselines as files and Automation variables' {

    Context 'the Azure baseline is what Invoke-AzurePimPolicyGovernance accepts' {
        It 'parses with the runbook parser, in minimum mode, with its approver group' {
            $result = & {
                . (Join-Path -Path $runbooks -ChildPath 'Invoke-AzurePimPolicyGovernance.ps1') -ScopeNames 'sub:Not Used' -AccessToken 'baseline-test-token-0000'
                $baseline = ConvertFrom-PimBaselineJson -Json ([System.IO.File]::ReadAllText($azureBaselinePath)) -DefaultApproverGroupName 'PIM Approvers'
                Assert-PimBaselineApprovers -Baseline $baseline
                [PSCustomObject]@{
                    Mode       = $baseline.Mode
                    PairCount  = @($baseline.PairEntries).Count
                    PairLabels = @($baseline.PairEntries | ForEach-Object { $_.Label })
                    PairRoles  = @($baseline.PairEntries | ForEach-Object { $_.RoleName })
                    Duration   = [string]$baseline.Defaults['activation_maximum_duration']
                    Approval   = [bool]$baseline.Defaults['require_approval']
                    Mfa        = [bool]$baseline.Defaults['require_multifactor_authentication']
                }
            }
            $result.Mode | Should Be 'minimum'
            $result.PairCount | Should Be 6
            $result.Duration | Should Be 'PT4H'
            $result.Mfa | Should Be $true
            $result.Approval | Should Be $false
        }
    }

    Context 'the Entra baseline is what Invoke-EntraPimPolicyDrift accepts' {
        It 'parses with the runbook parser, in minimum mode, with no context substitution' {
            $result = & {
                . (Join-Path -Path $runbooks -ChildPath 'Invoke-EntraPimPolicyDrift.ps1') -AccessToken 'baseline-test-token-0000' -BaselineVariableName ''
                $baseline = ConvertTo-PimBaseline -Json ([System.IO.File]::ReadAllText($entraBaselinePath)) -ApproverGroupName '' -Source 'Automation variable "PimPolicy_EntraBaseline"'
                [PSCustomObject]@{
                    Mode       = $baseline.Mode
                    Source     = $baseline.Source
                    GroupNames = @($baseline.Groups.Values | ForEach-Object { $_.Name })
                    RoleCount  = $baseline.Roles.Count
                    ContextMfa = $baseline.Defaults.AuthenticationContextSatisfiesMfa
                }
            }
            $result.Mode | Should Be 'minimum'
            $result.RoleCount | Should Be 0
            $result.ContextMfa | Should Be $false
            $result.Source | Should Match 'PimPolicy_EntraBaseline'
            ($result.GroupNames -join ';') | Should Be 'PIM Global Administrators'
        }
    }

    Context 'the corp automation cell publishes the baselines and passes their names' {
        $cell = ''
        if (Test-Path -LiteralPath $automationCellPath) { $cell = [System.IO.File]::ReadAllText($automationCellPath).Replace("`r`n", "`n") }

        It 'publishes both baseline files as the variables the runbooks read' -Skip:([string]::IsNullOrEmpty($cell)) {
            $cell | Should Match 'PimPolicy_AzureBaseline\s*=\s*"policies/azure/pim-governance/corp-baseline\.json"'
            $cell | Should Match 'PimPolicy_EntraBaseline\s*=\s*"policies/entra/pim-governance/corp-baseline\.json"'
            (Test-Path -LiteralPath $azureBaselinePath) | Should Be $true
            (Test-Path -LiteralPath $entraBaselinePath) | Should Be $true
        }

        It 'passes the variable name to each PIM runbook and no baseline JSON at all' -Skip:([string]::IsNullOrEmpty($cell)) {
            $azureEntry = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*azure-pim-policy-governance\s*=\s*\{'
            $entraEntry = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*entra-pim-policy-drift\s*=\s*\{'
            $azureEntry | Should Match 'baselinevariablename\s*=\s*"PimPolicy_AzureBaseline"'
            $entraEntry | Should Match 'baselinevariablename\s*=\s*"PimPolicy_EntraBaseline"'
            $cell.Contains('baselinejson') | Should Be $false
        }

        It 'writes every list parameter as a semicolon join, never jsonencode' -Skip:([string]::IsNullOrEmpty($cell)) {
            # Comments may name jsonencode (they say not to use it); no value may.
            $code = @($cell.Split("`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            $code.Contains('jsonencode') | Should Be $false
            $runbooksBlock = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*runbooks\s*=\s*\{'
            $runbooksBlock | Should Not BeNullOrEmpty
            # Every parameter value is a quoted string or a join(";", [...]).
            $values = @([regex]::Matches($runbooksBlock, '(?m)^\s{8}[a-z]+\s*=\s*(?<value>.+)$') | ForEach-Object { $_.Groups['value'].Value.Trim() })
            $values.Count | Should BeGreaterThan 20
            $bad = @($values | Where-Object { $_ -notmatch '^"' -and $_ -notmatch '^join\(";",' })
            ($bad -join ' | ') | Should Be ''
        }

        It 'gives every runbook an identity tier that the cell declares' -Skip:([string]::IsNullOrEmpty($cell)) {
            $identities = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*identities\s*=\s*\{'
            $identities | Should Not BeNullOrEmpty
            $tiers = @([regex]::Matches($identities, '(?m)^\s{4}(?<tier>[a-z][a-z0-9-]*)\s*=\s*\{') | ForEach-Object { $_.Groups['tier'].Value })
            $tiers.Count | Should Be 4
            ($tiers -contains 'observer') | Should Be $true
            ($tiers -contains 'subscription-guard') | Should Be $true

            $runbooksBlock = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*runbooks\s*=\s*\{'
            $entries = @([regex]::Matches($runbooksBlock, '(?m)^\s{4}(?<key>[a-z][a-z0-9-]*)\s*=\s*\{') | ForEach-Object { $_.Groups['key'].Value })
            $used = @([regex]::Matches($runbooksBlock, 'identity_key\s*=\s*"(?<tier>[^"]+)"') | ForEach-Object { $_.Groups['tier'].Value })
            $entries.Count | Should Be 9
            $used.Count | Should Be 9
            (@($used | Where-Object { $tiers -notcontains $_ }) -join ', ') | Should Be ''
            # Every declared tier is used by at least one runbook.
            (@($tiers | Where-Object { $used -notcontains $_ }) -join ', ') | Should Be ''
        }

        It 'keeps both safety switches of the subscription guard off' -Skip:([string]::IsNullOrEmpty($cell)) {
            $guard = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*subscription-guard\s*=\s*\{\s*\n\s*name\s*=\s*"Disable-UnauthorizedSubscriptions"'
            $guard | Should Not BeNullOrEmpty
            $guard | Should Match 'allowcancel\s*=\s*"false"'
            $cell | Should Match '(?m)^\s*dry_run\s*=\s*true\s*$'
        }

        It 'keeps the Azure plane of the eligibility renewal opt-in' -Skip:([string]::IsNullOrEmpty($cell)) {
            $renewal = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*pim-eligibility-renewal\s*=\s*\{'
            $renewal | Should Match 'includeazureresources\s*=\s*"false"'
        }
    }

    Context 'the Azure baseline mirrors tenants/azure/corp/azure-pim-governance' {
        $governance = ''
        if (Test-Path -LiteralPath $azurePimCellPath) { $governance = [System.IO.File]::ReadAllText($azurePimCellPath).Replace("`r`n", "`n") }

        It 'holds one pair per declared policy, with the same role name' -Skip:([string]::IsNullOrEmpty($governance)) {
            $policies = Get-BaselineTestBlock -Text $governance -OpeningPattern '(?m)^\s*policies\s*=\s*\{'
            $policies | Should Not BeNullOrEmpty
            $declared = @{}
            foreach ($entry in [regex]::Matches($policies, '(?m)^\s{4}(?<key>[a-z][a-z0-9-]*)\s*=\s*\{')) {
                $key = $entry.Groups['key'].Value
                $block = Get-BaselineTestBlock -Text $policies -OpeningPattern ('(?m)^\s{4}' + [regex]::Escape($key) + '\s*=\s*\{')
                $declared[$key] = [regex]::Match($block, 'role_name\s*=\s*"(?<role>[^"]+)"').Groups['role'].Value
            }
            $declared.Count | Should BeGreaterThan 3

            $baseline = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($azureBaselinePath))
            $mirrored = @{}
            foreach ($property in $baseline.pairs.PSObject.Properties) { $mirrored[$property.Name] = $property.Value.role_name }

            (@($declared.Keys | Where-Object { -not $mirrored.ContainsKey($_) }) -join ', ') | Should Be ''
            (@($mirrored.Keys | Where-Object { -not $declared.ContainsKey($_) }) -join ', ') | Should Be ''
            (@($declared.Keys | Where-Object { $mirrored[$_] -ne $declared[$_] }) -join ', ') | Should Be ''
        }
    }

    Context 'the tests that guard these files actually run in CI' {
        $workflowPath = Join-Path -Path $repoRoot -ChildPath '.github\workflows\automation-tests.yml'
        $workflow = ''
        if (Test-Path -LiteralPath $workflowPath) { $workflow = [System.IO.File]::ReadAllText($workflowPath).Replace("`r`n", "`n") }

        It 'triggers automation-tests on every tree this file asserts against' -Skip:([string]::IsNullOrEmpty($workflow)) {
            # This suite reads policies/ and tenants/ as well as automation/, so
            # a pull request that only edits a baseline or a cell has to run it.
            $triggers = @([regex]::Matches($workflow, '(?m)^ {2}(?<event>pull_request|push):\n(?<body>(?: {4,}[^\n]*\n)+)'))
            $triggers.Count | Should Be 2
            foreach ($trigger in $triggers) {
                $paths = @([regex]::Matches($trigger.Groups['body'].Value, '(?m)^\s*-\s*"(?<path>[^"]+)"') | ForEach-Object { $_.Groups['path'].Value })
                foreach ($needed in @('automation/**', 'scripts/**', 'policies/**', 'tenants/**')) {
                    ($paths -contains $needed) | Should Be $true
                }
            }
        }
    }

    Context 'the account-wide reach of the observer tier variable write is written down' {
        $cell = ''
        if (Test-Path -LiteralPath $automationCellPath) { $cell = [System.IO.File]::ReadAllText($automationCellPath).Replace("`r`n", "`n") }

        It 'says in the cell, the README, and ADR 0016 that the role reaches every variable' -Skip:([string]::IsNullOrEmpty($cell)) {
            # Azure RBAC has no per-variable scope, so the observer tier can
            # write the two PIM baselines this file checks. Every document that
            # describes that grant has to say so.
            $cell | Should Match 'EVERY variable in this account'
            $cell | Should Match 'PimPolicy_AzureBaseline, PimPolicy_EntraBaseline'
            $watcherRole = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*watcher-state-on-account\s*=\s*\{'
            $watcherRole | Should Match 'write on every variable in this account'

            $readme = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'automation\README.md'))
            $readme | Should Match 'Azure RBAC has no per-variable scope'
            $readme | Should Match 'replace a tier 0 input'

            $adr = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath 'docs\adr\0016-one-identity-per-privilege-tier-in-one-automation-account.md'))
            $adr | Should Match 'no per-variable scope'
            $adr | Should Match 'JobWatch_'
        }
    }

    Context 'the Entra baseline agrees with the groups the runbook is told to check' {
        $cell = ''
        if (Test-Path -LiteralPath $automationCellPath) { $cell = [System.IO.File]::ReadAllText($automationCellPath).Replace("`r`n", "`n") }

        It 'overrides only groups the cell lists in includegroupnames' -Skip:([string]::IsNullOrEmpty($cell)) {
            $entraEntry = Get-BaselineTestBlock -Text $cell -OpeningPattern '(?m)^\s*entra-pim-policy-drift\s*=\s*\{'
            $included = [regex]::Match($entraEntry, 'includegroupnames\s*=\s*join\(";",\s*\[(?<list>[^\]]*)\]')
            $included.Success | Should Be $true
            $names = @([regex]::Matches($included.Groups['list'].Value, '"(?<name>[^"]+)"') | ForEach-Object { $_.Groups['name'].Value })
            $names.Count | Should Be 3

            $baseline = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($entraBaselinePath))
            $overridden = @($baseline.groups.PSObject.Properties | ForEach-Object { $_.Name })
            (@($overridden | Where-Object { $names -notcontains $_ }) -join ', ') | Should Be ''
        }
    }
}
