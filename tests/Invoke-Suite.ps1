#Requires -Version 5.1

<#
    Runs one Pester file, or several (-Path a;b), and prints one RESULT line plus one FAILED line per failing
    test. Started by Invoke-AllTests.ps1 as a child process, once per PowerShell edition and engine. ASCII only.
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
$configuration = New-PesterConfiguration
$configuration.Run.Path = @($Path -split ';' | Where-Object { $_ })
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $configuration
foreach ($test in @($result.Failed)) {
    $message = ((@($test.ErrorRecord | ForEach-Object { $_.Exception.Message })) -join ' | ') -replace '\s+', ' '
    if ($message.Length -gt 700) { $message = $message.Substring(0, 700) + ' ...' }
    "FAILED [$Label] $($test.ExpandedPath): $message"
}
foreach ($container in @($result.Containers)) {
    if ($container.ErrorRecord) { "FAILED [$Label] the test file did not load: " + ((@($container.ErrorRecord | ForEach-Object { $_.Exception.Message })) -join ' | ') }
}
$broken = @($result.Containers | Where-Object { $_.ErrorRecord }).Count
"RESULT [$Label] passed=$($result.PassedCount) failed=$($result.FailedCount + $broken) skipped=$($result.SkippedCount) seconds=$([int]((Get-Date) - $started).TotalSeconds)"
exit ([Math]::Min(250, $result.FailedCount + $broken))
