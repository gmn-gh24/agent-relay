#Requires -Version 5.1

<#
.SYNOPSIS
    Reopens a room that was closed on this PC: the same room, its messages, plan and standing rules, for new
    sessions.

.DESCRIPTION
    Closed is what this PC says (the CLOSED marker of the canonical copy), so only the PC that closed a room can
    reopen it. The room must be in the room index of this PC and closed.

    When the room folder is still there it must hold this room's ROOM file. When it is gone (Close-RelayRoom.ps1
    -Remove), it is restored from the archive of the close, <local>\archive\<id>.zip: every entry is checked
    before anything is written (no absolute name, no drive, no '..', nothing that lands outside the room, at
    most 100000 entries and 4 GB), the files are unpacked into a new folder beside the room's place and that
    folder is moved into place only when it is whole. Either way the tamper check then puts every guarded file
    right from the canonical copy, so a reopened room cannot differ from it.

    Reopening then keeps the transcript of the close as TRANSCRIPT-closed-<time>.md (canonical copy and room) so
    the next close does not write over it, moves the archive of the close aside to <id>-closed-<time>.zip so it
    is never taken for the archive of the next close, stops every agent's old session (a stop through its
    control file: an old session that calls the tool again is told to stop; a new session from
    Add-RelayAgent.ps1 -Replace runs), removes the CLOSED marker, marks the room open in the room index and
    notes the reopen in the owner's log of this PC. The coordinator's own launcher works again as it was.

    A reopen that was cut short is completed by running this again. -WhatIf checks everything and writes
    nothing; -Confirm asks first.

.PARAMETER Room
    Room id or room folder of the closed room.

.EXAMPLE
    .\Reopen-RelayRoom.ps1 -Room 2026-10-10-docs

.EXAMPLE
    .\Reopen-RelayRoom.ps1 -Room 2026-10-10-docs -WhatIf

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$archiveRoot = Join-Path (Get-RelayLocalRoot) 'archive'
# What the archive writer of a close can produce at most; an archive that claims more is refused unread
$maxEntries = 100000
$maxBytes = [long]4294967296

function Format-Refusal {
    # A refusal says why and what to do; nothing has been changed when it is thrown
    param([string]$Reason, [string]$Next)
    return "$Reason NEXT: $Next"
}

function Find-IndexEntry {
    # The index entry of the room by id or by folder; $null when the index of this PC has none. The folder of a
    # room that was removed does not exist: it is compared as a path, never looked at.
    param([string]$Name)
    $entries = @(Get-RelayRoomIndex)
    if ($Name -match '[\\/:]') {
        $folder = Get-RelayNormalPath ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Name))
        foreach ($candidate in $entries) {
            $candidatePath = ''
            try { $candidatePath = Get-RelayNormalPath ([string](Get-RelayProperty $candidate 'path' '')) } catch { continue }
            if ([string]::Equals($candidatePath, $folder, [System.StringComparison]::OrdinalIgnoreCase)) { return $candidate }
        }
        return $null
    }
    foreach ($candidate in $entries) {
        if ([string](Get-RelayProperty $candidate 'id' '') -ceq $Name) { return $candidate }
    }
    return $null
}

function Test-RoomArchive {
    # An archive is a zip that opens and holds a file, as Close-RelayRoom.ps1 judges it
    param([string]$Archive)
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
        try { return ($zip.Entries.Count -gt 0) }
        finally { $zip.Dispose() }
    }
    catch { return $false }
}

function Get-EntryRelative {
    # The name of a zip entry as a path below the room, with forward slashes; an error for a name the archive
    # writer of a close never makes: absolute, with a drive or a stream (a colon), with '.' or '..' as a part,
    # with an empty part, with a control character or one Windows does not allow in a name, or with a part that
    # ends in a dot or a space (Windows would cut those off and so name another file). A backslash counts as a
    # separator, so '..\x' is '../x'. A name that ends in a slash is a folder and keeps its slash.
    param([string]$Name)
    $shown = ConvertTo-RelayHeaderText $Name
    if (-not $Name) { throw 'an entry of the archive has no name' }
    if ($Name -match '[\x00-\x1f\x7f:*?"<>|]') { throw "the archive entry '$shown' holds a drive, a stream or a character no room file name has" }
    $slashed = $Name.Replace('\', '/')
    if ($slashed.StartsWith('/', [System.StringComparison]::Ordinal)) { throw "the archive entry '$shown' is an absolute path" }
    $isFolder = $slashed.EndsWith('/', [System.StringComparison]::Ordinal)
    $body = $slashed
    if ($isFolder) { $body = $slashed.Substring(0, $slashed.Length - 1) }
    if (-not $body) { throw "the archive entry '$shown' names the room itself" }
    foreach ($part in $body.Split([char]'/')) {
        if (-not $part) { throw "the archive entry '$shown' has an empty part" }
        if ($part -ceq '.' -or $part -ceq '..') { throw "the archive entry '$shown' climbs out of its folder" }
        if ($part.EndsWith('.', [System.StringComparison]::Ordinal) -or $part.EndsWith(' ', [System.StringComparison]::Ordinal)) { throw "the archive entry '$shown' has a part that ends in a dot or a space" }
    }
    return $slashed
}

function Get-ContainedPath {
    # The full path of a relative entry below a root; an error when it does not stay below the root
    param([string]$Root, [string]$Relative)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $top = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $local = $Relative.TrimEnd('/').Replace([char]'/', $separator)
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($top, $local))
    if (-not $full.StartsWith($top + $separator, [System.StringComparison]::Ordinal)) { throw "the archive entry '$(ConvertTo-RelayHeaderText $Relative)' lands outside the room" }
    return $full
}

function Test-ArchiveEntry {
    # Checks every entry of the archive against the room's place before anything is written: names, count and
    # the size they claim. Returns how many files and bytes it would restore.
    param([string]$Archive, [string]$Root)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -gt $maxEntries) { throw "the archive holds $($zip.Entries.Count) entries, more than $maxEntries" }
        $seen = @{}
        $files = 0
        $total = [long]0
        foreach ($entry in $zip.Entries) {
            $relative = Get-EntryRelative $entry.FullName
            $null = Get-ContainedPath $Root $relative
            # Two entries for one file (in any case: Windows does not tell them apart) are none the writer makes
            $key = $relative.TrimEnd('/').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "the archive names '$(ConvertTo-RelayHeaderText $relative)' twice" }
            $seen[$key] = $true
            if ($relative.EndsWith('/', [System.StringComparison]::Ordinal)) { continue }
            $files++
            $total += [long]$entry.Length
            if ($total -gt $maxBytes) { throw "the archive unpacks to more than $maxBytes bytes" }
        }
        if ($files -eq 0) { throw 'the archive holds no file' }
        return [pscustomobject]@{ Files = $files; Bytes = $total }
    }
    finally { $zip.Dispose() }
}

function Expand-RoomArchive {
    # Unpacks the archive into the new folder $Target (which must not exist): every entry checked again, every
    # file created new (never written over, never through a link), and no file longer than its entry says or
    # the whole longer than the limit
    param([string]$Archive, [string]$Target)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $null = [System.IO.Directory]::CreateDirectory($Target)
    $buffer = New-Object byte[] 81920
    $total = [long]0
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $relative = Get-EntryRelative $entry.FullName
            $path = Get-ContainedPath $Target $relative
            if ($relative.EndsWith('/', [System.StringComparison]::Ordinal)) {
                if (Test-RelayLinkedPath -Root $Target -Path $path) { throw "the archive entry '$(ConvertTo-RelayHeaderText $relative)' would go through a link" }
                $null = [System.IO.Directory]::CreateDirectory($path)
                continue
            }
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            if (Test-RelayLinkedPath -Root $Target -Path $path) { throw "the archive entry '$(ConvertTo-RelayHeaderText $relative)' would go through a link" }
            $declared = [long]$entry.Length
            $written = [long]0
            $source = $entry.Open()
            try {
                $sink = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    while ($true) {
                        $count = $source.Read($buffer, 0, $buffer.Length)
                        if ($count -le 0) { break }
                        $written += $count
                        $total += $count
                        if ($written -gt $declared) { throw "the archive entry '$(ConvertTo-RelayHeaderText $relative)' unpacks to more than it says" }
                        if ($total -gt $maxBytes) { throw "the archive unpacks to more than $maxBytes bytes" }
                        $sink.Write($buffer, 0, $count)
                    }
                }
                finally { $sink.Dispose() }
            }
            finally { $source.Dispose() }
            if ($written -ne $declared) { throw "the archive entry '$(ConvertTo-RelayHeaderText $relative)' is shorter than it says" }
            $stamp = $entry.LastWriteTime
            try { [System.IO.File]::SetLastWriteTimeUtc($path, $stamp.UtcDateTime) } catch { $null = $_ }
        }
    }
    finally { $zip.Dispose() }
}

function Restore-RoomFolder {
    # The room folder from the archive: unpacked beside its place, then moved there whole. A failure leaves
    # nothing at the room's place and removes the half-made folder.
    param($Entry, [string]$Archive, [string]$Path)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    $null = [System.IO.Directory]::CreateDirectory($parent)
    $building = Join-Path $parent ('.{0}.reopen-{1}' -f ([System.IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N').Substring(0, 8))
    $isMoved = $false
    try {
        Expand-RoomArchive -Archive $Archive -Target $building
        # The folders a room has even when they are empty: a zip holds files only
        $folders = New-Object System.Collections.Generic.List[string]
        foreach ($name in 'tools', 'agents', 'files', 'work') { $folders.Add($name) }
        $canonAgents = Join-Path (Join-Path (Join-Path (Join-Path (Get-RelayLocalRoot) 'rooms') ([string]$Entry.id)) 'canon') 'agents'
        if (Test-Path -LiteralPath $canonAgents -PathType Container) {
            foreach ($agent in @(Get-ChildItem -LiteralPath $canonAgents -Directory -Force)) {
                if ($agent.Name -cnotmatch '^[a-z][a-z0-9]{1,15}$') { continue }
                foreach ($name in 'inbox', 'attach') { $folders.Add("agents/$($agent.Name)/$name") }
            }
        }
        foreach ($relative in $folders) {
            $folder = Get-ContainedPath $building $relative
            if (Test-RelayLinkedPath -Root $building -Path $folder) { continue }
            $null = [System.IO.Directory]::CreateDirectory($folder)
        }
        if (Test-Path -LiteralPath $Path) { throw "something appeared at $Path while the archive was unpacked" }
        [System.IO.Directory]::Move($building, $Path)
        $isMoved = $true
    }
    finally {
        if (-not $isMoved -and (Test-Path -LiteralPath $building)) {
            try { Remove-RelayTree -Path $building -Confirm:$false } catch { Write-Warning "Could not remove the half-restored folder ${building}: $($_.Exception.Message)" }
        }
    }
}

function Clear-ClosedStamp {
    # Marks the room open in the room index of this PC, under the index's lock, as New-RelayRoom.ps1 lists an
    # open room: closed_utc empty, and nothing said about what became of the folder of a closed room
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameter is read by the change the index helper runs inside its lock')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only after the script''s own ShouldProcess')]
    param([string]$Id)
    Update-RelayRoomIndex -Change {
        param($entries)
        foreach ($item in @($entries)) {
            if ([string](Get-RelayProperty $item 'id' '') -ceq $Id) {
                $item | Add-Member -NotePropertyName 'closed_utc' -NotePropertyValue '' -Force
                if ($null -ne $item.PSObject.Properties['folder']) { $item.PSObject.Properties.Remove('folder') }
            }
            $item
        }
    }
}

function Remove-RoomFile {
    # One file of the room, never through a link
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only after the script''s own ShouldProcess')]
    param($RoomObject, [string]$Relative)
    $path = Join-Path $RoomObject.Path $Relative
    Assert-RelayRoomTarget $RoomObject $path
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
}

# --- What the room is: this PC's index and canonical copy, never the room folder ---
$entry = Find-IndexEntry $Room
if ($null -eq $entry) { throw (Format-Refusal "No room '$Room': it is not in the room index of this PC." 'list the rooms with Get-RelayRooms.ps1 -All and give the id of the closed room.') }
$id = [string](Get-RelayProperty $entry 'id' '')
if (-not (Test-RelayRoomId $id)) { throw (Format-Refusal "The room index of this PC holds an entry whose id '$id' is no room id." 'repair the room index of this PC by hand.') }
$path = [string](Get-RelayProperty $entry 'path' '')
if (-not $path) { throw (Format-Refusal "The room '$id' is in the index of this PC without a folder." 'repair the room index of this PC by hand.') }
$path = Get-RelayNormalPath $path
$probe = Get-RelayRoomObject -Id $id -Path $path
if (-not (Test-Path -LiteralPath (Join-Path $probe.Canon 'ROOM') -PathType Leaf)) { throw (Format-Refusal "The room '$id' has no canonical copy on this PC: reopening works only on the PC that closed the room." 'run Reopen-RelayRoom.ps1 on the PC that created and closed this room.') }
$stamped = [string](Get-RelayProperty $entry 'closed_utc' '')
$canonClosed = Join-Path $probe.Canon 'CLOSED'

if (-not $probe.IsClosed) {
    if (-not $stamped) { throw (Format-Refusal "The room '$id' is not closed: there is nothing to reopen." "carry on in it, or close it with Close-RelayRoom.ps1 -Room $id.") }
    # The marker is gone and the index still says closed: a reopen that was cut short after the marker
    $roomObject = Resolve-RelayRoom $id
    if (-not $PSCmdlet.ShouldProcess($id, 'Mark the reopened room open in the room index')) { return }
    Clear-ClosedStamp -Id $id
    Add-RelayLine (Join-Path $roomObject.Owner 'log') ("{0}`treopen`t{1}`tsession`tcompleted" -f (Format-RelayUtc), $stamped)
    "The room index of this PC marks the room $id open now: an earlier reopen was cut short."
    "NEXT: bring the agents back with Add-RelayAgent.ps1 -Room $id -Replace <name>, or add seats with -OpenSeats <n>."
    return
}

# --- The folder: there and this room's, or restored from the archive ---
$archive = Join-Path $archiveRoot "$id.zip"
$needsRestore = -not (Test-Path -LiteralPath $path)
if ($needsRestore) {
    if (-not (Test-RoomArchive $archive)) { throw (Format-Refusal "The folder of the room '$id' is gone and there is no archive that opens at ${archive}: nothing to reopen from." "put the room's archive back at $archive, or the room folder back at $path, then run this again.") }
    try { $planned = Test-ArchiveEntry -Archive $archive -Root $path }
    catch { throw (Format-Refusal "The archive $archive is refused: $($_.Exception.Message). Nothing was restored." 'do not use this archive; put the room folder back from a copy you trust, then run this again.') }
}
else {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw (Format-Refusal "The room's place $path is not a folder." 'move what is there away, then run this again.') }
    $roomFile = Join-Path $path 'ROOM'
    $named = ''
    if (-not (Test-RelayLinkedPath -Root $path -Path $roomFile)) { $named = [string](Get-RelayValue (Read-RelayKeyValue $roomFile) 'room' '') }
    if (-not ($named -ceq $id)) { throw (Format-Refusal "The folder $path does not hold the ROOM file of room '$id': it is not this room's folder." "move that folder away, then run this again: the room is restored from $archive.") }
}

$what = 'Reopen the closed room: keep its transcript and archive aside, stop the old sessions, remove the CLOSED marker, mark it open in the room index'
if ($needsRestore) { $what = "Restore the room folder from $archive ($($planned.Files) files), then r" + $what.Substring(1) }
if (-not $PSCmdlet.ShouldProcess($id, $what)) { return }

if ($needsRestore) {
    try { Restore-RoomFolder -Entry $entry -Archive $archive -Path $path }
    catch { throw (Format-Refusal "The room folder could not be restored from ${archive}: $($_.Exception.Message). Nothing was restored." 'find the reason, then run this again.') }
}
$roomObject = Resolve-RelayRoom $id

# Every guarded file as this PC holds it: what an archive or anybody brought into the room is put right first
$blocked = New-Object System.Collections.Generic.List[string]
foreach ($finding in @(Test-RelayTamper $roomObject -Repair)) {
    ConvertTo-RelayPrintedLine ('tamper check: ' + (Format-RelayTamperFinding $finding))
    if (-not $finding.Repaired) { $blocked.Add([string]$finding.Relative) }
}
if ($blocked.Count -gt 0) { throw (Format-Refusal ("The room is still closed: these guarded files could not be put right: " + ($blocked -join ', ') + '.') "remove each link the tamper check names and see $(Join-Path $roomObject.Local 'alarms.log'), then run this again.") }

# The close's time names what is kept of it
$closedUtc = Get-RelayValue (Read-RelayKeyValue $canonClosed) 'closed_utc' ''
$closedTime = ConvertFrom-RelayUtc $closedUtc
if ($null -eq $closedTime) { $closedTime = Get-RelayFileTimeUtc $canonClosed }
$suffix = Format-RelayUtc $closedTime 'yyyyMMddTHHmmssZ'

# The transcript of the close stays, guarded, under a name the next close does not write
$kept = ''
$canonTranscript = Join-Path $roomObject.Canon 'TRANSCRIPT.md'
if (Test-Path -LiteralPath $canonTranscript -PathType Leaf) {
    $kept = "TRANSCRIPT-closed-$suffix.md"
    $number = 1
    while (Test-Path -LiteralPath (Join-Path $roomObject.Canon $kept)) { $number++; $kept = "TRANSCRIPT-closed-$suffix-$number.md" }
    Copy-RelayGuardedFile $roomObject $kept $canonTranscript
    Remove-RoomFile $roomObject 'TRANSCRIPT.md'
    [System.IO.File]::Delete($canonTranscript)
}

# The archive of the close goes aside: the next close must never find it and take it for its own
$keptArchive = ''
if (Test-Path -LiteralPath $archive -PathType Leaf) {
    $keptArchive = Join-Path $archiveRoot "$id-closed-$suffix.zip"
    $number = 1
    while (Test-Path -LiteralPath $keptArchive) { $number++; $keptArchive = Join-Path $archiveRoot "$id-closed-$suffix-$number.zip" }
    Move-Item -LiteralPath $archive -Destination $keptArchive
}

# Every agent's old session stays stopped. Closing told them to stop (the CLOSED marker) and a bye ends nothing
# in the tool: once the marker is gone, an old session whose generation is still the current one would run again.
# The stop in its control file ends it at its next command; -Replace writes a new generation with "run".
$stopped = New-Object System.Collections.Generic.List[string]
foreach ($name in @(Get-RelayRoster $roomObject)) {
    if ($name -ceq $roomObject.Coordinator) { continue }
    Write-RelayGuardedText $roomObject "agents/$name/control" "state: stop`nnote: the room was closed and is reopened for new sessions only`n"
    $stopped.Add($name)
}

# Open from here on: this PC's marker first, then the room's
[System.IO.File]::Delete($canonClosed)
Remove-RoomFile $roomObject 'CLOSED'
Clear-ClosedStamp -Id $id
Add-RelayLine (Join-Path $roomObject.Owner 'log') ("{0}`treopen`t{1}`tsession`t{2}" -f (Format-RelayUtc), $closedUtc, $(if ($needsRestore) { 'restored' } else { 'folder' }))

"REOPENED room $id"
if ($needsRestore) { "restored: the room folder $path from $archive" }
if ($kept) { 'transcript of the close: ' + (Join-Path $roomObject.Path $kept) }
if ($keptArchive) { "archive of the close: $keptArchive" }
if ($stopped.Count -gt 0) { 'old sessions stopped: ' + ($stopped -join ', ') }
'carried over: the messages, the plan, DECISIONS.md (standing rules) and every agent''s seat.'
"NEXT: bring each agent back with Add-RelayAgent.ps1 -Room $id -Replace <name> (a new session, same seat and memory), or add seats with -OpenSeats <n>; start the feed again; your own command works as before."
