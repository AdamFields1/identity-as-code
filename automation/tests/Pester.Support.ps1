<#
.SYNOPSIS
    Test support dot-sourced by the test files that run a runbook file from
    disk. One function, nothing else at load time.

.DESCRIPTION
    A "runs from disk" test starts a copy of the runbook with the call
    operator, or dot-sources it inside a script block, so that the copy loads
    its own Runbook.Common.ps1 (from ..\lib, or inlined the way the runbooks
    module publishes it) and the test can prove that the copy's own transport
    made the calls: an offline core appended to the library, or the
    Invoke-WebRequest mock one level below the real Invoke-HttpCore.

    That worked by accident under Pester 3, which installs a mock as a
    function in the test file's scope: a function the script defines in its
    own scope shadows it. Pester 4 installs a mock as an alias to a bootstrap
    function, and PowerShell resolves an alias before a function of the same
    name in every child scope, so the mock intercepted every call and the
    script's own Invoke-HttpCore never ran. Five tests failed under 4.10.1 and
    passed under 3.4.0 for exactly that reason.

    Suspend-MockAlias removes the alias for the named commands, runs the
    script block, and puts each alias back in the test file's scope, so the
    mock stays in force for every other test in the file, including the
    Assert-MockCalled that follows the run. Under Pester 3 there is no alias
    and the function is a pass-through. It touches only the commands it is
    given: mocks of commands the copy does not define for itself (Start-Sleep,
    the Invoke-WebRequest tripwire or router) stay in force for the run from
    disk on both Pester lines, which is what keeps it offline. A mock of a
    function the copy's library also defines (Test-AzAccountsAvailable) stays
    in force under Pester 4 only; under Pester 3 the copy's own definition
    shadows it, as it always did. The helper assumes an alias it removes is
    the one Pester installed in the test file's script scope, which is where
    it puts it back.

.EXAMPLE
    $summary = Suspend-MockAlias -Name 'Invoke-HttpCore' -ScriptBlock {
        & $copy -SenderMailbox 'iam-noreply@corp.example.com' -AccessToken $tokens 3>$null 4>$null
    }

.NOTES
    Windows PowerShell 5.1 and PowerShell 7 compatible. Pester 3.4.0 and 4.x.
#>

function Suspend-MockAlias {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $saved = @{}
    foreach ($commandName in $Name) {
        $alias = Get-Item -Path ('Alias:' + $commandName) -ErrorAction SilentlyContinue
        if ($null -ne $alias) {
            $saved[$commandName] = $alias.Definition
            # Removes it from the nearest scope that has one: the test file's.
            Remove-Item -Path ('Alias:' + $commandName)
        }
    }
    try {
        & $ScriptBlock
    }
    finally {
        foreach ($commandName in $saved.Keys) {
            Set-Alias -Name $commandName -Value $saved[$commandName] -Scope Script
        }
    }
}
