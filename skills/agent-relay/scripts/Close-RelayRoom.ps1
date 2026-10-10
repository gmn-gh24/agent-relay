#Requires -Version 5.1

<#
.SYNOPSIS
    Closes a room: transcript, CLOSED marker, statistics and an archive on this PC. Also lists closed rooms and
    removes the folder of one when the owner says so.

.DESCRIPTION
    Before this, the coordinator sends its closing note to all and waits for each agent's bye (the bye says what
    slowed that agent down). The script refuses while an agent that has started has not said bye, unless -Force.

    Closing writes TRANSCRIPT.md into the room, sets the CLOSED marker (the tools refuse a closed room from then
    on), saves the statistics and a zip of the whole room under the machine state folder, and marks the room
    closed in the room index. The room folder itself stays where it is.

    -ListClosed shows closed rooms whose folder still exists. -Remove deletes the folder of one closed room; it
    needs the archive to exist and asks for confirmation (-Confirm:$false to skip, -WhatIf to see only).
    Remove a room only when the owner said so.

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

if ($ListClosed) {
    $found = 0
    foreach ($entry in @(Get-RelayRoomIndex)) {
        if (-not (Get-RelayProperty $entry 'closed_utc' '')) { continue }
        if (-not (Test-Path -LiteralPath $entry.path)) { continue }
        $found++
        $hasArchive = Test-Path -LiteralPath (Join-Path $archiveRoot "$($entry.id).zip")
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
    if (-not (Test-Path -LiteralPath $archive)) { throw "The room '$Remove' has no archive at ${archive}: its folder is the only copy and is not removed" }
    $path = [string]$entry[0].path
    if (-not (Test-Path -LiteralPath (Join-Path $path 'CLOSED'))) { throw "The folder $path has no CLOSED marker: not removed" }
    if ($PSCmdlet.ShouldProcess($path, 'Delete the folder of the closed room (its archive stays)')) {
        Remove-Item -LiteralPath $path -Recurse -Force
        "REMOVED the folder of room $Remove. Its archive stays: $archive"
    }
    return
}

$roomObject = Resolve-RelayRoom $Room
if ($roomObject.IsClosed) { "The room $($roomObject.Id) is already closed."; return }
$board = Get-RelayBoard $roomObject
$stillHere = @($board.agents | Where-Object { -not $_.isCoordinator -and $_.isIntroduced -and @('offline', 'retired') -notcontains $_.state })
if ($stillHere.Count -gt 0 -and -not $Force) {
    "NOT CLOSED: these agents have not said bye: " + ((@($stillHere | ForEach-Object { "$($_.name) ($($_.state))" })) -join ', ')
    'NEXT: send your closing note to all and wait for each bye. Use -Force only for agents that cannot answer any more.'
    return
}

$stats = Get-RelayStatistic $roomObject
$messages = @(Get-RelayMessage $roomObject)
$closedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
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
$rules = @(((Read-RelayText (Join-Path $roomObject.Path 'DECISIONS.md')) -split "`n") | Where-Object { $_ -match '^\s*\|' })
if ($rules.Count -gt 2) { foreach ($rule in $rules) { $text.Add($rule) } } else { $text.Add('(none)') }
$text.Add('')
$text.Add('## Messages')
foreach ($message in $messages) {
    $re = ''
    if ($message.Re) { $re = ", re $($message.Re)" }
    $text.Add('')
    $text.Add("### $($message.Id): $($message.Type) from $($message.From) to $($message.To)$re")
    $text.Add('')
    $text.Add("$($message.Time.ToString('yyyy-MM-dd HH:mm:ss')) UTC. **$($message.Subject)**")
    $text.Add('')
    $text.Add($message.Body)
    $files = Join-Path (Join-Path $roomObject.Path 'files') $message.Id
    if (Test-Path -LiteralPath $files) {
        $text.Add('')
        $text.Add('Files: ' + ((@(Get-ChildItem -LiteralPath $files -File -Recurse | ForEach-Object { $_.Name })) -join ', '))
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
Write-RelayText (Join-Path $roomObject.Local 'stats.json') ((ConvertTo-Json -InputObject $stats -Depth 6) + "`n")

if (-not (Test-Path -LiteralPath $archiveRoot)) { $null = New-Item -ItemType Directory -Path $archiveRoot -Force }
$archive = Join-Path $archiveRoot "$($roomObject.Id).zip"
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
$isArchived = $true
try { Compress-Archive -Path (Join-Path $roomObject.Path '*') -DestinationPath $archive -Force }
catch { $isArchived = $false; Add-RelayAlarm $roomObject "ARCHIVE failed: $($_.Exception.Message)" }

$index = New-Object System.Collections.Generic.List[object]
foreach ($entry in @(Get-RelayRoomIndex)) {
    if ($entry.id -eq $roomObject.Id) { $entry.closed_utc = $closedUtc }
    $index.Add($entry)
}
Save-RelayRoomIndex $index.ToArray()

"CLOSED room $($roomObject.Id)"
"transcript: " + (Join-Path $roomObject.Path 'TRANSCRIPT.md')
if ($isArchived) { "archive: $archive" } else { "ARCHIVE FAILED: the room folder is the only copy, do not remove it" }
"statistics: " + (Join-Path $roomObject.Local 'stats.json')
if ($stillHere.Count -gt 0) { 'closed with -Force; no bye from: ' + ((@($stillHere | ForEach-Object { $_.name })) -join ', ') }
'NEXT: run the retro (workflow "Improve"): Get-RelayStats.ps1, the byes, lessons.md.'
