#Requires -Version 5.1

<#
    Runs one Pester file, or several (-Path a;b), and prints one RESULT line plus one FAILED line per failure:
    a failing test, a failing BeforeAll or AfterAll, a test file that did not load, a path that names nothing,
    and a run in which no test ran at all. Started by Invoke-AllTests.ps1 as a child process, once per
    PowerShell edition and engine. Exit code: the number of failures, 0 when everything passed. ASCII only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Engines = '',
    [string]$Label = ''
)

$ErrorActionPreference = 'Stop'
if ($Engines) { $env:RELAY_TEST_ENGINES = $Engines }
$started = Get-Date

function Get-FailureText {
    # The messages of a list of error records on one line, cut to what a FAILED line can carry
    param($Record)
    $message = ((@($Record | ForEach-Object { $_.Exception.Message })) -join ' | ') -replace '\s+', ' '
    if ($message.Length -gt 700) { $message = $message.Substring(0, 700) + ' ...' }
    return $message
}

$failures = 0
$passed = 0
$skipped = 0
# A path that names nothing makes Pester run nothing, or only the other files, and say so on a line nobody
# reads: each such path is a failure of its own
$present = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Path -split ';' | Where-Object { $_ })) {
    if (Test-Path -LiteralPath $item) { $present.Add($item) }
    else {
        $failures++
        "FAILED [$Label] the test file does not exist: $item"
    }
}
if ($present.Count -eq 0) {
    if ($failures -eq 0) {
        $failures++
        "FAILED [$Label] no test file was given"
    }
}
else {
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $present.ToArray()
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'None'
    # No test uses TestRegistry, and the gate runs several suites side by side: two Pester runs that start together
    # both try to create HKCU\Software\Pester, and the one that loses fails its whole file before a test ran
    $configuration.TestRegistry.Enabled = $false
    $result = Invoke-Pester -Configuration $configuration
    if ($null -eq $result) {
        # Pester returns nothing when the run itself failed, for example when it found no test file
        $failures++
        "FAILED [$Label] Pester returned no result: the run itself failed"
    }
    else {
        foreach ($test in @($result.Failed)) {
            $message = Get-FailureText $test.ErrorRecord
            if (-not $message) { $message = 'it did not run, most likely because a BeforeAll above it failed' }
            "FAILED [$Label] $($test.ExpandedPath): $message"
        }
        # A failing AfterAll leaves its tests passed, and the message of a failing BeforeAll is on its block, not
        # on the tests it kept from running: the blocks and the test files that failed outside their tests are
        # failures of their own
        foreach ($block in @($result.FailedBlocks)) {
            $where = [string]$block.ExpandedPath
            if (-not $where) { $where = @($block.Path) -join '.' }
            if (-not $where) { $where = 'the top level of a test file' }
            "FAILED [$Label] $where (BeforeAll or AfterAll): $(Get-FailureText $block.ErrorRecord)"
        }
        foreach ($container in @($result.FailedContainers)) {
            "FAILED [$Label] the test file did not load or failed outside its tests: $([string]$container.Item): $(Get-FailureText $container.ErrorRecord)"
        }
        # A skipped test is named unless it is tagged MaySkip: it may skip for a reason of the machine (no right to
        # make a symbolic link, an account that can read every folder), which the gate does not count against it
        foreach ($test in @($result.Skipped)) {
            if (@($test.Tag) -notcontains 'MaySkip') { "SKIPPED [$Label] $($test.ExpandedPath)" }
        }
        $failures += $result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount
        $passed = $result.PassedCount
        $skipped = $result.SkippedCount
        # A run in which every test was skipped, or none was found, tested nothing
        if ($failures -eq 0 -and $passed -eq 0) {
            $failures++
            "FAILED [$Label] no test ran: $($result.TotalCount) found, $($result.SkippedCount) skipped, $($result.NotRunCount) not run"
        }
    }
}
"RESULT [$Label] passed=$passed failed=$failures skipped=$skipped seconds=$([int]((Get-Date) - $started).TotalSeconds)"
exit ([Math]::Min(250, $failures))
