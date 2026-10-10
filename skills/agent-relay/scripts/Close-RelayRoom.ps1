#Requires -Version 5.1

<#
.SYNOPSIS
    Closes a room: transcript, CLOSED marker, statistics and an archive on this PC. Also lists closed rooms and
    removes the folder of one when the owner says so.

.DESCRIPTION
    Before this, the coordinator sends its closing note to all and waits for each agent's bye (the bye says what
    slowed that agent down). The script refuses while an agent that has started has not said bye, unless -Force.

    A room is closed when this PC says so: the CLOSED marker of its canonical copy. A CLOSED that anybody else puts into
    the room closes nothing; the tamper check, which runs first here, moves it out.

    Closing writes TRANSCRIPT.md into the room, sets the CLOSED marker (the tools refuse a closed room from then
    on), marks the room closed in the room index, and saves the statistics and a zip of the whole room under the
    machine state folder. A link in the room (a symbolic link or a junction) is left out of the zip and named: what
    it points at is not the room's. The room folder itself stays where it is. If the zip could not be made, run
    this again on the closed room: it makes the archive and says so. A close that was cut short is completed the
    same way. -WhatIf shows what closing would do and changes nothing; -Confirm asks first.

    -ListClosed shows closed rooms whose folder still exists. -Remove deletes the folder of one closed room; it
    needs the archive to exist and asks for confirmation (-Confirm:$false to skip, -WhatIf to see only). A link in
    the folder is removed as a link: nothing it points at is deleted. Remove a room only when the owner said so.

.PARAMETER Room
    Room id or room folder to close.

.PARAMETER Force
    Close although some agents have not said bye.

.PARAMETER ListClosed
    List closed rooms whose folder still exists.

.PARAMETER Remove
    Id of a closed room whose folder is to be deleted.

.EXAMPLE
    .\Close-RelayRoom.ps1 -Room 2026-10-10-docs

.EXAMPLE
    .\Close-RelayRoom.ps1 -Remove 2026-10-10-docs -WhatIf

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Close', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Close')][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(ParameterSetName = 'Close')][switch]$Force,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListClosed,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][ValidateNotNullOrEmpty()][string]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$archiveRoot = Join-Path (Get-RelayLocalRoot) 'archive'
# Closing asks nobody unless -Confirm is given (the coordinator closes when the owner said so); -WhatIf only shows
$isWhatIf = [bool]$WhatIfPreference
$askFirst = ($isWhatIf -or $PSBoundParameters.ContainsKey('Confirm'))

function Test-RoomArchive {
    # An archive is a zip that opens and holds a file. An empty or half-written file at its name is none: the
    # folder of a room is removed on the word of this check
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

if ($ListClosed) {
    $found = 0
    foreach ($entry in @(Get-RelayRoomIndex)) {
        if (-not (Get-RelayProperty $entry 'closed_utc' '')) { continue }
        if (-not (Test-Path -LiteralPath $entry.path)) { continue }
        $found++
        $hasArchive = Test-RoomArchive (Join-Path $archiveRoot "$($entry.id).zip")
        '{0}  closed {1}  archive: {2}  {3}' -f $entry.id, $entry.closed_utc, $(if ($hasArchive) { 'yes' } else { 'NO' }), $entry.path
    }
    if ($found -eq 0) { 'No closed room has a folder left.' }
    else { 'NEXT: remove one only when the owner says so: Close-RelayRoom.ps1 -Remove <id>' }
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Remove') {
    $entry = @(Get-RelayRoomIndex | Where-Object { $_.id -eq $Remove })
    if ($entry.Count -eq 0) { throw "No room '$Remove' in the room index" }
    if (-not (Get-RelayProperty $entry[0] 'closed_utc' '')) { throw "The room '$Remove' is not closed" }
    $archive = Join-Path $archiveRoot "$Remove.zip"
    if (-not (Test-RoomArchive $archive)) { throw "The room '$Remove' has no archive at ${archive}: its folder is the only copy and is not removed" }
    $path = [string]$entry[0].path
    if (-not (Test-Path -LiteralPath (Join-Path $path 'CLOSED'))) { throw "The folder $path has no CLOSED marker: not removed" }
    if ($PSCmdlet.ShouldProcess($path, 'Delete the folder of the closed room (its archive stays)')) {
        # Each link in the folder goes as a link: Windows PowerShell 5.1 would delete what lies behind a junction
        Remove-RelayTree -Path $path -Confirm:$false
        "REMOVED the folder of room $Remove. Its archive stays: $archive"
    }
    return
}

function ConvertTo-RoomRelative {
    # A path below the room folder as the room names it: relative, with forward slashes
    param([string]$Top, [string]$Path)
    return ($Path.Substring($Top.Length).TrimStart('\', '/') -replace '\\', '/')
}

function Write-RoomZip {
    # The zip of every file of the room, from a list that enters no link: what a link points at is not the room's
    # (a junction could pull in a whole disk). The paths are taken literally, brackets and all. A file an agent
    # still writes to is read all the same. Returns the links that were left out, relative to the room.
    param([string]$Folder, [string]$Zip)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $top = (Get-RelayNormalPath $Folder).TrimEnd('\', '/')
    $tree = Get-RelayFileTree $top
    $zipArchive = [System.IO.Compression.ZipFile]::Open($Zip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @($tree.Files)) {
            $entry = $zipArchive.CreateEntry((ConvertTo-RoomRelative $top $file.FullName), [System.IO.Compression.CompressionLevel]::Optimal)
            # A zip holds times from 1980 to 2107 only
            $stamp = $file.LastWriteTime
            if ($stamp.Year -ge 1980 -and $stamp.Year -le 2107) { $entry.LastWriteTime = [DateTimeOffset]$stamp }
            $source = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $target = $entry.Open()
                try { $source.CopyTo($target) }
                finally { $target.Dispose() }
            }
            finally { $source.Dispose() }
        }
    }
    finally { $zipArchive.Dispose() }
    return @($tree.Links | ForEach-Object { ConvertTo-RoomRelative $top $_ })
}

function Save-RoomArchive {
    # The zip of the whole room under the machine state folder: IsMade is $false (and an alarm raised) when it could
    # not be made, Links names the links that were left out. It is made beside its place and moved there only when
    # it is whole, so a file at the archive's name is always a whole archive. A room that is closing still has a
    # writer or two (a wait that sees the marker and removes its lease, a feed that puts a file back): a file that
    # went away while the zip was made fails the zip, so it is tried three times.
    param($RoomObject, [string]$Archive)
    $building = Join-Path $archiveRoot "$($RoomObject.Id).building.zip"
    $reason = ''
    $links = @()
    foreach ($try in 1..3) {
        try {
            if (-not (Test-Path -LiteralPath $archiveRoot)) { $null = New-Item -ItemType Directory -Path $archiveRoot -Force }
            if (Test-Path -LiteralPath $building) { Remove-Item -LiteralPath $building -Force }
            $links = @(Write-RoomZip -Folder $RoomObject.Path -Zip $building)
            if (-not (Test-RoomArchive $building)) { throw 'the zip that was made does not open or is empty' }
            if (Test-Path -LiteralPath $Archive) { Remove-Item -LiteralPath $Archive -Force }
            Move-Item -LiteralPath $building -Destination $Archive -Force
            return [pscustomobject]@{ IsMade = $true; Links = $links }
        }
        catch {
            $reason = $_.Exception.Message
            if ($try -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    try { if (Test-Path -LiteralPath $building) { Remove-Item -LiteralPath $building -Force } } catch { $null = $_ }
    Add-RelayAlarm $RoomObject "ARCHIVE failed: $reason"
    return [pscustomobject]@{ IsMade = $false; Links = $links }
}

function Save-ClosedStamp {
    # Marks the room closed in the room index of this PC, under the index's lock; an index that cannot be read is
    # an error, never an empty list. -KeepStamp: a date the entry already has stays.
    param([string]$Id, [string]$Stamp, [switch]$KeepStamp)
    Update-RelayRoomIndex -Change {
        param($entries)
        foreach ($entry in @($entries)) {
            if ([string](Get-RelayProperty $entry 'id' '') -ceq $Id -and -not ($KeepStamp -and [string](Get-RelayProperty $entry 'closed_utc' ''))) {
                $entry | Add-Member -NotePropertyName 'closed_utc' -NotePropertyValue $Stamp -Force
            }
            $entry
        }
    }
}

function Get-LinkLine {
    # The line that names the links the archive left out; nothing when there were none. A link's name is room text.
    param([string[]]$Links = @())
    $named = @($Links | Where-Object { $_ })
    if ($named.Count -eq 0) { return }
    ConvertTo-RelayPrintedLine ('archive: links left out (what they point at is not the room''s): ' + ($named -join ', '))
}

$roomObject = Resolve-RelayRoom $Room
# The tamper pass comes first: what anybody but this PC wrote into the room is put right before anything is read.
# With -WhatIf it only says what it would put right.
foreach ($finding in @(Test-RelayTamper $roomObject -Repair:(-not $isWhatIf))) {
    $line = Format-RelayTamperFinding $finding
    if ($isWhatIf -and $finding.Kind -ne 'link') { $line = "$($finding.Relative) was $($finding.Kind): left as it is (-WhatIf)" }
    ConvertTo-RelayPrintedLine "tamper check: $line"
}
# Closed is what this PC says: the canonical CLOSED marker
$canonClosed = Join-Path $roomObject.Canon 'CLOSED'
if (Test-Path -LiteralPath $canonClosed) {
    # A close that was cut short after the marker: the index learns of it now, with the date of the marker
    $indexed = @(Get-RelayRoomIndex | Where-Object { [string](Get-RelayProperty $_ 'id' '') -ceq $roomObject.Id })
    if ($indexed.Count -gt 0 -and -not [string](Get-RelayProperty $indexed[0] 'closed_utc' '')) {
        $stamp = Get-RelayValue (Read-RelayKeyValue $canonClosed) 'closed_utc' ''
        if (-not $stamp) { $stamp = Format-RelayUtc (Get-RelayFileTimeUtc $canonClosed) }
        if (-not $askFirst -or $PSCmdlet.ShouldProcess($roomObject.Id, 'Mark the closed room closed in the room index')) {
            Save-ClosedStamp -Id $roomObject.Id -Stamp $stamp -KeepStamp
            "The room index of this PC marks the room $($roomObject.Id) closed now ($stamp): an earlier close was cut short."
        }
    }
    $closedArchive = Join-Path $archiveRoot "$($roomObject.Id).zip"
    if (Test-RoomArchive $closedArchive) {
        "The room $($roomObject.Id) is already closed."
        "NEXT: nothing is left to do here. Remove its folder only when the owner says so: Close-RelayRoom.ps1 -Remove $($roomObject.Id)"
        return
    }
    # Closed, but the archive of an earlier call failed: make it now
    if (-not (Test-Path -LiteralPath $roomObject.Path)) { throw "The room $($roomObject.Id) is closed and has no archive, and its folder is gone: $($roomObject.Path)" }
    if ($askFirst -and -not $PSCmdlet.ShouldProcess($roomObject.Id, 'Make the missing archive of the closed room')) { return }
    $saved = Save-RoomArchive $roomObject $closedArchive
    if ($saved.IsMade) {
        "The room $($roomObject.Id) was already closed; its archive was missing and is made now."
        "archive: $closedArchive"
        Get-LinkLine $saved.Links
        "NEXT: nothing is left to do here. Remove its folder only when the owner says so: Close-RelayRoom.ps1 -Remove $($roomObject.Id)"
    }
    else {
        'ARCHIVE FAILED again: the room folder is the only copy, do not remove it. Run this again when the reason is gone (see alarms.log of the room).'
        Get-LinkLine $saved.Links
        "NEXT: find the reason in $(Join-Path $roomObject.Local 'alarms.log'), then run Close-RelayRoom.ps1 -Room $($roomObject.Id) again."
    }
    return
}
$board = Get-RelayBoard $roomObject
$stillHere = @($board.agents | Where-Object { -not $_.isCoordinator -and $_.isIntroduced -and @('offline', 'retired') -notcontains $_.state })
if ($stillHere.Count -gt 0 -and -not $Force) {
    # The state is what the agent's own status file says: room text, printed without its control characters
    ConvertTo-RelayPrintedLine ("NOT CLOSED: these agents have not said bye: " + ((@($stillHere | ForEach-Object { "$($_.name) ($($_.state))" })) -join ', '))
    'NEXT: send your closing note to all and wait for each bye. Use -Force only for agents that cannot answer any more.'
    return
}
if ($askFirst -and -not $PSCmdlet.ShouldProcess($roomObject.Id, 'Close the room: transcript, CLOSED marker, room index, statistics and archive')) { return }

$stats = Get-RelayStatistic $roomObject
$messages = @(Get-RelayMessage $roomObject)
$closedUtc = Format-RelayUtc
$text = New-Object System.Collections.Generic.List[string]
$text.Add("# Transcript of room $($roomObject.Id)")
$text.Add('')
$text.Add("- Job: $($board.job)")
$text.Add("- Coordinator: $($board.coordinator), authority: $($board.authority)")
$text.Add("- Created: $(Get-RelayValue $roomObject.Info 'created_utc' '?'), closed: $closedUtc")
$text.Add("- Protocol $(Get-RelayValue $roomObject.Info 'protocol' '?'), package $(Get-RelayValue $roomObject.Info 'package' '?')")
$text.Add("- Messages: $($messages.Count); requests: $($stats.requests), answered $($stats.answered); reply time median $($stats.replyMedianMinutes) min, longest $($stats.replyMaxMinutes) min")
$text.Add('')
$text.Add('## Agents')
$text.Add('')
$text.Add('| Name | Role | Machine | Runs on | As | Agent | Sessions |')
$text.Add('|------|------|---------|---------|----|-------|----------|')
foreach ($agent in @($board.agents)) {
    $care = 'in use'
    if ($agent.machineCare -eq 'disposable') { $care = 'disposable for this job' }
    $text.Add("| $($agent.display) | $($agent.role) | $($agent.machine) ($care) | $($agent.computer) $($agent.ipv4) | $($agent.user), $($agent.elevation) | $($agent.product) $($agent.model), $($agent.effort) | $($agent.gen) |")
}
$text.Add('')
$text.Add('## Standing rules and owner decisions')
$text.Add('')
$rules = @(((Read-RelayText (Join-Path $roomObject.Canon 'DECISIONS.md')) -split "`n") | Where-Object { $_ -match '^\s*\|' })
if ($rules.Count -gt 2) { foreach ($rule in $rules) { $text.Add($rule) } } else { $text.Add('(none)') }
$text.Add('')
$text.Add('## Messages')
foreach ($message in $messages) {
    $re = ''
    if ($message.Re) { $re = ", re $($message.Re)" }
    $text.Add('')
    $text.Add("### $($message.Id): $($message.Type) from $($message.From) to $($message.To)$re")
    $text.Add('')
    $text.Add("$(Format-RelayUtc $message.Time 'yyyy-MM-dd HH:mm:ss') UTC. **$($message.Subject)**")
    $text.Add('')
    $text.Add($message.Body)
    $files = Join-Path (Join-Path $roomObject.Path 'files') $message.Id
    # The attachments as the room holds them: a link among them is not followed
    if ((Test-Path -LiteralPath $files -PathType Container) -and -not (Test-RelayLinkedPath -Root $roomObject.Path -Path $files)) {
        $text.Add('')
        $text.Add('Files: ' + ((@((Get-RelayFileTree $files).Files | ForEach-Object { $_.Name })) -join ', '))
    }
}
$cards = @(Get-RelayOwnerCard $roomObject)
if ($cards.Count -gt 0) {
    $text.Add('')
    $text.Add('## Cards for the owner')
    foreach ($card in $cards) {
        $outcome = 'not answered'
        if (-not $card.IsOpen) { $outcome = "$($card.Decision), in the $($card.Via)" }
        $text.Add('')
        $text.Add("### $($card.Id): $($card.Subject)")
        $text.Add('')
        $text.Add("Sent $($card.SentUtc), about $($card.Re). Outcome: $outcome.")
        $text.Add('')
        $text.Add($card.Body)
    }
}
$alarms = @(((Read-RelayText (Join-Path $roomObject.Local 'alarms.log')) -split "`n") | Where-Object { $_ })
if ($alarms.Count -gt 0) {
    $text.Add('')
    $text.Add('## Alarms')
    $text.Add('')
    foreach ($alarm in $alarms) { $text.Add("- $alarm") }
}
$transcript = ($text -join "`n") + "`n"
Write-RelayGuardedText $roomObject 'TRANSCRIPT.md' $transcript
Write-RelayGuardedText $roomObject 'CLOSED' ("closed_utc: $closedUtc`nby: $($roomObject.Coordinator)`n")
# The index follows the marker at once: a close cut short after this point (the archive is slow) still lists the
# room as closed, and a call on the closed room makes what is missing
Save-ClosedStamp -Id $roomObject.Id -Stamp $closedUtc
Write-RelayText (Join-Path $roomObject.Local 'stats.json') ((ConvertTo-Json -InputObject $stats -Depth 6) + "`n")

$archive = Join-Path $archiveRoot "$($roomObject.Id).zip"
$saved = Save-RoomArchive $roomObject $archive

"CLOSED room $($roomObject.Id)"
"transcript: " + (Join-Path $roomObject.Path 'TRANSCRIPT.md')
if ($saved.IsMade) { "archive: $archive" } else { "ARCHIVE FAILED: the room folder is the only copy, do not remove it. Run this again on the closed room to make the archive." }
Get-LinkLine $saved.Links
"statistics: " + (Join-Path $roomObject.Local 'stats.json')
if ($stillHere.Count -gt 0) { 'closed with -Force; no bye from: ' + ((@($stillHere | ForEach-Object { $_.name })) -join ', ') }
'NEXT: run the retro (workflow "Improve"): Get-RelayStats.ps1, the byes, lessons.md.'
