#Requires -Version 5.1

<#
    Set-RelayPlan.ps1: the plan file the coordinator writes, the direct lines it opens, the changes of one part,
    the checks that refuse a plan and leave the room as it was, and -WhatIf, -NoLines and -Show.
    Runs under PowerShell 7 and Windows PowerShell 5.1. Pester 6. ASCII only.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $scripts = Get-RelayTestPath scripts
    $setPlan = Join-Path $scripts 'Set-RelayPlan.ps1'
    Import-Module (Join-Path $scripts 'RelayCommon.psm1') -Force
    $savedLocal = $env:AGENT_RELAY_LOCAL

    function Get-TestPlan {
        # The plan of the contract's example, as the object the plan file is made of
        return [ordered]@{
            goal  = 'A team view for every agent'
            parts = @(
                [ordered]@{ id = 'tool-ps'; owner = 'emma'; status = 'doing'; depends = @(); reviewer = 'henry'; title = 'The verbs in relay.ps1'
                    files = @('skills/agent-relay/assets/room-package/tools/relay.ps1'); notes = @('Output must match relay.sh line for line') },
                [ordered]@{ id = 'tests'; owner = 'jack'; depends = @('tool-ps'); title = 'Tests for both verbs'; files = @('tests/Relay.Team.Tests.ps1') },
                [ordered]@{ id = 'docs'; owner = 'olivia'; depends = @('tests'); reviewer = 'emma'; title = 'The documents' }
            )
        }
    }

    function Save-TestPlan {
        param([string]$Root, $Plan, [string]$Name = 'plan.json')
        $path = Join-Path $Root $Name
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Plan -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }

    function Get-TestSnapshot {
        # Every file of the room and of its canonical copy with its hash, size and time of last write, and every
        # folder: equal before and after means that nothing was written, rewritten, added or removed
        param([string]$Id)
        $object = Resolve-RelayRoom $Id
        $entries = New-Object System.Collections.Generic.List[string]
        foreach ($base in $object.Path, $object.Canon) {
            foreach ($item in @(Get-ChildItem -LiteralPath $base -Recurse -Force)) {
                if ($item.PSIsContainer) { $entries.Add('dir ' + $item.FullName); continue }
                $entries.Add('file ' + $item.FullName + ' ' + $item.Length + ' ' + $item.LastWriteTimeUtc.Ticks + ' ' + (Get-RelayFileHash $item.FullName))
            }
        }
        return (@($entries | Sort-Object) -join "`n")
    }
    function Get-TestLine {
        param([string]$Room, [string]$Agent)
        $path = Join-Path $Room "agents\$Agent\lines"
        return @(((Get-Content -LiteralPath $path -Raw) -replace "`r", '') -split "`n" | Where-Object { $_ })
    }

    function Lock-TestMutex {
        # Holds the named mutex on a thread of its own (a mutex is recursive on the thread that owns it)
        param([string]$Name)
        $release = New-Object System.Threading.ManualResetEvent($false)
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $shell = [powershell]::Create()
        $null = $shell.AddScript({
                param($MutexName, $Release, $Ready)
                $mutex = New-Object System.Threading.Mutex($false, $MutexName)
                $null = $mutex.WaitOne()
                $null = $Ready.Set()
                $null = $Release.WaitOne()
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }).AddArgument($Name).AddArgument($release).AddArgument($ready)
        $handle = $shell.BeginInvoke()
        if (-not $ready.WaitOne(10000)) { throw 'the mutex holder did not start' }
        return [pscustomobject]@{ Shell = $shell; Handle = $handle; Release = $release }
    }

    function Unlock-TestMutex {
        param($Holder)
        $null = $Holder.Release.Set()
        $null = $Holder.Shell.EndInvoke($Holder.Handle)
        $Holder.Shell.Dispose()
    }

    function Test-TestMutexFree {
        # True when another thread can take the mutex at once
        param([string]$Name)
        $shell = [powershell]::Create()
        try {
            $null = $shell.AddScript({
                    param($MutexName)
                    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
                    $free = $mutex.WaitOne(0)
                    if ($free) { $mutex.ReleaseMutex() }
                    $mutex.Dispose()
                    return $free
                }).AddArgument($Name)
            return [bool]($shell.Invoke() | Select-Object -First 1)
        }
        finally { $shell.Dispose() }
    }
    function Get-TestPlanLine {
        param([string]$Room)
        return @(([System.IO.File]::ReadAllText((Join-Path $Room 'PLAN'))).TrimEnd("`n") -split "`n")
    }
}

AfterAll {
    $env:AGENT_RELAY_LOCAL = $savedLocal
}

Describe 'Set-RelayPlan: the whole plan' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "plan-$case"
        $id = "plan-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $file = Save-TestPlan $root (Get-TestPlan)
    }

    It 'writes the PLAN text line by line, in the order of the contract, with defaults for what is left out' {
        $null = & $setPlan -Room $id -PlanFile $file
        $text = Get-TestPlanLine $room
        $text.Count | Should -Be 10
        $text[0] | Should -Be 'plan: 1'
        $text[1] | Should -Match '^updated_utc: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $text[2] | Should -Be 'goal: A team view for every agent'
        $text[3] | Should -Be 'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1'
        $text[4] | Should -Be 'part: tests | jack | todo | tool-ps | - | Tests for both verbs'
        $text[5] | Should -Be 'part: docs | olivia | todo | tests | emma | The documents'
        $text[6] | Should -Be 'files: tool-ps | skills/agent-relay/assets/room-package/tools/relay.ps1'
        $text[7] | Should -Be 'files: tests | tests/Relay.Team.Tests.ps1'
        $text[8] | Should -Be 'note: tool-ps | Output must match relay.sh line for line'
        $text[9] | Should -Be 'end: 1'
    }

    It 'writes updated_utc as the time now' {
        $before = [DateTime]::UtcNow.AddSeconds(-2)
        $null = & $setPlan -Room $id -PlanFile $file
        $stamp = [DateTime]::ParseExact(((Get-TestPlanLine $room)[1] -replace '^updated_utc: ', ''), 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $stamp | Should -BeGreaterThan $before
        $stamp | Should -BeLessThan ([DateTime]::UtcNow.AddSeconds(2))
    }

    It 'writes UTF-8 without a BOM and with LF line ends, a final LF and no CR, and keeps non-ASCII text' {
        $plan = Get-TestPlan
        $plan.parts[0].title = 'Caf' + [char]0x00E9 + ' verbs'
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'unicode.json')
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $room 'PLAN'))
        $bytes[0] | Should -Not -Be 0xEF
        $bytes -contains 13 | Should -BeFalse
        $bytes[$bytes.Length - 1] | Should -Be 10
        $bytes[$bytes.Length - 2] | Should -Not -Be 10
        [System.IO.File]::ReadAllText((Join-Path $room 'PLAN')) | Should -Match ('part: tool-ps \| emma \| doing \| - \| henry \| Caf' + [char]0x00E9 + ' verbs')
    }

    It 'keeps the canonical copy identical to the room''s file, and the tamper check agrees' {
        $null = & $setPlan -Room $id -PlanFile $file
        $object = Resolve-RelayRoom $id
        Test-Path -LiteralPath (Join-Path $object.Canon 'PLAN') | Should -BeTrue
        (Get-RelayFileHash (Join-Path $object.Canon 'PLAN')) | Should -Be (Get-RelayFileHash (Join-Path $room 'PLAN'))
        @(Test-RelayTamper $object).Count | Should -Be 0
    }

    It 'prints the heading, one line per part in the columns of the team view, the new lines and the NEXT line' {
        $output = @(& $setPlan -Room $id -PlanFile $file)
        $output[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
        $output[1] | Should -Be ('  tool-ps' + (' ' * 7) + 'doing' + (' ' * 5) + 'emma' + (' ' * 7) + 'The verbs in relay.ps1')
        $output[2] | Should -Be ('  tests' + (' ' * 9) + 'todo' + (' ' * 6) + 'jack' + (' ' * 7) + 'Tests for both verbs')
        $output[3] | Should -Be ('  docs' + (' ' * 10) + 'todo' + (' ' * 6) + 'olivia' + (' ' * 5) + 'The documents')
        $output[4] | Should -Be 'LINE open between emma and henry'
        $output[5] | Should -Be 'LINE open between emma and jack'
        $output[6] | Should -Be 'NEXT: the agents are shown the new plan with the next message they receive, or at once with the verb team.'
        $output.Count | Should -Be 7
    }

    It 'makes the id column as wide as the longest id of the plan, and keeps 12 for a short one' {
        $plan = [ordered]@{ goal = 'Long ids'; parts = @(
                [ordered]@{ id = 'short'; owner = 'emma'; status = 'doing'; title = 'Short' },
                [ordered]@{ id = 'tool-verbs-of-the-ps1'; owner = 'jack'; status = 'todo'; title = 'Long' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'wide.json'))
        $output[1] | Should -Be ('  ' + 'short'.PadRight(21) + '  ' + 'doing'.PadRight(8) + '  ' + 'emma'.PadRight(9) + '  ' + 'Short')
        $output[2] | Should -Be ('  ' + 'tool-verbs-of-the-ps1' + '  ' + 'todo'.PadRight(8) + '  ' + 'jack'.PadRight(9) + '  ' + 'Long')
        $null = Remove-Item -LiteralPath (Join-Path $room 'PLAN') -Force
        $small = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan) 'small.json'))
        $small[1] | Should -Be ('  ' + 'tool-ps'.PadRight(12) + '  ' + 'doing'.PadRight(8) + '  ' + 'emma'.PadRight(9) + '  ' + 'The verbs in relay.ps1')
    }

    It 'does not cut a value that is longer than its column and prints a nobody owner as it is written' {
        $plan = Get-TestPlan
        $plan.parts = @([ordered]@{ id = 'a-very-long-part-id-24'; status = 'blocked'; title = 'Long' })
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'long.json'))
        $output[1] | Should -Be ('  a-very-long-part-id-24' + '  ' + 'blocked ' + '  ' + '-'.PadRight(9) + '  ' + 'Long')
    }

    It 'raises the revision by one with every plan and every part change' {
        $null = & $setPlan -Room $id -PlanFile $file
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 1'
        $null = & $setPlan -Room $id -PlanFile $file
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 2'
        $null = & $setPlan -Room $id -Part 'tests' -Status 'doing'
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 3'
        (@(& $setPlan -Room $id -Part 'tests' -Status 'review'))[0] | Should -Be "PLAN 4 for room ${id}: 3 part(s)"
    }

    It 'ends every plan with an end: line that names the revision of the plan: line, the last line of the file' {
        foreach ($revision in 1, 2) {
            $null = & $setPlan -Room $id -PlanFile $file
            $text = Get-TestPlanLine $room
            $text[0] | Should -Be "plan: $revision"
            $text[$text.Count - 1] | Should -Be "end: $revision"
            @($text | Where-Object { $_ -like 'end:*' }).Count | Should -Be 1
        }
        $null = & $setPlan -Room $id -Part 'tests' -Status 'done'
        (Get-TestPlanLine $room)[-1] | Should -Be 'end: 3'
    }

    It 'allows a part with neither owner nor reviewer, and a reviewer with no owner' {
        $plan = [ordered]@{ goal = 'Nobody'; parts = @([ordered]@{ id = 'a'; title = 'Nobody at all' }, [ordered]@{ id = 'b'; reviewer = 'henry'; title = 'Reviewer only' }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'nobody.json')
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'part: a | - | todo | - | - | Nobody at all'
        $text | Should -Contain 'part: b | - | todo | - | henry | Reviewer only'
    }

    It 'starts at 1 when the canonical copy holds no plan: line, whatever the room''s file says' {
        $object = Resolve-RelayRoom $id
        Write-RelayGuardedText $object 'PLAN' "goal: nothing numbered`n"
        $null = & $setPlan -Room $id -PlanFile $file
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 1'
        (Get-RelayFileHash (Join-Path $object.Canon 'PLAN')) | Should -Be (Get-RelayFileHash (Join-Path $room 'PLAN'))
    }
    It 'writes a part without depends, files and notes as a bare part line' {
        $plan = [ordered]@{ goal = 'Small'; parts = @([ordered]@{ id = 'one'; title = 'Only one' }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'small.json')
        $text = Get-TestPlanLine $room
        $text.Count | Should -Be 5
        $text[3] | Should -Be 'part: one | - | todo | - | - | Only one'
        $text[4] | Should -Be 'end: 1'
    }

    It 'writes several depends with commas and no spaces, and several files and notes lines per part' {
        $plan = [ordered]@{ goal = 'Many'; parts = @(
                [ordered]@{ id = 'a'; title = 'A'; files = @('x/one.txt', 'x/two.txt'); notes = @('first', 'second') },
                [ordered]@{ id = 'b'; title = 'B' },
                [ordered]@{ id = 'c'; title = 'C'; depends = @('a', 'b') }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'many.json')
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'part: c | - | todo | a,b | - | C'
        $text[6..9] | Should -Be @('files: a | x/one.txt', 'files: a | x/two.txt', 'note: a | first', 'note: a | second')
        $text[10] | Should -Be 'end: 1'
    }

    It 'takes a depends or notes value that is one text instead of a list' {
        $plan = [ordered]@{ goal = 'Texts'; parts = @([ordered]@{ id = 'a'; title = 'A' }, [ordered]@{ id = 'b'; title = 'B'; depends = 'a'; notes = 'one note' }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'texts.json')
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'part: b | - | todo | a | - | B'
        $text | Should -Contain 'note: b | one note'
    }

    It 'takes the room folder instead of the room id' {
        $output = @(& $setPlan -Room $room -PlanFile $file)
        $output[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
    }

    It 'takes a plan file named by a relative path' {
        Push-Location $root
        try { $output = @(& $setPlan -Room $id -PlanFile '.\plan.json') }
        finally { Pop-Location }
        $output[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
    }
}

Describe 'Set-RelayPlan: direct lines' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "lines-$case"
        $id = "lines-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $file = Save-TestPlan $root (Get-TestPlan)
    }

    It 'opens a line between an owner and the owner of each part it depends on, and between an owner and its reviewer, both ways' {
        $null = & $setPlan -Room $id -PlanFile $file
        Get-TestLine $room 'emma' | Should -Be @('henry', 'jack')
        Get-TestLine $room 'jack' | Should -Be @('emma')
        Get-TestLine $room 'henry' | Should -Be @('emma')
        $object = Resolve-RelayRoom $id
        foreach ($name in 'emma', 'jack', 'henry') { (Get-RelayFileHash (Join-Path $object.Canon "agents\$name\lines")) | Should -Be (Get-RelayFileHash (Join-Path $room "agents\$name\lines")) -Because $name }
        @(Test-RelayTamper $object).Count | Should -Be 0
    }

    It 'opens no line with the coordinator, with nobody or from an agent to itself' {
        $plan = [ordered]@{ goal = 'No lines'; parts = @(
                [ordered]@{ id = 'a'; owner = 'olivia'; reviewer = 'emma'; title = 'Coordinator part' },
                [ordered]@{ id = 'b'; owner = 'jack'; depends = @('a'); title = 'Depends on the coordinator' },
                [ordered]@{ id = 'c'; owner = 'jack'; depends = @('b'); title = 'Depends on itself, one agent' },
                [ordered]@{ id = 'd'; owner = 'henry'; reviewer = 'olivia'; title = 'Reviewed by the coordinator' },
                [ordered]@{ id = 'e'; depends = @('d'); reviewer = 'emma'; title = 'Nobody owns it' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'nolines.json'))
        @($output | Where-Object { $_ -like 'LINE*' }).Count | Should -Be 0
        foreach ($name in 'olivia', 'emma', 'jack', 'henry') { (Get-Content -LiteralPath (Join-Path $room "agents\$name\lines") -Raw) | Should -BeNullOrEmpty -Because $name }
    }

    It 'prints a LINE line only for a line that was opened by this call, the two names in alphabetical order' {
        $null = & $setPlan -Room $id -PlanFile $file
        $again = @(& $setPlan -Room $id -PlanFile $file)
        @($again | Where-Object { $_ -like 'LINE*' }).Count | Should -Be 0
        $plan = Get-TestPlan
        $plan.parts[1].owner = 'henry'
        $changed = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'again.json'))
        @($changed | Where-Object { $_ -like 'LINE*' }) | Should -Be @()
        $plan.parts[1].owner = 'jack'
        $plan.parts[2].owner = 'jack'
        $plan.parts[2].reviewer = 'henry'
        $third = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'third.json'))
        @($third | Where-Object { $_ -like 'LINE*' }) | Should -Be @('LINE open between henry and jack')
    }

    It 'leaves a line that is open and the order of the entries alone' {
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Line 'emma' -To 'henry'
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Line 'emma' -To 'olivia'
        $output = @(& $setPlan -Room $id -PlanFile $file)
        @($output | Where-Object { $_ -like 'LINE*' }) | Should -Be @('LINE open between emma and jack')
        Get-TestLine $room 'emma' | Should -Be @('henry', 'olivia', 'jack')
        Get-TestLine $room 'henry' | Should -Be @('emma')
    }

    It 'writes the missing entry of a line that is open one way only, <Way>, and prints one LINE line for it' -ForEach @(
        @{ Way = 'emma names jack'; Opened = 'emma'; Missing = 'jack' }
        @{ Way = 'jack names emma'; Opened = 'jack'; Missing = 'emma' }
    ) {
        $object = Resolve-RelayRoom $id
        $other = @('emma', 'jack') | Where-Object { $_ -ne $Opened }
        Write-RelayGuardedText $object "agents/$Opened/lines" "$other`n"
        # The precondition: one direction is open, the other is not, in both copies
        Get-TestLine $room $Opened | Should -Be @($other)
        @(Get-TestLine $room $other).Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $object.Canon "agents\$other\lines") -Raw) | Should -BeNullOrEmpty
        $output = @(& $setPlan -Room $id -PlanFile $file)
        @($output | Where-Object { $_ -like 'LINE*' }) | Should -Be @('LINE open between emma and henry', 'LINE open between emma and jack')
        Get-TestLine $room 'emma' | Should -Contain 'jack'
        Get-TestLine $room 'jack' | Should -Be @('emma')
        Get-TestLine $room $Opened | Should -Be (Get-TestLine $room $Opened | Select-Object -Unique)
        foreach ($name in 'emma', 'jack') { (Get-RelayFileHash (Join-Path $object.Canon "agents\$name\lines")) | Should -Be (Get-RelayFileHash (Join-Path $room "agents\$name\lines")) -Because $name }
    }
    It 'never takes a line away: a line the new plan does not need stays' {
        $null = & $setPlan -Room $id -PlanFile $file
        $plan = [ordered]@{ goal = 'Others'; parts = @([ordered]@{ id = 'x'; owner = 'henry'; title = 'Alone' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'others.json'))
        @($output | Where-Object { $_ -like 'LINE*' }).Count | Should -Be 0
        Get-TestLine $room 'emma' | Should -Be @('henry', 'jack')
        Get-TestLine $room 'jack' | Should -Be @('emma')
    }

    It 'lets the agents it joined write to each other through the lines' {
        $null = & $setPlan -Room $id -PlanFile $file
        $started = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine (Get-RelayTestHostEngine) -Words @('start', 'p', 'm', 'e')
        $started.ExitCode | Should -Be 0
        foreach ($name in 'emma', 'jack') { (Invoke-RelayTool -Room $room -Agent $name -Engine (Get-RelayTestHostEngine) -Words @('start', 'p', 'm', 'e')).ExitCode | Should -Be 0 }
        (Send-RelayTestMessage -Room $room -Agent 'emma' -Engine (Get-RelayTestHostEngine) -Words @('note', 'jack') -Text "Direct`n`nHello Jack.").ExitCode | Should -Be 0
        (Send-RelayTestMessage -Room $room -Agent 'jack' -Engine (Get-RelayTestHostEngine) -Words @('note', 'henry') -Text "No line`n`nHello Henry.").ExitCode | Should -Be 1
    }

    It 'opens no line with -NoLines, and writes the plan all the same' {
        $output = @(& $setPlan -Room $id -PlanFile $file -NoLines)
        @($output | Where-Object { $_ -like 'LINE*' }).Count | Should -Be 0
        $output[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 1'
        foreach ($name in 'emma', 'jack', 'henry') { (Get-Content -LiteralPath (Join-Path $room "agents\$name\lines") -Raw) | Should -BeNullOrEmpty -Because $name }
    }

    It 'opens no line with -NoLines when one part changes either, and changes the part all the same' {
        $null = & $setPlan -Room $id -PlanFile $file -NoLines
        $output = @(& $setPlan -Room $id -Part 'tests' -Reviewer 'henry' -NoLines)
        $output[0] | Should -Be "PLAN 2 for room ${id}: 3 part(s)"
        @($output | Where-Object { $_ -like 'LINE*' }).Count | Should -Be 0
        $object = Resolve-RelayRoom $id
        foreach ($path in (Join-Path $room 'PLAN'), (Join-Path $object.Canon 'PLAN')) {
            $text = @(([System.IO.File]::ReadAllText($path)).TrimEnd("`n") -split "`n")
            $text[0] | Should -Be 'plan: 2' -Because $path
            $text | Should -Contain 'part: tests | jack | todo | tool-ps | henry | Tests for both verbs' -Because $path
            $text[-1] | Should -Be 'end: 2' -Because $path
        }
        foreach ($name in 'emma', 'jack', 'henry') { (Get-Content -LiteralPath (Join-Path $room "agents\$name\lines") -Raw) | Should -BeNullOrEmpty -Because $name }
    }}

Describe 'Set-RelayPlan: -WhatIf' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "whatif-$case"
        $id = "whatif-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $file = Save-TestPlan $root (Get-TestPlan)
    }

    It 'writes nothing for a whole plan: no PLAN, no copy, no lines' {
        $before = Get-TestSnapshot $id
        $output = @(& $setPlan -Room $id -PlanFile $file -WhatIf)
        $output.Count | Should -Be 0
        Get-TestSnapshot $id | Should -Be $before
        Test-Path -LiteralPath (Join-Path $room 'PLAN') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path (Resolve-RelayRoom $id).Canon 'PLAN') | Should -BeFalse
    }

    It 'prints what it would do: the plan and each line, through the host, and writes nothing' {
        $before = Get-TestSnapshot $id
        $result = Invoke-RelayTestScript -Script 'Set-RelayPlan.ps1' -Arguments @('-Room', $id, '-PlanFile', $file, '-WhatIf')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -Match ('What if: Performing the operation "write plan 1 with 3 part\(s\)" on target "room ' + [regex]::Escape($id) + '"')
        $result.Output | Should -Match 'What if: Performing the operation "open a direct line" on target "agents emma and henry"'
        $result.Output | Should -Match 'What if: Performing the operation "open a direct line" on target "agents emma and jack"'
        $result.Output | Should -Not -Match 'PLAN 1 for room'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'prints what it would do for a part change too' {
        $null = & $setPlan -Room $id -PlanFile $file
        $before = Get-TestSnapshot $id
        $result = Invoke-RelayTestScript -Script 'Set-RelayPlan.ps1' -Arguments @('-Room', $id, '-Part', 'tests', '-Status', 'done', '-WhatIf')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -Match ('What if: Performing the operation "write plan 2 with 3 part\(s\)" on target "room ' + [regex]::Escape($id) + '"')
        Get-TestSnapshot $id | Should -Be $before
    }
    It 'writes nothing for a change of one part' {
        $null = & $setPlan -Room $id -PlanFile $file -NoLines
        $before = Get-TestSnapshot $id
        $null = & $setPlan -Room $id -Part 'tests' -Status 'done' -Reviewer 'henry' -Note 'later' -WhatIf
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'still refuses a plan that is wrong' {
        $plan = Get-TestPlan
        $plan.goal = ''
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'bad.json') -WhatIf } | Should -Throw 'Plan refused: *'
    }
}

Describe 'Set-RelayPlan: one part' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "part-$case"
        $id = "part-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        $before = Get-TestPlanLine $room
    }

    It 'changes the status of one part and leaves every other line as it was' {
        $null = & $setPlan -Room $id -Part 'tests' -Status 'review'
        $after = Get-TestPlanLine $room
        $after.Count | Should -Be $before.Count
        $after[0] | Should -Be 'plan: 2'
        $after[2..($after.Count - 1)] | Should -Not -Contain 'part: tests | jack | todo | tool-ps | - | Tests for both verbs'
        $after | Should -Contain 'part: tests | jack | review | tool-ps | - | Tests for both verbs'
        foreach ($index in 2, 3, 5, 6, 7, 8) { $after[$index] | Should -Be $before[$index] }
    }

    It 'changes owner and reviewer, and nobody with -' {
        $null = & $setPlan -Room $id -Part 'tool-ps' -Owner 'jack' -Reviewer '-'
        (Get-TestPlanLine $room) | Should -Contain 'part: tool-ps | jack | doing | - | - | The verbs in relay.ps1'
        $null = & $setPlan -Room $id -Part 'tests' -Owner '-' -Reviewer 'henry'
        (Get-TestPlanLine $room) | Should -Contain 'part: tests | - | todo | tool-ps | henry | Tests for both verbs'
    }

    It 'adds a note after the notes the plan has, and several changes at once go in together' {
        $output = @(& $setPlan -Room $id -Part 'tool-ps' -Status 'review' -Note 'Please look at the table')
        $text = Get-TestPlanLine $room
        $text[3] | Should -Be 'part: tool-ps | emma | review | - | henry | The verbs in relay.ps1'
        $text[8] | Should -Be 'note: tool-ps | Output must match relay.sh line for line'
        $text[9] | Should -Be 'note: tool-ps | Please look at the table'
        $text[10] | Should -Be 'end: 2'
        $output[0] | Should -Be "PLAN 2 for room ${id}: 3 part(s)"
    }

    It 'keeps the goal, the files and the order of the parts, and the canonical copy follows' {
        $null = & $setPlan -Room $id -Part 'docs' -Status 'blocked'
        $text = Get-TestPlanLine $room
        $text[2] | Should -Be $before[2]
        @($text | Where-Object { $_ -like 'part:*' } | ForEach-Object { ($_ -split ' \| ')[0] }) | Should -Be @('part: tool-ps', 'part: tests', 'part: docs')
        @($text | Where-Object { $_ -like 'files:*' }) | Should -Be @($before | Where-Object { $_ -like 'files:*' })
        $object = Resolve-RelayRoom $id
        (Get-RelayFileHash (Join-Path $object.Canon 'PLAN')) | Should -Be (Get-RelayFileHash (Join-Path $room 'PLAN'))
        @(Test-RelayTamper $object).Count | Should -Be 0
    }

    It 'prints the whole plan as the plan file does, with the new lines the change opened' {
        $output = @(& $setPlan -Room $id -Part 'tests' -Reviewer 'henry')
        $output[0] | Should -Be "PLAN 2 for room ${id}: 3 part(s)"
        $output[2] | Should -Be ('  tests' + (' ' * 9) + 'todo' + (' ' * 6) + 'jack' + (' ' * 7) + 'Tests for both verbs')
        $output | Should -Contain 'LINE open between henry and jack'
        $output[$output.Count - 1] | Should -Match '^NEXT: the agents are shown the new plan'
        Get-TestLine $room 'jack' | Should -Be @('emma', 'henry')
    }

    It 'checks the roster only for the names this call sets: a part whose owner has retired does not block another change' {
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Retire 'jack'
        $output = @(& $setPlan -Room $id -Part 'tool-ps' -Status 'done')
        $output[0] | Should -Be "PLAN 2 for room ${id}: 3 part(s)"
        (Get-TestPlanLine $room) | Should -Contain 'part: tests | jack | todo | tool-ps | - | Tests for both verbs'
        (Get-TestPlanLine $room) | Should -Contain 'part: tool-ps | emma | done | - | henry | The verbs in relay.ps1'
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'docs' -Reviewer 'jack' } | Should -Throw "Plan refused: *reviewer 'jack'*"
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'reads the revision and the parts to change from the canonical copy, not from the room''s file' {
        $object = Resolve-RelayRoom $id
        [System.IO.File]::WriteAllText((Join-Path $room 'PLAN'), "plan: 99`ngoal: tampered`npart: evil | emma | done | - | - | Tampered`nend: 99`n")
        $output = @(& $setPlan -Room $id -Part 'tests' -Status 'doing')
        $output[0] | Should -Be "PLAN 2 for room ${id}: 3 part(s)"
        $text = Get-TestPlanLine $room
        $text[0] | Should -Be 'plan: 2'
        $text | Should -Contain 'goal: A team view for every agent'
        $text | Should -Not -Contain 'part: evil | emma | done | - | - | Tampered'
        $text[-1] | Should -Be 'end: 2'
        (Get-RelayFileHash (Join-Path $object.Canon 'PLAN')) | Should -Be (Get-RelayFileHash (Join-Path $room 'PLAN'))
    }

    It 'takes the revision of a whole plan from the canonical copy as well' {
        [System.IO.File]::WriteAllText((Join-Path $room 'PLAN'), "plan: 99`ngoal: tampered`nend: 99`n")
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan) 'again.json')
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 2'
    }

    It 'treats a room whose canonical copy has no plan as a room without a plan, whatever the room''s file says' {
        $object = Resolve-RelayRoom $id
        Remove-Item -LiteralPath (Join-Path $object.Canon 'PLAN') -Force
        { & $setPlan -Room $id -Part 'tests' -Status 'done' } | Should -Throw "Plan refused: room $id has no plan*"
    }
    It 'takes the part id as given and the owner in lower or upper case' {
        $null = & $setPlan -Room $id -Part 'tests' -Owner 'HENRY'
        (Get-TestPlanLine $room) | Should -Contain 'part: tests | henry | todo | tool-ps | - | Tests for both verbs'
    }
}

Describe 'Set-RelayPlan: -Show' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "show-$case"
        $id = "show-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
    }

    It 'prints NO PLAN when the room has no PLAN file, and writes nothing' {
        $before = Get-TestSnapshot $id
        $output = @(& $setPlan -Room $id -Show)
        $output | Should -Be @("NO PLAN in room $id")
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'prints NO PLAN when the PLAN file has no plan: line' {
        [System.IO.File]::WriteAllText((Join-Path $room 'PLAN'), "goal: nothing numbered`n")
        @(& $setPlan -Room $id -Show) | Should -Be @("NO PLAN in room $id")
    }

    It 'prints the PLAN file as it is, line by line, and changes nothing' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        $before = Get-TestSnapshot $id
        $output = @(& $setPlan -Room $id -Show)
        $output | Should -Be (Get-TestPlanLine $room)
        $output.Count | Should -Be 10
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'works in a closed room' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'CLOSED' "closed`n"
        @(& $setPlan -Room $id -Show)[0] | Should -Be 'plan: 1'
    }
}

Describe 'Set-RelayPlan: texts, lines in order, reserved seats' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "texts-$case"
        $id = "texts-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
    }

    It 'trims spaces and tabs from every text it writes' {
        $plan = [ordered]@{ goal = "  `tA goal`t "; parts = @([ordered]@{ id = ' one '; title = "`t Padded title  "; files = @(' x/y.txt '); notes = @("`tnote ") }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'trim.json')
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'goal: A goal'
        $text | Should -Contain 'part: one | - | todo | - | - | Padded title'
        $text | Should -Contain 'files: one | x/y.txt'
        $text | Should -Contain 'note: one | note'
        @($text | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
    }

    It 'counts characters, not UTF-16 units: a title of 120 characters outside the basic plane is allowed, 121 is not' {
        $face = [char]::ConvertFromUtf32(0x1F600)
        $plan = [ordered]@{ goal = 'Faces'; parts = @([ordered]@{ id = 'one'; title = ($face * 120) }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'faces.json')
        (Get-TestPlanLine $room) | Should -Contain ('part: one | - | todo | - | - | ' + ($face * 120))
        $before = Get-TestSnapshot $id
        $plan.parts[0].title = $face * 121
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'faces2.json') } | Should -Throw "Plan refused: *title*1 to 120*(it has 121)"
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'prints the LINE lines sorted by the first name, then the second, whatever the order of the parts' {
        $plan = [ordered]@{ goal = 'Order'; parts = @(
                [ordered]@{ id = 'a'; owner = 'jack'; reviewer = 'henry'; title = 'A' },
                [ordered]@{ id = 'b'; owner = 'jack'; reviewer = 'emma'; title = 'B' },
                [ordered]@{ id = 'c'; owner = 'henry'; reviewer = 'emma'; title = 'C' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'order.json'))
        @($output | Where-Object { $_ -like 'LINE*' }) | Should -Be @('LINE open between emma and henry', 'LINE open between emma and jack', 'LINE open between henry and jack')
    }

    It 'accepts the largest legal sizes: a goal of 200 characters, a title of 120, an id of 24 and the longest status'  {
        $plan = [ordered]@{ goal = ('g' * 200); parts = @([ordered]@{ id = ('a' * 24); title = ('t' * 120); status = 'blocked' }, [ordered]@{ id = ('0-9' * 8); title = 'Digits and hyphens' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'largest.json'))
        $output[0] | Should -Be "PLAN 1 for room ${id}: 2 part(s)"
        $text = Get-TestPlanLine $room
        $text[2] | Should -Be ('goal: ' + ('g' * 200))
        $text | Should -Contain ('part: ' + ('a' * 24) + ' | - | blocked | - | - | ' + ('t' * 120))
        $output[1] | Should -Be ('  ' + ('a' * 24) + '  blocked   ' + '-'.PadRight(9) + '  ' + ('t' * 120))
        $text | Should -Contain ('part: ' + ('0-9' * 8) + ' | - | todo | - | - | Digits and hyphens')
    }

    It 'prints the sorted LINE lines once each for pairs asked for several times and generated out of order' {
        $plan = [ordered]@{ goal = 'Order'; parts = @(
                [ordered]@{ id = 'a'; owner = 'jack'; reviewer = 'henry'; title = 'A' },
                [ordered]@{ id = 'b'; owner = 'henry'; depends = @('a'); reviewer = 'jack'; title = 'B' },
                [ordered]@{ id = 'c'; owner = 'jack'; depends = @('a', 'b'); title = 'C' },
                [ordered]@{ id = 'd'; owner = 'jack'; reviewer = 'emma'; title = 'D' },
                [ordered]@{ id = 'e'; owner = 'henry'; reviewer = 'emma'; title = 'E' },
                [ordered]@{ id = 'f'; owner = 'emma'; depends = @('e'); title = 'F' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'dupes.json'))
        @($output | Where-Object { $_ -like 'LINE*' }) | Should -Be @('LINE open between emma and henry', 'LINE open between emma and jack', 'LINE open between henry and jack')
        Get-TestLine $room 'jack' | Should -Be @('emma', 'henry')
    }
    It 'lets a part be reserved for a seat nobody has taken yet, and opens its lines' {
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -OpenSeats 1 -NoClipboard
        $seat = @(Get-RelayTestOpenSeat $room)[0]
        $plan = [ordered]@{ goal = 'Reserved'; parts = @([ordered]@{ id = 'a'; owner = $seat; reviewer = 'emma'; title = 'For the next agent' }) }
        $output = @(& $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'reserved.json'))
        (Get-TestPlanLine $room) | Should -Contain "part: a | $seat | todo | - | emma | For the next agent"
        $names = @($seat, 'emma') | Sort-Object
        $output | Should -Contain "LINE open between $($names[0]) and $($names[1])"
        Get-TestLine $room $seat | Should -Be @('emma')
        Get-TestLine $room 'emma' | Should -Be @($seat)
        $null = & $setPlan -Room $id -Part 'a' -Status 'doing'
        (Get-TestPlanLine $room) | Should -Contain "part: a | $seat | doing | - | emma | For the next agent"
    }
}

Describe 'Set-RelayPlan: the plan it reads' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "reads-$case"
        $id = "reads-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $canon = Join-Path (Resolve-RelayRoom $id).Canon 'PLAN'
        $file = Save-TestPlan $root (Get-TestPlan)
    }

    It 'refuses a part change when the canonical copy has no end: line, and writes nothing' -ForEach @(
        @{ Name = 'no end: line'; Text = "plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | A`n" }
        @{ Name = 'an end: line of another revision'; Text = "plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 2`n" }
        @{ Name = 'an empty file'; Text = '' }
        @{ Name = 'a plan: line that is not a number'; Text = "plan: three`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: three`n" }
        @{ Name = 'a files: line for a part that does not exist'; Text = "plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | A`nfiles: ghost | x`nend: 3`n" }
    ) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        [System.IO.File]::WriteAllText($canon, $Text)
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Status 'done' } | Should -Throw "Plan refused: the plan of room $id cannot be read; write it again with -PlanFile"
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'takes the revision for a whole plan from the plan: line of a copy it cannot read as a whole, else starts at 1' -ForEach @(
        @{ Text = "plan: 7`ngoal: A goal`n"; Revision = 8 }
        @{ Text = "plan: 5`ngoal: A goal`nend: 4`n"; Revision = 6 }
        @{ Text = "plan: three`ngoal: A goal`n"; Revision = 1 }
        @{ Text = ''; Revision = 1 }
    ) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        [System.IO.File]::WriteAllText($canon, $Text)
        $output = @(& $setPlan -Room $id -PlanFile $file)
        $output[0] | Should -Be "PLAN $Revision for room ${id}: 3 part(s)"
        (Get-TestPlanLine $room)[0] | Should -Be "plan: $Revision"
        (Get-TestPlanLine $room)[-1] | Should -Be "end: $Revision"
    }

    It 'refuses every write when the revision counter is used up (revision 999999999 in the canonical copy), and writes nothing' -ForEach @(
        @{ Name = 'a whole plan'; Text = "plan: 999999999`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 999999999`n"; Arguments = @{ PlanFile = 'plan.json' } }
        @{ Name = 'a part change'; Text = "plan: 999999999`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 999999999`n"; Arguments = @{ Part = 'a'; Status = 'done' } }
        @{ Name = 'a whole plan over a copy it cannot read'; Text = "plan: 999999999`ngoal: A goal`n"; Arguments = @{ PlanFile = 'plan.json' } }
        @{ Name = 'a whole plan over a counter of ten digits'; Text = "plan: 1234567890`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 1234567890`n"; Arguments = @{ PlanFile = 'plan.json' } }
        @{ Name = 'a part change over a counter of ten digits'; Text = "plan: 1234567890`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 1234567890`n"; Arguments = @{ Part = 'a'; Status = 'done' } }
        @{ Name = 'a whole plan over a counter of thirty digits without an end line'; Text = ("plan: " + ('9' * 30) + "`ngoal: A goal`n"); Arguments = @{ PlanFile = 'plan.json' } }
        @{ Name = 'a part change over a counter of ten digits without an end line'; Text = "plan: 1000000000`ngoal: A goal`npart: a | emma | todo | - | - | A`n"; Arguments = @{ Part = 'a'; Status = 'done' } }
        @{ Name = 'a part change over a counter with leading zeros that is still 999999999'; Text = "plan: 0999999999`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 0999999999`n"; Arguments = @{ Part = 'a'; Status = 'done' } }
    ) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        [System.IO.File]::WriteAllText($canon, $Text)
        $arguments = $Arguments
        if ($arguments.ContainsKey('PlanFile')) { $arguments['PlanFile'] = $file }
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id @arguments } | Should -Throw "Plan refused: the revision counter of room $id is used up"
        Get-TestSnapshot $id | Should -Be $before
        Test-Path -LiteralPath (Join-Path $room 'PLAN') | Should -BeFalse
    }

    It 'still writes revision 999999999 itself: the last revision before the counter is used up' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        [System.IO.File]::WriteAllText($canon, "plan: 999999998`ngoal: A goal`npart: a | emma | todo | - | - | A`nend: 999999998`n")
        $null = & $setPlan -Room $id -Part 'a' -Status 'done'
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 999999999'
        (Get-TestPlanLine $room)[-1] | Should -Be 'end: 999999999'
    }
    It 'ignores a second part line with an id already seen, and a number with leading zeros counts as that number' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        [System.IO.File]::WriteAllText($canon, "plan: 0004`ngoal: A goal`npart: a | emma | todo | - | - | A`npart: a | jack | done | - | - | Second`nend: 4`n")
        $null = & $setPlan -Room $id -Part 'a' -Status 'doing'
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'part: a | emma | doing | - | - | A'
        @($text | Where-Object { $_ -like 'part:*' }).Count | Should -Be 1
        $text[0] | Should -Be 'plan: 5'
    }

    It 'refuses a part change when the plan it keeps breaks a rule of the writer: <Name>, and writes nothing' -ForEach @(
        @{ Name = 'a title with a bar'; Part = 'part: b | emma | todo | - | - | A | with bar'; Match = "*part 'b' title*bar*" }
        @{ Name = 'an id with an underscore'; Part = 'part: bad_id | emma | todo | - | - | Fine'; Match = "*part 'bad_id' id*" }
        @{ Name = 'an id of 25 characters'; Part = ('part: ' + ('x' * 25) + ' | emma | todo | - | - | Fine'); Match = '*id*1 to 24*' }
        @{ Name = 'a status that is not one of the five'; Part = 'part: b | emma | finished | - | - | Fine'; Match = "*part 'b'*status 'finished'*" }
        @{ Name = 'a title with a tab inside'; Part = "part: b | emma | todo | - | - | A`tB"; Match = "*part 'b' title*control character*" }
        @{ Name = 'a title of 121 characters'; Part = ('part: b | emma | todo | - | - | ' + ('t' * 121)); Match = "*part 'b' title*1 to 120*" }
        @{ Name = 'a depends entry for a part that does not exist'; Part = 'part: b | emma | todo | ghost | - | Fine'; Match = "*part 'b' depends on 'ghost'*" }
        @{ Name = 'the same owner and reviewer'; Part = 'part: b | emma | todo | - | emma | Fine'; Match = "*part 'b'*owner and as reviewer*" }
    ) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $canon) -Force | Out-Null
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'PLAN' ("plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | Fine`n$Part`nend: 3`n")
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Status 'done' } | Should -Throw ('Plan refused: ' + $Match)
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a part change when a retained note or files entry is longer than 300 characters or holds a control character' -ForEach @(
        @{ Line = ('note: a | ' + ('n' * 301)); Match = '*note*1 to 300*' }
        @{ Line = ('files: a | ' + ('f' * 301)); Match = '*files entry*1 to 300*' }
        @{ Line = "note: a | one`ttwo"; Match = '*note*control character*' }
    ) {
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'PLAN' ("plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | Fine`n$Line`nend: 3`n")
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Status 'done' } | Should -Throw ('Plan refused: ' + $Match)
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'does not take the later line when the first of two equal keys is bad: <Name>' -ForEach @(
        @{ Name = 'an empty first goal'; Text = "plan: 3`ngoal: `ngoal: A second goal`npart: a | emma | todo | - | - | Fine`nend: 3`n"; Match = '*goal*1 to 200*' }
        @{ Name = 'a first plan: line that is no number'; Text = "plan: abc`nplan: 7`ngoal: A goal`npart: a | emma | todo | - | - | Fine`nend: 7`n"; Match = '*cannot be read*' }
        @{ Name = 'a first end: line that is no number'; Text = "plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | Fine`nend: x`nend: 3`n"; Match = '*cannot be read*' }
        @{ Name = 'a first end: line of another revision'; Text = "plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | Fine`nend: 2`nend: 3`n"; Match = '*cannot be read*' }
        @{ Name = 'digits of another script in plan: and end:'; Text = ("plan: " + [char]0x0663 + "`ngoal: A goal`npart: a | emma | todo | - | - | Fine`nend: " + [char]0x0663 + "`n"); Match = '*cannot be read*' }
        @{ Name = 'digits of another script only in end:'; Text = ("plan: 3`ngoal: A goal`npart: a | emma | todo | - | - | Fine`nend: " + [char]0x0663 + "`n"); Match = '*cannot be read*' }
    ) {
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'PLAN' $Text
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Status 'done' } | Should -Throw ('Plan refused: ' + $Match)
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'starts again at 1 over a plan: line that holds no number of the digits 0 to 9, whatever a later line holds' -ForEach @(
        @{ Text = "plan: abc`nplan: 7`ngoal: A goal`n" }
        @{ Text = ("plan: " + [char]0x0663 + "`ngoal: A goal`nend: " + [char]0x0663 + "`n") }
        @{ Text = ("plan: " + [char]0x0661 + [char]0x0662 + "`ngoal: A goal`n") }
    ) {
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'PLAN' $Text
        $output = @(& $setPlan -Room $id -PlanFile $file)
        $output[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 1'
    }
    It 'keeps a retained owner who has retired, as long as the call does not set the name' {
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'PLAN' "plan: 3`ngoal: A goal`npart: a | zed | todo | - | - | Fine`npart: b | emma | todo | - | - | Fine too`nend: 3`n"
        $null = & $setPlan -Room $id -Part 'b' -Status 'done'
        (Get-TestPlanLine $room) | Should -Contain 'part: a | zed | todo | - | - | Fine'
    }}

Describe 'Set-RelayPlan: one writer at a time' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "mutex-$case"
        $id = "mutex-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $file = Save-TestPlan $root (Get-TestPlan)
        $name = "Global\agent-relay-plan-$id"
    }

    It 'refuses after 30 seconds when another call holds the room''s mutex, writes nothing, and works once it is free' {
        $holder = Lock-TestMutex $name
        try {
            $before = Get-TestSnapshot $id
            $started = Get-Date
            { & $setPlan -Room $id -PlanFile $file } | Should -Throw "Plan refused: another Set-RelayPlan is running for room $id"
            ((Get-Date) - $started).TotalSeconds | Should -BeGreaterOrEqual 29
            ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 50
            Get-TestSnapshot $id | Should -Be $before
        }
        finally { Unlock-TestMutex $holder }
        @(& $setPlan -Room $id -PlanFile $file)[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)"
    }

    It 'does not wait for the mutex of another room' {
        $holder = Lock-TestMutex 'Global\agent-relay-plan-some-other-room'
        try { @(& $setPlan -Room $id -PlanFile $file)[0] | Should -Be "PLAN 1 for room ${id}: 3 part(s)" }
        finally { Unlock-TestMutex $holder }
    }

    It 'lets go of the mutex after a plan, after a part change, after -WhatIf and after a refusal' {
        $null = & $setPlan -Room $id -PlanFile $file
        Test-TestMutexFree $name | Should -BeTrue
        $null = & $setPlan -Room $id -Part 'tests' -Status 'doing'
        Test-TestMutexFree $name | Should -BeTrue
        $null = & $setPlan -Room $id -Part 'tests' -Status 'done' -WhatIf
        Test-TestMutexFree $name | Should -BeTrue
        { & $setPlan -Room $id -Part 'ghost' -Status 'done' } | Should -Throw 'Plan refused: *'
        Test-TestMutexFree $name | Should -BeTrue
        { & $setPlan -Room $id -PlanFile (Join-Path $root 'missing.json') } | Should -Throw 'Plan refused: *'
        Test-TestMutexFree $name | Should -BeTrue
    }

    It 'does not take the mutex for -Show' {
        $null = & $setPlan -Room $id -PlanFile $file
        $holder = Lock-TestMutex $name
        try { @(& $setPlan -Room $id -Show)[0] | Should -Be 'plan: 1' }
        finally { Unlock-TestMutex $holder }
    }
}
Describe 'Set-RelayPlan: the limits of the writer''s texts' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "limits-$case"
        $id = "limits-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
    }

    It 'allows a files entry and a note of 300 characters and refuses 301' {
        $plan = [ordered]@{ goal = 'Limits'; parts = @([ordered]@{ id = 'a'; title = 'A'; files = @('f' * 300); notes = @('n' * 300) }) }
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'ok.json')
        (Get-TestPlanLine $room) | Should -Contain ('files: a | ' + ('f' * 300))
        (Get-TestPlanLine $room) | Should -Contain ('note: a | ' + ('n' * 300))
        $null = & $setPlan -Room $id -Part 'a' -Note ('m' * 300)
        (Get-TestPlanLine $room) | Should -Contain ('note: a | ' + ('m' * 300))
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Note ('m' * 301) } | Should -Throw '*note*1 to 300*(it has 301)'
        $plan.parts[0].files = @('f' * 301)
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'files.json') } | Should -Throw '*files entry*1 to 300*(it has 301)'
        $plan.parts[0].files = @('f'); $plan.parts[0].notes = @('n' * 301)
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'notes.json') } | Should -Throw '*note*1 to 300*(it has 301)'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a tab inside a text, in every field, and writes nothing' -ForEach @(
        @{ Field = 'goal' }, @{ Field = 'title' }, @{ Field = 'file' }, @{ Field = 'note' }, @{ Field = 'owner' }
    ) {
        $plan = [ordered]@{ goal = 'Tabs'; parts = @([ordered]@{ id = 'a'; title = 'A'; files = @('f'); notes = @('n') }) }
        switch ($Field) {
            'goal' { $plan.goal = "a`tb" }
            'title' { $plan.parts[0].title = "a`tb" }
            'file' { $plan.parts[0].files = @("a`tb") }
            'note' { $plan.parts[0].notes = @("a`tb") }
            'owner' { $plan.parts[0].owner = "em`tma" }
        }
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'tabs.json') } | Should -Throw 'Plan refused: *'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a control character of the C1 range and a Unicode line separator in every text, and writes nothing' -ForEach @(
        @{ Field = 'goal'; Char = 0x0085 }, @{ Field = 'goal'; Char = 0x009F }, @{ Field = 'title'; Char = 0x0085 }, @{ Field = 'title'; Char = 0x009F }
        @{ Field = 'file'; Char = 0x0080 }, @{ Field = 'note'; Char = 0x0085 }, @{ Field = 'title'; Char = 0x2028 }, @{ Field = 'note'; Char = 0x2029 }
    ) {
        $plan = [ordered]@{ goal = 'C1'; parts = @([ordered]@{ id = 'a'; title = 'A'; files = @('f'); notes = @('n') }) }
        $bad = 'a' + [char]$Char + 'b'
        switch ($Field) {
            'goal' { $plan.goal = $bad }
            'title' { $plan.parts[0].title = $bad }
            'file' { $plan.parts[0].files = @($bad) }
            'note' { $plan.parts[0].notes = @($bad) }
        }
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'c1.json') } | Should -Throw 'Plan refused: *'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a note with a control character of the C1 range through -Part' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root ([ordered]@{ goal = 'C1'; parts = @([ordered]@{ id = 'a'; title = 'A' }) }))
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Note ('a' + [char]0x0085 + 'b') } | Should -Throw '*note*control character*'
        Get-TestSnapshot $id | Should -Be $before
    }
    It 'refuses a note with a tab inside through -Part' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root ([ordered]@{ goal = 'Tabs'; parts = @([ordered]@{ id = 'a'; title = 'A' }) }))
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'a' -Note "a`tb" } | Should -Throw '*note*control character*'
        Get-TestSnapshot $id | Should -Be $before
    }
}
Describe 'Set-RelayPlan: a plan that is refused' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "refuse-$case"
        $id = "refuse-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
    }

    It 'refuses <Name> and leaves a room without a plan as it was' -ForEach @(
        @{ Name = 'an empty goal'; Patch = { param($p) $p.goal = '' }; Match = '*goal*' }
        @{ Name = 'a goal of 201 characters'; Patch = { param($p) $p.goal = 'g' * 201 }; Match = '*goal*1 to 200*' }
        @{ Name = 'a missing goal'; Patch = { param($p) $p.Remove('goal') }; Match = '*goal*' }
        @{ Name = 'a goal with a bar'; Patch = { param($p) $p.goal = 'a | b' }; Match = '*goal*bar*' }
        @{ Name = 'a goal with a line break'; Patch = { param($p) $p.goal = "a`nb" }; Match = '*goal*line break*' }
        @{ Name = 'a title of blanks only'; Patch = { param($p) $p.parts[1].title = "  	 " }; Match = "*part 'tests' title*1 to 120*" }
        @{ Name = 'an empty title'; Patch = { param($p) $p.parts[1].title = '' }; Match = "*part 'tests' title*" }
        @{ Name = 'a title of 121 characters'; Patch = { param($p) $p.parts[1].title = 't' * 121 }; Match = "*part 'tests' title*1 to 120*" }
        @{ Name = 'a title with a bar'; Patch = { param($p) $p.parts[1].title = 'a|b' }; Match = "*part 'tests' title*bar*" }
        @{ Name = 'a title with a line break'; Patch = { param($p) $p.parts[1].title = "a`r`nb" }; Match = "*part 'tests' title*line break*" }
        @{ Name = 'a files entry with a bar'; Patch = { param($p) $p.parts[0].files = @('a | b') }; Match = '*files entry*bar*' }
        @{ Name = 'a note with a line break'; Patch = { param($p) $p.parts[0].notes = @("a`nb") }; Match = '*note*line break*' }
        @{ Name = 'a note with a bar'; Patch = { param($p) $p.parts[0].notes = @('a|b') }; Match = '*note*bar*' }
        @{ Name = 'a files entry with a line break'; Patch = { param($p) $p.parts[0].files = @("a`nb") }; Match = '*files entry*line break*' }
        @{ Name = 'a lone carriage return in a title'; Patch = { param($p) $p.parts[1].title = "a`rb" }; Match = '*title*line break*' }
        @{ Name = 'a lone line feed in a goal'; Patch = { param($p) $p.goal = "a`nb" }; Match = '*goal*line break*' }
        @{ Name = 'a depends entry with a bar'; Patch = { param($p) $p.parts[1].depends = @('tool-ps|x') }; Match = '*depends entry*bar*' }
        @{ Name = 'an id with an underscore'; Patch = { param($p) $p.parts[1].id = 'a_b' }; Match = "*part 'a_b' id*" }
        @{ Name = 'an id with a dot'; Patch = { param($p) $p.parts[1].id = 'a.b' }; Match = "*part 'a.b' id*" }
        @{ Name = 'an id with a capital'; Patch = { param($p) $p.parts[1].id = 'Tests' }; Match = "*part 'Tests' id*" }
        @{ Name = 'an id with a space'; Patch = { param($p) $p.parts[1].id = 'a b' }; Match = "*part 'a b' id*" }
        @{ Name = 'an id of 25 characters'; Patch = { param($p) $p.parts[1].id = 'a' * 25 }; Match = '*id*1 to 24*' }
        @{ Name = 'a missing id'; Patch = { param($p) $p.parts[1].Remove('id') }; Match = '*part #2 id*' }
        @{ Name = 'an id that is not text'; Patch = { param($p) $p.parts[1].id = 5 }; Match = '*part #2 id*text*' }
        @{ Name = 'a part id used twice'; Patch = { param($p) $p.parts[2].id = 'tool-ps' }; Match = "*'tool-ps' is used twice*" }
        @{ Name = 'a status that is not one of the five'; Patch = { param($p) $p.parts[1].status = 'finished' }; Match = "*part 'tests'*status 'finished'*todo, doing, review, done, blocked*" }
        @{ Name = 'a status in capitals'; Patch = { param($p) $p.parts[1].status = 'Done' }; Match = "*part 'tests'*status 'Done'*" }
        @{ Name = 'an owner who is not in the room'; Patch = { param($p) $p.parts[1].owner = 'nobody' }; Match = "*part 'tests' owner 'nobody' is not an agent of this room*" }
        @{ Name = 'a reviewer who is not in the room'; Patch = { param($p) $p.parts[0].reviewer = 'zoe' }; Match = "*part 'tool-ps' reviewer 'zoe'*" }
        @{ Name = 'a retired owner'; Patch = { param($p) $p.parts[1].owner = 'zed' }; Match = "*owner 'zed'*" }
        @{ Name = 'the owner as reviewer of the same part'; Patch = { param($p) $p.parts[0].reviewer = 'emma' }; Match = "*part 'tool-ps'*emma*owner and as reviewer*" }
        @{ Name = 'a dependency that is not a part'; Patch = { param($p) $p.parts[1].depends = @('ghost') }; Match = "*part 'tests' depends on 'ghost'*not a part*" }
        @{ Name = 'a part that depends on itself'; Patch = { param($p) $p.parts[1].depends = @('tests') }; Match = "*part 'tests' depends on itself*" }
        @{ Name = 'a circle of two parts'; Patch = { param($p) $p.parts[0].depends = @('tests') }; Match = '*circle*' }
        @{ Name = 'a circle of three parts'; Patch = { param($p) $p.parts[0].depends = @('docs') }; Match = '*circle*tool-ps*' }
        @{ Name = 'the same files entry for two parts'; Patch = { param($p) $p.parts[1].files = @('skills/agent-relay/assets/room-package/tools/relay.ps1') }; Match = "*files entry*'tool-ps'*'tests'*" }
        @{ Name = 'the same files entry in other case for two parts'; Patch = { param($p) $p.parts[1].files = @('SKILLS/Agent-Relay/assets/room-package/tools/RELAY.PS1') }; Match = '*files entry*' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $room 'agents\zed') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\zed\retired'), "retired_utc: 2026-10-10T00:00:00Z`n")
        $plan = Get-TestPlan
        & $Patch $plan
        $file = Save-TestPlan $root $plan 'refused.json'
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile $file } | Should -Throw ('Plan refused: ' + $Match)
        Get-TestSnapshot $id | Should -Be $before
        Test-Path -LiteralPath (Join-Path $room 'PLAN') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path (Resolve-RelayRoom $id).Canon 'PLAN') | Should -BeFalse
    }

    It 'refuses a plan and leaves the plan the room has, its copy and the lines as they were' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        $before = Get-TestSnapshot $id
        $plan = Get-TestPlan
        $plan.parts[2].depends = @('docs')
        $plan.parts[2].owner = 'henry'
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'worse.json') } | Should -Throw 'Plan refused: *'
        Get-TestSnapshot $id | Should -Be $before
        (Get-TestPlanLine $room)[0] | Should -Be 'plan: 1'
    }

    It 'refuses a plan whose fault is in the last part, before the first part opens a line' {
        $plan = Get-TestPlan
        $plan.parts[2].status = 'finished'
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root $plan 'last.json') } | Should -Throw 'Plan refused: *'
        Get-TestSnapshot $id | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $room 'agents\emma\lines') -Raw) | Should -BeNullOrEmpty
    }

    It 'refuses a plan file that does not exist' {
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile (Join-Path $root 'missing.json') } | Should -Throw 'Plan refused: there is no plan file*'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a plan file that is not JSON, or not one object' {
        $before = Get-TestSnapshot $id
        $broken = Join-Path $root 'broken.json'
        [System.IO.File]::WriteAllText($broken, '{ "goal": "x", ')
        { & $setPlan -Room $id -PlanFile $broken } | Should -Throw 'Plan refused: the plan file is not valid JSON*'
        $list = Join-Path $root 'list.json'
        [System.IO.File]::WriteAllText($list, '[1, 2]')
        { & $setPlan -Room $id -PlanFile $list } | Should -Throw 'Plan refused: the plan file must hold one JSON object*'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a plan in a closed room' {
        Write-RelayGuardedText (Resolve-RelayRoom $id) 'CLOSED' "closed`n"
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan)) } | Should -Throw 'Plan refused: the room * is closed'
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses a room that does not exist' {
        { & $setPlan -Room 'no-such-room' -Show } | Should -Throw '*No room*'
    }
}

Describe 'Set-RelayPlan: a part change that is refused' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "partrefuse-$case"
        $id = "partrefuse-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
    }

    It 'refuses a part change in a room without a plan and writes nothing' {
        $before = Get-TestSnapshot $id
        { & $setPlan -Room $id -Part 'tests' -Status 'done' } | Should -Throw "Plan refused: room $id has no plan*"
        Get-TestSnapshot $id | Should -Be $before
    }

    It 'refuses <Name> and leaves the plan, its copy and the lines as they were' -ForEach @(
        @{ Name = 'a part that is not in the plan'; Arguments = @{ Part = 'ghost'; Status = 'done' }; Match = "*no part 'ghost'*" }
        @{ Name = 'no change at all'; Arguments = @{ Part = 'tests' }; Match = '*at least one of*' }
        @{ Name = 'a status that is not one of the five'; Arguments = @{ Part = 'tests'; Status = 'finished' }; Match = "*status 'finished'*" }
        @{ Name = 'an owner who is not in the room'; Arguments = @{ Part = 'tests'; Owner = 'zoe' }; Match = "*owner 'zoe'*" }
        @{ Name = 'a reviewer who is not in the room'; Arguments = @{ Part = 'tests'; Reviewer = 'zoe' }; Match = "*reviewer 'zoe'*" }
        @{ Name = 'a reviewer who is the owner'; Arguments = @{ Part = 'tests'; Reviewer = 'jack' }; Match = "*part 'tests'*owner and as reviewer*" }
        @{ Name = 'an owner who is the reviewer'; Arguments = @{ Part = 'tool-ps'; Owner = 'henry' }; Match = "*part 'tool-ps'*owner and as reviewer*" }
        @{ Name = 'a note with a bar'; Arguments = @{ Part = 'tests'; Note = 'a | b' }; Match = '*note*bar*' }
        @{ Name = 'a note with a line break'; Arguments = @{ Part = 'tests'; Note = "a`nb" }; Match = '*note*line break*' }
        @{ Name = 'a good change next to a bad one'; Arguments = @{ Part = 'tests'; Status = 'done'; Reviewer = 'jack' }; Match = '*owner and as reviewer*' }
    ) {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        $before = Get-TestSnapshot $id
        $arguments = $Arguments
        { & $setPlan -Room $id @arguments } | Should -Throw ('Plan refused: ' + $Match)
        Get-TestSnapshot $id | Should -Be $before
    }
}

Describe 'Set-RelayPlan: what the board, the feed and the tamper check make of the plan' -Tag 'Plan' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "board-$case"
        $id = "board-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $object = Resolve-RelayRoom $id
        $boardScript = Join-Path $scripts 'Get-RelayBoard.ps1'
        # A plan the way a person might write it by hand: in the room and in this PC's copy
        $header = "plan: 3`nupdated_utc: 2026-10-10T08:15:00Z`ngoal: A goal`n"
        $esc = [string][char]27
    }

    It 'counts the parts of an owner written in another case for that agent on the board, a to z only' {
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | Lower`npart: b | Emma | todo | - | - | Capital`npart: c | EMMA | todo | - | - | Shouting`npart: d | Zoe | todo | - | - | Nobody here`npart: e | " + [char]0x00C9 + "mma | todo | - | - | Not a to z`nend: 3`n")
        $board = Get-RelayBoard $object
        @(@($board.agents | Where-Object { $_.name -eq 'emma' })[0].parts) | Should -Be @('a', 'b', 'c')
        @(@($board.agents | Where-Object { $_.name -eq 'jack' })[0].parts).Count | Should -Be 0
        ((& $boardScript -Room $id) -join "`n") | Should -Match '(?m)^ {13}parts: a, b, c$'
    }

    It 'prints no line that ends in a blank, on the board and in the feed, also for a part without a title' {
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | `npart: b | jack | doing | - | - |    `npart: c | henry | done | - | - | With title`nend: 3`n")
        $text = @(& $boardScript -Room $id)
        @($text | Where-Object { $_ -match '^PLAN 3' }).Count | Should -Be 1
        @($text | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
        $text | Should -Contain '  a             todo      emma'
        $feed = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments @('-Room', $id, '-Follow', '-Once', '-NoHeartbeat', '-NoTamperCheck')
        $feed.ExitCode | Should -Be 0 -Because $feed.Error
        $feedLines = @($feed.Output -split "`n")
        @($feedLines | Where-Object { $_ -match '^  PLAN 3' }).Count | Should -Be 1
        @($feedLines | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
        $feedLines | Should -Contain '    a             todo      emma'
    }

    It 'keeps the status of every row in one column on the board and in the feed when an id is longer than 12, and keeps 12 for short ids' {
        $feedArguments = @('-Room', $id, '-Follow', '-Once', '-NoHeartbeat', '-NoTamperCheck')
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | Short`npart: a-rather-long-id | jack | doing | - | - | Long`nend: 3`n")
        $text = @(& $boardScript -Room $id)
        $text | Should -Contain ('  ' + 'a'.PadRight(16) + '  todo      emma       Short')
        $text | Should -Contain ('  ' + 'a-rather-long-id'.PadRight(16) + '  doing     jack       Long')
        $feed = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments $feedArguments
        $feed.ExitCode | Should -Be 0 -Because $feed.Error
        $feedLines = @($feed.Output -split "`n")
        $feedLines | Should -Contain ('    ' + 'a'.PadRight(16) + '  todo      emma       Short')
        $feedLines | Should -Contain ('    ' + 'a-rather-long-id'.PadRight(16) + '  doing     jack       Long')
        # Short ids only: as before, 12 columns
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | Short`npart: twelve-chars | jack | doing | - | - | Twelve`nend: 3`n")
        $text = @(& $boardScript -Room $id)
        $text | Should -Contain '  a             todo      emma       Short'
        $text | Should -Contain '  twelve-chars  doing     jack       Twelve'
        $feed = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments $feedArguments
        @($feed.Output -split "`n") | Should -Contain '    a             todo      emma       Short'
    }

    It 'marks a plan caught half written on the board with the new text' {
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | A`n")
        $line = @(& $boardScript -Room $id | Where-Object { $_ -like 'PLAN *' })[0]
        $line | Should -Be 'PLAN 3, 2026-10-10T08:15:00Z: A goal   [INCOMPLETE: read again in a second; if it stays, write it again with Set-RelayPlan.ps1]'
    }

    It 'replaces every control character from a room file by a blank in what is printed for reading, and keeps JSON escaped' {
        Write-RelayGuardedText $object 'PLAN' ("plan: 3`nupdated_utc: 2026-10-10T08:15:00Z`ngoal: Goal${esc}[31m red`npart: a | emma | to" + [char]7 + "do | - | - | Ti${esc}tle" + [char]127 + "x`nend: 3`n")
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\jack\progress'), "2026-10-10T08:20:00Z | said${esc}[2Jhello" + [char]1 + "`n")
        $text = @(& $boardScript -Room $id)
        @($text | Where-Object { $_ -match '[\x00-\x1f\x7f]' }).Count | Should -Be 0
        $text | Should -Contain 'PLAN 3, 2026-10-10T08:15:00Z: Goal [31m red'
        $text | Should -Contain '  a             to do     emma       Ti tle x'
        @($text | Where-Object { $_ -like '*progress: said*' })[0] | Should -Be '             progress: said [2Jhello   (2026-10-10T08:20:00Z)'
        $feed = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments @('-Room', $id, '-Follow', '-Once', '-NoHeartbeat', '-NoTamperCheck')
        @($feed.Output -split "`n" | Where-Object { $_ -match '[\x00-\x1f\x7f]' }).Count | Should -Be 0
        $feed.Output | Should -Match '(?m)^  PLAN 3: Goal \[31m red$'
        # JSON escapes instead: one line, ASCII, the control characters as \u escapes
        $json = (& $boardScript -Room $id -AsJson)
        $json | Should -Match '^[\x20-\x7E]+$'
        $json | Should -Match '\\u001b'
        $jsonFeed = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments @('-Room', $id, '-Json', '-Once', '-NoHeartbeat', '-NoTamperCheck')
        $jsonFeed.Output | Should -Match '\\u001b'
        @($jsonFeed.Output -split "`n" | Where-Object { $_ -match '[\x00-\x1f\x7f]' }).Count | Should -Be 0
    }

    It 'takes a PLAN, a CLOSED marker or a TRANSCRIPT.md that has no copy on this PC for a file that does not belong: <Name>' -ForEach @(
        @{ Name = 'PLAN'; Alarm = 'TAMPER extra moved out: PLAN' }
        @{ Name = 'CLOSED'; Alarm = 'TAMPER extra moved out: CLOSED' }
        @{ Name = 'TRANSCRIPT.md'; Alarm = 'TAMPER extra moved out: TRANSCRIPT.md' }
    ) {
        [System.IO.File]::WriteAllText((Join-Path $room $Name), "plan: 1`nend: 1`n")
        $found = @(Test-RelayTamper $object)
        $found.Count | Should -Be 1
        $found[0].Relative | Should -Be $Name
        $found[0].Kind | Should -Be 'extra'
        Test-Path -LiteralPath (Join-Path $room $Name) | Should -BeTrue
        $repaired = @(Test-RelayTamper $object -Repair)
        $repaired.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $room $Name) | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $object.Local 'quarantine') -File | Where-Object { $_.Name -like "*-$Name" }).Count | Should -Be 1
        ((Get-Content -LiteralPath (Join-Path $object.Local 'alarms.log')) -join "`n") | Should -Match ([regex]::Escape($Alarm))
        @(Test-RelayTamper $object).Count | Should -Be 0
    }

    It 'does not take for a stranger a PLAN, a CLOSED marker or a TRANSCRIPT.md that this PC wrote first' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        Write-RelayGuardedText $object 'TRANSCRIPT.md' "# Transcript`n"
        Write-RelayGuardedText $object 'CLOSED' "closed_utc: 2026-10-10T09:00:00Z`nby: olivia`n"
        @(Test-RelayTamper (Resolve-RelayRoom $id) -Repair).Count | Should -Be 0
        foreach ($name in 'PLAN', 'CLOSED', 'TRANSCRIPT.md') { Test-Path -LiteralPath (Join-Path $room $name) | Should -BeTrue -Because $name }
    }

    It 'still restores a PLAN that was changed after this PC wrote it' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        $good = Get-RelayFileHash (Join-Path $room 'PLAN')
        [System.IO.File]::AppendAllText((Join-Path $room 'PLAN'), "part: evil | emma | done | - | - | Forged`n")
        $found = @(Test-RelayTamper $object -Repair)
        $found.Count | Should -Be 1
        $found[0].Kind | Should -Be 'changed'
        Get-RelayFileHash (Join-Path $room 'PLAN') | Should -Be $good
    }

    It 'marks on the board a plan that differs from this PC''s copy, byte for byte, or has no copy' {
        $null = & $setPlan -Room $id -PlanFile (Save-TestPlan $root (Get-TestPlan))
        (Get-RelayBoard $object).plan.differs | Should -BeFalse
        @(& $boardScript -Room $id | Where-Object { $_ -like '*DIFFERS*' }).Count | Should -Be 0
        # Changed in the room by one byte: the copy is still the good one
        [System.IO.File]::AppendAllText((Join-Path $room 'PLAN'), "`n")
        (Get-RelayBoard $object).plan.differs | Should -BeTrue
        $line = @(& $boardScript -Room $id | Where-Object { $_ -like 'PLAN *' })[0]
        $line | Should -Match '^PLAN 1, \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z: A team view for every agent   \[DIFFERS FROM THE COPY ON THIS PC: the feed puts it back\]$'
        ((& $boardScript -Room $id -AsJson)) | Should -Match '"differs":true'
        # No copy at all
        [System.IO.File]::Delete((Join-Path $object.Canon 'PLAN'))
        (Get-RelayBoard $object).plan.differs | Should -BeTrue
        # Both marks, the half written one first
        Write-RelayGuardedText $object 'PLAN' ($header + "part: a | emma | todo | - | - | A`n")
        [System.IO.File]::AppendAllText((Join-Path $room 'PLAN'), "x`n")
        @(& $boardScript -Room $id | Where-Object { $_ -like 'PLAN *' })[0] | Should -Match '   \[INCOMPLETE: read again in a second; if it stays, write it again with Set-RelayPlan\.ps1\]   \[DIFFERS FROM THE COPY ON THIS PC: the feed puts it back\]$'
    }

    It 'does not mark a room without a plan as differing' {
        (Get-RelayBoard $object).plan | Should -BeNullOrEmpty
        @(& $boardScript -Room $id | Where-Object { $_ -like '*DIFFERS*' }).Count | Should -Be 0
    }

    It 'takes what follows part:, files: or note: as the value with or without a blank after the colon' {
        Write-RelayGuardedText $object 'PLAN' "plan: 3`nupdated_utc: 2026-10-10T08:15:00Z`ngoal: G`npart:a | emma | todo | - | - | X`nfiles:a | f/one`nnote:a | n one`nend: 3`n"
        $part = @((Get-RelayBoard $object).plan.parts)
        $part.Count | Should -Be 1
        $part[0].id | Should -Be 'a'
        @($part[0].files) | Should -Be @('f/one')
        @($part[0].notes) | Should -Be @('n one')
        $null = & $setPlan -Room $id -Part 'a' -Status 'doing'
        $text = Get-TestPlanLine $room
        $text | Should -Contain 'part: a | emma | doing | - | - | X'
        $text | Should -Contain 'files: a | f/one'
        $text | Should -Contain 'note: a | n one'
    }
}
