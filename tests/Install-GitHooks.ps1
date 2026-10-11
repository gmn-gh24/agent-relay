<#
.SYNOPSIS
    Installs (or removes) the pre-push git hook that runs tests\Invoke-PrePush.ps1.

.DESCRIPTION
    Git starts a hook through its own shell, so the hook file is a three-line stub that starts PowerShell 7 on
    tests\Invoke-PrePush.ps1; the stub is written here, on this PC, and is not part of the repository. A hook
    file that this script did not write is left alone unless -Force is given.

.PARAMETER Remove
    Deletes the hook this script installed.

.PARAMETER Force
    Replaces a pre-push hook that this script did not write.

.EXAMPLE
    pwsh -File tests\Install-GitHooks.ps1
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = '# agent-relay pre-push hook (tests\Install-GitHooks.ps1)'
$repo = Split-Path -Parent $PSScriptRoot
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $git) { throw 'git is not on PATH' }

$hookPath = @(& $git.Source -C $repo rev-parse --git-path hooks/pre-push)[0]
if ($LASTEXITCODE -ne 0 -or -not $hookPath) { throw "$repo is not a git working copy" }
$hookPath = [string]$hookPath
if (-not [System.IO.Path]::IsPathRooted($hookPath)) { $hookPath = Join-Path $repo $hookPath }

$existing = $null
if (Test-Path -LiteralPath $hookPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($hookPath)
}
$ours = $null -ne $existing -and $existing.Contains($marker)

if ($Remove) {
    if ($null -eq $existing) { Write-Output "no pre-push hook at $hookPath"; return }
    if (-not $ours -and -not $Force) { throw "$hookPath was not written by this script: left alone (-Force deletes it)" }
    Remove-Item -LiteralPath $hookPath -Force
    Write-Output "removed $hookPath"
    return
}

if ($null -ne $existing -and -not $ours -and -not $Force) {
    throw "$hookPath exists and was not written by this script: left alone (-Force replaces it)"
}

# Git runs a pre-push hook from the top of the working copy
$stub = "#!/bin/sh`n$marker`nexec pwsh -NoProfile -File tests/Invoke-PrePush.ps1`n"
$hooksFolder = Split-Path -Parent $hookPath
if (-not (Test-Path -LiteralPath $hooksFolder -PathType Container)) { New-Item -ItemType Directory -Path $hooksFolder | Out-Null }
[System.IO.File]::WriteAllText($hookPath, $stub, (New-Object System.Text.UTF8Encoding($false)))
$chmod = Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $chmod) { & $chmod.Source +x $hookPath }
Write-Output "installed $hookPath (git push --no-verify skips it; -Remove deletes it)"
