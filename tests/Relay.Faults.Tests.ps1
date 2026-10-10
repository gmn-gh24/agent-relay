#Requires -Version 5.1

<#
    Round 2 of the team-plan job: one context per fault F1 to F6 of work\team-plan\ROUND2.md. Every test fails against
    the room tool as it was before the fixes and passes against the fixed one. The same cases run for every engine:
    relay.ps1 under PowerShell 7 and under Windows PowerShell 5.1, relay.sh under dash. Every tool call is a real child
    process. Pester 6. ASCII only.

    Faults that need no schedule are forced from outside: a message file that is empty, has no type or is held open, a
    number range filled with folders, a deleted work folder, a proposals file written back by hand, a claim or a lock
    file put in place by hand. The three races (F3, F4, F6) need a forced schedule and use the test hook of the tools:

        RELAY_PAUSE_AT=<point>  RELAY_PAUSE_DIR=<folder>
            At the named point the tool creates <folder>/<point>.reached, then waits until <folder>/<point>.go exists
            (60 seconds at most). Points: send-placed, lease-judged, proposals-write.

    A test that needs the hook skips itself while the source of the tool does not contain the text RELAY_PAUSE_AT.
    RELAY_FAULTS_RUN_HOOK_TESTS=1 runs them anyway (to see them fail against a tool without the hook).
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $engineCases = @(Get-RelayTestEngine | ForEach-Object { @{ Engine = $_ } })
}

Describe 'Round 2 faults on <Engine>' -Tag 'Faults' -ForEach $engineCases {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
        $engine = $Engine
        $root = Join-Path $TestDrive "faults-$engine"
        $template = (New-RelayTestRoom -Root $root -RoomId 'template').Path
        foreach ($agent in 'olivia', 'emma', 'jack', 'henry') {
            $started = Invoke-RelayTool -Room $template -Agent $agent -Engine $engine -Words @('start', 'test-product', 'test-model', 'low')
            if ($started.ExitCode -ne 0) { throw "start failed for $agent on ${engine}: $($started.Output) $($started.Error)" }
        }
        # The coordinator has read the three introductions: every test starts with nothing new anywhere
        $null = Invoke-RelayTool -Room $template -Agent 'olivia' -Engine $engine -Words @('check')
        $toolFile = 'relay.ps1'
        if ($engine -eq 'sh') { $toolFile = 'relay.sh' }
        $toolSource = [System.IO.File]::ReadAllText((Join-Path $template "tools\$toolFile"))
        $onWindows = ($env:OS -eq 'Windows_NT')
        # relay.sh under dash on Windows needs seconds for what the other engines do in a fraction of one: a time
        # factor for waits and limits (per engine), and the length of a tool minute (the same for all engines)
        $slow = ($engine -eq 'sh')
        # A minute of 15 seconds on every engine: a loaded machine makes any of them slow, and "young" has to hold at the first look
        $pace = 1
        $shortMinute = 15
        $waitMinute = 15
        $lockWait = 2.5
        if ($slow) { $pace = 3; $lockWait = 1.8 }

        function Get-ReadableMessage {
            # A valid message file as a sender's tool would leave it
            param([string]$From = 'olivia', [string]$To = 'emma', [string]$Number = '0001', [string]$Subject = 'Hello there', [string]$Type = 'note')
            return "---`nid: $From-$To-$Number`nfrom: $From`nto: $To`ntype: $Type`nre: `nsubject: $Subject`nsent_utc: 2026-10-10T08:00:00Z`nexpects: none`n---`nThe text of $Number.`n"
        }

        function Write-InboxFile {
            param([string]$Room, [string]$Agent = 'emma', [string]$Name, [AllowEmptyString()][string]$Text)
            [System.IO.File]::WriteAllText((Join-Path $Room "agents\$Agent\inbox\$Name"), $Text, (New-Object System.Text.UTF8Encoding($false)))
        }

        function Get-DeliveredText {
            param([string]$Room, [string]$Agent = 'emma')
            $path = Join-Path $Room "agents\$Agent\delivered"
            if (-not [System.IO.File]::Exists($path)) { return '' }
            return [System.IO.File]::ReadAllText($path)
        }

        function Write-Marker {
            # A claim or a lock by hand: relay.ps1 creates a file, relay.sh a directory (mkdir); aged by $AgeSeconds
            param([string]$Path, [int]$AgeSeconds = 0, [switch]$Held)
            if ($engine -eq 'sh') { $null = New-Item -ItemType Directory -Path $Path -Force }
            else { [System.IO.File]::WriteAllText($Path, "held by a test`n") }
            if ($AgeSeconds -gt 0) { (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-$AgeSeconds) }
            # Held: fresh however long the call takes to look at it. A time in the future is not old for a tool that takes the age as now minus the file time (both tools do, as far as I know: not verified for a room on a share with another clock)
            if ($Held) { (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(120) }
        }

        function Wait-Listening {
            # A wait that was started is listening once its status says so; slow engines take their time
            param([string]$Room, [string]$Agent = 'emma')
            $until = [DateTime]::UtcNow.AddSeconds(40 * $pace)
            $path = Join-Path $Room "agents\$Agent\status"
            while ([DateTime]::UtcNow -lt $until) {
                if ([System.IO.File]::Exists($path)) {
                    try { if ([System.IO.File]::ReadAllText($path) -match '(?m)^state: listening') { return $true } } catch { $null = $_ }
                }
                Start-Sleep -Milliseconds 200
            }
            return $false
        }

        function Get-DotEntry {
            param([string]$Folder)
            return @(Get-ChildItem -LiteralPath $Folder -Force | Where-Object { $_.Name -like '.*' })
        }

        function Wait-ForFile {
            param([string]$Path, [int]$Seconds = 30)
            $until = [DateTime]::UtcNow.AddSeconds($Seconds * $pace)
            while ([DateTime]::UtcNow -lt $until) {
                if (Test-Path -LiteralPath $Path) { return $true }
                Start-Sleep -Milliseconds 100
            }
            return $false
        }

        function Open-Pause {
            # The environment of the one call that is to pause at $Point, and the folder it reports in
            param([string]$Room, [string]$Point)
            $folder = Join-Path $Room 'pause'
            $null = New-Item -ItemType Directory -Path $folder -Force
            return @{ RELAY_PAUSE_AT = $Point; RELAY_PAUSE_DIR = $folder }
        }

        function Skip-WithoutHook {
            # True (and the test marked skipped) while the tool does not have the pause point (or, for $Needs, the feature)
            param([string]$Point, [string]$Needs = '')
            if ($env:RELAY_FAULTS_RUN_HOOK_TESTS -eq '1') { return $false }
            if ($toolSource.Contains("'$Point'") -and ($Needs -eq '' -or $toolSource.Contains($Needs))) { return $false }
            # The gate sets RELAY_FAULTS_REQUIRE_HOOKS=1: a renamed or missing point is then a failure, not a quiet skip
            if ($env:RELAY_FAULTS_REQUIRE_HOOKS -eq '1') { throw "the tool has no pause point '$Point' $Needs" }
            Set-ItResult -Skipped -Because "waiting for the test hook point '$Point' $Needs in the tool (asked of Emma and Olivia)"
            return $true
        }
    }

    BeforeEach {
        $room = Copy-RelayTestRoom -Template $template -Target (Join-Path $root ('room-' + (New-RelayTestId)))
    }

    Context 'F1: delivery records only what it showed' {
        It 'neither announces nor records a message file that is still empty' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            $first = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $first.ExitCode | Should -Be 3
            $first.Output | Should -Not -Match 'new message'
            Get-DeliveredText -Room $room | Should -Not -Match 'olivia-emma-0001'
            # Once the sender has finished writing it, it is delivered like any other
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text (Get-ReadableMessage)
            $later = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $later.ExitCode | Should -Be 0
            $later.Output | Should -Match '=== 1 new message\(s\) for emma'
            $later.Output | Should -Match 'The text of 0001\.'
            Get-DeliveredText -Room $room | Should -Match '(?m)^olivia-emma-0001 '
        }

        It 'does not take a header without a type for a readable message' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text "---`nid: olivia-emma-0001`nfrom: olivia`nto: emma`n---`nNo type here.`n"
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $result.ExitCode | Should -Be 3
            $result.Output | Should -Not -Match 'No type here'
            Get-DeliveredText -Room $room | Should -Not -Match 'olivia-emma-0001'
            # A tool that delivers nothing at all would meet the above: the readable one beside it must come
            Write-InboxFile -Room $room -Name 'olivia-0002.md' -Text (Get-ReadableMessage -Number '0002' -Subject 'The readable one')
            $beside = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $beside.ExitCode | Should -Be 0
            $beside.Output | Should -Match '=== 1 new message\(s\) for emma'
            $beside.Output | Should -Match 'subject: The readable one'
            $beside.Output | Should -Not -Match 'No type here'
        }

        It 'prints, counts and records the readable messages only' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            Write-InboxFile -Room $room -Name 'olivia-0002.md' -Text (Get-ReadableMessage -Number '0002' -Subject 'The readable one')
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '=== 1 new message\(s\) for emma'
            $result.Output | Should -Match 'subject: The readable one'
            $delivered = Get-DeliveredText -Room $room
            $delivered | Should -Match '(?m)^olivia-emma-0002 '
            $delivered | Should -Not -Match 'olivia-emma-0001'
            # The unreadable one is not a message yet: the next look says nothing new
            (Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')).ExitCode | Should -Be 3
        }

        It 'goes on waiting when every new file is unreadable' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = [string]$waitMinute } -TimeoutSeconds (60 * $pace)
            $result.ExitCode | Should -Be 3
            $result.Output | Should -Match 'nothing arrived in 1 minutes'
            Get-DeliveredText -Room $room | Should -Not -Match 'olivia-emma-0001'
        }

        It 'leaves a message file that is held open by its writer pending, and delivers it when it is free' {
            if (-not $onWindows) { Set-ItResult -Skipped -Because 'a file cannot be held open without sharing on this system'; return }
            $path = Join-Path $room 'agents\emma\inbox\olivia-0001.md'
            [System.IO.File]::WriteAllText($path, (Get-ReadableMessage))
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                $held = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
                $held.ExitCode | Should -Be 3
                $held.Output | Should -Not -Match 'new message'
                Get-DeliveredText -Room $room | Should -Not -Match 'olivia-emma-0001'
            }
            finally { $stream.Dispose() }
            $free = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $free.ExitCode | Should -Be 0
            $free.Output | Should -Match 'The text of 0001\.'
        }

        It 'delivers an unreadable file once as a placeholder when it is older than two minutes' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            (Get-Item -LiteralPath (Join-Path $room 'agents\emma\inbox\olivia-0001.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            # A second one that is still young stays pending
            Write-InboxFile -Room $room -Name 'olivia-0002.md' -Text ''
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '=== 1 new message\(s\) for emma'
            $result.Output | Should -Match '(?m)^--- olivia-emma-0001 \| unreadable message from Olivia \(coordinator\) \| re: - \| sent - \| expects: none$'
            $block = "subject: (this message could not be read)`n`nIts file is in your inbox but cannot be read, or has no valid header. It is recorded as delivered so that it does not wake you again.`n`nDO: ask its sender to send it again; if you have no line to the sender, tell the coordinator."
            $result.Output.Contains($block) | Should -BeTrue
            $result.Output | Should -Not -Match 'olivia-emma-0002'
            $delivered = Get-DeliveredText -Room $room
            $delivered | Should -Match '(?m)^olivia-emma-0001 '
            $delivered | Should -Not -Match 'olivia-emma-0002'
            (Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')).ExitCode | Should -Be 3
        }

        It 'measures the two minutes in the length of a minute of the tool' {
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            $fast = @{ RELAY_MINUTE_SECONDS = [string]$shortMinute }
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $young = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $fast
            $clock.Stop()
            # The file has to be young at the first look: two tool minutes are 30 seconds, and one call took as long as it took
            if ($clock.Elapsed.TotalSeconds -gt (2 * $shortMinute - 8)) { Set-ItResult -Skipped -Because "one call took $([int]$clock.Elapsed.TotalSeconds) seconds, too long for the margin of this test"; return }
            $young.ExitCode | Should -Be 3
            Start-Sleep -Seconds (2 * $shortMinute + 2)
            $old = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $fast
            $old.ExitCode | Should -Be 0
            $old.Output | Should -Match 'unreadable message from Olivia'
        }

        It 'does not count an unreadable file as a request or let it close one (also true of the tool before the fixes)' {
            # A task that can be read, a file beside it that cannot, and an unreadable result in the inbox of the sender
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text (Get-ReadableMessage -Type 'task' -Subject 'A real task')
            Write-InboxFile -Room $room -Name 'olivia-0002.md' -Text ''
            Write-InboxFile -Room $room -Agent 'olivia' -Name 'emma-0002.md' -Text ''
            $open = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('show', 'open')
            $open.ExitCode | Should -Be 0
            $open.Output | Should -Match 'you owe a reply to 1'
            $open.Output | Should -Match 'olivia-emma-0001'
            $open.Output | Should -Not -Match 'olivia-emma-0002'
        }
    }

    Context 'F2: a send that created no message fails' {        BeforeAll {
            # Every number the loop can try (it tries 500, from the next free one) is taken by a folder under files, 700 of them:
            # with an attachment the send cannot place it
            $f2Room = Copy-RelayTestRoom -Template $template -Target (Join-Path $root ('room-' + (New-RelayTestId)))
            $null = New-Item -ItemType Directory -Path (Join-Path $f2Room 'files') -Force
            foreach ($number in 1..700) { $null = [System.IO.Directory]::CreateDirectory((Join-Path $f2Room ('files\emma-olivia-{0:0000}' -f $number))) }
            $null = New-Item -ItemType Directory -Path (Join-Path $f2Room 'agents\emma\attach') -Force
            [System.IO.File]::WriteAllText((Join-Path $f2Room 'agents\emma\attach\evidence.txt'), "evidence`n")
            $f2Text = "Cannot be sent`n`nThe text that must not be lost."
            Set-RelayTestDraft -Room $f2Room -Agent 'emma' -Text $f2Text
            $f2 = Invoke-RelayTool -Room $f2Room -Agent 'emma' -Engine $engine -Words @('note') -TimeoutSeconds (240 * $pace)
        }

        It 'says so and exits with 2 instead of reporting SENT' {
            $f2.ExitCode | Should -Be 2
            $f2.Output | Should -Not -Match 'SENT '
            $f2.Output | Should -Match '(?m)^ERROR: could not find a free message number in .*inbox'
            $f2.Output | Should -Match '(?m)^NEXT: tell the coordinator'
            # No message was created, and no claim or temporary file is left in the inbox
            @(Get-RelayTestInbox -Room $f2Room -Agent 'olivia' -From 'emma').Count | Should -Be 1
            @(Get-DotEntry (Join-Path $f2Room 'agents\olivia\inbox')).Count | Should -Be 0
        }

        It 'keeps the draft' {
            $draft = Join-Path $f2Room 'agents\emma\draft.md'
            Test-Path -LiteralPath $draft | Should -BeTrue
            ([System.IO.File]::ReadAllText($draft) -replace "`r", '') | Should -BeExactly $f2Text
        }

        It 'puts the attachments back and removes the staging folder' {
            Test-Path -LiteralPath (Join-Path $f2Room 'agents\emma\attach\evidence.txt') | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $f2Room 'files') -Force | Where-Object { $_.Name -like '.staging-*' }).Count | Should -Be 0
        }

        It 'ends a wait whose lease another wait has taken before it says that the agent is paused' {
            # F4b: also the pause and resume lines are said only by the wait that owns the lease
            $waiting = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = [string](30 * $pace) }
            Wait-Listening -Room $room | Should -BeTrue
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\wait.lease'), "token: somebody-else`ngen: 1`nhost: elsewhere`npid: 1`n")
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\control'), "state: pause`n")
            $result = Wait-RelayTool -Handle $waiting -TimeoutSeconds (60 * $pace)
            $result.ExitCode | Should -Be 4
            $result.Output | Should -Match 'another wait took over for emma'
            $result.Output | Should -Not -Match 'you are paused'
        }

        It 'ends a wait whose lease another wait has taken before it announces a proposal as due' {
            $waiting = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = [string](30 * $pace) }
            Wait-Listening -Room $room | Should -BeTrue
            # Both at once, so that the wait finds the lease gone and the proposal due in the same look
            $longAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1000
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\wait.lease'), "token: somebody-else`ngen: 1`nhost: elsewhere`npid: 1`n")
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\proposals'), "emma-olivia-0002 1 $longAgo open`n")
            $result = Wait-RelayTool -Handle $waiting -TimeoutSeconds (60 * $pace)
            $result.ExitCode | Should -Be 4
            $result.Output | Should -Match 'another wait took over for emma'
            $result.Output | Should -Not -Match 'no objection'
        }
    }

    Context 'F2b: a send that fails while it prepares the attachments' {        It 'puts every attachment back, keeps the draft and removes the staging folder' {
            if (-not $onWindows) { Set-ItResult -Skipped -Because 'a file cannot be held open without sharing on this system'; return }
            # The last of three files is held: the tools take them in the order of their names, so A and B are already moved when C fails
            $attach = Join-Path $room 'agents\emma\attach'
            $null = New-Item -ItemType Directory -Path $attach -Force
            [System.IO.File]::WriteAllText((Join-Path $attach 'A.txt'), "first`n")
            [System.IO.File]::WriteAllText((Join-Path $attach 'B.txt'), "second`n")
            [System.IO.File]::WriteAllText((Join-Path $attach 'C.txt'), "third`n")
            $text = "Held attachment`n`nOne of the files cannot be moved."
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text $text
            $stream = [System.IO.File]::Open((Join-Path $attach 'C.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try { $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('note') -TimeoutSeconds (60 * $pace) }
            finally { $stream.Dispose() }
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Not -Match 'SENT '
            Test-Path -LiteralPath (Join-Path $attach 'A.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $attach 'B.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $attach 'C.txt') | Should -BeTrue
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md')) -replace "`r", '') | Should -BeExactly $text
            @(Get-ChildItem -LiteralPath (Join-Path $room 'files') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.staging-*' }).Count | Should -Be 0
            @(Get-RelayTestInbox -Room $room -Agent 'olivia' -From 'emma').Count | Should -Be 1
        }
    }
    Context 'F3: one number, one sender' {
        It 'removes a claim that a dead sender left behind and skips its number' {
            $inbox = Join-Path $room 'agents\olivia\inbox'
            $number = 2
            Write-Marker -Path (Join-Path $inbox ('.claim-emma-{0:0000}' -f $number)) -AgeSeconds 300
            $sent = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Text "After a dead sender`n`nText."
            $sent.ExitCode | Should -Be 0
            $sent.Output | Should -Match 'SENT emma-olivia-0003 '
            @(Get-DotEntry $inbox).Count | Should -Be 0
        }

        It 'skips a number whose claim is held and leaves that claim alone' {
            $inbox = Join-Path $room 'agents\olivia\inbox'
            $claim = Join-Path $inbox '.claim-emma-0002'
            Write-Marker -Path $claim -Held
            $sent = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Text "Beside a claim`n`nText."
            $sent.ExitCode | Should -Be 0
            $sent.Output | Should -Match 'SENT emma-olivia-0003 '
            Test-Path -LiteralPath $claim | Should -BeTrue
        }

        It 'gives a send without attachments another number than one that has placed its files and not yet its message' {
            if (Skip-WithoutHook 'send-placed') { return }
            $pause = Open-Pause -Room $room -Point 'send-placed'
            $draftA = Join-Path $room 'agents\emma\draft-a.md'
            $draftB = Join-Path $room 'agents\emma\draft-b.md'
            Set-RelayTestDraft -Room $room -Agent 'emma' -Path $draftA -Text "With files`n`nFirst session."
            Set-RelayTestDraft -Room $room -Agent 'emma' -Path $draftB -Text "Without files`n`nSecond session."
            $null = New-Item -ItemType Directory -Path (Join-Path $room 'agents\emma\attach') -Force
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\attach\mine.txt'), "mine`n")
            $inbox = Join-Path $room 'agents\olivia\inbox'
            $first = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Environment ($pause + @{ RELAY_DRAFT = $draftA })
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'send-placed.reached') | Should -BeTrue
                $second = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Environment @{ RELAY_DRAFT = $draftB }
                $second.ExitCode | Should -Be 0
                $secondId = ([regex]::Match($second.Output, 'SENT (emma-olivia-\d{4,6})')).Groups[1].Value
                $secondId | Should -Not -BeNullOrEmpty
                # The first session has its files in place under the id it is about to use
                $placed = @(Get-ChildItem -LiteralPath (Join-Path $room 'files') -Directory | Where-Object { $_.Name -like 'emma-olivia-*' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'mine.txt')) })
                $placed.Count | Should -Be 1
                $secondId | Should -Not -BeExactly $placed[0].Name
                $secondFolder = Join-Path $room "files\$secondId"
                Test-Path -LiteralPath $secondFolder | Should -BeFalse
                # The message file is the last thing to appear: while the claim is held it is not there yet
                $heldNumber = $placed[0].Name.Substring($placed[0].Name.Length - 4)
                Test-Path -LiteralPath (Join-Path $inbox ('emma-' + $heldNumber + '.md')) | Should -BeFalse
                # While it holds the number, the claim shows it
                Test-Path -LiteralPath (Join-Path $inbox ('.claim-emma-' + $placed[0].Name.Substring($placed[0].Name.Length - 4))) | Should -BeTrue
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'send-placed.go'), 'go') }
            $done = Wait-RelayTool -Handle $first -TimeoutSeconds (60 * $pace)
            $done.ExitCode | Should -Be 0
            $done.Output | Should -Match ('SENT ' + [regex]::Escape($placed[0].Name))
            @(Get-DotEntry $inbox).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $room ("files\$($placed[0].Name)\mine.txt")) | Should -BeTrue
        }
    }

    Context 'F4: one wait per agent, also when two start at once' {
        It 'answers as if a wait were running while another call holds the lease lock' {
            Write-Marker -Path (Join-Path $room 'agents\emma\wait.lease.lock') -Held
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $watch.Stop()
            $result.ExitCode | Should -Be 4
            $result.Output | Should -Match 'another wait is already running for emma'
            # It tries for about three seconds first
            $watch.Elapsed.TotalSeconds | Should -BeGreaterThan $lockWait
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\wait.lease.lock') | Should -BeTrue
        }

        It 'removes a lease lock that is older than 15 seconds and goes on' {
            $lock = Join-Path $room 'agents\emma\wait.lease.lock'
            Write-Marker -Path $lock -AgeSeconds 40
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $result.ExitCode | Should -Be 3
            Test-Path -LiteralPath $lock | Should -BeFalse
        }

        It 'lets only one of two waits that start together on a dead lease deliver' {
            if (Skip-WithoutHook 'lease-judged') { return }
            $pause = Open-Pause -Room $room -Point 'lease-judged'
            $lease = Join-Path $room 'agents\emma\wait.lease'
            [System.IO.File]::WriteAllText($lease, "token: dead`ngen: 1`nhost: elsewhere`npid: 1`n")
            (Get-Item -LiteralPath $lease).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-120)
            $first = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment $pause
            $second = $null
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'lease-judged.reached') | Should -BeTrue
                # The second call finds the same dead lease while the first one is between judging it and replacing it
                $second = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1')
                $null = $second.Process.WaitForExit(6 * $pace * 1000)
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'lease-judged.go'), 'go') }
            Start-Sleep -Seconds (2 * $pace)
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('note', 'emma') -Text "One message`n`nOne reader."
            $one = Wait-RelayTool -Handle $first -TimeoutSeconds (60 * $pace)
            $two = Wait-RelayTool -Handle $second -TimeoutSeconds (60 * $pace)
            $readers = @(@($one, $two) | Where-Object { $_.Output -match '=== 1 new message' })
            $readers.Count | Should -Be 1
            @(@($one, $two) | Where-Object { $_.ExitCode -eq 4 }).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\wait.lease.lock') | Should -BeFalse
        }

        It 'ends a wait whose lease another wait has taken, and delivers nothing' {
            # F4b: the lease is confirmed directly before anything is said that an agent acts on
            $waiting = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = [string](30 * $pace) }
            Wait-Listening -Room $room | Should -BeTrue
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\wait.lease'), "token: somebody-else`ngen: 1`nhost: elsewhere`npid: 1`n")
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('note', 'emma') -Text "Not for the old wait`n`nThe new wait has to show it."
            $result = Wait-RelayTool -Handle $waiting -TimeoutSeconds (60 * $pace)
            $result.ExitCode | Should -Be 4
            $result.Output | Should -Match 'another wait took over for emma'
            $result.Output | Should -Not -Match 'new message'
            Get-DeliveredText -Room $room | Should -Not -Match 'olivia-emma-0001'
        }

        It 'does not let a refresh overwrite the lease that another wait took while it held the lock' {
            # F4a: a wait is between reading its own token and writing the refresh when a second one finds the lease dead
            if (Skip-WithoutHook 'lease-refresh') { return }
            $pause = Open-Pause -Room $room -Point 'lease-refresh'
            $first = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment ($pause + @{ RELAY_MINUTE_SECONDS = [string](30 * $pace) })
            $second = $null
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'lease-refresh.reached') 40 | Should -BeTrue
                (Get-Item -LiteralPath (Join-Path $room 'agents\emma\wait.lease')).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-60)
                $second = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = [string](30 * $pace) }
                $null = $second.Process.WaitForExit(6 * $pace * 1000)
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'lease-refresh.go'), 'go') }
            Start-Sleep -Seconds (2 * $pace)
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('note', 'emma') -Text "One message`n`nOne reader."
            $one = Wait-RelayTool -Handle $first -TimeoutSeconds (60 * $pace)
            $two = Wait-RelayTool -Handle $second -TimeoutSeconds (60 * $pace)
            @(@($one, $two) | Where-Object { $_.Output -match '=== 1 new message' }).Count | Should -Be 1
        }
    }

    Context 'F5: the audit of a folder that is gone' {
        BeforeAll {
            $f5Number = New-RelayTestId
            $f5Work = Join-Path $root "work-$f5Number"
            $null = New-Item -ItemType Directory -Path (Join-Path $f5Work 'src'), (Join-Path $f5Work 'docs') -Force
            [System.IO.File]::WriteAllText((Join-Path $f5Work 'src\a.txt'), "a`n")
            [System.IO.File]::WriteAllText((Join-Path $f5Work 'docs\readme.txt'), "readme`n")
            $f5ForTool = $f5Work
            if ($engine -eq 'sh') { $f5ForTool = $f5Work -replace '\\', '/' }
            $f5Agents = @([ordered]@{ name = 'emma'; role = 'developer'; kind = 'generic'; transport = 'same-pc'; work = 'development'; roots = @(@{ root = $f5ForTool; may = @('src/*') }) })
            $f5Room = (New-RelayTestRoom -Root (Join-Path $root "f5-$f5Number") -RoomId "f5-$engine-$f5Number" -Agents $f5Agents).Path
            foreach ($agent in 'olivia', 'emma') { $null = Invoke-RelayTool -Room $f5Room -Agent $agent -Engine $engine -Words @('start', 'p', 'm', 'e') }
            $null = Send-RelayTestMessage -Room $f5Room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Work`n`nWork in the folder."
            $null = Invoke-RelayTool -Room $f5Room -Agent 'emma' -Engine $engine -Words @('check')
            Remove-Item -LiteralPath $f5Work -Recurse -Force
            $f5 = Send-RelayTestMessage -Room $f5Room -Agent 'emma' -Engine $engine -Words @('report') -Text "Folder gone`n`n1. Result: the folder was deleted."
            $f5Audit = ''
            # The id of the report as the tool printed it (not a number the test has counted for itself)
            $f5Id = [regex]::Match($f5.Output, 'SENT (emma-olivia-\d+) \(result').Groups[1].Value
            $auditFile = Join-Path $f5Room ('files\' + $f5Id + '\self-audit.txt')
            if (Test-Path -LiteralPath $auditFile) { $f5Audit = (Get-Content -LiteralPath $auditFile -Raw) -replace "`r", '' }
        }

        It 'still sends the report' {
            $f5.ExitCode | Should -Be 0
            $f5.Output | Should -Match 'SENT emma-olivia-\d+ \(result of olivia-emma-0001\)'
            $f5Id | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $f5Room ('agents\olivia\inbox\' + $f5Id.Replace('-olivia', '') + '.md')) | Should -BeTrue
        }

        It 'audits the folder as empty: every file of its baseline is listed as deleted' {
            $f5Audit | Should -Match '(?m)^  ok       D  src/a\.txt$'
            $f5Audit | Should -Match '(?m)^  OUTSIDE  D  docs/readme\.txt$'
            $f5.Output | Should -Match 'self-audit: 2 changed since start, 1 OUTSIDE the assigned paths'
        }

        It 'says in the heading line of the folder that it is gone, once' {
            $heading = @($f5Audit -split "`n" | Where-Object { $_ -like 'root: *' })
            $heading.Count | Should -Be 1
            $heading[0] | Should -BeExactly "root: $f5ForTool (files; the folder is gone, every file of the baseline is listed as deleted)"
        }

        It 'says so for a git folder that is gone, with its baseline commit, and does not compare it' {
            # The baseline of a git folder is made by hand (git need not be installed): a commit and the status at start
            $gitNumber = New-RelayTestId
            $gitWork = Join-Path $root "gitwork-$gitNumber"
            $null = New-Item -ItemType Directory -Path $gitWork -Force
            [System.IO.File]::WriteAllText((Join-Path $gitWork 'a.txt'), "a`n")
            $gitForTool = $gitWork
            if ($engine -eq 'sh') { $gitForTool = $gitWork.Replace([string][char]92, '/') }
            $gitAgents = @([ordered]@{ name = 'emma'; role = 'developer'; kind = 'generic'; transport = 'same-pc'; work = 'development'; roots = @(@{ root = $gitForTool; may = @('*') }) })
            $gitRoom = (New-RelayTestRoom -Root (Join-Path $root "git-$gitNumber") -RoomId "git-$engine-$gitNumber" -Agents $gitAgents).Path
            foreach ($agent in 'olivia', 'emma') { $null = Invoke-RelayTool -Room $gitRoom -Agent $agent -Engine $engine -Words @('start', 'p', 'm', 'e') }
            $baseline = Join-Path $gitRoom 'agents\emma\baseline'
            foreach ($item in @(Get-ChildItem -LiteralPath $baseline -File | Where-Object { $_.Name -like 'g1-root1.*' })) { [System.IO.File]::Delete($item.FullName) }
            $commit = '0123456789abcdef0123456789abcdef01234567'
            [System.IO.File]::WriteAllText((Join-Path $baseline 'g1-root1.git-head'), "$commit`n")
            [System.IO.File]::WriteAllText((Join-Path $baseline 'g1-root1.git-status'), "`n")
            $null = Send-RelayTestMessage -Room $gitRoom -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Work`n`nWork in the folder."
            $null = Invoke-RelayTool -Room $gitRoom -Agent 'emma' -Engine $engine -Words @('check')
            [System.IO.Directory]::Delete($gitWork, $true)
            $report = Send-RelayTestMessage -Room $gitRoom -Agent 'emma' -Engine $engine -Words @('report') -Text "Gone`n`n1. Result: the git folder was deleted."
            $report.ExitCode | Should -Be 0
            $gitId = [regex]::Match($report.Output, 'SENT (emma-olivia-\d+) \(result').Groups[1].Value
            $audit = (Get-Content -LiteralPath (Join-Path $gitRoom ('files\' + $gitId + '\self-audit.txt')) -Raw) -replace "`r", ''
            $heading = @($audit -split "`n" | Where-Object { $_ -like 'root: *' })
            $heading.Count | Should -Be 1
            $heading[0] | Should -BeExactly "root: $gitForTool (git, baseline $commit; the folder is gone: NOT COMPARED)"
            $report.Output | Should -Match 'NOT COMPARED'
        }
    }

    Context 'F6: a denial is final' {        It 'does not tell the agent to proceed when the proposals file is written back with a denied proposal open' {
            $fast = @{ RELAY_MINUTE_SECONDS = [string]$shortMinute }
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Rename a file`n`nI will rename it."
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('reply', 'emma-olivia-0002', 'deny')).ExitCode | Should -Be 0
            $told = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')
            $told.Output | Should -Match 'DO: it was denied\.'
            # What a propose that ran during the delivery writes back from its older copy: the proposal open again, receipt seen long ago
            $longAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1000
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\proposals'), "emma-olivia-0002 1 $longAgo open`n")
            $after = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '3') -Environment $fast
            $after.Output | Should -Not -Match 'no objection'
            $after.ExitCode | Should -Be 3
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\proposals')) -replace "`r", '') | Should -Match '(?m)^emma-olivia-0002 1 \S+ closed$'
        }

        It 'keeps an entry that another call closed, and one that it added, when a write is in flight' {
            if (Skip-WithoutHook 'proposals-write') { return }
            $pause = Open-Pause -Room $room -Point 'proposals-write'
            $proposals = Join-Path $room 'agents\emma\proposals'
            $longAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1000
            [System.IO.File]::WriteAllText($proposals, "emma-olivia-0002 1 $longAgo open`n")
            # This wait finds the proposal due and is about to write that down
            $waiting = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment ($pause + @{ RELAY_MINUTE_SECONDS = [string]$waitMinute })
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'proposals-write.reached') | Should -BeTrue
                # Meanwhile another call closes the proposal and adds a new one
                [System.IO.File]::WriteAllText($proposals, "emma-olivia-0002 1 $longAgo closed`nemma-olivia-0003 5 - open`n")
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'proposals-write.go'), 'go') }
            $null = Wait-RelayTool -Handle $waiting -TimeoutSeconds (60 * $pace)
            $text = [System.IO.File]::ReadAllText($proposals) -replace "`r", ''
            $text | Should -Match '(?m)^emma-olivia-0002 1 \S+ closed$'
            $text | Should -Match '(?m)^emma-olivia-0003 5 \S+ open$'
        }

        It 'does not announce a proposal as due while the inbox holds a message that has not been shown' {
            # F6b: what cannot be read yet may be the denial
            $fast = @{ RELAY_MINUTE_SECONDS = [string]$waitMinute }
            $longAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1000
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\proposals'), "emma-olivia-0002 1 $longAgo open`n")
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            $result = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment $fast -TimeoutSeconds (60 * $pace)
            $result.Output | Should -Not -Match 'no objection'
            $result.ExitCode | Should -Be 3
        }

        It 'leaves the proposals file alone while another call holds its lock, and goes on' {
            # F6a: an update that cannot get proposals.lock is skipped; the inbox stays the authority
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Rename a file`n`nI will rename it."
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('reply', 'emma-olivia-0002', 'deny')).ExitCode | Should -Be 0
            $proposals = Join-Path $room 'agents\emma\proposals'
            $before = [System.IO.File]::ReadAllText($proposals)
            Write-Marker -Path (Join-Path $room 'agents\emma\proposals.lock') -Held
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $told = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $watch.Stop()
            $told.ExitCode | Should -Be 0
            $told.Output | Should -Match 'DO: it was denied\.'
            $watch.Elapsed.TotalSeconds | Should -BeGreaterThan $lockWait
            [System.IO.File]::ReadAllText($proposals) | Should -BeExactly $before
        }

        It 'takes away a proposals lock that is older than 15 seconds and updates the file' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Rename a file`n`nI will rename it."
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('reply', 'emma-olivia-0002', 'deny')).ExitCode | Should -Be 0
            $lock = Join-Path $room 'agents\emma\proposals.lock'
            Write-Marker -Path $lock -AgeSeconds 40
            $told = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $told.ExitCode | Should -Be 0
            Test-Path -LiteralPath $lock | Should -BeFalse
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\proposals')) -replace "`r", '') | Should -Match '(?m)^emma-olivia-0002 1 \S+ closed$'
        }

        It 'makes a second call that delivers a denial wait for the lock of a call that is writing' {
            if (Skip-WithoutHook 'proposals-write' 'proposals.lock') { return }
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "First`n`nFirst proposal."
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('reply', 'emma-olivia-0002', 'deny')).ExitCode | Should -Be 0
            $pause = Open-Pause -Room $room -Point 'proposals-write'
            $proposals = Join-Path $room 'agents\emma\proposals'
            $draft = Join-Path $room 'agents\emma\draft-second.md'
            Set-RelayTestDraft -Room $room -Agent 'emma' -Path $draft -Text "Second`n`nSecond proposal."
            $writer = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '5') -Environment ($pause + @{ RELAY_DRAFT = $draft })
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'proposals-write.reached') | Should -BeTrue
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $told = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
                $watch.Stop()
                $told.ExitCode | Should -Be 0
                $watch.Elapsed.TotalSeconds | Should -BeGreaterThan $lockWait
                ([System.IO.File]::ReadAllText($proposals) -replace "`r", '') | Should -Match '(?m)^emma-olivia-0002 1 \S+ open$'
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'proposals-write.go'), 'go') }
            (Wait-RelayTool -Handle $writer -TimeoutSeconds (60 * $pace)).ExitCode | Should -Be 0
            ([System.IO.File]::ReadAllText($proposals) -replace "`r", '') | Should -Match '(?m)^emma-olivia-0003 5 \S+ open$'
        }

        It 'sends a proposal that cannot be noted because the lock is held, and never notes it' {
            # T5: a proposal is noted inside proposals.lock or not at all; without the note it never comes due by itself
            $proposals = Join-Path $room 'agents\emma\proposals'
            $lock = Join-Path $room 'agents\emma\proposals.lock'
            Write-Marker -Path $lock -Held
            $sent = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Locked out`n`nI will rename it." 
            $sent.ExitCode | Should -Be 0
            $sent.Output | Should -Match 'SENT emma-olivia-0002 \(proposal\)'
            @(Get-RelayTestInbox -Room $room -Agent 'olivia' -From 'emma') | Should -Contain 'emma-0002.md'
            $noted = ''
            if (Test-Path -LiteralPath $proposals) { $noted = [System.IO.File]::ReadAllText($proposals) }
            $noted | Should -Not -Match 'emma-olivia-0002'
            # Not later either, when the lock is gone and the tool looks again
            if ($engine -eq 'sh') { [System.IO.Directory]::Delete($lock, $true) } else { [System.IO.File]::Delete($lock) }
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            $null = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $later = ''
            if (Test-Path -LiteralPath $proposals) { $later = [System.IO.File]::ReadAllText($proposals) }
            $later | Should -Not -Match 'emma-olivia-0002'
        }

        It 'notes the receipt of a proposal while a message cannot be read, and announces nothing as due' {
            # T6: the receipt time is noted all the same; a proposal is not announced while the inbox holds a message not shown
            $fast = @{ RELAY_MINUTE_SECONDS = [string]$waitMinute }
            $proposals = Join-Path $room 'agents\emma\proposals'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Rename`n`nI will rename it."
            $null = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')
            Write-InboxFile -Room $room -Name 'olivia-0001.md' -Text ''
            $round = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $fast -TimeoutSeconds (60 * $pace)
            $round.ExitCode | Should -Be 3
            $round.Output | Should -Not -Match 'no objection'
            $line = @(([System.IO.File]::ReadAllText($proposals) -replace "`r", '') -split "`n" | Where-Object { $_ -like 'emma-olivia-0002 *' })
            $line.Count | Should -Be 1
            @($line[0] -split ' ')[2] | Should -Match '^\d+$'
            # However long ago the time ran out, nothing is announced while the file is unreadable and young
            $longAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1000
            [System.IO.File]::WriteAllText($proposals, "emma-olivia-0002 1 $longAgo open`n")
            $again = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check') -Environment $fast -TimeoutSeconds (60 * $pace)
            $again.ExitCode | Should -Be 3
            $again.Output | Should -Not -Match 'no objection'
        }
    }

    Context 'F7: a replaced session sends nothing, bye included' {
        It 'refuses bye to a replaced session although its control says stop, and lets the current one say it' {
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\gen'), "2`n")
            foreach ($name in 'emma', 'jack') { [System.IO.File]::WriteAllText((Join-Path $room "agents\$name\control"), "state: stop`n") }
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text "Leaving`n`nI am the old session."
            $old = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('bye') -Generation 1
            $old.ExitCode | Should -Be 5
            $old.Output | Should -Match 'a new session \(generation 2\) has replaced you as emma'
            @(Get-RelayTestInbox -Room $room -Agent 'olivia' -From 'emma').Count | Should -Be 1
            $current = Invoke-RelayTool -Room $room -Agent 'jack' -Engine $engine -Words @('bye') -Generation 1
            $current.ExitCode | Should -Be 0
            $current.Output | Should -Match 'SENT jack-olivia-0002 \(bye\)'
            # Not in a room that is closed, and not for a retired agent, whatever control says
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\henry\control'), "state: stop`n")
            [System.IO.File]::WriteAllText((Join-Path $room 'agents\henry\retired'), "retired`n")
            (Invoke-RelayTool -Room $room -Agent 'henry' -Engine $engine -Words @('bye')).ExitCode | Should -Be 5
            [System.IO.File]::WriteAllText((Join-Path $room 'CLOSED'), "closed`n")
            (Invoke-RelayTool -Room $room -Agent 'jack' -Engine $engine -Words @('bye')).ExitCode | Should -Be 5
            @(Get-RelayTestInbox -Room $room -Agent 'olivia' -From 'henry').Count | Should -Be 1
            @(Get-RelayTestInbox -Room $room -Agent 'olivia' -From 'jack').Count | Should -Be 2
        }

    }

    Context 'F8: a new assignment counts as seen only after it was shown' {
        It 'shows it with the next call when the baseline could not be rebuilt the first time' {
            if (-not $onWindows) { Set-ItResult -Skipped -Because 'a file cannot be held open without sharing on this system'; return }
            $f8Number = New-RelayTestId
            $f8Work = Join-Path $root "work-$f8Number"
            $null = New-Item -ItemType Directory -Path $f8Work -Force
            [System.IO.File]::WriteAllText((Join-Path $f8Work 'before.txt'), "old baseline`n")
            $f8ForTool = $f8Work
            if ($engine -eq 'sh') { $f8ForTool = $f8Work -replace '\\', '/' }
            $f8Agents = @([ordered]@{ name = 'emma'; role = 'developer'; kind = 'generic'; transport = 'same-pc'; work = 'development'; roots = @(@{ root = $f8ForTool; may = @('*') }) })
            $f8Room = (New-RelayTestRoom -Root (Join-Path $root "f8-$f8Number") -RoomId "f8-$engine-$f8Number" -Agents $f8Agents).Path
            foreach ($agent in 'olivia', 'emma') { $null = Invoke-RelayTool -Room $f8Room -Agent $agent -Engine $engine -Words @('start', 'p', 'm', 'e') }
            $assignment = Join-Path $f8Room 'agents\emma\ASSIGNMENT.md'
            [System.IO.File]::AppendAllText($assignment, "`nA new limit that has to be shown.`n")
            $null = Send-RelayTestMessage -Room $f8Room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "New work`n`nDo it."
            # The baseline of a plain folder: relay.ps1 keeps a .manifest, relay.sh a .list (with a .marker next to it)
            $baselineKind = 'manifest'
            if ($engine -eq 'sh') { $baselineKind = 'list' }
            $manifest = Join-Path $f8Room ('agents\emma\baseline\g1-root1.' + $baselineKind)
            Test-Path -LiteralPath $manifest | Should -BeTrue
            $stream = [System.IO.File]::Open($manifest, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try { $null = Invoke-RelayTool -Room $f8Room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace) }
            finally { $stream.Dispose() }
            $again = Invoke-RelayTool -Room $f8Room -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $again.ExitCode | Should -Be 0
            $again.Output | Should -Match '(?s)=== your assignment has changed.*A new limit that has to be shown\..*=== 1 new message'
            Test-Path -LiteralPath (Join-Path $f8Room 'agents\emma\baseline\g1.done') | Should -BeTrue
            # Shown once
            $null = Send-RelayTestMessage -Room $f8Room -Agent 'olivia' -Engine $engine -Words @('note', 'emma') -Text "More`n`nNothing."
            (Invoke-RelayTool -Room $f8Room -Agent 'emma' -Engine $engine -Words @('check')).Output | Should -Not -Match 'assignment has changed'
        }

        It 'shows the first assignment with the next call when start failed before it could show it' {
            $startNumber = New-RelayTestId
            $startRoom = (New-RelayTestRoom -Root (Join-Path $root "f8s-$startNumber") -RoomId "f8s-$engine-$startNumber").Path
            [System.IO.File]::WriteAllText((Join-Path $startRoom 'agents\emma\ASSIGNMENT.md'), "Important first assignment that must be shown.`n")
            # The hello cannot get a number, so start fails after it has read the assignment and before it has printed it
            $null = New-Item -ItemType Directory -Path (Join-Path $startRoom 'files') -Force
            foreach ($number in 1..700) { $null = [System.IO.Directory]::CreateDirectory((Join-Path $startRoom ('files\emma-olivia-{0:0000}' -f $number))) }
            $started = Invoke-RelayTool -Room $startRoom -Agent 'emma' -Engine $engine -Words @('start', 'p', 'm', 'e') -TimeoutSeconds (240 * $pace)
            $started.ExitCode | Should -Not -Be 0
            $started.Output | Should -Match 'could not find a free message number'
            $null = Invoke-RelayTool -Room $startRoom -Agent 'olivia' -Engine $engine -Words @('start', 'p', 'm', 'e')
            $null = Send-RelayTestMessage -Room $startRoom -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "First task`n`nRead the assignment first."
            $first = Invoke-RelayTool -Room $startRoom -Agent 'emma' -Engine $engine -Words @('check') -TimeoutSeconds (60 * $pace)
            $first.ExitCode | Should -Be 0
            $first.Output | Should -Match 'Important first assignment that must be shown\.'
            $first.Output | Should -Match '=== 1 new message'
        }
    }

    Context 'F2c: a failure after the attachments were staged' {
        It 'puts every attachment back when the inbox of the recipient is gone before the number is chosen' {
            if (Skip-WithoutHook 'send-staged') { return }
            $pause = Open-Pause -Room $room -Point 'send-staged'
            $attach = Join-Path $room 'agents\emma\attach'
            $null = New-Item -ItemType Directory -Path $attach -Force
            [System.IO.File]::WriteAllText((Join-Path $attach 'A.txt'), "must be restored`n")
            $text = "Inbox gone`n`nThe listing of the inbox fails."
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text $text
            $sending = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('note') -Environment $pause
            try {
                Wait-ForFile (Join-Path $pause.RELAY_PAUSE_DIR 'send-staged.reached') | Should -BeTrue
                [System.IO.Directory]::Delete((Join-Path $room 'agents\olivia\inbox'), $true)
            }
            finally { [System.IO.File]::WriteAllText((Join-Path $pause.RELAY_PAUSE_DIR 'send-staged.go'), 'go') }
            $result = Wait-RelayTool -Handle $sending -TimeoutSeconds (60 * $pace)
            @(Get-ChildItem -LiteralPath (Join-Path $room 'files') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.staging-*' }).Count | Should -Be 0
            if ($result.ExitCode -eq 0) {
                # The inbox was made again and the message sent: the file is where the message says
                $result.Output | Should -Match 'SENT emma-olivia-'
                @(Get-ChildItem -LiteralPath (Join-Path $room 'files') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'A.txt') }).Count | Should -Be 1
            }
            else {
                $result.Output | Should -Not -Match 'SENT '
                Test-Path -LiteralPath (Join-Path $attach 'A.txt') | Should -BeTrue
                ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md')) -replace "`r", '') | Should -BeExactly $text
            }
        }
    }
}
