# policies/entra/pim-governance

The baseline `Invoke-EntraPimPolicyDrift` compares every Entra directory role,
and the named PIM for Groups groups, against: one JSON file per tenant.
`stacks/azure-automation` publishes it as the Automation string variable named
in `desired_state_files` (`PimPolicy_EntraBaseline` for corp), and the job
schedule passes only that variable's name in `baselinevariablename`.

## Why a file and a variable, not a job parameter

The same reason as `policies/azure/pim-governance`: a job schedule carries
only `[bool]`, `[int]`, and `[string]` values reliably, and the Automation
service may parse a JSON-looking parameter value before it binds it. A string
variable is returned exactly as stored. A missing or empty variable stops the
run instead of falling back to the built-in baseline, because a silent
fallback would drop every override and patch a role the baseline meant to
exclude. Store `{}` to mean "the built-in baseline".

## What it must contain

`mode` (`minimum` or `exact`), `defaults`
(`maximumActivationDuration`, `activationRequirements`, `requireApproval`,
`approverGroupName`, `authenticationContextSatisfiesMfa`), and overrides under
`roles` (by directory role display name) and `groups` (by PIM group display
name). An override may also set `"exclude": true`. An unknown key is an error,
so a typo cannot quietly leave a role on the defaults.

`corp-baseline.json` mirrors `tenants/azure/corp/entra-pim-governance`: the
defaults are `modules/entra/pim-role-policy`'s, and `PIM Global Administrators`
carries the approval that cell declares. A group listed here must also be in
the runbook's `includegroupnames`, and a pull request that changes the PIM
cell changes this file in the same pull request
([ADR 0015](../../../docs/adr/0015-runtime-pim-governance-alongside-declarative-stacks.md)).

`authenticationContextSatisfiesMfa` is `false` here: an enabled Conditional
Access authentication context does not stand in for MFA, because the
requirements behind that context live in a policy this runbook does not read.
Set it to `true` for a role only as a reviewed decision.

## Checking a change

```powershell
. .\automation\runbooks\Invoke-EntraPimPolicyDrift.ps1 -AccessToken 'local' -BaselineVariableName ''
$baseline = ConvertTo-PimBaseline -Json (Get-Content -Raw .\policies\entra\pim-governance\corp-baseline.json) -ApproverGroupName '' -Source 'file'
$baseline.Mode
$baseline.Groups.Keys
```
