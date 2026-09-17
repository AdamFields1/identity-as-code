# policies/azure/pim-governance

The baseline `Invoke-AzurePimPolicyGovernance` holds every eligible Azure
(scope, role) pair to, one JSON file per tenant. The file is not read by the
runbook from disk: `stacks/azure-automation` publishes it as the Automation
string variable named in `desired_state_files`
(`PimPolicy_AzureBaseline` for corp), and the job schedule passes only that
variable's name in `baselinevariablename`.

## Why a file and a variable, not a job parameter

A job schedule binds only `[bool]`, `[int]`, and `[string]` values reliably,
and the Automation service may parse a JSON-looking parameter value before it
binds it, so JSON in a schedule parameter can reach the runbook as `@{...}` or
as a space-joined array. A string variable comes back exactly as it was
stored. The runbook refuses a converted-looking value from either source
rather than guessing ([ADR 0015](../../../docs/adr/0015-runtime-pim-governance-alongside-declarative-stacks.md)
and `automation/lib/Runbook.Common.ps1`, `Get-AutomationStringVariable`).

## What it must contain

The document is described in the runbook's `.PARAMETER BaselineJson` help:
`mode` (`minimum`, the floor, or `exact`), `defaults`, `roles` keyed by role
display name, `pairs` in the shape of the `policies` map of
`stacks/azure-pim-governance`, and `pairs_report_only`.

`corp-baseline.json` mirrors `tenants/azure/corp/azure-pim-governance`: its
`defaults` are that cell's tenant-level values and its `pairs` are that cell's
`policies` entries, entry for entry. A pull request that changes a policy
there changes this file in the same pull request, or the nightly sweep and the
next apply disagree about that pair. Both writers run in `minimum` mode, so
the disagreement is loud (a digest and a plan diff), never silent.

A `management_group` scope is matched by display name, as
`modules/azure/pim-role-policy` matches it; a name that is only a group id
stops the run.

## Checking a change

Parse it before merging, the same way the runbook does:

```powershell
. .\automation\runbooks\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'sub:Not Used' -AccessToken 'local'
$baseline = ConvertFrom-PimBaselineJson -Json (Get-Content -Raw .\policies\azure\pim-governance\corp-baseline.json) -DefaultApproverGroupName 'PIM Approvers'
Assert-PimBaselineApprovers -Baseline $baseline
$baseline.Source
```

A dry run against the tenant is
`.\automation\runbooks\Invoke-AzurePimPolicyGovernance.ps1 -ScopeNames 'mg:mg-example-root' -BaselineJson (Get-Content -Raw .\policies\azure\pim-governance\corp-baseline.json) -AccessToken $tokens`.
