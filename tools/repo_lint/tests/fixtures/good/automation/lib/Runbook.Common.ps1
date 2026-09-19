# fixture library: shared runbook plumbing, inlined at deploy time.

function Get-RunbookSetting {
    param([string]$Name, [string]$Default = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Default }
    return $Name
}
