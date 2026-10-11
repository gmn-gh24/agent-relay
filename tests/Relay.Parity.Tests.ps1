#Requires -Version 5.1

<#
    Lines and orders that relay.ps1 must print exactly (ROUND2.md: F10, F11, F15, F16), the same cases for every
    engine: relay.ps1 under PowerShell 7 and under Windows PowerShell 5.1. A literal expected line in a test is
    what makes the engines print the same thing. Written from work\team-plan\ROUND2.md. Every tool call is a real
    child process. Pester 6. ASCII only.

    The round-5 context adds the culture of the machine.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $engineCases = @(Get-RelayTestEngine | ForEach-Object { @{ Engine = $_ } })
}

Describe 'Parity on <Engine>' -Tag 'Parity' -ForEach $engineCases {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
        $engine = $Engine
        $root = Join-Path $TestDrive "parity-$engine"
        $utf8 = New-Object System.Text.UTF8Encoding($false)

        function Write-ParityFile {
            param([string]$Path, [string]$Text)
            [System.IO.File]::WriteAllText($Path, $Text, $utf8)
        }

        function Get-ParityLine {
            param([string]$Text)
            return @(($Text -replace "`r", '').TrimEnd("`n") -split "`n")
        }

        function Join-ParityLine {
            param([string[]]$Lines)
            return (@($Lines) -join "`n")
        }

        function Invoke-Parity {
            param([string]$Agent, [string[]]$Words, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 120)
            return (Invoke-RelayTool -Room $room -Agent $Agent -Engine $engine -Words $Words -Environment $Environment -TimeoutSeconds $TimeoutSeconds)
        }

        function Get-ParityCall {
            # The command prefix the tool prints for itself, read off its own help
            $help = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('help')
            if ($help.Output -match '(?m)^  (?<call>.+?) who {2,}\S') { return $Matches['call'] }
            return 'relay'
        }

        function Write-ParityMessage {
            # A message file by hand, in the header format the tool writes; its file time is set as given
            param([string]$From, [string]$To, [int]$Number, [string]$Sent = '2026-10-10T08:00:00Z', [DateTime]$FileTime = [DateTime]::MinValue)
            $id = '{0}-{1}-{2:0000}' -f $From, $To, $Number
            $path = Join-Path $room ('agents\{0}\inbox\{1}-{2:0000}.md' -f $To, $From, $Number)
            Write-ParityFile $path "---`nid: $id`nfrom: $From`nto: $To`ntype: note`nre: `nsubject: Note $id`nsent_utc: $Sent`nexpects: none`n---`nText of $id.`n"
            if ($FileTime -ne [DateTime]::MinValue) { [System.IO.File]::SetLastWriteTimeUtc($path, $FileTime) }
            return $id
        }

        function Read-ParityAudit {
            # The self-audit file that a report attached, from the SENT line of the report
            param($Report)
            ($Report.Output -match 'SENT (?<id>\S+) \(result') | Should -BeTrue
            return (([System.IO.File]::ReadAllText((Join-Path $room ('files\{0}\self-audit.txt' -f $Matches['id'])))) -replace "`r", '')
        }

        function Send-ParityReport {
            # The coordinator gives emma a task, emma reports on it: the report carries the self-audit
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Audit task`n`nDo the work."
            return (Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('report', 'olivia-emma-0001') -Text "Done`n`nDone.")
        }
        function Use-ParityScope {
            # Assigns one folder to emma and has the tool take its baseline again
            param([string]$Folder)
            Write-ParityFile (Join-Path $room 'agents\emma\scope') "root: $Folder`nmay: *`n"
            $started = Invoke-Parity 'emma' @('start')
            $started.ExitCode | Should -Be 0
        }

        $template = (New-RelayTestRoom -Root $root -RoomId 'template').Path
        foreach ($agent in 'olivia', 'emma', 'jack', 'henry') {
            $started = Invoke-RelayTool -Room $template -Agent $agent -Engine $engine -Words @('start', 'test-product', 'test-model', 'low')
            if ($started.ExitCode -ne 0) { throw "start failed for $agent on ${engine}: $($started.Output) $($started.Error)" }
        }
        $null = Invoke-RelayTool -Room $template -Agent 'olivia' -Engine $engine -Words @('check')
    }

    BeforeEach {
        $room = Copy-RelayTestRoom -Template $template -Target (Join-Path $root ('room-' + (New-RelayTestId)))
    }

    Context 'F10: a parked agent is told to stop, and nothing else' {
        It 'ends with one NEXT line' {
            $seat = Join-Path $room 'agents\emma\seat'
            $text = [System.IO.File]::ReadAllText($seat)
            $text = $text -replace 'park_after: \d+', 'park_after: 2'
            Write-ParityFile $seat $text
            $call = Get-ParityCall
            $fast = @{ RELAY_MINUTE_SECONDS = '1' }
            (Invoke-Parity 'emma' @('wait', '2') $fast).ExitCode | Should -Be 3
            $parked = Invoke-Parity 'emma' @('wait', '2') $fast
            $parked.ExitCode | Should -Be 6
            $lines = Get-ParityLine $parked.Output
            $lines[$lines.Count - 1] | Should -BeExactly "NEXT: stop calling wait. Tell your user in one line that you are parked in room template. When your user tells you to continue, run: $call wait"
            @($lines | Where-Object { $_ -like 'NEXT: *' }).Count | Should -Be 1
            $lines | Should -Contain '=== nothing arrived in 2 waits in a row: you are parked ==='
        }
    }

    Context 'F11: help names the real attach folder' {
        It 'names the full path of the attach folder of a known agent, on the last line' {
            $lines = Get-ParityLine (Invoke-Parity 'emma' @('help')).Output
            $last = $lines[$lines.Count - 1]
            $last | Should -Match '^\(line 1 = subject\)\. Files to attach go into .+ before you send\.$'
            $named = ($last -replace '^\(line 1 = subject\)\. Files to attach go into ', '' -replace ' before you send\.$', '')
            $normal = ($named -replace '/', '\').TrimEnd('\').ToLowerInvariant()
            $wanted = (Join-Path $room 'agents\emma\attach').TrimEnd('\').ToLowerInvariant()
            # With a short (8.3) temp folder name, only the part from the room folder on can be known; a wrong
            # folder above the room cannot be seen by this test
            if ($room.Contains('~')) {
                # From the room folder on, and an absolute path
                $named | Should -Match '^(/|[A-Za-z]:)'
                $normal.EndsWith('\' + (Split-Path -Leaf $room).ToLowerInvariant() + '\agents\emma\attach') | Should -BeTrue
            }
            else { $normal | Should -BeExactly $wanted }
        }

        It 'says where the attach folder is in words when it does not know the agent' {
            $lines = Get-ParityLine (Invoke-RelayTool -Room $room -Agent '' -Engine $engine -Words @('help')).Output
            $lines[$lines.Count - 1] | Should -BeExactly '(line 1 = subject). Files to attach go into the attach folder inside your agent folder in the room before you send.'
        }
    }

    Context 'F15: a folder that has grown past the limit is not compared' {
        It 'says NOT COMPARED, lists no old file as deleted, and counts the folder as not compared' {
            # The limit of the tool is 20000 files; this makes 20100 (a few seconds, more with a scanner on every file)
            $work = Join-Path $root ('big-' + (New-RelayTestId))
            $null = New-Item -ItemType Directory -Path $work -Force
            foreach ($name in 'a.txt', 'b.txt', 'c.txt') { Write-ParityFile (Join-Path $work $name) "$name`n" }
            Use-ParityScope $work
            foreach ($folder in 1..201) {
                $dir = Join-Path $work ('d{0:000}' -f $folder)
                $null = New-Item -ItemType Directory -Path $dir -Force
                foreach ($file in 1..100) { [System.IO.File]::Create((Join-Path $dir ('f{0:000}.dat' -f $file))).Dispose() }
            }
            $report = Send-ParityReport
            $report.ExitCode | Should -Be 0
            $audit = Read-ParityAudit $report
            $lines = Get-ParityLine $audit
            $lines | Should -Contain "root: $work (too large to list now: NOT COMPARED)"
            @($lines | Where-Object { $_ -match '^  (ok|OUTSIDE|nothing changed)' }).Count | Should -Be 0
            @($lines | Where-Object { $_ -match '^D  |^  ok +D  |^  OUTSIDE +D  ' }).Count | Should -Be 0
            $lines[$lines.Count - 1] | Should -BeExactly 'self-audit: 0 changed since start, 0 OUTSIDE the assigned paths, 1 folder(s) NOT COMPARED'
        }
    }

    Context 'F16: the same order and the same numbers' {
        It 'delivers oldest first by whole seconds of the file time, then sender, then number' {
            $base = [DateTime]::new(2026, 10, 10, 8, 0, 10, [DateTimeKind]::Utc)
            $null = Write-ParityMessage 'jack' 'emma' 2 -FileTime $base.AddMilliseconds(100)
            $null = Write-ParityMessage 'henry' 'emma' 1 -FileTime $base.AddMilliseconds(900)
            $null = Write-ParityMessage 'jack' 'emma' 1 -FileTime $base.AddMilliseconds(800)
            $null = Write-ParityMessage 'olivia' 'emma' 1 -FileTime $base.AddMilliseconds(-1500)
            # The case needs a file system that keeps a file time to the millisecond (not FAT, exFAT or some shares)
            $kept = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $room 'agents\emma\inbox\henry-0001.md'))
            if ([Math]::Abs(($kept - $base.AddMilliseconds(900)).TotalMilliseconds) -gt 20) { Set-ItResult -Skipped -Because 'the file system of the test folder does not keep file times to the millisecond'; return }
            $result = Invoke-Parity 'emma' @('check')
            $result.ExitCode | Should -Be 0
            $ids = New-Object System.Collections.Generic.List[string]
            foreach ($line in (Get-ParityLine $result.Output)) { if ($line -match '^--- (\S+) \|') { $ids.Add($Matches[1]) } }
            Join-ParityLine $ids.ToArray() | Should -BeExactly (Join-ParityLine @('olivia-emma-0001', 'henry-emma-0001', 'jack-emma-0001', 'jack-emma-0002'))
        }

        It 'prints whole minutes rounded down when it says how long an agent has been silent: <Seconds> seconds' -ForEach @(
            @{ Seconds = 333; Minutes = 5 }
            @{ Seconds = 453; Minutes = 7 }
        ) {
            $status = Join-Path $room 'agents\emma\status'
            Write-ParityFile $status "state: listening`ndetail: `nsince_utc: 2026-10-10T08:00:00Z`ngen: 1`n"
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddSeconds(-$Seconds))
            $who = Invoke-Parity 'jack' @('who')
            $who.ExitCode | Should -Be 0
            $who.Output | Should -Match "state: STALE \(listening, but silent for $Minutes min\)"
        }

        It 'prints whole minutes rounded down in the line about a silent coordinator: 633 seconds' {
            # Whole minutes, rounded down: 10.55 minutes is 10
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\olivia\alive'), [DateTime]::UtcNow.AddSeconds(-633))
            $result = Invoke-Parity 'emma' @('check')
            $result.Output | Should -Match '(?m)^=== the coordinator has given no sign of life for 10 minutes ===$'
        }
        It 'shows a message for an id in any case' {
            $null = Write-ParityMessage 'olivia' 'emma' 1
            $shown = Invoke-Parity 'emma' @('show', 'OLIVIA-EMMA-0001')
            $shown.ExitCode | Should -Be 0
            $shown.Output | Should -Match 'Text of olivia-emma-0001\.'
        }

        It 'says "waiting for 1 reply" and "waiting for N replies" at start' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('ask') -Text "Which folder?`n`nWhich folder do you mean?"
            $one = Invoke-Parity 'emma' @('start')
            $lines = Get-ParityLine $one.Output
            $lines | Should -Contain '=== you are waiting for 1 reply ==='
            $lines | Should -Contain '  emma-olivia-0002  question to Olivia (coordinator): Which folder?'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('ask') -Text "Which file?`n`nWhich file do you mean?"
            $two = Invoke-Parity 'emma' @('start')
            Get-ParityLine $two.Output | Should -Contain '=== you are waiting for 2 replies ==='
        }

        It 'lists the files of a folder in the order of their paths (ordinal), whatever happened to them' {
            $work = Join-Path $root ('order-' + (New-RelayTestId))
            $null = New-Item -ItemType Directory -Path $work -Force
            foreach ($name in 'a.txt', 'a-b.txt', 'z.txt') { Write-ParityFile (Join-Path $work $name) "$name`n" }
            Use-ParityScope $work
            Start-Sleep -Seconds 2
            Write-ParityFile (Join-Path $work 'a.txt') "a.txt changed and longer`n"
            [System.IO.File]::Delete((Join-Path $work 'a-b.txt'))
            foreach ($name in 'B.txt', 'a.b.txt', 'a_b.txt') { Write-ParityFile (Join-Path $work $name) "$name`n" }
            $null = New-Item -ItemType Directory -Path (Join-Path $work 'a') -Force
            Write-ParityFile (Join-Path $work 'a\z.txt') "z`n"
            $report = Send-ParityReport
            $audit = Read-ParityAudit $report
            $entries = @(Get-ParityLine $audit | Where-Object { $_ -match '^  ok ' })
            # Capital letters before small ones, - before . before / before _: not the order of a culture sort
            Join-ParityLine $entries | Should -BeExactly (Join-ParityLine @('  ok       A  B.txt', '  ok       D  a-b.txt', '  ok       A  a.b.txt', '  ok       M  a.txt', '  ok       A  a/z.txt', '  ok       A  a_b.txt'))
        }
        It 'stores the body of a message without blanks at its end' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Text ("A subject`n`nBody text   `t  `n`n   `n`n")
            $raw = ([System.IO.File]::ReadAllText((Join-Path $room 'agents\olivia\inbox\emma-0002.md'))) -replace "`r", ''
            $raw.EndsWith("`nBody text`n") | Should -BeTrue
        }

        It 'cuts a subject at 120 characters, never inside a character: <Name>' -ForEach @(
            @{ Name = 'plain characters'; Subject = ('s' * 130); Expected = ('s' * 120) }
            @{ Name = 'a character of two halves at the cut'; Subject = (('s' * 119) + [char]::ConvertFromUtf32(0x1F600) + 'zz'); Expected = (('s' * 119) + [char]::ConvertFromUtf32(0x1F600)) }
            @{ Name = 'accented characters'; Subject = ([string][char]0x00E9 * 130); Expected = ([string][char]0x00E9 * 120) }
        ) {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Text ($Subject + "`n`nThe text.")
            (Read-RelayTestMessage (Join-Path $room 'agents\olivia\inbox\emma-0002.md'))['subject'] | Should -BeExactly $Expected
        }
    }

    Context 'Room memory: the same lines on every engine' {
        It 'prints REMEMBERED with the counts, and ALREADY RECORDED for the same text again' {
            $first = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('remember', 'build') -Text 'The build runs only from the repository root.'
            $first.ExitCode | Should -Be 0
            $call = Get-ParityCall
            Join-ParityLine (Get-ParityLine $first.Output) | Should -BeExactly (Join-ParityLine @('REMEMBERED (1 of yours, 1 in the room)', "NEXT: carry on with your work. Before you ask anybody, look first with: $call find <words>"))
            $stamp = ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\memory'))).Substring(0, 20)
            $again = Send-RelayTestMessage -Room $room -Agent 'jack' -Engine $engine -Words @('remember') -Text 'the build runs only from the  REPOSITORY root.'
            $again.ExitCode | Should -Be 0
            Join-ParityLine (Get-ParityLine $again.Output) | Should -BeExactly (Join-ParityLine @("ALREADY RECORDED by Emma at $stamp", "NEXT: nothing was written. Carry on with your work; what the room knows: $call find <words>"))
            $second = Send-RelayTestMessage -Room $room -Agent 'jack' -Engine $engine -Words @('remember') -Text 'The tests need a local disk, not a share.'
            (Get-ParityLine $second.Output)[0] | Should -BeExactly 'REMEMBERED (1 of yours, 2 in the room)'
        }

        It 'orders the entries in byte order of author when their times are equal, whatever the culture' {
            Write-ParityFile (Join-Path $room 'agents\jack\memory') "2026-10-10T08:00:00Z | - | Same second, written by jack.`n"
            Write-ParityFile (Join-Path $room 'agents\emma\memory') "2026-10-10T08:00:00Z | - | Same second, written by emma.`n"
            $danish = @{ LC_ALL = 'da_DK.UTF-8'; LC_MESSAGES = 'da_DK.UTF-8'; LANG = 'da_DK.UTF-8' }
            $found = Invoke-Parity 'henry' @('find', 'same') $danish
            $found.ExitCode | Should -Be 0
            $lines = Get-ParityLine $found.Output
            $lines[1] | Should -BeExactly '2026-10-10T08:00:00Z Jack [-] Same second, written by jack.'
            $lines[2] | Should -BeExactly '2026-10-10T08:00:00Z Emma [-] Same second, written by emma.'
        }
    }

    Context 'Round 5: the same words and orders on every machine' {
        It 'refuses a sign in front of the minutes of wait: <Word>' -ForEach @(
            @{ Word = '-0' }
            @{ Word = '-5' }
        ) {
            $result = Invoke-Parity 'emma' @('wait', $Word) -TimeoutSeconds 60
            $result.TimedOut | Should -BeFalse
            $result.ExitCode | Should -Be 1
            $lines = Get-ParityLine $result.Output
            $lines | Should -Contain 'ERROR: wait takes a number of minutes, or nothing'
            $lines[$lines.Count - 1] | Should -BeExactly "NEXT: example: $(Get-ParityCall) wait 9"
        }

        It 'compares the type of a message exactly: a Task is no task' {
            Write-ParityFile (Join-Path $room 'agents\emma\inbox\olivia-0001.md') "---`nid: olivia-emma-0001`nfrom: olivia`nto: emma`ntype: Task`nre: `nsubject: Capital type`nsent_utc: 2026-10-10T08:00:00Z`nexpects: reply`n---`nNot a request.`n"
            $open = Invoke-Parity 'emma' @('show', 'open')
            $open.ExitCode | Should -Be 0
            Get-ParityLine $open.Output | Should -Contain '=== no open requests: you owe nobody a reply ==='
        }

        It 'writes its times in the same form whatever the culture of the machine (Thai: another calendar)' {
            # .NET takes the culture from these on Linux and macOS; on Windows the test asks nothing of the culture
            $thai = @{ LC_ALL = 'th_TH.UTF-8'; LC_MESSAGES = 'th_TH.UTF-8'; LANG = 'th_TH.UTF-8' }
            Write-ParityFile (Join-Path $room 'agents\emma\draft.md') "In Thai`n`nThe time stays Gregorian."
            $sent = Invoke-Parity 'emma' @('note') $thai
            $sent.ExitCode | Should -Be 0
            $message = Read-RelayTestMessage (Join-Path $room 'agents\olivia\inbox\emma-0002.md')
            $message['sent_utc'] | Should -Match '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
            $journal = @([System.IO.File]::ReadAllLines((Join-Path $room 'agents\emma\journal')))
            $journal[$journal.Count - 1] | Should -Match '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z sent emma-olivia-0002 note$'
        }

        It 'lists the agents in byte order whatever the culture of the machine (Danish: aa after z)' {
            $number = New-RelayTestId
            $agents = @(
                [ordered]@{ name = 'zed'; role = 'tester'; kind = 'generic'; transport = 'same-pc' },
                [ordered]@{ name = 'aage'; role = 'reviewer'; kind = 'generic'; transport = 'same-pc' }
            )
            $danishRoom = (New-RelayTestRoom -Root (Join-Path $root "danish-$number") -RoomId "danish-$number" -Agents $agents).Path
            (Invoke-RelayTool -Room $danishRoom -Agent 'olivia' -Engine $engine -Words @('start', 'p', 'm', 'e')).ExitCode | Should -Be 0
            $danish = @{ LC_ALL = 'da_DK.UTF-8'; LC_MESSAGES = 'da_DK.UTF-8'; LANG = 'da_DK.UTF-8' }
            $who = Invoke-RelayTool -Room $danishRoom -Agent 'olivia' -Engine $engine -Words @('who') -Environment $danish
            $who.ExitCode | Should -Be 0
            $first = $who.Output.IndexOf('(aage)', [System.StringComparison]::Ordinal)
            $second = $who.Output.IndexOf('(zed)', [System.StringComparison]::Ordinal)
            $first | Should -BeGreaterThan -1
            $second | Should -BeGreaterThan $first
        }
    }
}
