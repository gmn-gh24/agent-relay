#Requires -Version 5.1

<#
.SYNOPSIS
    The test gate of agent-relay: nothing is committed while it fails.

.DESCRIPTION
    1. Static checks: PSScriptAnalyzer without findings on every PowerShell file; ASCII only and LF line ends
       (the byte fixtures excepted) in every file git tracks or would add, so that logs, test results and eval
       transcripts that git ignores are not part of it; every PowerShell wrapper template of the room package
       parses once its placeholders are filled in; every test file is listed for a run and every listed one
       exists.
    2. The pane: claude plugin validate and claude plugin test, when claude is on PATH.
    3. Pester 6: the room tools under PowerShell 7 and Windows PowerShell 5.1, one run per test file and engine,
       and the coordinator-side scripts under both PowerShell editions.

    sh: none (postponed). There is no sh tool and no sh engine.

    Windows PowerShell 5.1 exists only on Windows. Elsewhere the gate says that ps5 is not available on this OS
    and runs ps7 alone; on Windows a missing Windows PowerShell fails the gate.

    The Pester runs are separate processes, six side by side. Each one must end with a RESULT line, an exit
    code of 0 and at least one test passed. Exit code: 0 when everything passed. A gate that passed lists
    what it did not test (NOT TESTED lines) above its GATE line.

    One file on one engine is a run of a few minutes, and what it prints can be kept in a file, so that a
    session that ends does not take the result with it: tests\Invoke-Suite.ps1 -Path <test file> -Engines
    ps7|ps5 -Label <any word>. Start it with the host that is to run the tests (pwsh for ps7, powershell.exe
    for ps5). The script files (Scripts, Plan, Guard, Owner) take no -Engines.

    Start the tests from a folder on a local disk: Pester 6 does not run when the working folder is a network
    path.

.PARAMETER StaticOnly
    Only the static checks: no pane checks, no Pester runs.

.PARAMETER Sequential
    One Pester run after the other (slower; for reading a failure in peace).

.PARAMETER PowerShellRuns
    How many Pester runs go side by side (6).

.PARAMETER ShellRuns
    Deprecated and ignored: there is no sh tool (postponed) and the gate starts no sh runs. Kept so that an
    older command line still works.

.PARAMETER SkipAnalyzer
    Leaves out PSScriptAnalyzer. Without this switch a machine that does not have it fails the gate; with it,
    the result says that the analyzer did not run.

.PARAMETER SkipPane
    Leaves out the pane's checks. Without this switch a machine where claude is not on PATH fails the gate;
    with it, the result says pane NOT TESTED.

.PARAMETER Editions
    Which PowerShell editions run the Pester files: ps7, ps5 or both (the default). CI runs each edition in a
    job of its own; an edition left out is named on a NOT TESTED line.

.EXAMPLE
    pwsh -File tests\Invoke-AllTests.ps1

.EXAMPLE
    pwsh -File tests\Invoke-AllTests.ps1 -StaticOnly

.EXAMPLE
    pwsh -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines ps7 -Label 'Faults ps7' > faults-ps7.log

    One file on one engine, its result kept in a file.

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [switch]$StaticOnly,
    [switch]$Sequential,
    [ValidateRange(1, 16)][int]$PowerShellRuns = 6,
    [ValidateRange(1, 16)][int]$ShellRuns = 2,
    [switch]$SkipAnalyzer,
    [switch]$SkipPane,
    [ValidateSet('ps7', 'ps5')][string[]]$Editions = @('ps7', 'ps5')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')

$repo = Get-RelayTestPath repo
$problems = New-Object System.Collections.Generic.List[string]
# What this run did not test: printed above the GATE line, so that a gate that passed does not claim more
$untested = New-Object System.Collections.Generic.List[string]
$started = Get-Date
$onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

if ($PSBoundParameters.ContainsKey('ShellRuns')) { "note: -ShellRuns $ShellRuns is ignored: there is no sh tool and the gate starts no sh runs" }
'sh: none (postponed)'

function Invoke-GateCommand {
    # Exit code and output, standard error included, of a program the gate starts
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    # Under Stop, Windows PowerShell ends the gate on the first line a program writes to standard error
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
    }
    finally { $ErrorActionPreference = $previous }
}

function Get-GateFile {
    # The files the static checks read: what git tracks plus what it would add (untracked, not ignored). What
    # git ignores (logs, test results, eval transcripts, this machine's state) is not part of the product.
    # Without git, a walk of the folder that leaves the same places out by name.
    param([Parameter(Mandatory)][string]$Root)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $git) {
        $listing = $null
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& $git.Source -C $Root -c core.quotepath=false ls-files --cached --others --exclude-standard 2>$null)
            if ($LASTEXITCODE -eq 0) { $listing = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        }
        catch { $listing = $null }
        finally { $ErrorActionPreference = $previous }
        if ($null -ne $listing) {
            $found = New-Object System.Collections.Generic.List[object]
            foreach ($name in $listing) {
                # A tracked file deleted from the working copy is listed too, and a nested repository as a folder;
                # a name git had to quote is no path at all
                try { $info = New-Object System.IO.FileInfo (Join-Path $Root $name) }
                catch { $info = $null }
                if ($null -ne $info -and $info.Exists) { $found.Add($info) }
            }
            return [pscustomobject]@{ Source = 'the files git tracks or would add'; Files = $found.ToArray() }
        }
    }
    $skip = '[\\/](\.git|\.local|history|node_modules)[\\/]|[\\/]\.claude-plugin[\\/]types[\\/]|[\\/]evals[\\/]results[\\/]|\.log$|[\\/]testResults[^\\/]*\.xml$'
    $walked = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object { $_.FullName -notmatch $skip })
    return [pscustomobject]@{ Source = 'a walk of the folder (git is not available)'; Files = $walked }
}

# Static checks
$fileSet = Get-GateFile -Root $repo
$files = @($fileSet.Files)
$powershellFiles = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1' })
if ($SkipAnalyzer) {
    $untested.Add('PSScriptAnalyzer NOT RUN: -SkipAnalyzer')
    "static: PSScriptAnalyzer skipped (-SkipAnalyzer), $($powershellFiles.Count) files not analyzed"
}
elseif ($null -eq (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    $problems.Add('PSScriptAnalyzer not installed: install it (Install-Module PSScriptAnalyzer), or pass -SkipAnalyzer to run the rest without it')
    'static: PSScriptAnalyzer not installed'
}
else {
    $findings = 0
    foreach ($file in $powershellFiles) {
        foreach ($finding in @(Invoke-ScriptAnalyzer -Path $file.FullName -ExcludeRule PSAvoidUsingWriteHost -Severity Error, Warning)) {
            $findings++
            $problems.Add("analyzer: $($file.FullName.Substring($repo.Length + 1)):$($finding.Line) $($finding.RuleName): $($finding.Message)")
        }
    }
    "static: PSScriptAnalyzer, $($powershellFiles.Count) files, $findings finding(s)"
}

$encodingProblems = 0
foreach ($file in $files) {
    $relative = $file.FullName.Substring($repo.Length + 1)
    if ($relative -match '^tests[\\/]fixtures[\\/].*\.md$') { continue }
    if ($file.Extension -in '.png', '.jpg', '.gif', '.zip', '.wav', '.mp3') { continue }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $isAscii = $true
    $hasCarriageReturn = $false
    foreach ($byte in $bytes) {
        if ($byte -gt 127) { $isAscii = $false; break }
        if ($byte -eq 13) { $hasCarriageReturn = $true }
    }
    if (-not $isAscii) { $encodingProblems++; $problems.Add("not ASCII: $relative") }
    if ($hasCarriageReturn -and $file.Extension -notin '.cmd', '.bat') { $encodingProblems++; $problems.Add("CRLF line ends: $relative") }
}
"static: ASCII and line ends, $($files.Count) files ($($fileSet.Source)), $encodingProblems problem(s)"

# The PowerShell wrappers a room gets are templates, so the analyzer never sees them as PowerShell: each one,
# its placeholders filled in with a harmless word, must parse
$wrapperFolder = Join-Path (Get-RelayTestPath package) 'wrappers'
$templates = @(Get-ChildItem -LiteralPath $wrapperFolder -Filter '*.ps1.tmpl' -File -ErrorAction SilentlyContinue)
$parseProblems = 0
if ($templates.Count -eq 0) { $problems.Add("no PowerShell wrapper template found in $wrapperFolder") }
foreach ($template in $templates) {
    $expanded = [regex]::Replace([System.IO.File]::ReadAllText($template.FullName), '\{\{[A-Za-z0-9_]+\}\}', 'relay')
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($expanded, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) {
        $parseProblems++
        $problems.Add("wrapper template does not parse: $($template.Name) line $($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}
"static: PowerShell wrapper templates, $($templates.Count) files, $parseProblems parse error(s)"

# The files that test the room tools run once per engine, each as a run of its own: the engines differ in
# speed, and a run takes its tests one after the other. The coordinator-side scripts are one run per edition.
# A test file that is in neither list would never run, so the gate fails on one.
$toolFiles = @('Relay.Tool.Tests.ps1', 'Relay.Team.Tests.ps1', 'Relay.Faults.Tests.ps1', 'Relay.Parity.Tests.ps1')
$scriptFiles = @('Relay.Scripts.Tests.ps1', 'Relay.Plan.Tests.ps1', 'Relay.Guard.Tests.ps1', 'Relay.Owner.Tests.ps1', 'Relay.Gate.Tests.ps1', 'Relay.Memory.Tests.ps1', 'Relay.Reopen.Tests.ps1')
$listed = @($toolFiles + $scriptFiles)
$missingFiles = @($listed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) })
foreach ($file in $missingFiles) { $problems.Add("the test file $file is missing") }
$unlistedFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Where-Object { $listed -notcontains $_.Name } | ForEach-Object { $_.Name })
foreach ($file in $unlistedFiles) { $problems.Add("the test file $file is in neither `$toolFiles nor `$scriptFiles of tests\Invoke-AllTests.ps1: the gate would never run it") }
"static: test files, $($listed.Count) listed, $($missingFiles.Count) missing, $($unlistedFiles.Count) not listed"

function Write-GateResult {
    # The problems, what was not tested, and the GATE line; the exit code is the number of problems
    param([string]$Scope)
    ''
    foreach ($problem in $problems) { "PROBLEM $problem" }
    foreach ($gap in $untested) { $gap }
    if ($problems.Count -eq 0) { "GATE passed $Scope" } else { "GATE FAILED $Scope`: $($problems.Count) problem(s)" }
}

if ($StaticOnly) {
    $untested.Add('pane and Pester runs NOT RUN: -StaticOnly')
    Write-GateResult '(static checks only)'
    exit ([Math]::Min(250, $problems.Count))
}

# The pane: its manifests and hooks module, and its own tests
if ($SkipPane) {
    $untested.Add('pane NOT TESTED: -SkipPane')
    'pane: skipped (-SkipPane)'
}
else {
    $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $claude) {
        $problems.Add('claude is not on PATH, so the pane was not tested (claude plugin validate, claude plugin test): pass -SkipPane to run the rest without it')
        $untested.Add('pane NOT TESTED: claude is not on PATH')
        'pane: claude is not on PATH, pane NOT TESTED'
    }
    else {
        foreach ($verb in 'validate', 'test') {
            $outcome = Invoke-GateCommand -FilePath $claude.Source -ArgumentList @('plugin', $verb, $repo)
            "pane: claude plugin $verb, exit code $($outcome.ExitCode)"
            if ($outcome.ExitCode -ne 0) {
                $tail = @($outcome.Lines | Where-Object { $_.Trim() } | Select-Object -Last 12) -join ' / '
                $problems.Add("claude plugin $verb failed with exit code $($outcome.ExitCode): $tail")
            }
        }
    }
}

# Pester runs: one process per PowerShell edition and engine
$pwsh = ''
$windowsPowerShell = ''
if ($Editions -contains 'ps7') {
    $pwsh = Get-RelayTestPwsh
    if (-not $pwsh) { $problems.Add('PowerShell 7 was not found: its runs (ps7) were skipped') }
}
else { $untested.Add('ps7 NOT TESTED: -Editions') }
if ($Editions -notcontains 'ps5') { $untested.Add('ps5 NOT TESTED: -Editions') }
elseif ($onWindows) {
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $windowsPowerShell = $candidate }
    else { $problems.Add("Windows PowerShell 5.1 was not found at $candidate`: its runs (ps5) were skipped") }
}
else {
    'ps5: not available on this OS (Windows PowerShell 5.1 exists only on Windows), its runs are skipped'
    $untested.Add('ps5 NOT TESTED: not available on this OS')
}
$presentScripts = @($scriptFiles | Where-Object { $missingFiles -notcontains $_ } | ForEach-Object { Join-Path $PSScriptRoot $_ })
$scriptTests = $presentScripts -join ';'
$runs = New-Object System.Collections.Generic.List[object]
foreach ($file in @($toolFiles | Where-Object { $missingFiles -notcontains $_ })) {
    $part = $file -replace '^Relay\.|\.Tests\.ps1$', ''
    $path = Join-Path $PSScriptRoot $file
    if ($pwsh) { $runs.Add(@{ Label = "$part ps7"; Host = $pwsh; Path = $path; Engines = 'ps7' }) }
    if ($windowsPowerShell) { $runs.Add(@{ Label = "$part ps5"; Host = $windowsPowerShell; Path = $path; Engines = 'ps5' }) }
}
if ($presentScripts.Count -gt 0) {
    if ($pwsh) { $runs.Add(@{ Label = 'scripts on PowerShell 7'; Host = $pwsh; Path = $scriptTests; Engines = '' }) }
    if ($windowsPowerShell) { $runs.Add(@{ Label = 'scripts on Windows PowerShell 5.1'; Host = $windowsPowerShell; Path = $scriptTests; Engines = '' }) }
}

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
    $exitCode = $Handle.Process.ExitCode
    $text = ([string]$Handle.Output.Result) -replace "`r", ''
    $lines = @($text -split "`n" | Where-Object { $_ -match '^(RESULT|FAILED|SKIPPED) ' })
    foreach ($line in $lines) { $line }
    $resultLines = @($lines | Where-Object { $_ -match '^RESULT ' })
    $failedLines = @($lines | Where-Object { $_ -match '^FAILED ' })
    if ($resultLines.Count -eq 0) {
        $errorText = (([string]$Handle.Error.Result) -replace '\s+', ' ')
        if ($errorText.Length -gt 600) { $errorText = $errorText.Substring(0, 600) }
        $problems.Add("[$($Handle.Run.Label)] the run did not finish (exit code $exitCode): $errorText")
    }
    foreach ($line in $failedLines) { $problems.Add($line) }
    # The exit code and the count of passed tests are checked as well: a run that names no failure has still
    # failed when it ended with an error, and a run in which nothing passed tested nothing
    if ($resultLines.Count -gt 0 -and $failedLines.Count -eq 0 -and $exitCode -ne 0) {
        $problems.Add("[$($Handle.Run.Label)] the run ended with exit code $exitCode and named no failure")
    }
    foreach ($line in $resultLines) {
        if ($line -match ' passed=(\d+) ' -and [int]$Matches[1] -eq 0) { $problems.Add("[$($Handle.Run.Label)] no test passed: $line") }
    }
    # A fault test that skips itself tests nothing. On Windows, under PowerShell, none has a reason to unless it
    # is tagged MaySkip (it needs a right the account may not have): every other skip is named on a SKIPPED line.
    if ($Handle.Run.Label -like 'Faults ps*' -and $onWindows) {
        foreach ($line in @($lines | Where-Object { $_ -match '^SKIPPED ' })) {
            $problems.Add("[$($Handle.Run.Label)] a fault test skipped itself: $line")
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

if ($runs.Count -eq 0) { $problems.Add('no Pester run could be started') }
elseif ($Sequential) { Invoke-Phase $runs.ToArray() 1 }
else { Invoke-Phase $runs.ToArray() $PowerShellRuns }

$seconds = [int]((Get-Date) - $started).TotalSeconds
Write-GateResult "in $seconds s"
exit ([Math]::Min(250, $problems.Count))
