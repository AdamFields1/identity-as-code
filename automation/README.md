# automation

Runbooks that keep the identity estate tidy between Terraform applies: things
that Terraform should not own because they are decisions made against live data
every day (which credentials have expired, which guests have gone quiet), or
cannot own because no resource exists (the authentication methods policy), but
that still deserve code, review, tests, and a deployment pipeline. The runbooks
are deployed as code by `stacks/azure-automation`; the rules below are what every
runbook in this directory follows, and what a reviewer checks a new one against.

```
automation/
  runbooks/
    Invoke-AppCredentialHygiene.ps1        expiring and expired app credentials: digest owners, remove after a grace period
    Invoke-GuestLifecycle.ps1              dormant guests: warn, disable, purge, with the stage held in group membership
    Invoke-AuthenticationMethodsDrift.ps1  authentication methods policy versus policies/entra/authentication-methods: digest, enforce when allowed
  lib/
    AuthenticationMethods.Common.ps1       diff, plan, apply, export; dot-sourced by the script, inlined into the runbook at deploy time
  tests/
    *.Tests.ps1                            Pester tests, offline, Graph mocked
    Invoke-Tests.ps1                       parse gate plus Pester runner
```

The related export helper, `scripts/Export-PimEligibilityImports.ps1`, lives with
the other adoption scripts because it is run from a workstation, not from
Automation. `scripts/Set-AuthenticationMethods.ps1` is the workstation and
pipeline face of the drift runbook: same library, same comparison, plus
`-FailOnDrift` for a pull request check and `-Export` for adopting a tenant.

## Design rules

**Managed identity only.** A runbook authenticates as the Automation account's
user-assigned managed identity, and nothing else. In the sandbox it reads
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` and asks for a token for the Graph
resource with the identity's `client_id`; if `Az.Accounts` happens to be loaded it
uses `Connect-AzAccount -Identity`; on a workstation the caller passes
`-AccessToken` obtained from their own session. There is no credential asset, no
certificate, no client secret, and no code path that could read one. The token
value is held in a script variable and never written to any stream. See
[ADR 0010](../docs/adr/0010-automation-runs-on-managed-identity-with-dry-run-defaults.md).

**DryRun is the default.** Every runbook declares `[bool]$DryRun = $true`. It is a boolean rather than a switch because Azure Automation passes schedule parameters as JSON strings, and a string binds to a boolean but not to a switch. A
dry run reads everything, computes everything, logs every action it would take
with the word "Would", and writes nothing. Acting requires `-DryRun:$false` in
the job schedule parameters, which is a reviewed Terraform value in the tenant
cell (`dry_run = false`), never a portal edit. The shipped cell runs both
runbooks dry.

**Every destructive action has a cap, and the two kinds of cap are different on
purpose.** Credential removal is capped by `-MaxRemovalsPerRun` (default 25) and
truncates: the oldest expiries are removed, the rest are logged and left for
tomorrow, because each removal is independent and already announced to its
owner. Guest disable and purge are capped by `-MaxDisablePerRun` (25) and
`-MaxPurgePerRun` (10) and abort: if the planned count exceeds the cap the run
stops with an error before writing anything, because a number that large is a
symptom (a clock problem, a bulk import, a broken filter) and a partial run
would hide it. Both caps are job schedule parameters.

**Lifecycle stage lives in group membership.** The guest ladder records where a
guest is by putting it in `LC Guests Warned` or `LC Guests Disabled`, and takes it
off the ladder when it is in `LC Guests Exempt`. Every transition is therefore a
group membership write in the Entra audit log, listable by anyone with Global
Reader, reviewable through access reviews, and reversible by a helpdesk agent
without touching code. The three groups are resolved by display name at run
time and are created outside this repository (they are ordinary security
groups). See [ADR 0011](../docs/adr/0011-lifecycle-stage-tracked-in-groups.md).

**Graph writes go through one function.** `Invoke-GraphRequest` is the only place
a request is built, and `Invoke-RestCall` is the only place `Invoke-WebRequest` is
called. Tests mock those two and nothing else. Retries on 429 and 5xx honour
`Retry-After` and otherwise back off exponentially (2, 4, 8 ... 60 seconds) for
up to five attempts; a 4xx other than 429 fails immediately with the Graph error
body, truncated and never including a header.

**National cloud is a switch.** `-Environment Global|USGov` selects the Graph base
URL (`graph.microsoft.com` or `graph.microsoft.us`) and the ARM base URL where a
script needs one, and the same value is the token resource. Nothing else in a
runbook knows which cloud it is in.

**Runbooks are self-contained files.** Azure Automation runs one file, so the
logging, identity, and transport helpers are repeated in each runbook rather than
imported from a module. That is a deliberate trade: a runbook can be read top to
bottom and deployed with `content = file(...)`, and there is no module asset to
version separately. The one exception is logic that a runbook must share
byte-for-byte with a workstation script: it lives under `automation/lib`, the
script dot-sources it, and the runbook carries a `# INLINE_LIBRARY_BEGIN` /
`# INLINE_LIBRARY_END` block that `stacks/azure-automation` fills with the
file at deploy time, so what is published is still one file. See
`modules/azure/automation-runbooks/README.md` for why that beats a module
asset, and [ADR 0012](../docs/adr/0012-authentication-methods-policy-as-desired-state.md).

**Desired state comes through the account, never from a portal-editable place.**
The drift runbook reads its desired state from Automation variables that the
stack publishes from `policies/entra/authentication-methods` with `file()`
(`AuthMethods_Policy`, `AuthMethods_Fido2`, and so on). A file edit is a plan
diff on a variable; the runbook compares the tenant with what the repository
says, and the two guards it applies (never disable the last enabled method,
never send `policyMigrationState` without `-AllowMigrationStateChange $true`)
are the same guards the script applies in the pipeline.

**Windows PowerShell 5.1 and PowerShell 7.** The runbooks are deployed as
`PowerShell72` but must also run under 5.1 on a workstation, so there is no
ternary, no `??`, no `?.`, and every `Invoke-WebRequest` error path handles both
`WebException` and `HttpResponseException`.

## Logging contract

Every runbook has a `Write-RunLog -Level Info|Action|Warn|Error -Message` helper.
Each line is

```
2026-09-16T06:00:12Z [ACTION] run=8f1c... Would remove secret ci on "Payroll API" (keyId ..., expired 2026-08-01).
```

`Info` and `Action` go to the verbose stream, which Azure Automation keeps with
the job because the runbook is deployed with `log_verbose = true`. `Warn` and
`Error` go to their own streams so a job filter finds them. An `Action` line
starting with "Would" is a dry run; the same line without it is a write that
happened. The last thing a runbook emits on the output stream is one summary
object (counts, `RunId`, `DryRun`, warnings, errors, `CompletedUtc`). The
Automation account's diagnostic settings forward job streams to the SIEM, the
`RunId` correlates the summary with the Entra audit log entries the identity
wrote, and that is the record a ticket points at.

## Graph permissions

| Runbook | Application permissions | Why |
|---------|-------------------------|-----|
| `Invoke-AppCredentialHygiene` | `Application.ReadWrite.All`, `Directory.Read.All`, `Mail.Send` | read registrations and credentials, remove them, read owners, send digests |
| `Invoke-GuestLifecycle` | `User.ReadWrite.All`, `Group.ReadWrite.All`, `AuditLog.Read.All`, `Mail.Send` | read guests with `signInActivity`, disable and delete, write stage groups, read sponsors, send warnings |
| `Invoke-AuthenticationMethodsDrift` | `Policy.ReadWrite.AuthenticationMethod` (`Policy.Read.AuthenticationMethod` is enough for a dry run), `Group.Read.All` (covered by `Group.ReadWrite.All`), `Mail.Send` | read and patch the authentication methods policy, resolve group names, send the drift digest |

`modules/entra/graph-app-role-grant` grants these to the managed identity's
service principal as code. `Mail.Send` as an application permission lets the
identity send as any mailbox; pair it with an Exchange Online application access
policy that restricts the identity to the sender mailbox
(`New-ApplicationAccessPolicy -AppId <identity client id> -PolicyScopeGroupId <mail-enabled security group holding the shared mailbox> -AccessRight RestrictAccess`).
That policy is an Exchange object with no Terraform resource and is applied
once, outside this repository. `signInActivity` also needs a Microsoft Entra ID
P1 or P2 licence in the tenant.

## Testing locally

```powershell
cd automation\tests
.\Invoke-Tests.ps1
```

The runner parses every `.ps1` under `automation/` and `scripts/` first, then
runs Pester with whichever version is installed (3.4.0 on a stock Windows
PowerShell 5.1; the tests use the `Should Be` syntax that 3.x and 4.x share).
Nothing in the tests reaches a tenant: `Invoke-GraphGetAll`, `Invoke-GraphRequest`,
`Invoke-ArmGetAll`, and `Invoke-RestCall` are mocked with the JSON shapes the
APIs document, and the clock is a parameter.

To run a runbook against a real tenant from a workstation, dry:

```powershell
$token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
.\runbooks\Invoke-AppCredentialHygiene.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $token -ReportPath .\out\credentials.csv
.\runbooks\Invoke-GuestLifecycle.ps1 -SenderMailbox iam-noreply@corp.example.com -AccessToken $token -ReportPath .\out\guests.csv
.\runbooks\Invoke-AuthenticationMethodsDrift.ps1 -SenderMailbox iam-noreply@corp.example.com -Recipients iam@corp.example.com -DesiredStatePath ..\policies\entra\authentication-methods -AccessToken $token
```

The drift runbook takes `-DesiredStatePath` on a workstation because
`Get-AutomationVariable` exists only inside the sandbox; in Automation it
reads the variables and the parameter is left empty.

Your own account needs the delegated equivalents of the permissions above for a
dry run to read everything. Do not pass `-DryRun:$false` from a workstation; the
live path is the Automation job, on the managed identity, with the parameters
the tenant cell declares.

## Adding a runbook

1. Copy the header, logging, identity, and transport sections from an existing
   runbook verbatim.
2. Put every write behind `if ($DryRun) { Write-RunLog -Level Action -Message 'Would ...'; continue }`.
3. Give every destructive action a cap parameter and decide, in the header,
   whether it truncates or aborts, and why.
4. Keep the decision logic in pure functions that take the clock and the
   inputs as parameters, and test the boundaries.
5. Add the file to the `runbooks` map in the tenant cell with a schedule and
   `DryRun` on.
6. If the runbook must share logic with a workstation script, put the shared
   functions in `automation/lib/<Name>.ps1` with no transport or logging of
   their own, add the two `INLINE_LIBRARY` marker lines with a dot-source
   between them, and name the file as `library` in the cell.
