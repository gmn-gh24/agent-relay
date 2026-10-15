#Requires -Version 5.1

<#
    Reopening a closed room: the preconditions, the room folder kept or restored from the archive of the close
    (and an archive that would write outside the room refused), the transcript and the archive of the close kept
    aside, the old sessions kept stopped, and the room working again for the coordinator's scripts.
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

    function Get-TestTreeHash {
        # Every file under a folder with the hash of its bytes, by its relative path; empty for no folder
        param([string]$Path)
        $map = @{}
        if (-not (Test-Path -LiteralPath $Path)) { return $map }
        $top = (Get-RelayNormalPath $Path).TrimEnd('\', '/')
        foreach ($file in @((Get-RelayFileTree $top).Files)) {
            $map[($file.FullName.Substring($top.Length).TrimStart('\', '/') -replace '\\', '/')] = Get-RelayFileHash $file.FullName
        }
        return $map
    }

    function Get-TestZipHash {
        # Every entry of a zip with the hash of its bytes, by its name with forward slashes
        param([string]$Path)
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $map = @{}
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $zip.Entries) {
                $stream = $entry.Open()
                $memory = New-Object System.IO.MemoryStream
                try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
                $map[($entry.FullName -replace '\\', '/')] = Get-RelayBytesHash ($memory.ToArray())
            }
        }
        finally { $zip.Dispose() }
        return $map
    }

    function Add-TestZipEntry {
        # Writes one more entry, named exactly as given, into an existing zip
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
        param([string]$Path, [string]$Name, [string]$Text)
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $zip.CreateEntry($Name)
            $stream = $entry.Open()
            try {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
        finally { $zip.Dispose() }
    }

    function Close-TestRoom {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
        param([switch]$Remove)
        $closed = (& (Join-Path $scripts 'Close-RelayRoom.ps1') -Room 'reo' -Force) -join "`n"
        if ($closed -notmatch 'CLOSED room reo') { throw "The test room did not close: $closed" }
        if ($Remove) { $null = & (Join-Path $scripts 'Close-RelayRoom.ps1') -Remove 'reo' -Confirm:$false }
    }

    function Get-TestClosedStamp {
        return [string]@(Get-RelayRoomIndex | Where-Object { $_.id -eq 'reo' })[0].closed_utc
    }
}

AfterAll {
    $env:AGENT_RELAY_LOCAL = $savedLocal
}

Describe 'Reopen-RelayRoom' -Tag 'Scripts' {

    BeforeAll {
        $baseRoot = Join-Path $TestDrive 'reopen-template'
        $template = (New-RelayTestRoom -Root $baseRoot -RoomId 'reo').Path
        foreach ($name in 'olivia', 'emma', 'jack') {
            $started = Invoke-RelayTool -Room $template -Agent $name -Engine $engine -Words @('start', 'product', 'model', 'low')
            if ($started.ExitCode -ne 0) { throw "start failed for ${name}: $($started.Output) $($started.Error)" }
        }
        $null = Send-RelayTestMessage -Room $template -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Count the files`n`nCount them."
        $null = Send-RelayTestMessage -Room $template -Agent 'emma' -Engine $engine -Words @('bye') -Text "Leaving`n`nNothing slowed me down."
    }

    BeforeEach {
        $case = New-RelayTestId
        $root = Join-Path $TestDrive "reopen-$case"
        $null = New-Item -ItemType Directory -Path $root -Force
        Copy-Item -LiteralPath (Join-Path $baseRoot 'local') -Destination (Join-Path $root 'local') -Recurse
        $room = Copy-RelayTestRoom -Template $template -Target (Join-Path $root 'rooms\reo')
        $env:AGENT_RELAY_LOCAL = Join-Path $root 'local'
        $index = @(Get-RelayRoomIndex)
        foreach ($entry in $index) { if ($entry.id -eq 'reo') { $entry.path = $room } }
        Save-RelayRoomIndex $index
        $object = Resolve-RelayRoom 'reo'
        $archive = Join-Path $root 'local\archive\reo.zip'
        $reopen = Join-Path $scripts 'Reopen-RelayRoom.ps1'
    }

    It 'refuses a room the index does not know' {
        { & $reopen -Room 'nowhere' } | Should -Throw '*not in the room index of this PC*NEXT:*'
    }

    It 'refuses a room that is open and changes nothing' {
        $before = Get-TestTreeHash $room
        { & $reopen -Room 'reo' } | Should -Throw '*is not closed*NEXT:*'
        Get-TestClosedStamp | Should -Be ''
        Test-Path -LiteralPath (Join-Path $object.Owner 'log') | Should -BeFalse
        $after = Get-TestTreeHash $room
        $after.Count | Should -Be $before.Count
        foreach ($key in $before.Keys) { $after[$key] | Should -Be $before[$key] -Because $key }
    }

    It 'refuses a room whose canonical copy is not on this PC' {
        Close-TestRoom
        Remove-Item -LiteralPath $object.Canon -Recurse -Force
        { & $reopen -Room 'reo' } | Should -Throw '*reopening works only on the PC that closed the room*NEXT:*'
        Test-Path -LiteralPath (Join-Path $room 'CLOSED') | Should -BeTrue
        Get-TestClosedStamp | Should -Not -Be ''
    }

    It 'reopens a room whose folder is still there: markers and stamp gone, the transcript and the archive kept aside, old sessions stopped' {
        Close-TestRoom
        $transcript = Get-RelayFileHash (Join-Path $room 'TRANSCRIPT.md')
        $output = (& $reopen -Room 'reo') -join "`n"
        $output | Should -Match '(?m)^REOPENED room reo$'
        $output | Should -Match '(?m)^old sessions stopped: .*emma.*jack'
        $output | Should -Match '(?m)^NEXT: .*-Replace <name>.*-OpenSeats <n>'
        Test-Path -LiteralPath (Join-Path $object.Canon 'CLOSED') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $room 'CLOSED') | Should -BeFalse
        Get-TestClosedStamp | Should -Be ''
        (Resolve-RelayRoom 'reo').IsClosed | Should -BeFalse
        foreach ($folder in $room, $object.Canon) {
            Test-Path -LiteralPath (Join-Path $folder 'TRANSCRIPT.md') | Should -BeFalse
            $kept = @(Get-ChildItem -LiteralPath $folder -File -Filter 'TRANSCRIPT-closed-*.md')
            $kept.Count | Should -Be 1
            $kept[0].Name | Should -Match '^TRANSCRIPT-closed-\d{8}T\d{6}Z\.md$'
            Get-RelayFileHash $kept[0].FullName | Should -Be $transcript
        }
        Test-Path -LiteralPath $archive | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $root 'local\archive') -File -Filter 'reo-closed-*.zip').Count | Should -Be 1
        @((Get-Content -LiteralPath (Join-Path $object.Owner 'log')) | Where-Object { $_ -match "`treopen`t" }).Count | Should -Be 1
        @(Test-RelayTamper (Resolve-RelayRoom 'reo')).Count | Should -Be 0

        # An old session stays stopped; the coordinator's own command works again
        $old = Invoke-RelayTool -Room $room -Agent 'jack' -Engine $engine -Words @('check')
        $old.ExitCode | Should -Be 5
        $old.Output | Should -Match 'you were stopped'
        (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')).ExitCode | Should -Be 0
    }

    It 'leaves an open seat that nobody took running, so that the first agent to join the reopened room is not told it was stopped' {
        $added = (& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room 'reo' -OpenSeats 2) -join "`n"
        $added | Should -Match 'free seats added'
        $open = @(Get-RelayTestOpenSeat $room)
        $open.Count | Should -Be 2
        # The first open seat is taken before the close; the second stays free
        $joined = Invoke-RelayTool -Room $room -Agent '' -Engine $engine -Words @('join', 'codex', 'some-model', 'low')
        $joined.ExitCode | Should -Be 0 -Because $joined.Output
        Get-RelayTestJoinedName $joined | Should -Be $open[0]
        Close-TestRoom
        $output = (& $reopen -Room 'reo') -join "`n"
        $output | Should -Match "(?m)^old sessions stopped: .*$($open[0])"
        $output | Should -Not -Match "(?m)^old sessions stopped: .*$($open[1])"
        Get-RelayValue (Read-RelayKeyValue (Join-Path $object.Canon "agents/$($open[0])/control")) 'state' 'run' | Should -Be 'stop'
        Get-RelayValue (Read-RelayKeyValue (Join-Path $object.Canon "agents/$($open[1])/control")) 'state' 'run' | Should -Be 'run'
        @(Test-RelayTamper (Resolve-RelayRoom 'reo')).Count | Should -Be 0
        # An agent given the join prompt after the reopen gets the free seat and works; the old session stays stopped
        $fresh = Invoke-RelayTool -Room $room -Agent '' -Engine $engine -Words @('join', 'new', 'gemini', 'm', 'e')
        $fresh.ExitCode | Should -Be 0 -Because $fresh.Output
        Get-RelayTestJoinedName $fresh | Should -Be $open[1]
        $fresh.Output | Should -Not -Match 'you were stopped'
        $old = Invoke-RelayTool -Room $room -Agent $open[0] -Engine $engine -Words @('check')
        $old.ExitCode | Should -Be 5
        $old.Output | Should -Match 'you were stopped'
    }

    It 'restores a removed folder from the archive: files as the archive holds them, guarded files as the canonical copy' {
        Close-TestRoom -Remove
        Test-Path -LiteralPath $room | Should -BeFalse
        $zipped = Get-TestZipHash $archive
        $output = (& $reopen -Room 'reo') -join "`n"
        $output | Should -Match '(?m)^restored: the room folder '
        $output | Should -Match '(?m)^REOPENED room reo$'
        Get-TestClosedStamp | Should -Be ''
        [string](Get-RelayProperty @(Get-RelayRoomIndex | Where-Object { $_.id -eq 'reo' })[0] 'folder' '') | Should -Be ''
        $restored = Resolve-RelayRoom 'reo'
        $guarded = @(Get-RelayGuardedFile $restored)
        $tree = Get-TestTreeHash $room
        foreach ($name in $zipped.Keys) {
            if ($guarded -contains $name) { continue }
            if (@('CLOSED', 'TRANSCRIPT.md') -contains $name) { $tree.ContainsKey($name) | Should -BeFalse -Because $name; continue }
            $tree[$name] | Should -Be $zipped[$name] -Because $name
        }
        foreach ($name in $guarded) {
            Get-RelayFileHash (Join-Path $room $name) | Should -Be (Get-RelayFileHash (Join-Path $restored.Canon $name)) -Because $name
        }
        foreach ($folder in 'files', 'work', 'agents\henry\inbox', 'agents\emma\attach') {
            Test-Path -LiteralPath (Join-Path $room $folder) -PathType Container | Should -BeTrue -Because $folder
        }
        @(Get-ChildItem -LiteralPath (Join-Path $root 'rooms') -Force | Where-Object { $_.Name -like '.reo.reopen-*' }).Count | Should -Be 0
        @(Test-RelayTamper $restored).Count | Should -Be 0
        (Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('check')).ExitCode | Should -Be 5
    }

    It 'refuses an archive entry that would land outside the room and restores nothing: <Name>' -TestCases @(
        @{ Name = '..\evil.txt' }
        @{ Name = '../evil.txt' }
        @{ Name = 'work/../../evil.txt' }
        @{ Name = '/tmp/evil.txt' }
        @{ Name = '\\server\share\evil.txt' }
        @{ Name = 'C:/evil.txt' }
        @{ Name = 'C:evil.txt' }
        @{ Name = 'work/.. /evil.txt' }
    ) {
        Close-TestRoom -Remove
        Add-TestZipEntry -Path $archive -Name $Name -Text 'outside'
        { & $reopen -Room 'reo' } | Should -Throw '*is refused*Nothing was restored*NEXT:*'
        Test-Path -LiteralPath $room | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'evil.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'rooms\evil.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $root -Recurse -Force -Filter 'evil.txt').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $root 'rooms') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.reo.reopen-*' }).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $object.Canon 'CLOSED') | Should -BeTrue
        Get-TestClosedStamp | Should -Not -Be ''
        Test-Path -LiteralPath $archive | Should -BeTrue
    }

    It 'makes no folder through a link that appears in the half-restored folder while the archive is unpacked' -Tag 'MaySkip' {
        $outside = Join-Path $root 'outside'
        $null = New-Item -ItemType Directory -Path $outside -Force
        # A link to a folder: a symbolic link, or a junction where the account may not make one
        $probe = Join-Path $root 'probe'
        $kind = ''
        try { $null = New-Item -ItemType SymbolicLink -Path $probe -Target $outside -ErrorAction Stop; $kind = 'SymbolicLink' } catch { $null = $_ }
        if (-not $kind) { try { $null = New-Item -ItemType Junction -Path $probe -Target $outside -ErrorAction Stop; $kind = 'Junction' } catch { $null = $_ } }
        if (-not $kind) { Set-ItResult -Skipped -Because 'this account can make neither a symbolic link nor a junction'; return }
        [System.IO.Directory]::Delete($probe, $false)
        Close-TestRoom -Remove
        # Many entries first, so that the link is in place before the last one: a file in a folder not made yet
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($archive, [System.IO.Compression.ZipArchiveMode]::Update)
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes('filler')
            foreach ($number in 1..1500) {
                $stream = $zip.CreateEntry("work/fill-$number.txt").Open()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
            $stream = $zip.CreateEntry('a/sub/x.txt').Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        finally { $zip.Dispose() }
        # Somebody who can write beside the room puts the link in as soon as the half-restored folder is there
        $planter = [powershell]::Create()
        $null = $planter.AddScript({
                param($Rooms, $Target, $Kind)
                $until = [DateTime]::UtcNow.AddSeconds(120)
                while ([DateTime]::UtcNow -lt $until) {
                    $building = @(Get-ChildItem -LiteralPath $Rooms -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.reo.reopen-*' })
                    if ($building.Count -gt 0) {
                        $null = New-Item -ItemType $Kind -Path (Join-Path $building[0].FullName 'a') -Target $Target -ErrorAction Stop
                        return 'planted'
                    }
                    Start-Sleep -Milliseconds 2
                }
                return 'timed out'
            }).AddArgument((Join-Path $root 'rooms')).AddArgument($outside).AddArgument($kind)
        $handle = $planter.BeginInvoke()
        try {
            { & $reopen -Room 'reo' } | Should -Throw '*could not be restored*would go through a link*Nothing was restored*'
            [string]@($planter.EndInvoke($handle))[0] | Should -Be 'planted'
        }
        finally { $planter.Dispose() }
        Test-Path -LiteralPath (Join-Path $outside 'sub') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
        Test-Path -LiteralPath $room | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $root 'rooms') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.reo.reopen-*' }).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $object.Canon 'CLOSED') | Should -BeTrue
    }

    It 'refuses a removed folder without an archive that opens' {
        Close-TestRoom -Remove
        Remove-Item -LiteralPath $archive -Force
        { & $reopen -Room 'reo' } | Should -Throw '*no archive that opens*NEXT:*'
        [System.IO.File]::WriteAllText($archive, 'not a zip')
        { & $reopen -Room 'reo' } | Should -Throw '*no archive that opens*NEXT:*'
        Remove-Item -LiteralPath $archive -Force
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        ([System.IO.Compression.ZipFile]::Open($archive, [System.IO.Compression.ZipArchiveMode]::Create)).Dispose()
        { & $reopen -Room 'reo' } | Should -Throw '*no archive that opens*NEXT:*'
        Test-Path -LiteralPath $room | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $object.Canon 'CLOSED') | Should -BeTrue
    }

    It 'refuses a folder at the room''s place that is not this room''s' {
        Close-TestRoom
        [System.IO.File]::WriteAllText((Join-Path $room 'ROOM'), "room: other`n")
        { & $reopen -Room 'reo' } | Should -Throw '*does not hold the ROOM file of room*NEXT:*'
        Test-Path -LiteralPath (Join-Path $object.Canon 'CLOSED') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf, with the folder there and with the folder removed' {
        Close-TestRoom
        $local = Join-Path $root 'local'
        $beforeRoom = Get-TestTreeHash $room
        $beforeLocal = Get-TestTreeHash $local
        $null = & $reopen -Room 'reo' -WhatIf
        foreach ($pair in @(@($beforeRoom, (Get-TestTreeHash $room)), @($beforeLocal, (Get-TestTreeHash $local)))) {
            $pair[1].Count | Should -Be $pair[0].Count
            foreach ($key in $pair[0].Keys) { $pair[1][$key] | Should -Be $pair[0][$key] -Because $key }
        }

        $null = & (Join-Path $scripts 'Close-RelayRoom.ps1') -Remove 'reo' -Confirm:$false
        $beforeLocal = Get-TestTreeHash $local
        $null = & $reopen -Room 'reo' -WhatIf
        Test-Path -LiteralPath $room | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $root 'rooms') -Force).Count | Should -Be 0
        $afterLocal = Get-TestTreeHash $local
        $afterLocal.Count | Should -Be $beforeLocal.Count
        foreach ($key in $beforeLocal.Keys) { $afterLocal[$key] | Should -Be $beforeLocal[$key] -Because $key }
    }

    It 'closes, reopens and closes again: two transcripts and a second archive that holds both' {
        Close-TestRoom
        $null = & $reopen -Room 'reo'
        Close-TestRoom
        Test-Path -LiteralPath (Join-Path $room 'TRANSCRIPT.md') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $room -File -Filter 'TRANSCRIPT-closed-*.md').Count | Should -Be 1
        Test-Path -LiteralPath $archive | Should -BeTrue
        $entries = @((Get-TestZipHash $archive).Keys)
        $entries | Should -Contain 'TRANSCRIPT.md'
        @($entries | Where-Object { $_ -like 'TRANSCRIPT-closed-*.md' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $root 'local\archive') -File -Filter 'reo-closed-*.zip').Count | Should -Be 1
        @(Test-RelayTamper (Resolve-RelayRoom 'reo')).Count | Should -Be 0
        ((& (Join-Path $scripts 'Close-RelayRoom.ps1') -ListClosed) -join "`n") | Should -Match '(?m)^reo  closed .+  archive: yes'
    }

    It 'lets Update-RelayRoom and Add-RelayAgent work again, which refuse the closed room' {
        Close-TestRoom
        { & (Join-Path $scripts 'Update-RelayRoom.ps1') -Room 'reo' } | Should -Throw '*is closed*'
        { & (Join-Path $scripts 'Add-RelayAgent.ps1') -Room 'reo' -Replace 'jack' } | Should -Throw '*is closed*'
        $null = & $reopen -Room 'reo'
        ((& (Join-Path $scripts 'Update-RelayRoom.ps1') -Room 'reo') -join "`n") | Should -Match 'UP TO DATE|UPDATED'
        ((& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room 'reo' -Replace 'jack' -Force -Reason 'the old session stays stopped after the reopen') -join "`n") | Should -Match 'REPLACED jack: generation 2'
        ((& (Join-Path $scripts 'Add-RelayAgent.ps1') -Room 'reo' -OpenSeats 1) -join "`n") | Should -Match '1 free seat added'
        (Invoke-RelayTool -Room $room -Agent 'jack' -Engine $engine -Generation 2 -Words @('start', 'product', 'model', 'low')).ExitCode | Should -Be 0
        $old = Invoke-RelayTool -Room $room -Agent 'jack' -Engine $engine -Words @('check')
        $old.ExitCode | Should -Be 5
        $old.Output | Should -Match 'has replaced you'
    }

    It 'is not undone by the tamper check: the kept transcript is guarded, a CLOSED in the room is moved out' {
        Close-TestRoom
        $null = & $reopen -Room 'reo'
        $reopened = Resolve-RelayRoom 'reo'
        $kept = @(Get-ChildItem -LiteralPath $room -File -Filter 'TRANSCRIPT-closed-*.md')[0]
        $hash = Get-RelayFileHash $kept.FullName
        [System.IO.File]::WriteAllText((Join-Path $room 'CLOSED'), "closed_utc: 2020-01-01T00:00:00Z`n")
        [System.IO.File]::WriteAllText($kept.FullName, 'rewritten by an agent')
        $findings = @(Test-RelayTamper $reopened -Repair)
        @($findings | Where-Object { $_.Relative -eq 'CLOSED' -and $_.Kind -eq 'extra' -and $_.Repaired }).Count | Should -Be 1
        @($findings | Where-Object { $_.Relative -eq $kept.Name -and $_.Kind -eq 'changed' -and $_.Repaired }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $room 'CLOSED') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $reopened.Canon 'CLOSED') | Should -BeFalse
        Get-RelayFileHash $kept.FullName | Should -Be $hash
        @(Test-RelayTamper $reopened -Repair).Count | Should -Be 0
    }

    It 'completes a reopen that was cut short after the marker' {
        Close-TestRoom
        $null = & $reopen -Room 'reo'
        $index = @(Get-RelayRoomIndex)
        foreach ($entry in $index) { if ($entry.id -eq 'reo') { $entry.closed_utc = '2020-01-01T00:00:00Z' } }
        Save-RelayRoomIndex $index
        ((& $reopen -Room 'reo') -join "`n") | Should -Match 'earlier reopen was cut short'
        Get-TestClosedStamp | Should -Be ''
        { & $reopen -Room 'reo' } | Should -Throw '*is not closed*'
    }

    It 'removes the room''s CLOSED as well when the cut came between this PC''s marker and the room''s' {
        Close-TestRoom
        $null = & $reopen -Room 'reo'
        # As the cut leaves it: this PC's marker gone, the room's still there, the index still closed
        [System.IO.File]::WriteAllText((Join-Path $room 'CLOSED'), "closed_utc: 2020-01-01T00:00:00Z`n")
        $index = @(Get-RelayRoomIndex)
        foreach ($entry in $index) { if ($entry.id -eq 'reo') { $entry.closed_utc = '2020-01-01T00:00:00Z' } }
        Save-RelayRoomIndex $index
        (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')).ExitCode | Should -Be 5
        ((& $reopen -Room 'reo') -join "`n") | Should -Match 'earlier reopen was cut short'
        Test-Path -LiteralPath (Join-Path $room 'CLOSED') | Should -BeFalse
        Get-TestClosedStamp | Should -Be ''
        (Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engine -Words @('check')).ExitCode | Should -Not -Be 5
    }
}
