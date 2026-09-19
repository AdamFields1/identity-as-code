<#
.SYNOPSIS
    Example runbook: every top-level parameter binds from a job schedule string.

.DESCRIPTION
    Lists arrive as semicolon-separated strings and are split here. A comment
    that mentions [switch], [string[]], or Write-Host is not code.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+$')]
    [string]$SenderMailbox,

    [string]$Recipients = '',

    [ValidateRange(1, 365)]
    [int]$WarnDays = 30,

    [bool]$DryRun = $true
)

function Split-List {
    # A nested function may take an array: it is called from code, not from a schedule.
    param([string]$Value, [switch]$Trim, [string[]]$Defaults = @())
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Defaults }
    return @($Value -split ';' | ForEach-Object { if ($Trim) { $_.Trim() } else { $_ } })
}

$recipients = Split-List -Value $Recipients -Trim
Write-Output "Recipients: $($recipients.Count)"
Write-Output 'The words Write-Host and [switch] inside a string are not code.'
Write-Output "Neither is $('Write-Host') inside a subexpression."
$help = @'
Write-Host in a here-string is not code either.
'@
Write-Verbose $help
