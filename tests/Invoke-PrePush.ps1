<#
.SYNOPSIS
    What the pre-push git hook runs: the gate of this PC, so a push does not carry a red commit to CI.

.DESCRIPTION
    Runs tests\Invoke-AllTests.ps1 for PowerShell 7 (the static checks, the pane when Claude Code is on PATH, and the
    ps7 Pester files). The Windows PowerShell 5.1 files are not part of it (they take the longest): run
    tests\Invoke-AllTests.ps1 without -Editions before a release. CI runs only the static and pane jobs on Linux.
    Install the hook with tests\Install-GitHooks.ps1. A push that must go anyway: git push --no-verify.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gate = Join-Path $PSScriptRoot 'Invoke-AllTests.ps1'
$arguments = @('-Editions', 'ps7')
if ($null -eq (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Write-Output 'pre-push: claude is not on PATH, the pane checks are left out (CI runs them)'
    $arguments += '-SkipPane'
}

Write-Output 'pre-push: the gate for PowerShell 7 (git push --no-verify skips it)'
$global:LASTEXITCODE = 0
& $gate @arguments
if (-not $? -or $LASTEXITCODE -ne 0) {
    Write-Output 'pre-push: the gate failed, nothing was pushed'
    exit 1
}
exit 0
