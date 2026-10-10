#Requires -Version 5.1

<#
.SYNOPSIS
    Lists the rooms this PC knows, the machines and shares remembered from earlier jobs, and where the machine
    state lives.

.DESCRIPTION
    The first thing to run when a session resumes a room or starts a new one: it shows which rooms are open,
    and what is already known about machines and shares so the interview does not ask for it again.

    What is remembered about a machine is facts only: how it is reached, its operating system, which agents are
    installed. Whether a machine may be changed is never remembered: that is asked for every job.

.PARAMETER All
    Include closed rooms.

.PARAMETER AsJson
    JSON instead of text.

.EXAMPLE
    .\Get-RelayRooms.ps1

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [switch]$All,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$local = Get-RelayLocalRoot
$machinesFile = Join-Path $local 'machines.json'
$machinesText = Read-RelayText $machinesFile
$rooms = New-Object System.Collections.Generic.List[object]
foreach ($entry in @(Get-RelayRoomIndex)) {
    $closed = [string](Get-RelayProperty $entry 'closed_utc' '')
    if ($closed -and -not $All) { continue }
    $isReachable = Test-Path -LiteralPath (Join-Path ([string]$entry.path) 'ROOM')
    $rooms.Add([pscustomobject]@{ id = $entry.id; state = $(if ($closed) { 'closed' } else { 'open' }); isReachable = $isReachable; coordinator = $entry.coordinator; created_utc = $entry.created_utc; closed_utc = $closed; job = $entry.job; path = $entry.path })
}
if ($AsJson) {
    $machines = $null
    if ($machinesText.Trim()) { $machines = ConvertFrom-RelayJson $machinesText }
    return (ConvertTo-Json -Depth 8 -InputObject ([pscustomobject]@{ local = $local; isWorkingCopy = (Test-RelayWorkingCopy); repo = (Get-RelayRepoRoot); machinesFile = $machinesFile; machines = $machines; rooms = @($rooms.ToArray()) }))
}

"machine state: $local"
if (Test-RelayWorkingCopy) { "plugin: working copy at $(Get-RelayRepoRoot) (edits apply after /reload-plugins)" }
else { "plugin: an installed copy at $(Get-RelayRepoRoot) (it cannot improve itself; that needs the working copy)" }
''
if ($rooms.Count -eq 0) { 'ROOMS: none open' }
else {
    'ROOMS'
    foreach ($room in $rooms) {
        $reach = ''
        if (-not $room.isReachable) { $reach = '  [folder not reachable]' }
        "  $($room.id)  $($room.state)  coordinator $($room.coordinator)  created $($room.created_utc)$reach"
        "      $($room.job)"
        "      $($room.path)"
    }
}
''
if ($machinesText.Trim()) {
    "KNOWN MACHINES AND SHARES ($machinesFile)"
    foreach ($line in ($machinesText.TrimEnd() -split "`n")) { "  $line" }
}
else { "KNOWN MACHINES AND SHARES: none recorded yet ($machinesFile)" }
''
'Remembered are facts only (how a machine is reached, its system, its agents). Whether a machine may be changed is asked for every job.'
'NEXT: resume an open room of this job (Get-RelayBoard.ps1 -Room <id>, then your own start), or interview the owner for a new one.'
