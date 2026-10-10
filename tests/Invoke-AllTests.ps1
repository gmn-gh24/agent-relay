#Requires -Version 5.1

<#
.SYNOPSIS
    The test gate of agent-relay: nothing is committed while it fails.

.DESCRIPTION
    1. Static checks: PSScriptAnalyzer without findings on every PowerShell file, ASCII only, LF line ends
       (the byte fixtures excepted), relay.sh passes the syntax check of dash.
    2. Pester 6: the room tools on every engine (relay.ps1 under PowerShell 7 and Windows PowerShell 5.1,
       relay.sh under dash), one run per test file and engine, and the coordinator-side scripts under both
       PowerShell editions.

    The Pester runs are separate processes: first the PowerShell engines, six side by side, then the sh runs,
    two side by side (they are slow on Windows, slow everything next to them, and each holds a few hundred
    megabytes for as long as it runs). Exit code: 0 when everything passed.

    The whole gate takes the better part of an hour. One file on one engine is a run of a few minutes, and
    what it prints can be kept in a file, so that a session that ends does not take the result with it:
    tests\Invoke-Suite.ps1 -Path <test file> -Engines ps7|ps5|sh -Label <any word>. Start it with the host that
    is to run the tests (pwsh for ps7 and sh, powershell.exe for ps5). The script files (Scripts, Plan, Guard,
    Owner) take no -Engines.

    Start the tests from a folder on a local disk: Pester 6 does not run when the working folder is a network
    path.

.PARAMETER StaticOnly
    Only the static checks.

.PARAMETER Sequential
    One Pester run after the other (slower; for reading a failure in peace).

.PARAMETER PowerShellRuns
    How many runs of the PowerShell engines go side by side (6).

.PARAMETER ShellRuns
    How many sh runs go side by side (2). More is faster and takes more memory: four at once, next to a
    desktop in use, ran a 32 GB machine out of it.

.EXAMPLE
    pwsh -File tests\Invoke-AllTests.ps1

.EXAMPLE
    pwsh -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines sh -Label 'Faults sh' > faults-sh.txt

    One file on one engine, its result kept in a file.

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [switch]$StaticOnly,
    [switch]$Sequential,
    [ValidateRange(1, 16)][int]$PowerShellRuns = 6,
    [ValidateRange(1, 16)][int]$ShellRuns = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')

$repo = Get-RelayTestPath repo
$problems = New-Object System.Collections.Generic.List[string]
$started = Get-Date

# Static checks
$skip = '\\(\.git|\.local|history|node_modules)\\|\\\.claude-plugin\\types\\|\\evals\\results\\'
$files = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force | Where-Object { $_.FullName -notmatch $skip })
$powershellFiles = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1' })
$findings = 0
foreach ($file in $powershellFiles) {
    foreach ($finding in @(Invoke-ScriptAnalyzer -Path $file.FullName -ExcludeRule PSAvoidUsingWriteHost -Severity Error, Warning)) {
        $findings++
        $problems.Add("analyzer: $($file.FullName.Substring($repo.Length + 1)):$($finding.Line) $($finding.RuleName): $($finding.Message)")
    }
}
"static: PSScriptAnalyzer, $($powershellFiles.Count) files, $findings finding(s)"

$encodingProblems = 0
foreach ($file in $files) {
    if ($file.FullName -match '\\tests\\fixtures\\.*\.md$') { continue }
    if ($file.Extension -in '.png', '.jpg', '.gif', '.zip', '.wav', '.mp3') { continue }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $relative = $file.FullName.Substring($repo.Length + 1)
    $isAscii = $true
    $hasCarriageReturn = $false
    foreach ($byte in $bytes) {
        if ($byte -gt 127) { $isAscii = $false; break }
        if ($byte -eq 13) { $hasCarriageReturn = $true }
    }
    if (-not $isAscii) { $encodingProblems++; $problems.Add("not ASCII: $relative") }
    if ($hasCarriageReturn -and $file.Extension -notin '.cmd', '.bat') { $encodingProblems++; $problems.Add("CRLF line ends: $relative") }
}
"static: ASCII and line ends, $($files.Count) files, $encodingProblems problem(s)"

$dash = Get-RelayTestDash
if ($dash) {
    $savedPath = $env:PATH
    try {
        $env:PATH = (Split-Path -Parent $dash) + ';' + $env:PATH
        $syntax = @(& $dash -n ((Join-Path (Get-RelayTestPath package) 'tools\relay.sh') -replace '\\', '/') 2>&1)
        if ($LASTEXITCODE -ne 0) { $problems.Add('relay.sh does not pass the syntax check: ' + ($syntax -join ' ')) }
        "static: relay.sh syntax under dash, exit code $LASTEXITCODE"
    }
    finally { $env:PATH = $savedPath }
}
else { 'static: no dash on this machine, relay.sh was not checked' }

if ($StaticOnly) {
    foreach ($problem in $problems) { "PROBLEM $problem" }
    if ($problems.Count -eq 0) { 'GATE passed (static checks only)' } else { "GATE FAILED: $($problems.Count) problem(s)" }
    exit ([Math]::Min(250, $problems.Count))
}

# Pester runs: one process per PowerShell edition and engine
$pwsh = Get-RelayTestPwsh
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# The files that test the room tools run once per engine, each as a run of its own: the engines differ a lot in
# speed (relay.sh starts a process for nearly everything it does, which is slow on Windows), and a run takes
# its tests one after the other. The coordinator-side scripts are one run per edition.
$toolFiles = @('Relay.Tool.Tests.ps1', 'Relay.Team.Tests.ps1', 'Relay.Faults.Tests.ps1', 'Relay.Parity.Tests.ps1')
$scriptFiles = @('Relay.Scripts.Tests.ps1', 'Relay.Plan.Tests.ps1', 'Relay.Guard.Tests.ps1', 'Relay.Owner.Tests.ps1')
foreach ($file in $scriptFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { $problems.Add("the test file $file is missing") }
}
$scriptTests = (@($scriptFiles | ForEach-Object { Join-Path $PSScriptRoot $_ })) -join ';'
$runs = New-Object System.Collections.Generic.List[object]
foreach ($file in $toolFiles) {
    $part = $file -replace '^Relay\.|\.Tests\.ps1$', ''
    $path = Join-Path $PSScriptRoot $file
    if ($pwsh) {
        $runs.Add(@{ Label = "$part ps7"; Host = $pwsh; Path = $path; Engines = 'ps7' })
        if ($dash) { $runs.Add(@{ Label = "$part sh"; Host = $pwsh; Path = $path; Engines = 'sh' }) }
    }
    $runs.Add(@{ Label = "$part ps5"; Host = $windowsPowerShell; Path = $path; Engines = 'ps5' })
}
if ($pwsh) { $runs.Add(@{ Label = 'scripts on PowerShell 7'; Host = $pwsh; Path = $scriptTests; Engines = '' }) }
else { $problems.Add('PowerShell 7 was not found: its runs were skipped') }
$runs.Add(@{ Label = 'scripts on Windows PowerShell 5.1'; Host = $windowsPowerShell; Path = $scriptTests; Engines = '' })

function Start-Run {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a test process')]
    param([hashtable]$Run)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Run.Host
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Invoke-Suite.ps1'), '-Path', $Run.Path, '-Label', $Run.Label)
    if ($Run.Engines) { $arguments += @('-Engines', $Run.Engines) }
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-RelayTestArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Windows PowerShell must not inherit the module path of PowerShell 7
    if ($Run.Host -eq $windowsPowerShell -and $startInfo.EnvironmentVariables.ContainsKey('PSModulePath')) { $startInfo.EnvironmentVariables.Remove('PSModulePath') }
    foreach ($name in 'AGENT_RELAY_LOCAL', 'RELAY_TEST_ENGINES') { if ($startInfo.EnvironmentVariables.ContainsKey($name)) { $startInfo.EnvironmentVariables.Remove($name) } }
    # The fault tests force their races through the tools' pause points. Run by hand, a test whose point the tool
    # does not have skips itself; in the gate that is a failure, or a renamed point would pass unseen.
    $startInfo.EnvironmentVariables['RELAY_FAULTS_REQUIRE_HOOKS'] = '1'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    return [pscustomobject]@{ Run = $Run; Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
}

function Complete-Run {
    param($Handle)
    $Handle.Process.WaitForExit()
    $text = ([string]$Handle.Output.Result) -replace "`r", ''
    $lines = @($text -split "`n" | Where-Object { $_ -match '^(RESULT|FAILED) ' })
    foreach ($line in $lines) { $line }
    if (@($lines | Where-Object { $_ -match '^RESULT ' }).Count -eq 0) {
        $errorText = (([string]$Handle.Error.Result) -replace '\s+', ' ')
        if ($errorText.Length -gt 600) { $errorText = $errorText.Substring(0, 600) }
        $problems.Add("[$($Handle.Run.Label)] the run did not finish: $errorText")
    }
    foreach ($line in @($lines | Where-Object { $_ -match '^FAILED ' })) { $problems.Add($line) }
    # A fault test that skips itself tests nothing. On Windows, under PowerShell, none of them has a reason to:
    # they skip where a file cannot be held open without sharing, and where one call took longer than a test's
    # margin, which happens to relay.sh on a busy machine and shows in its RESULT line.
    if ($Handle.Run.Label -like 'Faults ps*' -and [System.IO.Path]::DirectorySeparatorChar -eq '\') {
        foreach ($line in @($lines | Where-Object { $_ -match '^RESULT .* skipped=([1-9][0-9]*) ' })) {
            $problems.Add("[$($Handle.Run.Label)] skipped tests in the fault tests: $line")
        }
    }
}

function Invoke-Phase {
    # Runs side by side, at most $Limit at a time; each one's lines are printed when it ends
    param([object[]]$Phase, [int]$Limit)
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($run in @($Phase)) { $queue.Enqueue($run) }
    $active = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0 -or $active.Count -gt 0) {
        while ($queue.Count -gt 0 -and $active.Count -lt $Limit) { $active.Add((Start-Run $queue.Dequeue())) }
        $ended = @($active | Where-Object { $_.Process.HasExited })
        foreach ($handle in $ended) {
            Complete-Run $handle
            $null = $active.Remove($handle)
        }
        if ($ended.Count -eq 0) { Start-Sleep -Milliseconds 500 }
    }
}

# Two phases: the PowerShell engines first, the sh runs after them. relay.sh starts thousands of processes, and
# next to that the PowerShell engines get several times slower: enough to break a test that measures a few
# seconds. Six PowerShell runs side by side leave each other alone.
$firstPhase = @($runs | Where-Object { $_.Engines -ne 'sh' })
$secondPhase = @($runs | Where-Object { $_.Engines -eq 'sh' })
if ($Sequential) { Invoke-Phase $runs.ToArray() 1 }
else {
    Invoke-Phase $firstPhase $PowerShellRuns
    Invoke-Phase $secondPhase $ShellRuns
}

''
foreach ($problem in $problems) { "PROBLEM $problem" }
$seconds = [int]((Get-Date) - $started).TotalSeconds
if ($problems.Count -eq 0) { "GATE passed in $seconds s" } else { "GATE FAILED in $seconds s: $($problems.Count) problem(s)" }
exit ([Math]::Min(250, $problems.Count))
