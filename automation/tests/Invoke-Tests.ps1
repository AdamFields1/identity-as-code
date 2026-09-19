<#
.SYNOPSIS
    Parses every PowerShell file in automation/ and scripts/ with the language
    parser, then runs the Pester tests in this directory under Pester 3.4 or 4.

.DESCRIPTION
    Two gates, in order:

      1. Every .ps1 under automation/ and scripts/ must parse cleanly with
         System.Management.Automation.Language.Parser. A parse error fails the
         run before any test executes.
      2. The *.Tests.ps1 files in this directory run under Pester. The tests
         are written in the assertion syntax Pester 3 and 4 share ("Should Be",
         not "Should -Be"), because Windows PowerShell 5.1 ships Pester 3.4.0
         and the workflow installs 4.10.1 in two of its three jobs.

    Which Pester is used, first match wins:

      1. -PesterVersion, when given: that exact version, or the run fails
         saying how to install it. This is what .github/workflows/automation-tests.yml
         passes in each of its jobs, one of them the 3.4.0 Windows ships.
      2. A Pester 3 or 4 module already imported in this session: left alone,
         so a caller who imported a particular build gets it.
      3. The newest installed version below 5.
      4. Otherwise the newest installed version, with a warning: Pester 5
         removed the legacy assertion syntax, so the tests will fail on syntax
         rather than on behaviour. Install 4.10.1 (see below) or use Windows
         PowerShell.

    Exit code is the number of failed tests, or 1 when parsing fails.

    On GitHub Actions (GITHUB_ACTIONS is true) the runner also writes one
    notice naming the PowerShell and Pester versions and the counts, and one
    error annotation per failed test up to the ten a step can show, so the
    run's summary page names what failed without opening the log.

.PARAMETER OutputPath
    Optional NUnit XML results file, for a CI test report.

.PARAMETER PesterVersion
    Exact Pester version to import, for example 4.10.1. Empty (the default)
    picks as described above.

.EXAMPLE
    .\Invoke-Tests.ps1

.EXAMPLE
    Install-Module Pester -RequiredVersion 4.10.1 -Force -SkipPublisherCheck -Scope CurrentUser
    .\Invoke-Tests.ps1 -PesterVersion 4.10.1 -OutputPath .\out\test-results.xml

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = '',
    [string]$PesterVersion = ''
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

# ---- Gate 1: parse ----------------------------------------------------------

$parseFailures = 0
$files = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'automation'), (Join-Path -Path $repoRoot -ChildPath 'scripts') -Filter '*.ps1' -Recurse -File)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $parseFailures++
        foreach ($e in $errors) {
            Write-Output ('PARSE ERROR {0}:{1} {2}' -f $file.FullName, $e.Extent.StartLineNumber, $e.Message)
        }
    }
}
Write-Output ('Parsed {0} file(s), {1} with errors.' -f $files.Count, $parseFailures)
if ($parseFailures -gt 0) { exit 1 }

# ---- Gate 2: Pester ---------------------------------------------------------

$installHint = 'Install-Module Pester -RequiredVersion 4.10.1 -Force -SkipPublisherCheck -Scope CurrentUser'
$available = @(Get-Module -ListAvailable -Name Pester | Sort-Object -Property Version -Descending)
$loaded = @(Get-Module -Name Pester)

if (-not [string]::IsNullOrWhiteSpace($PesterVersion)) {
    $wanted = @($available | Where-Object { $_.Version.ToString() -eq $PesterVersion })
    if ($wanted.Count -eq 0) {
        throw ('Pester {0} is not installed. Run: {1}' -f $PesterVersion, $installHint)
    }
    Import-Module -Name Pester -RequiredVersion $wanted[0].Version -Force
}
elseif ($loaded.Count -gt 0 -and $loaded[0].Version.Major -le 4) {
    # Already imported by the caller; use it as it is.
}
elseif ($available.Count -eq 0) {
    throw ('Pester is not installed. Windows PowerShell 5.1 ships 3.4.0; otherwise run: {0}' -f $installHint)
}
else {
    $legacy = @($available | Where-Object { $_.Version.Major -le 4 } | Select-Object -First 1)
    if ($legacy.Count -gt 0) {
        Import-Module -Name Pester -RequiredVersion $legacy[0].Version -Force
    }
    else {
        Write-Warning ('Only Pester {0} is installed. These tests use the assertion syntax of Pester 3 and 4, which 5 removed; expect syntax failures. Run: {1}' -f $available[0].Version, $installHint)
        Import-Module -Name Pester -Force
    }
}

$pester = Get-Module -Name Pester
if ($null -eq $pester) { throw 'Pester could not be imported.' }
Write-Output ('Using Pester {0} on PowerShell {1} ({2}).' -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

$params = @{ PassThru = $true }
# Pester 4 takes the test files in -Script (a path or a hashtable); Pester 5
# renamed that to -Path and dropped -Script.
if ($pester.Version.Major -ge 5) { $params.Path = $here } else { $params.Script = $here }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $directory = Split-Path -Path $OutputPath -Parent
    if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    $params.OutputFile = $OutputPath
    $params.OutputFormat = 'NUnitXml'
}

$result = Invoke-Pester @params

# On GitHub Actions, say which PowerShell and Pester ran and name each failed
# test in an annotation, so the run's summary page shows what failed without
# opening the log (the editions and the two Pester lines do not behave the
# same, so the version matters). A workflow command is one line: the
# message's newlines become spaces and its percent signs are escaped.
if ($env:GITHUB_ACTIONS -eq 'true') {
    Write-Output ('::notice title=Pester::Pester {0} on PowerShell {1} ({2}): {3} passed, {4} failed.' -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $result.PassedCount, $result.FailedCount)
    # GitHub shows at most ten error annotations per step, so the tenth line
    # counts the rest instead of letting them drop without a trace.
    $failed = @($result.TestResult | Where-Object { $_.Result -eq 'Failed' })
    $shown = 0
    foreach ($test in $failed) {
        if ($shown -eq 9 -and $failed.Count -gt 10) {
            Write-Output ('::error title=Pester::{0} more failed test(s) are not annotated; open the job log for the full list.' -f ($failed.Count - $shown))
            break
        }
        $message = (([string]$test.FailureMessage) -replace '%', '%25') -replace '\r?\n', ' '
        if ($message.Length -gt 400) { $message = $message.Substring(0, 400) }
        Write-Output ('::error title=Pester::{0} > {1} > {2}: {3}' -f $test.Describe, $test.Context, $test.Name, $message)
        $shown++
    }
}

Write-Output ''
Write-Output ('Result: {0} passed, {1} failed, {2} skipped.' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
exit ([int]$result.FailedCount)
