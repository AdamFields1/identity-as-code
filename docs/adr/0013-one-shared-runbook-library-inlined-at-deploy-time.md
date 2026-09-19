# ADR 0013: Runbook plumbing lives in one shared library, inlined at deploy time

Status: accepted
Date: 2026-09-17

## Context

ADR 0010 made every runbook a self-contained file: the logging, identity, and
transport helpers were repeated in each, because Azure Automation runs one
file and a shared module asset is a second thing to build and version. With
the first three runbooks that was three copies of about 250 lines, and the
trade was cheap.

Six runbooks arrived together: a runbook backup, a PIM eligibility renewal, a
subscription guard, an Azure PIM policy sweep, an Entra PIM policy drift
check, and a job watcher. Their plumbing is not 250 lines. Between them they
need tokens for Microsoft Graph, Azure Resource Manager, and Azure Storage in
one run, from the Automation identity endpoint, from Az.Accounts, or from a
caller on a workstation; endpoints for all three services in the global and
US Government clouds; paging through both Graph's `@odata.nextLink` and ARM's
`nextLink`; blob requests with the storage version header; scope resolution
for management groups (by ID, then display name), subscriptions, and
management group descendants; group, user, and transitive member lookups;
mail; a circuit breaker; a run summary; and a scrubber that keeps anything
shaped like a token out of every log line and error. That is about 2,200
lines with its own tests. Six copies would be about 13,000 lines of identical
plumbing in which a retry bug or a scrubbing gap has to be found and fixed six
times, and the copies drift the first time one is fixed and another is not.

The options were:

1. **Keep copying**, per ADR 0010. Rejected for the reason above.
2. **A PowerShell module asset.** `azurerm_automation_module` takes a
   packaged module (`.zip` or `.nupkg`) from an https URL. That is a build
   step, a place to host the package that the Automation service can reach,
   a version to bump, and a second artifact to adopt in every account; the
   published runbook would no longer be the whole program, and a reviewer
   reading a runbook diff would not see the code it calls. The newer runtime
   environments for PowerShell 7.x have the same packaging model.
3. **Child runbooks** (`Start-AutomationRunbook`). Those are jobs, not
   functions: no shared state, no return values worth the name, and a job
   per helper call.
4. **Inline a library at deploy time**, with the mechanism ADR 0012 added for
   the authentication methods diff: the runbook carries two marker lines
   with a dot-source between them, and `modules/azure/automation-runbooks`
   replaces the block with the library's text at plan time.

## Decision

**The plumbing lives once, in `automation/lib/Runbook.Common.ps1`, and every
new runbook names it as its `library`.** Each runbook carries

```
# INLINE_LIBRARY_BEGIN
. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Runbook.Common.ps1')
# INLINE_LIBRARY_END
```

after its param block. On a workstation and in the tests the line in the
middle loads the library from disk. At plan time the runbooks module splits
the runbook on the two markers and joins the library text in their place, so
the published runbook is one file, its `content_sha256` tag covers the
library, and the text that was tested is the text that runs.

**The library has a file contract, enforced by its tests.** Because it
becomes the middle of another script it has no param block, no `#Requires`
line, and no use of `$PSScriptRoot` or `$MyInvocation`. It is ASCII with no
byte order mark, because `file()` would carry a BOM into the middle of the
published runbook. It never contains either marker string. Every function has
comment-based help. Every function that returns a list writes its items to
the pipeline, so a caller wraps the call in `@()`. One function,
`Invoke-HttpCore`, calls `Invoke-WebRequest`, and it handles the error shapes
of both Windows PowerShell 5.1 and PowerShell 7, so the tests mock that one
function.

**The host runbook has a contract too.** It declares `[bool]$DryRun = $true`,
`$Environment`, `$ClientId`, `$AccessToken`, and `$RunId`; sets
`$ErrorActionPreference = 'Stop'` and `$VerbosePreference = 'Continue'`
before the marker block; defines no function with a name the library uses;
calls `Initialize-RunContext` first and `New-RunSummary` next; calls
`Test-CircuitBreaker` before any write and routes writes through
`Invoke-RunbookAction`; ends with `Complete-RunSummary`; and gates its entry
point on `$MyInvocation.InvocationName -ne '.'` so the tests can dot-source
it. Schedule-bound parameters are `[bool]`, `[int]`, or `[string]`; a list is
one string holding a semicolon list, parsed with `ConvertTo-StringList`, and
structured configuration (a PIM baseline) is read from an Automation string
variable with `Get-AutomationStringVariable`, never from JSON text in a
parameter. The Automation service may parse a JSON-looking parameter value
before it binds it, so JSON in a schedule can reach a `[string]` parameter as
`@{...}` or as a space-joined array; the runbooks refuse those shapes rather
than guess. A JSON array is still accepted from a local run, where the text
arrives unchanged.

**The assembly is tested the way Terraform performs it.** The last context of
`automation/tests/Runbook.Common.Tests.ps1` checks the library's file
contract, checks that `modules/azure/automation-runbooks/main.tf` still splits
on the same marker strings, writes a sample runbook with the marker block,
runs it from disk, assembles it exactly as `main.tf` does, and runs the
assembled file too, against the US Government cloud, expecting one summary
object from each.

**A runbook names at most one library.** The authentication methods drift
runbook keeps `AuthenticationMethods.Common.ps1`, the domain logic it shares
with `scripts/Set-AuthenticationMethods.ps1`, and its own plumbing.

**Why inlining beats the module asset here.** The deployable is still one
file per runbook, so ADR 0010's reason for self-contained runbooks holds for
what is published. A change to the library is a plan diff on every runbook
that names it, which is the blast radius a reviewer needs to see. There is no
package to build or host, no version to keep in step across accounts, and a
workstation run needs nothing but the repository.

## Consequences

- A library change republishes six runbooks in one plan. That is intended:
  the release summary reads as six runbook changes because six runbooks
  changed.
- Published runbooks are larger. The library is about 130 KB, so the largest
  assembled runbook is about 280 KB. The Azure Automation limits page lists no
  runbook size limit (it caps job parameters at 512 KB and a job stream at
  1 MiB); the first apply confirms the upload. Nothing about a job's streams
  changes.
- The first three runbooks still carry their own copies. Moving them onto the
  library is a separate change with its own tests; until then ADR 0010's
  wording is refined rather than replaced: what is published is
  self-contained, what is written is not.
- The gaps the backup runbook found in the first version of the library are
  now closed in it (version 1.1.0), which is the point of one copy:
  `Invoke-StorageRequest` streams a blob to a file (`GetBlobToFile`), so no
  runbook keeps a second `Invoke-WebRequest` call site; `Invoke-RunbookHttp`
  no longer repeats a POST or a PATCH after a server error or a lost response
  unless the call passes `-RetryNonIdempotent`, so a digest or a PIM request
  is not sent twice by the transport; `Resolve-ArmScope` refuses a
  subscription entry whose id is not a GUID; blob names and the built URI are
  checked before any token is fetched; `Get-AutomationStringVariable` reads
  structured configuration from an Automation variable; and
  `Test-RunbookJsonObject` replaces `-is [PSCustomObject]`, which is true for
  a JSON array on Windows PowerShell 5.1. `Resolve-GroupIdByName` still does
  not require `securityEnabled`, where the Terraform data sources do. Several
  runbooks carry small generic helpers (null-safe property reads, UTC
  conversion) that are candidates to move into the library.
- The backup runbook calls functions the library marks as internal. The
  library has no enforced public surface; its help says which functions are
  meant for hosts.
- Every test runs offline. Locally that is Windows PowerShell 5.1 with the
  Pester 3.4.0 it ships; `.github/workflows/automation-tests.yml` runs the
  same suite on `windows-latest` three ways, `powershell` (5.1) with that
  shipped 3.4.0, `powershell` with Pester 4.10.1, and `pwsh` (7) with Pester
  4.10.1, so the PowerShell 7 paths and both Pester lines are covered by a
  test run on every pull request that touches `automation/` or `scripts/`.
