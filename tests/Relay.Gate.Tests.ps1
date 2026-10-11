#Requires -Version 5.1

<#
    The suite runner the gate starts for every test file counts every kind of failure: a failing test, a
    failing BeforeAll or AfterAll, a file that does not load, a path that names nothing, and a run in which no
    test ran. Each case runs Invoke-Suite.ps1 as a child process under the edition that runs this file.
    Runs under PowerShell 7 and Windows PowerShell 5.1. Pester 6. ASCII only.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeAll {
    $suite = Join-Path $PSScriptRoot 'Invoke-Suite.ps1'

    function Invoke-GateSuite {
        # Invoke-Suite.ps1 on one or more test files, in a child process of this edition: its lines and exit code
        param([Parameter(Mandatory)][string]$Path, [string]$Label = 'gate')
        $host_ = (Get-Process -Id $PID).Path
        $arguments = @('-NoProfile', '-NonInteractive')
        if ($PSVersionTable.PSVersion.Major -lt 6) { $arguments += @('-ExecutionPolicy', 'Bypass') }
        $output = @(& $host_ @arguments -File $suite -Path $Path -Label $Label 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Lines = $output; ExitCode = $LASTEXITCODE }
    }

    function New-GateTestFile {
        # A small Pester file in this test's drive
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, $Text)
        return $path
    }
}

Describe 'Invoke-Suite.ps1 counts every kind of failure (round 5)' -Tag 'Gate' {

    It 'passes a file whose tests pass' {
        $file = New-GateTestFile 'Pass.Tests.ps1' "Describe 'a' { It 'passes' { 1 | Should -Be 1 } }`n"
        $run = Invoke-GateSuite -Path $file -Label 'pass'
        $run.ExitCode | Should -Be 0
        @($run.Lines | Where-Object { $_ -like 'RESULT `[pass`] passed=1 failed=0 *' }).Count | Should -Be 1
    }

    It 'fails a run whose AfterAll fails, although every test passed' {
        $file = New-GateTestFile 'AfterAll.Tests.ps1' "Describe 'a block' { AfterAll { throw 'AfterAll broke' }; It 'passes' { 1 | Should -Be 1 } }`n"
        $run = Invoke-GateSuite -Path $file -Label 'afterall'
        $run.ExitCode | Should -BeGreaterThan 0
        @($run.Lines | Where-Object { $_ -like 'FAILED `[afterall`]*AfterAll broke*' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -like 'RESULT `[afterall`] passed=1 failed=1 *' }).Count | Should -Be 1
    }

    It 'names the message of a failing BeforeAll' {
        $file = New-GateTestFile 'BeforeAll.Tests.ps1' "Describe 'a block' { BeforeAll { throw 'BeforeAll broke' }; It 'never runs' { 1 | Should -Be 1 } }`n"
        $run = Invoke-GateSuite -Path $file -Label 'beforeall'
        $run.ExitCode | Should -BeGreaterThan 0
        @($run.Lines | Where-Object { $_ -like 'FAILED `[beforeall`]*BeforeAll broke*' }).Count | Should -Be 1
    }

    It 'fails a path that names no file instead of reporting nothing failed' {
        $run = Invoke-GateSuite -Path (Join-Path $TestDrive 'Nope.Tests.ps1') -Label 'wrongpath'
        $run.ExitCode | Should -BeGreaterThan 0
        @($run.Lines | Where-Object { $_ -like 'FAILED `[wrongpath`] the test file does not exist:*' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -like 'RESULT `[wrongpath`] passed=0 failed=1 *' }).Count | Should -Be 1
    }

    It 'names a skipped test on a SKIPPED line unless it is tagged MaySkip' {
        $file = New-GateTestFile 'Skips.Tests.ps1' "Describe 'a' { It 'passes' { 1 | Should -Be 1 }; It 'may skip' -Tag 'MaySkip' { Set-ItResult -Skipped -Because 'no right'; return }; It 'should not skip' { Set-ItResult -Skipped -Because 'why'; return } }`n"
        $run = Invoke-GateSuite -Path $file -Label 'skips'
        $run.ExitCode | Should -Be 0
        @($run.Lines | Where-Object { $_ -like 'SKIPPED `[skips`]*' }) | Should -Be @('SKIPPED [skips] a.should not skip')
    }

    It 'fails a run in which no test ran' {
        $file = New-GateTestFile 'Skipped.Tests.ps1' "Describe 'a' { It 'is skipped' -Skip { 1 | Should -Be 1 } }`n"
        $run = Invoke-GateSuite -Path $file -Label 'skipped'
        $run.ExitCode | Should -BeGreaterThan 0
        @($run.Lines | Where-Object { $_ -like 'FAILED `[skipped`] no test ran:*' }).Count | Should -Be 1
    }
}

Describe 'Invoke-AllTests.ps1 runs the editions it is given' -Tag 'Gate' {
    BeforeAll {
        $gate = Join-Path $PSScriptRoot 'Invoke-AllTests.ps1'

        function Invoke-Gate {
            # Invoke-AllTests.ps1 in a child process of this edition: its lines and exit code
            param([string[]]$Words)
            $host_ = (Get-Process -Id $PID).Path
            $arguments = @('-NoProfile', '-NonInteractive')
            if ($PSVersionTable.PSVersion.Major -lt 6) { $arguments += @('-ExecutionPolicy', 'Bypass') }
            # Windows PowerShell turns each line a program writes to standard error into an error, and under Stop
            # the first one ends the test
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = @(& $host_ @arguments -File $gate @Words 2>&1 | ForEach-Object { [string]$_ })
                return [pscustomobject]@{ Lines = $output; ExitCode = $LASTEXITCODE }
            }
            finally { $ErrorActionPreference = $previous }
        }
    }

    It 'refuses an edition it does not know' {
        $run = Invoke-Gate @('-StaticOnly', '-SkipAnalyzer', '-Editions', 'sh')
        $run.ExitCode | Should -Not -Be 0
        # Windows PowerShell wraps an error record at the width of its console: compare without the white space
        $said = ($run.Lines -join '') -replace '\s', ''
        $said | Should -Match 'Cannotvalidateargument'
        $said | Should -Match 'Editions'
        @($run.Lines | Where-Object { $_ -like 'GATE *' -or $_ -like '* NOT TESTED*' }).Count | Should -Be 0
    }

    # On Windows, ps5 alone would run every Pester file under Windows PowerShell: half an hour
    It 'names the edition it leaves out and fails when that leaves nothing to run' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $run = Invoke-Gate @('-SkipAnalyzer', '-SkipPane', '-Editions', 'ps5')
        $run.ExitCode | Should -BeGreaterThan 0
        @($run.Lines | Where-Object { $_ -ceq 'ps7 NOT TESTED: -Editions' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -like '*no Pester run could be started*' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -like 'RESULT *' }).Count | Should -Be 0
    }
}
