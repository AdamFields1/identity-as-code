<#
.SYNOPSIS
    Parses every PowerShell file in automation/ and scripts/ with the language
    parser, then runs the Pester tests in this directory with whichever Pester
    is installed.

.DESCRIPTION
    Two gates, in order:

      1. Every .ps1 under automation/ and scripts/ must parse cleanly with
         System.Management.Automation.Language.Parser. A parse error fails the
         run before any test executes.
      2. The *.Tests.ps1 files in this directory run under Pester. The tests
         are written in the Pester 3/4 assertion syntax ("Should Be") because
         Windows PowerShell 5.1 ships Pester 3.4.0. When only Pester 5 or later
         is installed the runner still tries, but warns that the assertion
         syntax may need Pester 4 (Install-Module Pester -RequiredVersion 4.10.1
         -Scope CurrentUser) or Windows PowerShell.

    Exit code is the number of failed tests, or 1 when parsing fails.

.PARAMETER OutputPath
    Optional NUnit XML results file, for a CI test report.

.EXAMPLE
    .\Invoke-Tests.ps1

.EXAMPLE
    .\Invoke-Tests.ps1 -OutputPath .\out\test-results.xml

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = ''
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
            Write-Host ('PARSE ERROR {0}:{1} {2}' -f $file.FullName, $e.Extent.StartLineNumber, $e.Message)
        }
    }
}
Write-Host ('Parsed {0} file(s), {1} with errors.' -f $files.Count, $parseFailures)
if ($parseFailures -gt 0) { exit 1 }

# ---- Gate 2: Pester ---------------------------------------------------------

$available = @(Get-Module -ListAvailable -Name Pester | Sort-Object -Property Version -Descending)
if ($available.Count -eq 0) {
    throw 'Pester is not installed. Windows PowerShell 5.1 ships 3.4.0; otherwise run Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser.'
}

$legacy = @($available | Where-Object { $_.Version.Major -le 4 } | Select-Object -First 1)
if ($legacy.Count -gt 0) {
    Import-Module -Name Pester -RequiredVersion $legacy[0].Version -Force
}
else {
    Write-Warning ('Only Pester {0} is installed. These tests use the Pester 3/4 assertion syntax; if they fail on syntax, install Pester 4.10.1 or run under Windows PowerShell 5.1.' -f $available[0].Version)
    Import-Module -Name Pester -Force
}
$loaded = Get-Module -Name Pester
Write-Host ('Using Pester {0} on PowerShell {1}.' -f $loaded.Version, $PSVersionTable.PSVersion)

$params = @{ PassThru = $true }
if ($loaded.Version.Major -ge 5) { $params.Path = $here } else { $params.Script = $here }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $directory = Split-Path -Path $OutputPath -Parent
    if ($directory -and -not (Test-Path -Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    $params.OutputFile = $OutputPath
    $params.OutputFormat = 'NUnitXml'
}

$result = Invoke-Pester @params

Write-Host ''
Write-Host ('Result: {0} passed, {1} failed, {2} skipped.' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
exit ([int]$result.FailedCount)
