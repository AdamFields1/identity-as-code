<#
.SYNOPSIS
    A runbook a job schedule cannot bind.
#>
param(
    [switch]$Force,

    [string[]]$Names = @(),

    [string]$Mailbox = ''
)

Write-Host "starting"

function Helper {
    param([switch]$Quiet)
    Write-Host 'nested'
}
