#Requires -Version 5.1

<#
    The coordinator's scripts and the module do not believe the room: what a room is comes from this PC's index
    and canonical copy (G1), the tamper check goes on after a file it cannot restore (G2), the coordinator runs
    its own launcher (G4), the owner's log covers the whole message file (G6), numbers that do not fit are a
    failed send (G8) or 0 (G9), generations, seats and controls come from this PC's copy (G10), the prompts are
    guarded (G11), ssh is refused (G13), text from a room file is printed without control characters (G14).
    Runs under PowerShell 7 and Windows PowerShell 5.1. Pester 6. ASCII only.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $scripts = Get-RelayTestPath scripts
    Import-Module (Join-Path $scripts 'RelayCommon.psm1') -Force
    $savedLocal = $env:AGENT_RELAY_LOCAL

    function Get-GuardFile {
        # The text of a file as it is, or an empty string
        param([string]$Path)
        if (-not [System.IO.File]::Exists($Path)) { return '' }
        return [System.IO.File]::ReadAllText($Path)
    }
}

AfterAll {
    $env:AGENT_RELAY_LOCAL = $savedLocal
}

Describe 'Resolve-RelayRoom: the index and the canonical copy say what a room is' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "resolve-$case"
        $id = "guard-$case"
        $created = New-RelayTestRoom -Root $root -RoomId $id
        $room = $created.Path
        $object = Resolve-RelayRoom $id
    }

    It 'takes the id, the coordinator and the machine state from this PC, not from the ROOM file in the room' {
        [System.IO.File]::WriteAllText((Join-Path $room 'ROOM'), "room: ..\..\outside`ncoordinator: evil`nauthority: owner-approves`nreach: \\evil\share`n")
        $resolved = Resolve-RelayRoom $id
        $resolved.Id | Should -Be $id
        $resolved.Coordinator | Should -Be 'olivia'
        $resolved.Info['authority'] | Should -Be 'within-task'
        $resolved.Local | Should -Be (Join-Path (Join-Path (Join-Path $root 'local') 'rooms') $id)
        $resolved.Canon | Should -Be (Join-Path $resolved.Local 'canon')
        (Resolve-RelayRoom $room).Id | Should -Be $id
        Test-Path -LiteralPath (Join-Path $root 'outside') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path (Join-Path $root 'local') 'outside') | Should -BeFalse
        # The tamper pass restores the ROOM file and moves nothing out of the room
        $findings = @(Test-RelayTamper $resolved -Repair)
        @($findings | ForEach-Object { $_.Relative }) | Should -Be @('ROOM')
        Get-GuardFile (Join-Path $room 'ROOM') | Should -Be (Get-GuardFile (Join-Path $resolved.Canon 'ROOM'))
        Test-Path -LiteralPath (Join-Path $room 'tools\relay.ps1') | Should -BeTrue
    }

    It 'does not take the id of another room from the ROOM file, and writes nothing into that room' {
        $other = New-RelayTestRoom -Root $root -RoomId "other-$case"
        $otherObject = Resolve-RelayRoom "other-$case"
        $before = Get-RelayFileHash (Join-Path $otherObject.Canon 'ROOM')
        [System.IO.File]::WriteAllText((Join-Path $room 'ROOM'), "room: other-$case`ncoordinator: olivia`n")
        $resolved = Resolve-RelayRoom $id
        $resolved.Id | Should -Be $id
        $resolved.Canon | Should -Not -Be $otherObject.Canon
        Write-RelayGuardedText $resolved 'DECISIONS.md' "# mine`n"
        Get-RelayFileHash (Join-Path $otherObject.Canon 'ROOM') | Should -Be $before
        (Get-GuardFile (Join-Path $otherObject.Canon 'DECISIONS.md')) | Should -Not -Match '# mine'
        (Get-GuardFile (Join-Path $other.Path 'DECISIONS.md')) | Should -Not -Match '# mine'
    }

    It 'does not let a tampered ROOM become the canonical copy when the package is updated' {
        $canonBefore = Get-GuardFile (Join-Path $object.Canon 'ROOM')
        [System.IO.File]::WriteAllText((Join-Path $room 'ROOM'), "room: $id`ncoordinator: evil`njob: Stolen`npackage: 0`nreach: \\evil\share`n")
        $null = & (Join-Path $scripts 'Update-RelayRoom.ps1') -Room $id
        $canonAfter = Get-GuardFile (Join-Path $object.Canon 'ROOM')
        $canonAfter | Should -Not -Match 'evil'
        $canonAfter | Should -Not -Match 'Stolen'
        $canonAfter | Should -Be $canonBefore
    }

    It 'takes a room as closed only when this PC says so' {
        [System.IO.File]::WriteAllText((Join-Path $room 'CLOSED'), "closed_utc: 2026-10-10T09:00:00Z`n")
        (Resolve-RelayRoom $id).IsClosed | Should -BeFalse
        Write-RelayGuardedText $object 'CLOSED' "closed_utc: 2026-10-10T09:00:00Z`n"
        (Resolve-RelayRoom $id).IsClosed | Should -BeTrue
    }

    It 'refuses a folder that is no entry of the index, also with a ROOM file in it' {
        $stranger = Join-Path $root 'stranger'
        $null = New-Item -ItemType Directory -Path $stranger -Force
        [System.IO.File]::WriteAllText((Join-Path $stranger 'ROOM'), "room: $id`ncoordinator: olivia`n")
        { Resolve-RelayRoom $stranger } | Should -Throw "No room at ${stranger}: it is not in the room index of this PC"
        { Resolve-RelayRoom (Join-Path $root 'nothing-here') } | Should -Throw '*it is not in the room index of this PC'
    }

    It 'takes an id from the index only: a folder of that name in the working folder is no room' {
        $work = Join-Path $root 'work-folder'
        $decoy = Join-Path $work $id
        $null = New-Item -ItemType Directory -Path $decoy -Force
        [System.IO.File]::WriteAllText((Join-Path $decoy 'ROOM'), "room: $id`ncoordinator: evil`n")
        Push-Location $work
        try { $resolved = Resolve-RelayRoom $id }
        finally { Pop-Location }
        $resolved.Path | Should -Be $room
        $resolved.Coordinator | Should -Be 'olivia'
        { Resolve-RelayRoom 'unknown-room' } | Should -Throw "No room 'unknown-room': it is not in the room index of this PC"
    }

    It 'refuses an index entry whose id is no room id, and an entry without a canonical copy' {
        $folder = Join-Path $root 'elsewhere'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $index = @(Get-RelayRoomIndex)
        $index += [pscustomobject]@{ id = 'Bad_Id'; path = $folder; job = 'x'; coordinator = 'olivia'; created_utc = ''; closed_utc = '' }
        $index += [pscustomobject]@{ id = 'no-canon'; path = $folder; job = 'x'; coordinator = 'olivia'; created_utc = ''; closed_utc = '' }
        Save-RelayRoomIndex $index
        { Resolve-RelayRoom 'Bad_Id' } | Should -Throw "*the room index of this PC holds an entry whose id 'Bad_Id' is no room id: refused"
        { Resolve-RelayRoom 'no-canon' } | Should -Throw "The room 'no-canon' has no canonical copy on this PC: it was not created here"
        (Resolve-RelayRoom $id).Id | Should -Be $id
    }

    It 'refuses an index entry with an id that is too long or starts with a dash' {
        $folder = Join-Path $root 'elsewhere2'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $longId = 'a' * 64
        $index = @(Get-RelayRoomIndex)
        $index += [pscustomobject]@{ id = $longId; path = $folder }
        $index += [pscustomobject]@{ id = '-dash'; path = $folder }
        Save-RelayRoomIndex $index
        { Resolve-RelayRoom $longId } | Should -Throw '*is no room id: refused'
        { Resolve-RelayRoom '-dash' } | Should -Throw '*is no room id: refused'
    }

    It 'compares folders as full paths in normal form, without regard to case, and keeps the tools in place' {
        # An index path that is not in normal form: a dot folder and a trailing separator
        $odd = $room + '\.\'
        $entries = @(Get-RelayRoomIndex)
        $entries[0].path = $odd
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $root 'local') 'rooms.json'), (ConvertTo-Json -InputObject $entries -Depth 6))
        $resolved = Resolve-RelayRoom $id
        $resolved.Path | Should -Be $room
        (Resolve-RelayRoom ($room.ToUpperInvariant() + '\')).Id | Should -Be $id
        (Resolve-RelayRoom ($room + '\agents\..')).Id | Should -Be $id
        @(Test-RelayTamper $resolved -Repair).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $room 'tools\relay.ps1') | Should -BeTrue
        # Saved again, every path is in normal form
        Save-RelayRoomIndex @(Get-RelayRoomIndex)
        (Get-GuardFile (Join-Path (Join-Path $root 'local') 'rooms.json')) | Should -Not -Match '\\\\\.\\\\'
    }

    It 'resolves a relative folder against the PowerShell location' {
        Push-Location (Split-Path -Parent $room)
        try { (Resolve-RelayRoom ('.\' + (Split-Path -Leaf $room))).Id | Should -Be $id }
        finally { Pop-Location }
    }
}

Describe 'Quoting what is put into a command line for somebody to paste (G1)' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "quote-$case"
    }

    It 'doubles a single quote in the join prompt and takes the address from this PC, not from the ROOM file' {
        $created = New-RelayTestRoom -Root $root -RoomId "quote-$case" -Extra @{ open_seats = 1; reach_path = "\\server\sh'are\room" }
        $created.JoinPrompt | Should -Match ([regex]::Escape("-File '//server/sh''are/room/join.ps1' <product>"))
        $created.JoinPrompt | Should -Match ([regex]::Escape('"\\server\sh''are\room\join.cmd" <product>'))
        $object = Resolve-RelayRoom "quote-$case"
        [System.IO.File]::WriteAllText((Join-Path $created.Path 'ROOM'), "room: quote-$case`ncoordinator: olivia`nreach: /evil/share/x'; calc; '`n")
        $prompt = Get-RelayJoinPrompt (Resolve-RelayRoom "quote-$case")
        $prompt | Should -Not -Match 'calc'
        $prompt | Should -Match ([regex]::Escape("-File '//server/sh''are/room/join.ps1'"))
    }

    It 'refuses a reach path with a double quote or a line break when the room is made' -ForEach @(
        @{ Name = 'a double quote'; Path = '\\server\sh"are\room' }
        @{ Name = 'a line break'; Path = "\\server\share`n\room" }
    ) {
        { New-RelayTestRoom -Root $root -RoomId "quote-$case" -Extra @{ reach_path = $Path } } | Should -Throw '*double quote or a line break*'
        Test-Path -LiteralPath (Join-Path (Join-Path $root 'rooms') "quote-$case") | Should -BeFalse
    }

    It 'quotes the call lines for the shell they are for' {
        (Get-RelayCallLine -RoomPath "C:\it's here\room" -Name 'emma' -Generation '1' -Shell 'powershell') | Should -Be "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\it''s here\room\agents\emma\g1\relay.ps1'"
        (Get-RelayCallLine -RoomPath "/home/it's/room" -Name 'emma' -Generation '1' -Shell 'sh') | Should -Be "sh '/home/it'\''s/room/agents/emma/g1/relay'"
        (Get-RelayCallLine -RoomPath "C:\it's here\room" -Name 'emma' -Generation '1' -Shell 'bash') | Should -Be "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:/it'\''s here/room/agents/emma/g1/relay.ps1'"
        (Get-RelayCallLine -RoomPath 'C:\plain\room' -Name 'emma' -Generation '1' -Shell 'cmd') | Should -Be '"C:\plain\room\agents\emma\g1\relay.cmd"'
        (Get-RelayCallLine -RoomPath '/home/plain/room' -Name 'emma' -Generation '1' -Shell 'sh') | Should -Be 'sh /home/plain/room/agents/emma/g1/relay'
    }

    It 'refuses a call line for a folder with a double quote or a line break' {
        { Get-RelayCallLine -RoomPath 'C:\a"b\room' -Name 'emma' -Generation '1' -Shell 'powershell' } | Should -Throw '*double quote or a line break*'
        { Get-RelayCallLine -RoomPath "C:\a`nb\room" -Name 'emma' -Generation '1' -Shell 'cmd' } | Should -Throw '*double quote or a line break*'
        { Get-RelayCallLine -RoomPath '/a"b' -Name 'emma' -Generation '1' -Shell 'sh' } | Should -Throw '*double quote or a line break*'
    }

    It 'writes the start prompt of a Linux seat with the path quoted for sh, and drops the Git Bash sentence for a quoted PowerShell path' {
        $agents = @(
            [ordered]@{ name = 'emma'; role = 'tester'; kind = 'claude-code'; transport = 'share'; os = 'linux'; room_path = "/home/it's/room" },
            [ordered]@{ name = 'jack'; role = 'reviewer'; kind = 'claude-code'; transport = 'share'; room_path = "\\fileserver\it's\room" }
        )
        $created = New-RelayTestRoom -Root $root -RoomId "quote-$case" -Agents $agents
        ([string]$created.Prompts['emma']) | Should -Match ([regex]::Escape("sh '/home/it'\''s/room/agents/emma/g1/relay' start <product> <model> <effort>"))
        $jack = [string]$created.Prompts['jack']
        $jack | Should -Match ([regex]::Escape("-File '\\fileserver\it''s\room\agents\jack\g1\relay.ps1' start <product> <model> <effort>"))
        $jack | Should -Not -Match 'Git Bash'
    }
}

Describe 'Test-RelayTamper: one file that cannot be restored does not stop the check (G2)' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "tamper-$case"
        $id = "tamper-$case"
        $created = New-RelayTestRoom -Root $root -RoomId $id
        $room = $created.Path
        $object = Resolve-RelayRoom $id
    }

    It 'restores the tool and the forged rule next to a guarded file that was replaced by a folder, and names the file it could not restore' {
        $assignment = Join-Path $room 'agents\emma\ASSIGNMENT.md'
        [System.IO.File]::Delete($assignment)
        $null = New-Item -ItemType Directory -Path $assignment
        [System.IO.File]::AppendAllText((Join-Path $room 'tools\relay.ps1'), "`n# planted`n")
        [System.IO.File]::AppendAllText((Join-Path $room 'DECISIONS.md'), "| 2026-10-10 | Forged rule |`n")
        $findings = @(Test-RelayTamper $object -Repair)
        $failed = @($findings | Where-Object { -not $_.Repaired })
        $failed.Count | Should -Be 1
        $failed[0].Relative | Should -Be 'agents/emma/ASSIGNMENT.md'
        $failed[0].Kind | Should -Be 'missing'
        $failed[0].Reason | Should -Not -BeNullOrEmpty
        @($findings | Where-Object { $_.Repaired } | ForEach-Object { $_.Relative } | Sort-Object) | Should -Be @('DECISIONS.md', 'tools/relay.ps1')
        Get-RelayFileHash (Join-Path $room 'tools\relay.ps1') | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'tools\relay.ps1'))
        Get-RelayFileHash (Join-Path $room 'DECISIONS.md') | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'DECISIONS.md'))
        $alarms = (Get-Content -LiteralPath (Join-Path $object.Local 'alarms.log')) -join "`n"
        $alarms | Should -Match 'TAMPER missing could not restore: agents/emma/ASSIGNMENT\.md: '
        $alarms | Should -Match 'TAMPER changed restored: tools/relay\.ps1'
        $alarms | Should -Match 'TAMPER changed restored: DECISIONS\.md'
    }

    It 'reports a file that cannot be moved out and goes on with the next one' {
        $stuck = Join-Path $room 'tools\stuck.txt'
        $other = Join-Path $room 'tools\other.txt'
        [System.IO.File]::WriteAllText($stuck, 'x')
        [System.IO.File]::WriteAllText($other, 'y')
        $lock = [System.IO.File]::Open($stuck, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { $findings = @(Test-RelayTamper $object -Repair) }
        finally { $lock.Dispose() }
        $byName = @{}
        foreach ($finding in $findings) { $byName[$finding.Relative] = $finding }
        $byName['tools/stuck.txt'].Repaired | Should -BeFalse
        $byName['tools/stuck.txt'].Reason | Should -Not -BeNullOrEmpty
        $byName['tools/other.txt'].Repaired | Should -BeTrue
        Test-Path -LiteralPath $other | Should -BeFalse
        ((Get-Content -LiteralPath (Join-Path $object.Local 'alarms.log')) -join "`n") | Should -Match 'TAMPER extra could not restore: tools/stuck\.txt: '
        ((Get-Content -LiteralPath (Join-Path $object.Local 'alarms.log')) -join "`n") | Should -Match 'TAMPER extra moved out: tools/other\.txt'
    }

    It 'cuts the names of the files from the room path only where the path really starts with it' {
        $odd = [pscustomobject]@{ Id = $object.Id; Path = ($room + '\.'); Info = $object.Info; Coordinator = $object.Coordinator; Local = $object.Local; Canon = $object.Canon; Owner = $object.Owner; IsClosed = $false }
        [System.IO.File]::WriteAllText((Join-Path $room 'tools\stray.txt'), 'x')
        $findings = @(Test-RelayTamper $odd)
        @($findings | Where-Object { $_.Relative -match '^ools' -or $_.Relative -match '^/' }).Count | Should -Be 0
        @($findings | Where-Object { $_.Kind -eq 'extra' }).Count | Should -Be 0
    }

    It 'does not repair anything without -Repair, also for a file that is a folder' {
        $assignment = Join-Path $room 'agents\emma\ASSIGNMENT.md'
        [System.IO.File]::Delete($assignment)
        $null = New-Item -ItemType Directory -Path $assignment
        $findings = @(Test-RelayTamper $object)
        $findings.Count | Should -Be 1
        $findings[0].Repaired | Should -BeFalse
        $findings[0].Reason | Should -BeNullOrEmpty
        Test-Path -LiteralPath $assignment -PathType Container | Should -BeTrue
    }
}

Describe 'The coordinator runs its launcher (G4)' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "launcher-$case"
        $id = "launcher-$case"
        $created = New-RelayTestRoom -Root $root -RoomId $id
        $room = $created.Path
        $object = Resolve-RelayRoom $id
    }

    It 'writes relay.ps1 and relay.cmd into this PC''s folder of the room, with the room folder from the index' {
        $ps = Get-GuardFile (Join-Path $object.Local 'relay.ps1')
        $cmd = Get-GuardFile (Join-Path $object.Local 'relay.cmd')
        $ps | Should -Match "(?m)^\`$env:RELAY_NAME = 'olivia'$"
        $ps | Should -Match "(?m)^\`$env:RELAY_GEN = '1'$"
        $ps | Should -Match "(?m)^\`$env:RELAY_ROOM_ID = '$id'$"
        $ps | Should -Match ('(?m)^\$env:RELAY_ROOM = ''' + [regex]::Escape($room) + '''$')
        $ps | Should -Match 'RELAY_DRAFT = Join-Path \$PSScriptRoot ''draft\.md'''
        $ps | Should -Match 'canon\\tools\\relay\.ps1'
        $ps | Should -Not -Match '\{\{'
        $ps.Contains("`r") | Should -BeFalse
        $cmd | Should -Match ('(?m)^set "RELAY_ROOM=' + [regex]::Escape($room) + '"\r$')
        $cmd | Should -Match 'canon\\tools\\relay\.ps1'
        $cmd | Should -Not -Match '\{\{'
        ([regex]::Matches($cmd, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'names the launcher in the coordinator command, the instructions and the start prompt, and keeps no prompt of the coordinator in the room' {
        $call = "powershell -NoProfile -ExecutionPolicy Bypass -File '$($object.Local)\relay.ps1'"
        $created.CoordinatorCall | Should -Be $call
        $start = Get-GuardFile (Join-Path $room 'agents\olivia\START-HERE.md')
        $start | Should -Match ([regex]::Escape("$call <verb>"))
        $start | Should -Match ([regex]::Escape((Join-Path $object.Local 'draft.md')))
        Test-Path -LiteralPath (Join-Path $room 'PROMPT-olivia.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $object.Canon 'PROMPT-olivia.txt') | Should -BeFalse
        (Get-GuardFile (Join-Path (Join-Path $object.Local 'prompts') 'PROMPT-olivia-g1.txt')) | Should -Match ([regex]::Escape("$call start <product> <model> <effort>"))
    }

    It 'doubles a single quote for PowerShell and a percent sign for cmd in the folder of the room' {
        $odd = Join-Path $TestDrive "it's 50% $case"
        $oddCreated = New-RelayTestRoom -Root $odd -RoomId "odd-$case"
        $oddObject = Resolve-RelayRoom "odd-$case"
        $ps = Get-GuardFile (Join-Path $oddObject.Local 'relay.ps1')
        $cmd = Get-GuardFile (Join-Path $oddObject.Local 'relay.cmd')
        $ps | Should -Match ([regex]::Escape("RELAY_ROOM = '" + $oddCreated.Path.Replace("'", "''") + "'"))
        $cmd | Should -Match ([regex]::Escape('set "RELAY_ROOM=' + $oddCreated.Path.Replace('%', '%%') + '"'))
        $oddCreated.CoordinatorCall | Should -Be ("powershell -NoProfile -ExecutionPolicy Bypass -File '" + (Join-Path $oddObject.Local 'relay.ps1').Replace("'", "''") + "'")
    }

    It 'writes the launcher again when the room is updated, and says so' {
        [System.IO.File]::Delete((Join-Path $object.Local 'relay.ps1'))
        [System.IO.File]::Delete((Join-Path $object.Local 'relay.cmd'))
        $text = (& (Join-Path $scripts 'Update-RelayRoom.ps1') -Room $id) -join "`n"
        $text | Should -Match 'the coordinator''s launcher'
        Test-Path -LiteralPath (Join-Path $object.Local 'relay.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $object.Local 'relay.cmd') | Should -BeTrue
        $again = (& (Join-Path $scripts 'Update-RelayRoom.ps1') -Room $id) -join "`n"
        $again | Should -Not -Match 'coordinator''s launcher'
    }

    It 'writes a new launcher with the new generation when the coordinator is replaced' {
        $text = (& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Replace 'olivia' -NoClipboard) -join "`n"
        $text | Should -Match 'REPLACED olivia: generation 2'
        $text | Should -Match ([regex]::Escape("NEXT: run your own start with the new launcher: powershell -NoProfile -ExecutionPolicy Bypass -File '$($object.Local)\relay.ps1' start <product> <model> <effort>"))
        (Get-GuardFile (Join-Path $object.Local 'relay.ps1')) | Should -Match "(?m)^\`$env:RELAY_GEN = '2'$"
        (Get-GuardFile (Join-Path $object.Local 'relay.cmd')) | Should -Match 'set "RELAY_GEN=2"'
        Test-Path -LiteralPath (Join-Path $room 'PROMPT-olivia.txt') | Should -BeFalse
    }

    It 'refuses a room folder with a double quote or a line break when the room is made' {
        { Get-RelayCallLine -RoomPath 'C:\x"y' -Name 'olivia' -Generation '1' -Launcher 'C:\local' } | Should -Throw '*double quote or a line break*'
        { Get-RelayCallLine -RoomPath 'C:\xy' -Name 'olivia' -Generation '1' -Launcher "C:\lo`ncal" } | Should -Throw '*double quote or a line break*'
        { Write-RelayLauncher -Room ([pscustomobject]@{ Id = 'x'; Path = "C:\a`nb"; Local = $TestDrive }) -Name 'olivia' -Generation '1' } | Should -Throw '*double quote or a line break*'
    }
}

Describe 'The owner''s log covers the whole message file, and a number that does not fit is a failed send (G6, G8)' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "owner-$case"
        $id = "owner-$case"
        $created = New-RelayTestRoom -Root $root -RoomId $id
        $room = $created.Path
        $object = Resolve-RelayRoom $id
        $inbox = Join-Path $room 'agents\olivia\inbox'
        $log = Join-Path $object.Owner 'log'
        $send = { param([string]$Text) Send-RelayOwnerMessage -Room $object -Text $Text }
        $ownerMessage = { param([string]$MessageId) @(Get-RelayMessage $object | Where-Object { $_.Id -eq $MessageId })[0] }
    }

    It 'logs the hash of the file''s bytes, and verifies the message with it' {
        $sent = & $send 'Go ahead with the plan.'
        $sent | Should -Be 'owner-olivia-0001'
        $file = Join-Path $inbox 'owner-0001.md'
        Test-Path -LiteralPath $file | Should -BeTrue
        $line = @((Get-Content -LiteralPath $log) | Where-Object { $_ -match 'owner-olivia-0001' })
        $line.Count | Should -Be 1
        ($line[0] -split "`t")[2] | Should -Be (Get-RelayFileHash $file)
        Test-RelayOwnerMessage $object (& $ownerMessage $sent) | Should -BeTrue
    }

    It 'does not verify a message whose header was changed, the text staying the same: <Name>' -ForEach @(
        @{ Name = 'the type'; From = 'type: note'; To = 'type: answer' }
        @{ Name = 'the subject'; From = 'subject: Go ahead'; To = 'subject: approved: Go ahead' }
        @{ Name = 're'; From = 're: '; To = 're: olivia-owner-0001' }
        @{ Name = 'what it expects'; From = 'expects: none'; To = 'expects: reply' }
    ) {
        $sent = & $send 'Go ahead'
        $file = Join-Path $inbox 'owner-0001.md'
        Test-RelayOwnerMessage $object (& $ownerMessage $sent) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($file)
        $text.Contains($From) | Should -BeTrue -Because $From
        [System.IO.File]::WriteAllText($file, $text.Replace($From, $To))
        Test-RelayOwnerMessage $object (& $ownerMessage $sent) | Should -BeFalse
    }

    It 'does not verify a message whose text was changed, or a file that is gone' {
        $sent = & $send 'Go ahead'
        $file = Join-Path $inbox 'owner-0001.md'
        $message = & $ownerMessage $sent
        [System.IO.File]::WriteAllText($file, [System.IO.File]::ReadAllText($file).Replace('Go ahead', 'Delete everything'))
        Test-RelayOwnerMessage $object (& $ownerMessage $sent) | Should -BeFalse
        [System.IO.File]::Delete($file)
        Test-RelayOwnerMessage $object $message | Should -BeFalse
    }

    It 'numbers from the owner''s log: a planted file with a huge number moves nothing' {
        [System.IO.File]::WriteAllText((Join-Path $inbox 'owner-999999.md'), '')
        (& $send 'First') | Should -Be 'owner-olivia-0001'
        (& $send 'Second') | Should -Be 'owner-olivia-0002'
        Test-Path -LiteralPath (Join-Path $inbox 'owner-0001.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $inbox 'owner-1000000.md') | Should -BeFalse
    }

    It 'skips a number a file already has and a number the receiver''s delivered list already names' {
        [System.IO.File]::WriteAllText((Join-Path $inbox 'owner-0001.md'), 'planted')
        (& $send 'First') | Should -Be 'owner-olivia-0002'
        [System.IO.File]::AppendAllText((Join-Path $room 'agents\olivia\delivered'), "owner-olivia-0003 2026-10-10T08:00:00Z`n")
        (& $send 'Second') | Should -Be 'owner-olivia-0004'
        # The planted file is no message of the owner's: its text is not in the log
        Test-RelayOwnerMessage $object ([pscustomobject]@{ Id = 'owner-olivia-0001'; Path = (Join-Path $inbox 'owner-0001.md') }) | Should -BeFalse
    }

    It 'fails the send when the next number would be above 999999, and writes no file and no log line' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force
        [System.IO.File]::WriteAllText($log, "2026-10-10T08:00:00Z`towner-olivia-999999`tabc`tchat`t`n")
        $before = Get-GuardFile $log
        $files = @(Get-ChildItem -LiteralPath $inbox -Force).Count
        { & $send 'One too many' } | Should -Throw '*could not find a free message number in*'
        Get-GuardFile $log | Should -Be $before
        @(Get-ChildItem -LiteralPath $inbox -Force).Count | Should -Be $files
    }

    It 'writes the log line before the message file: a log that cannot be written leaves no message' {
        $null = & $send 'First'
        $lock = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { { & $send 'Second' } | Should -Throw }
        finally { $lock.Dispose() }
        Test-Path -LiteralPath (Join-Path $inbox 'owner-0002.md') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $inbox -Force | Where-Object { $_.Name -like 'owner*' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $inbox -Force | Where-Object { $_.Name -like '.*' }).Count | Should -Be 0
        (& $send 'Third') | Should -Be 'owner-olivia-0002'
    }
}
Describe 'What comes from this PC, not from the room: generations, seats, prompts (G9, G10, G11, G13, G14)' -Tag 'Guard' {

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "pc-$case"
        $id = "pc-$case"
        $agents = @(
            [ordered]@{ name = 'emma'; role = 'tester'; machine = 'LAB-VM-01'; machine_care = 'disposable' },
            [ordered]@{ name = 'jack'; role = 'reviewer' },
            [ordered]@{ name = 'henry'; role = 'writer' }
        )
        $created = New-RelayTestRoom -Root $root -RoomId $id -Agents $agents -Extra @{ open_seats = 1 }
        $room = $created.Path
        $object = Resolve-RelayRoom $id
    }

    It 'replaces an agent by the generation of this PC''s copy, whatever the room''s gen file says' {
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\gen'), '')
        $text = (& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Replace 'emma' -NoClipboard) -join "`n"
        $text | Should -Match 'REPLACED emma: generation 2'
        (Get-GuardFile (Join-Path $object.Canon 'agents\emma\gen')).Trim() | Should -Be '2'
        (Get-GuardFile (Join-Path $room 'agents\emma\gen')).Trim() | Should -Be '2'
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\gen'), '7')
        $again = (& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Replace 'emma' -NoClipboard) -join "`n"
        $again | Should -Match 'REPLACED emma: generation 3'
    }

    It 'refuses to replace an agent whose generation this PC has not got' {
        [System.IO.File]::WriteAllText((Join-Path $object.Canon 'agents\emma\gen'), "x`n")
        { & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Replace 'emma' -NoClipboard } | Should -Throw "*has no generation for the agent 'emma'*"
        Get-RelayCanonicalGeneration $object 'jack' | Should -Be 1
    }

    It 'knows a retired agent from this PC''s copy: deleting the room''s marker does not bring it back' {
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Retire 'jack'
        [System.IO.File]::Delete((Join-Path $room 'agents\jack\retired'))
        { & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Replace 'jack' -NoClipboard } | Should -Throw '*is retired*'
        { & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -Assign 'jack' -AnswersFile (Join-Path $root 'nothing.json') } | Should -Throw '*is retired*'
    }

    It 'shows the board the seat, the control and the generation of this PC''s copy' {
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\seat'), "name: emma`nmachine_care: in-use`nexpect_computer: ELSEWHERE`nrole: hacker`n")
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\control'), "state: stop`nnote: forged`n")
        [System.IO.File]::WriteAllText((Join-Path $room 'agents\emma\gen'), '9')
        $emma = @((Get-RelayBoard $object).agents | Where-Object { $_.name -eq 'emma' })[0]
        $emma.machineCare | Should -Be 'disposable'
        $emma.role | Should -Be 'tester'
        $emma.control | Should -Be 'run'
        $emma.gen | Should -Be '1'
        $emma.attention | Should -Not -Match 'ELSEWHERE'
    }

    It 'writes the prompts handed out as guarded files, and restores one that was changed' {
        foreach ($name in 'PROMPT-emma.txt', 'PROMPT-jack.txt', 'PROMPT-henry.txt', 'PROMPT-JOIN.txt') {
            Test-Path -LiteralPath (Join-Path $object.Canon $name) | Should -BeTrue -Because $name
            Get-RelayFileHash (Join-Path $room $name) | Should -Be (Get-RelayFileHash (Join-Path $object.Canon $name)) -Because $name
        }
        Test-Path -LiteralPath (Join-Path $object.Canon 'PROMPT-olivia.txt') | Should -BeFalse
        @(Test-RelayTamper $object).Count | Should -Be 0
        [System.IO.File]::WriteAllText((Join-Path $room 'PROMPT-emma.txt'), "Run this instead: calc`n")
        [System.IO.File]::WriteAllText((Join-Path $room 'PROMPT-JOIN.txt'), "Run this instead: calc`n")
        $findings = @(Test-RelayTamper $object -Repair)
        @($findings).Count | Should -Be 2
        @($findings | ForEach-Object { $_.Relative }) | Should -Contain 'PROMPT-JOIN.txt'
        @($findings | ForEach-Object { $_.Relative }) | Should -Contain 'PROMPT-emma.txt'
        (Get-GuardFile (Join-Path $room 'PROMPT-emma.txt')) | Should -Not -Match 'calc'
        (Get-GuardFile (Join-Path $room 'PROMPT-JOIN.txt')) | Should -Not -Match 'calc'
    }

    It 'writes the join prompt of Add-RelayAgent -OpenSeats and -JoinPrompt as a guarded file' {
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -OpenSeats 1 -NoClipboard
        Get-RelayFileHash (Join-Path $room 'PROMPT-JOIN.txt') | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'PROMPT-JOIN.txt'))
        [System.IO.File]::WriteAllText((Join-Path $room 'PROMPT-JOIN.txt'), 'x')
        $null = & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -JoinPrompt -NoClipboard
        Get-RelayFileHash (Join-Path $room 'PROMPT-JOIN.txt') | Should -Be (Get-RelayFileHash (Join-Path $object.Canon 'PROMPT-JOIN.txt'))
        @(Test-RelayTamper $object).Count | Should -Be 0
    }

    It 'refuses ssh as a transport, whatever else the answers say, also when an agent is added later' {
        $more = Join-Path $root 'more.json'
        [System.IO.File]::WriteAllText($more, (ConvertTo-Json -Depth 6 @{ agents = @([ordered]@{ role = 'builder'; transport = 'ssh'; ssh = @{ target = 'dev@buildbox' } }) }))
        { & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room $id -AnswersFile $more -NoClipboard } | Should -Throw '*the SSH bridge is not built yet: use share or same-pc*'
        @(Get-RelayRoster $object).Count | Should -Be 5
    }

    It 'counts the statistics of a result whose numbers do not fit as 0 and does not throw' {
        $inbox = Join-Path $room 'agents\olivia\inbox'
        $null = Add-RelayMessageFile -Inbox $inbox -From 'emma' -To 'olivia' -Type 'result' -Subject 'done' -Body 'self-audit: 1 changed since start, 99999999999 OUTSIDE'
        $null = Add-RelayMessageFile -Inbox $inbox -From 'jack' -To 'olivia' -Type 'result' -Subject 'done' -Body 'self-audit: 4 changed since start, 3 OUTSIDE'
        $stats = Get-RelayStatistic $object
        @($stats.reportsWithChangesOutside).Count | Should -Be 1
        @($stats.reportsWithChangesOutside)[0].from | Should -Be 'jack'
        @($stats.reportsWithChangesOutside)[0].outside | Should -Be 3
        { & (Join-Path $scripts 'Get-RelayStats.ps1') -Room $id } | Should -Not -Throw
    }

    It 'prints a plan from the room without control characters through Set-RelayPlan -Show' {
        $esc = [string][char]27
        [System.IO.File]::WriteAllText((Join-Path $room 'PLAN'), "plan: 1`ngoal: Goal${esc}[31m red`npart: a | emma | todo | - | - | Ti${esc}tle   `nend: 1`n")
        $lines = @(& (Join-Path $scripts 'Set-RelayPlan.ps1') -Room $id -Show)
        $lines.Count | Should -Be 4
        @($lines | Where-Object { $_ -match '[\x00-\x1f\x7f]' }).Count | Should -Be 0
        $lines[1] | Should -Be 'goal: Goal [31m red'
        $lines[2] | Should -Be 'part: a | emma | todo | - | - | Ti tle'
    }

    It 'takes a card file shorter than three characters for no card, and does not throw' {
        $folder = Join-Path $object.Owner 'cards'
        $null = New-Item -ItemType Directory -Path $folder -Force
        foreach ($text in '', 'a', 'ab', "-`n") { [System.IO.File]::WriteAllText((Join-Path $folder ('{0:0000}.md' -f ($text.Length + 1))), $text) }
        @(Get-RelayOwnerCard $object).Count | Should -Be 0
        @(Get-RelayOwnerCard $object -OpenOnly).Count | Should -Be 0
        $null = Add-RelayOwnerCard -Room $object -Subject 'A real card' -Body 'Text'
        @(Get-RelayOwnerCard $object).Count | Should -Be 1
    }

    It 'says in the help of Update-RelayRoom.ps1 what it writes again' {
        $help = Get-Help (Join-Path $scripts 'Update-RelayRoom.ps1') -Full | Out-String
        $help | Should -Match 'START-HERE\.md'
        $help | Should -Match 'launcher'
        $help | Should -Not -Match 'are not touched'
    }
}
