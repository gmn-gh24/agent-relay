#Requires -Version 5.1

<#
    The room's integrity as the coordinator and the agents see it: the feed's stamps (this PC's feed.state and the
    integrity stamp in the room), the FEED line of the board, the NO FEED block and the wait that does not start
    without a feed, the agents' note about an old stamp, memory that nobody checks (the board's attention line,
    Repair-RelayMemory.ps1), the tamper pass that restores a protected file, the exit steps of -Retire and
    -Replace, the host name first in the prompts with the address as the fallback, the self-audit that leaves the
    room's own folders out, and a verb run from a working folder that is gone.
    Runs under PowerShell 7 and Windows PowerShell 5.1. Pester 6. ASCII only.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $scripts = Get-RelayTestPath scripts
    Import-Module (Join-Path $scripts 'RelayCommon.psm1') -Force
    $engine = Get-RelayTestHostEngine
    $savedLocal = $env:AGENT_RELAY_LOCAL
    $boardScript = Join-Path $scripts 'Get-RelayBoard.ps1'
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    function Start-TestAgent {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
        param([string]$Room, [string[]]$Names)
        foreach ($name in $Names) {
            $result = Invoke-RelayTool -Room $Room -Agent $name -Engine $engine -Words @('start', 'product', 'model', 'low')
            if ($result.ExitCode -ne 0) { throw "start failed for ${name}: $($result.Output) $($result.Error)" }
        }
    }

    function Write-TestFeedState {
        # This PC's feed.state of a room, written as the feed writes it, with the times given as minutes ago
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
        param([string]$Local, [double]$AliveMinutesAgo, [string]$Ended = '')
        $alive = Format-RelayUtc -Time ([DateTime]::UtcNow.AddMinutes(-$AliveMinutesAgo))
        $text = "pid: 1`nstarted: $alive`nalive: $alive`npass: $alive`ninterval: 15`ntamper_check: on`n"
        if ($Ended) { $text += "ended: $alive`n" }
        [System.IO.File]::WriteAllText((Join-Path $Local 'feed.state'), $text, $utf8)
    }
}

AfterAll {
    $env:AGENT_RELAY_LOCAL = $savedLocal
}

Describe 'The feed stamp and the board' -Tag 'Integrity' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "feed-$case"
        $id = "feed-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $local = Join-Path (Join-Path $env:AGENT_RELAY_LOCAL 'rooms') $id
    }

    It 'says on the first line of the board that no feed runs, and what to do first' {
        $lines = @(& $boardScript -Room $id)
        $lines[0] | Should -Match '^FEED: NOT RUNNING and never started on this PC for this room'
        $lines[0] | Should -Match 'Watch-RelayFeed\.ps1'
        @($lines | Where-Object { $_ -match '^START THE FEED FIRST' }).Count | Should -Be 1
        $json = ConvertFrom-RelayJson ((@(& $boardScript -Room $id -AsJson)) -join '')
        $json.feed.isRunning | Should -BeFalse
    }

    It 'says that the feed runs while it does, stamps the integrity pass in the room, and says when it ended' {
        $handle = Start-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments @('-Room', $id, '-Json', '-MaxSeconds', '14')
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        $stampFile = Join-Path $room 'agents\olivia\integrity'
        while ([DateTime]::UtcNow -lt $deadline -and -not [System.IO.File]::Exists($stampFile)) { Start-Sleep -Milliseconds 200 }
        $lines = @(& $boardScript -Room $id)
        $lines[0] | Should -Match '^FEED: running; the tamper check passed \d+ s ago, the heartbeat \d+ s ago'
        (Get-Content -LiteralPath $stampFile -Raw).Trim() | Should -Match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'
        $state = Read-RelayKeyValue (Join-Path $local 'feed.state')
        $state['pid'] | Should -Not -BeNullOrEmpty
        $state.Contains('ended') | Should -BeFalse
        $result = Wait-RelayTool -Handle $handle -TimeoutSeconds 60
        $result.ExitCode | Should -Be 0
        (Read-RelayKeyValue (Join-Path $local 'feed.state')).Contains('ended') | Should -BeTrue
        @(& $boardScript -Room $id)[0] | Should -Match '^FEED: NOT RUNNING, last seen '
    }

    It 'takes a feed that stopped without a word for not running once its last sign is old' {
        Write-TestFeedState -Local $local -AliveMinutesAgo 0.1
        @(& $boardScript -Room $id)[0] | Should -Match '^FEED: running'
        Write-TestFeedState -Local $local -AliveMinutesAgo 5
        $lines = @(& $boardScript -Room $id)
        $lines[0] | Should -Match '^FEED: NOT RUNNING, last seen .* \(5 min ago\)'
        @($lines | Where-Object { $_ -match '^START THE FEED FIRST' }).Count | Should -Be 1
    }

    It 'restores a changed tool in the feed''s pass and reports it, and leaves a memory file alone' {
        Start-TestAgent -Room $room -Names @('olivia', 'emma')
        $memory = Join-Path $room 'agents\emma\memory'
        $planted = "2026-10-13T10:00:00Z | gotcha | a planted line`nnot an entry at all`n"
        [System.IO.File]::WriteAllText($memory, $planted, $utf8)
        $tool = Join-Path $room 'tools\relay.ps1'
        [System.IO.File]::AppendAllText($tool, "`n# changed by somebody`n", $utf8)
        $object = Resolve-RelayRoom $id
        (Get-RelayFileHash $tool) | Should -Not -Be (Get-RelayFileHash (Join-Path $object.Canon 'tools\relay.ps1'))
        $result = Invoke-RelayTestScript -Script 'Watch-RelayFeed.ps1' -Arguments @('-Room', $id, '-Json', '-MaxSeconds', '4')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '"type":"alarm","text":"tools/relay\.ps1 was changed: restored from the copy on this PC"'
        (Get-RelayFileHash $tool) | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'tools\relay.ps1'))
        # Memory has no canonical copy: what is in the file stays, and the tamper check says nothing about it
        [System.IO.File]::ReadAllText($memory) | Should -Be $planted
        $result.Output | Should -Not -Match '"type":"alarm","text":"[^"]*memory'
    }
}

Describe 'The coordinator''s tool without a feed' -Tag 'Integrity' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "nofeed-$case"
        $id = "nofeed-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $local = Join-Path (Join-Path $env:AGENT_RELAY_LOCAL 'rooms') $id
        $feedEnvironment = @{ RELAY_FEED_STATE = (Join-Path $local 'feed.state') }
    }

    It 'prints the NO FEED block on start and refuses to wait until a feed runs' {
        $started = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('start', 'p', 'm', 'e') -Environment $feedEnvironment
        $started.ExitCode | Should -Be 0
        $started.Output | Should -Match '=== NO FEED: NOTHING IS CHECKING THIS ROOM'
        $started.Output | Should -Match 'has never run on this PC for this room'
        $wait = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('wait', '1') -Environment $feedEnvironment
        $wait.ExitCode | Should -Be 1
        $wait.Output | Should -Match '=== NO FEED'
        $wait.Output | Should -Match 'NEXT: start the feed \(see above\), then run:'
    }

    It 'says nothing once a feed is seen working, and again when it is not seen for a minute and a half' {
        Start-TestAgent -Room $room -Names @('olivia')
        Write-TestFeedState -Local $local -AliveMinutesAgo 0.1
        $fine = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check') -Environment $feedEnvironment
        $fine.Output | Should -Not -Match 'NO FEED'
        Write-TestFeedState -Local $local -AliveMinutesAgo 3
        $late = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check') -Environment $feedEnvironment
        $late.Output | Should -Match '=== NO FEED'
        $late.Output | Should -Match 'was last seen .* \(3 min ago\)'
        # A feed that said it ended is not running either, however fresh its last sign
        Write-TestFeedState -Local $local -AliveMinutesAgo 0.1 -Ended 'yes'
        (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check') -Environment $feedEnvironment).Output | Should -Match '=== NO FEED'
        # No launcher naming the record, no judgement (the tool of an agent, or a test calling it directly)
        (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')).Output | Should -Not -Match 'NO FEED'
    }

    It 'tells an agent when the coordinator''s integrity stamp is old or was never written' {
        Start-TestAgent -Room $room -Names @('olivia', 'emma')
        $notes = @{ RELAY_NO_INTEGRITY_NOTE = '' }
        (Get-RelayValue (Resolve-RelayRoom $id).Info 'integrity' '') | Should -Be 'stamped'
        $never = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $notes
        $never.Output | Should -Match '=== NO INTEGRITY CHECK: .* has never run ==='
        $stamp = Join-Path $room 'agents\olivia\integrity'
        [System.IO.File]::WriteAllText($stamp, "stamp`n", $utf8)
        $fresh = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $notes
        $fresh.Output | Should -Not -Match 'NO INTEGRITY CHECK'
        [System.IO.File]::SetLastWriteTimeUtc($stamp, [DateTime]::UtcNow.AddMinutes(-9))
        $old = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $notes
        $old.Output | Should -Match '=== NO INTEGRITY CHECK: .* last ran 9 minutes ago ==='
        $old.Output | Should -Match 'Tell your user, and tell the coordinator'
    }
}

Describe 'Memory that nobody checks' -Tag 'Integrity' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "memory-$case"
        $id = "memory-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $local = Join-Path (Join-Path $env:AGENT_RELAY_LOCAL 'rooms') $id
        $memory = Join-Path $room 'agents\emma\memory'
        $good = "2026-10-13T10:00:00Z | gotcha | a real entry about the build"
        [System.IO.File]::WriteAllText($memory, "$good`nwritten by hand, no fields`n2026-10-13T10:05:00Z | howto | a second real entry`n", $utf8)
    }

    It 'flags malformed lines as an attention item on the board, and warns in Get-RelayMemory' {
        $lines = @(& $boardScript -Room $id)
        ($lines -join "`n") | Should -Match "memory: 2 entries from 1 agent \(written by the agents, UNVERIFIED"
        ($lines -join "`n") | Should -Match "ATTENTION: 1 malformed line\(s\) skipped in emma's memory"
        $json = ConvertFrom-RelayJson ((@(& $boardScript -Room $id -AsJson)) -join '')
        @($json.memory.skipped)[0].agent | Should -Be 'emma'
        @($json.memory.skipped)[0].lines | Should -Be 1
        $read = @(& (Join-Path $scripts 'Get-RelayMemory.ps1') -Room $id) -join "`n"
        $read | Should -Match 'WARNING: 1 line\(s\) of the agents'' memory files are not entries'
        $read | Should -Match 'Repair-RelayMemory\.ps1 -Room'
    }

    It 'lists the lines with their numbers and changes nothing' {
        $before = [System.IO.File]::ReadAllText($memory)
        $listing = @(& (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -List)
        ($listing -join "`n") | Should -Match '(?m)^\s+1  ENTRY\s'
        ($listing -join "`n") | Should -Match '(?m)^\s+2  MALFORMED\s+written by hand'
        [System.IO.File]::ReadAllText($memory) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $local 'evidence') | Should -BeFalse
    }

    It 'removes a line after an evidence copy of the whole file, and writes a record' {
        $before = [System.IO.File]::ReadAllText($memory)
        $output = @(& (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -Malformed) -join "`n"
        $output | Should -Match 'REMOVED 1 line\(s\) \(2\)'
        $after = [System.IO.File]::ReadAllText($memory)
        $after | Should -Not -Match 'written by hand'
        ($after -split "`n" | Where-Object { $_ }).Count | Should -Be 2
        $evidence = @(Get-ChildItem -LiteralPath (Join-Path $local 'evidence') -Filter 'memory-emma-*.txt')
        $evidence.Count | Should -Be 1
        [System.IO.File]::ReadAllText($evidence[0].FullName) | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $local 'alarms.log') -Raw) | Should -Match 'MEMORY repaired: line\(s\) 2 removed from the memory file of emma'
        # The board has nothing to say any more
        (@(& $boardScript -Room $id) -join "`n") | Should -Not -Match 'malformed line'
        { & (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -Line 99 } | Should -Throw '*there is no line 99*'
        { & (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma } | Should -Throw '*Give -List*'
        { & (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent nobody -List } | Should -Throw "*no agent 'nobody'*"
    }

    It 'sees an empty memory file as no lines, and does not write blank lines into it' {
        [System.IO.File]::WriteAllText($memory, '', $utf8)
        $listing = @(& (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -List)
        ($listing -join "`n") | Should -Match ': 0 line\(s\)\.'
        ($listing -join "`n") | Should -Not -Match 'BLANK'
        { & (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -Line 1 } | Should -Throw '*there is no line 1*'
        [System.IO.File]::ReadAllText($memory) | Should -Be ''
    }

    It 'removes an entry by its number (a planted entry that is well formed)' {
        $null = & (Join-Path $scripts 'Repair-RelayMemory.ps1') -Room $id -Agent emma -Line 3
        $after = [System.IO.File]::ReadAllText($memory)
        $after | Should -Not -Match 'second real entry'
        $after | Should -Match 'a real entry about the build'
    }
}

Describe 'The exit steps of -Retire and -Replace' -Tag 'Integrity' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "exit-$case"
        $id = "exit-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId $id).Path
        $local = Join-Path (Join-Path $env:AGENT_RELAY_LOCAL 'rooms') $id
        $addScript = Join-Path $scripts 'Add-RelayAgent.ps1'
        Start-TestAgent -Room $room -Names @('olivia', 'emma')
    }

    It 'asks an agent that is alive to remember and say bye, and keeps its seat while it has not' {
        { & $addScript -Room $id -Retire emma -WaitMinutes 0 } | Should -Throw '*emma is alive and has not said bye*'
        @(Get-RelayRoster (Resolve-RelayRoom $id) -IncludeRetired) | Should -Contain 'emma'
        Test-Path -LiteralPath (Join-Path (Resolve-RelayRoom $id).Canon 'agents\emma\retired') | Should -BeFalse
        $request = @(Get-RelayTestInbox -Room $room -Agent 'emma' -From 'olivia')
        $request.Count | Should -Be 1
        (Read-RelayTestMessage (Join-Path $room "agents\emma\inbox\$($request[0])")).Body | Should -Match 'run remember for your last durable findings.*run your bye verb'
        # Once the agent said bye, the retirement goes through, and says how the agent left
        Set-RelayTestDraft -Room $room -Agent 'emma' -Text "bye`n`nnothing slowed me down."
        (Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('bye')).ExitCode | Should -Be 0
        $output = @(& $addScript -Room $id -Retire emma -WaitMinutes 0) -join "`n"
        $output | Should -Match 'RETIRED emma .*\(exit: bye\)'
        (Get-Content -LiteralPath (Join-Path (Resolve-RelayRoom $id).Canon 'agents\emma\retired') -Raw) | Should -Match '(?m)^exit: bye$'
        (Get-Content -LiteralPath (Join-Path $local 'exits.log') -Raw) | Should -Match 'retire emma exit=bye'
    }

    It 'does not ask a second time for the exit of an agent that already said bye' {
        Set-RelayTestDraft -Room $room -Agent 'emma' -Text "bye`n`nfine."
        $null = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('bye')
        $null = & $addScript -Room $id -Retire emma -WaitMinutes 0
        @(Get-RelayTestInbox -Room $room -Agent 'emma' -From 'olivia').Count | Should -Be 0
    }

    It 'goes on without the bye only with a reason, and records the reason' {
        { & $addScript -Room $id -Retire emma -Force } | Should -Throw '*needs -Reason*'
        $output = @(& $addScript -Room $id -Retire emma -Force -Reason 'the session was killed by the owner') -join "`n"
        $output | Should -Match 'exit: forced: the session was killed by the owner'
        (Get-Content -LiteralPath (Join-Path (Resolve-RelayRoom $id).Canon 'agents\emma\retired') -Raw) | Should -Match '(?m)^exit: forced: the session was killed by the owner$'
    }

    It 'does not wait for an agent whose session is gone: the request stays in its inbox and the exit is recorded as lost' {
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddMinutes(-30))
        $output = @(& $addScript -Room $id -Retire emma) -join "`n"
        $output | Should -Match 'RETIRED emma .*\(exit: lost: the session was not alive'
        @(Get-RelayTestInbox -Room $room -Agent 'emma' -From 'olivia').Count | Should -Be 1
    }

    It 'asks an agent that never introduced itself for nothing' {
        $output = @(& $addScript -Room $id -Retire jack) -join "`n"
        $output | Should -Match 'RETIRED jack .*\(exit: none\)'
        @(Get-RelayTestInbox -Room $room -Agent 'jack' -From 'olivia').Count | Should -Be 0
    }

    It 'applies the same steps to a replaced session, and names the prompt to paste' {
        { & $addScript -Room $id -Replace emma -WaitMinutes 0 } | Should -Throw '*emma is alive and has not said bye*'
        Get-RelayCanonicalGeneration (Resolve-RelayRoom $id) 'emma' | Should -Be 1
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddMinutes(-30))
        $output = @(& $addScript -Room $id -Replace emma) -join "`n"
        $output | Should -Match 'REPLACED emma: generation 2'
        $output | Should -Match 'exit of the old session: lost'
        $output | Should -Match 'NEXT: paste the start prompt for emma into the new session \(-Clipboard emma puts it on the clipboard\)'
        { & $addScript -Room $id -Clipboard nobody } | Should -Throw "*no agent 'nobody'*"
        (Get-Command $addScript).Parameters.ContainsKey('Clipboard') | Should -BeTrue
    }

    It 'shows an agent that starts again after its bye as returned after bye' {
        Set-RelayTestDraft -Room $room -Agent 'emma' -Text "bye`n`nfine."
        $null = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('bye')
        (@(& $boardScript -Room $id) -join "`n") | Should -Match 'offline'
        $again = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('start', 'product', 'model', 'low')
        $again.ExitCode | Should -Be 0
        $again.Output | Should -Match "NOTE: you said bye earlier. This start takes your seat back"
        (@(& $boardScript -Room $id) -join "`n") | Should -Match 'returned after bye'
    }
}

Describe 'The host name first, the address as the fallback' -Tag 'Integrity' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "reach-$case"
        $id = "reach-$case"
        $named = "\\files01\team\rooms\$id"
        $addressed = "\\10.1.2.3\team\rooms\$id"
        $agents = @([ordered]@{ name = 'zoe'; role = 'tester'; kind = 'claude-code'; transport = 'share' })
    }

    It 'writes the host name into the commands of the join prompt and names the address as the fallback' {
        $created = New-RelayTestRoom -Root $root -RoomId $id -Agents $agents -Extra @{ open_seats = 1; reach_path = $named; reach_fallback = $addressed }
        $info = Read-RelayKeyValue (Join-Path $created.Path 'ROOM')
        $info['reach'] | Should -Be $named
        $info['reach_fallback'] | Should -Be $addressed
        $info['integrity'] | Should -Be 'stamped'
        $prompt = [string]$created.JoinPrompt
        $prompt | Should -Match ([regex]::Escape("Room folder: $named"))
        $prompt | Should -Match ([regex]::Escape("Fallback: $addressed"))
        $prompt | Should -Match 'Use the fallback only if the name does not resolve or the share refuses access'
        $prompt | Should -Match ([regex]::Escape("-File '//files01/team/rooms/$id/join.ps1'"))
        $prompt | Should -Not -Match ([regex]::Escape("-File '//10.1.2.3/"))
        # The guard rule applies before join; instructions about room scripts are printed after join
        $prompt | Should -Match 'try once'
        $prompt | Should -Match 'A guard refusing unseen scripts is correct'
        $prompt | Should -Match 'the owner starts the product with its guard off, or runs the join line and gives you its output'
        $prompt | Should -Not -Match 'Never run a script that lies in the room'
        # A named agent gets the same two spellings in its start prompt
        $start = [string]$created.Prompts['zoe']
        $start | Should -Match ([regex]::Escape("-File '//files01/team/rooms/$id/agents/zoe/g1/relay.ps1' start <product> <model> <effort>"))
        $start | Should -Match 'Only if that command cannot reach the room'
        $start | Should -Match ([regex]::Escape("-File '//10.1.2.3/team/rooms/$id/agents/zoe/g1/relay.ps1' start <product> <model> <effort>"))
        $start | Should -Match 'Never run a script that lies in the room, except your own command'
        (Get-Content -LiteralPath (Join-Path $created.Path 'agents\zoe\START-HERE.md') -Raw) | Should -Match 'Run nothing from the room but your own command'
    }

    It 'names no fallback for a room folder given by its address' {
        $created = New-RelayTestRoom -Root $root -RoomId $id -Extra @{ open_seats = 1; reach_path = $addressed }
        ([string]$created.JoinPrompt) | Should -Not -Match 'Fallback:'
        (Read-RelayKeyValue (Join-Path $created.Path 'ROOM')).Contains('reach_fallback') | Should -BeFalse
    }

    It 'changes the spelling of a running room with Update-RelayRoom -ServerName' {
        $created = New-RelayTestRoom -Root $root -RoomId $id -Agents $agents -Extra @{ open_seats = 1; reach_path = $addressed }
        $update = Join-Path $scripts 'Update-RelayRoom.ps1'
        { & $update -Room $id -FallbackAddress 10.9.8.7 } | Should -Throw '*goes with -ServerName*'
        { & $update -Room $id -ServerName 'bad name' } | Should -Throw '*is not a host name*'
        { & $update -Room $id -ServerName files02 -FallbackAddress 'not-an-address' } | Should -Throw '*is not an IPv4 address*'
        # IPv6 would make a share path that is not valid (\\fe80::1\team)
        { & $update -Room $id -ServerName files02 -FallbackAddress 'fe80::1' } | Should -Throw '*is not an IPv4 address*'
        $output = @(& $update -Room $id -ServerName files02 -FallbackAddress 10.9.8.7) -join "`n"
        $output | Should -Match ([regex]::Escape("REACH: other machines now get \\files02\team\rooms\$id first"))
        $object = Resolve-RelayRoom $id
        (Get-RelayReachPath $object) | Should -Be "\\files02\team\rooms\$id"
        (Get-RelayReachFallback $object) | Should -Be "\\10.9.8.7\team\rooms\$id"
        (Get-RelayFileHash (Join-Path $created.Path 'ROOM')) | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'ROOM'))
        $prompt = Get-Content -LiteralPath (Join-Path $created.Path 'PROMPT-JOIN.txt') -Raw
        $prompt | Should -Match ([regex]::Escape("Room folder: \\files02\team\rooms\$id"))
        $prompt | Should -Match ([regex]::Escape("\\10.9.8.7\team\rooms\$id"))
        (Get-Content -LiteralPath (Join-Path $created.Path 'agents\zoe\START-HERE.md') -Raw) | Should -Match ([regex]::Escape("'\\files02\team\rooms\$id\agents\zoe\g1\relay.ps1'"))
        @(Test-RelayTamper $object).Count | Should -Be 0
    }
}

Describe 'The self-audit leaves the room''s own folders out' -Tag 'Integrity' {

    It 'does not count the other agents'' heartbeats and attachments as changes outside the assigned paths' {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "audit-$case"
        $id = "audit-$case"
        # The assigned root holds the room itself: everything the other agents write there is the room's bookkeeping
        $work = Join-Path $root 'share'
        $agents = @(
            [ordered]@{ name = 'emma'; role = 'developer'; kind = 'generic'; transport = 'same-pc'; work = 'development'; roots = @(@{ root = $work; may = @('src/*') }) },
            [ordered]@{ name = 'jack'; role = 'reviewer'; kind = 'generic'; transport = 'same-pc' }
        )
        $room = (New-RelayTestRoom -Root $root -RoomId $id -Agents $agents -Extra @{ rooms_root = (Join-Path $work 'rooms') }).Path
        Start-TestAgent -Room $room -Names @('olivia', 'emma')
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force
        $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Work`n`nDo a thing."
        $null = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
        Start-Sleep -Milliseconds 1200
        # What the others do in the room meanwhile
        Start-TestAgent -Room $room -Names @('jack')
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\jack\alive'), "later`n")
        [System.IO.File]::WriteAllText((Join-Path $work 'src\mine.txt'), "mine`n")
        $report = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('report') -Text "Done`n`n1. Result: done."
        $report.ExitCode | Should -Be 0
        $report.Output | Should -Match 'self-audit: 1 changed since start, 0 OUTSIDE the assigned paths'
        $report.Output | Should -Not -Match 'OUTSIDE  .*agents'
        $audit = (Get-Content -LiteralPath (Join-Path $room "files\emma-olivia-0002\self-audit.txt") -Raw) -replace "`r", ''
        $audit | Should -Match "(?m)^  \(\d+ change\(s\) in the room's own folders agents, files and tools are not counted"
    }

    It 'still counts a folder of the work that has the room''s name' {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "audit2-$case"
        $id = "audit2-$case"
        $work = Join-Path $root 'share'
        $agents = @(
            [ordered]@{ name = 'emma'; role = 'developer'; kind = 'generic'; transport = 'same-pc'; work = 'development'; roots = @(@{ root = $work; may = @('src/*') }) },
            [ordered]@{ name = 'jack'; role = 'reviewer'; kind = 'generic'; transport = 'same-pc' }
        )
        $room = (New-RelayTestRoom -Root $root -RoomId $id -Agents $agents -Extra @{ rooms_root = (Join-Path $work 'rooms') }).Path
        Start-TestAgent -Room $room -Names @('olivia', 'emma')
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force
        $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Work`n`nDo a thing."
        $null = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
        Start-Sleep -Milliseconds 1200
        # Not the room: another folder of the same name, with a tools folder in it
        $other = Join-Path $work "archive\$id\tools"
        $null = New-Item -ItemType Directory -Path $other -Force
        [System.IO.File]::WriteAllText((Join-Path $other 'output.txt'), "work`n")
        [System.IO.File]::WriteAllText((Join-Path $work 'src\mine.txt'), "mine`n")
        $report = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('report') -Text "Done`n`n1. Result: done."
        $report.ExitCode | Should -Be 0
        $report.Output | Should -Match 'self-audit: 2 changed since start, 1 OUTSIDE the assigned paths'
        $report.Output | Should -Match 'OUTSIDE  .*output\.txt'
    }
}

Describe 'A verb run from a working folder that is gone' -Tag 'Integrity' {

    It 'does not depend on the folder the shell stands in' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        # Linux and macOS let a process stand in a folder that is removed; Windows does not (the hardening is for a
        # folder on a share that another machine removes, which this suite cannot make)
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "cwd-$case"
        $room = (New-RelayTestRoom -Root $root -RoomId "cwd-$case").Path
        $gone = Join-Path $root 'gone'
        $null = New-Item -ItemType Directory -Path $gone -Force
        $shell = Get-RelayTestPwsh
        $line = "cd '$gone' && rmdir '$gone' && RELAY_NAME=emma RELAY_GEN=1 RELAY_NO_TITLE=1 '$shell' -NoProfile -File '$(Join-Path $room 'tools/relay.ps1')' start p m e; echo exit=`$?"
        $output = (& bash -c $line 2>&1) -join "`n"
        $output | Should -Match '=== you are Emma \(emma\)'
        $output | Should -Match 'exit=0'
    }
}
