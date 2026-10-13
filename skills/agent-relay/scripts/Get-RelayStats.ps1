#Requires -Version 5.1

<#
.SYNOPSIS
    Numbers about a room for the retro: reply times, repeated questions, what the self-audits and the tamper check
    found, where time was lost, and what each agent said slowed it down.

.PARAMETER Room
    Room id or room folder. A closed room works too.

.PARAMETER AsJson
    JSON instead of text.

.EXAMPLE
    .\Get-RelayStats.ps1 -Room 2026-10-10-docs

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only. Times are the file server's, never a comparison of two clocks.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

# The close saves the numbers on this PC before the folder may be removed: a room whose folder is gone is read from
# that copy (this PC's own file, never one from the room)
$stats = $null
try {
    $roomObject = Resolve-RelayRoom $Room
    $stats = Get-RelayStatistic $roomObject
}
catch {
    $saved = Join-Path (Join-Path (Join-Path (Get-RelayLocalRoot) 'rooms') $Room) 'stats.json'
    if ((Test-RelayRoomId $Room) -and $_.Exception.Message -match 'its folder is not reachable' -and (Test-Path -LiteralPath $saved -PathType Leaf)) {
        $stats = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($saved))
    }
    else { throw }
}
if ($AsJson) { return (ConvertTo-Json -InputObject $stats -Depth 6) }
# Numbers read back from the saved file are objects, those just counted are tables: one list of pairs for both
$byTypePairs = if ($stats.byType -is [System.Collections.IDictionary]) { @($stats.byType.Keys | ForEach-Object { "$_ $($stats.byType[$_])" }) } else { @($stats.byType.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value)" }) }

# Every line printed for reading passes one place: no control character from a room file, no blank at the end
& {
    "=== statistics of room $($stats.room) (package $($stats.package)) ==="
    "job: $($stats.job)"
    "messages: $($stats.messages) in $($stats.minutesFromFirstToLast) minutes  (" + ($byTypePairs -join ', ') + ')'
    "requests: $($stats.requests), answered $($stats.answered), never answered $($stats.unanswered)"
    "reply time: median $($stats.replyMedianMinutes) min, longest $($stats.replyMaxMinutes) min"
    foreach ($responder in @($stats.byResponder)) { "  $($responder.agent): $($responder.answered) answered, median $($responder.medianMinutes) min, longest $($responder.maxMinutes) min" }
    "requests waited on the coordinator: $($stats.waitedOnCoordinatorMinutes) min in total; on the owner ($($stats.ownerCards) cards): $($stats.waitedOnOwnerMinutes) min"
    if (@($stats.slowest).Count -gt 0) {
        'slowest answers:'
        foreach ($request in @($stats.slowest)) { "  $($request.minutes) min  $($request.id) ($($request.type) to $($request.to)): $($request.subject)" }
    }
    "asked twice: $(@($stats.repeatedQuestions).Count)"
    foreach ($repeat in @($stats.repeatedQuestions)) { "  $($repeat.from), $($repeat.times) times: $($repeat.subject) ($($repeat.ids))" }
    "delivered twice: $($stats.redelivered)"
    "reports with changes outside the assigned paths: $(@($stats.reportsWithChangesOutside).Count)"
    foreach ($report in @($stats.reportsWithChangesOutside)) { "  $($report.id) from $($report.from): $($report.outside) outside" }
    "alarms from the tamper check: $($stats.alarms)"
    ''
    'agent      sent  recv  sessions  timeouts  2nd-wait  silent  proceeded'
    foreach ($agent in @($stats.agents)) { '{0,-10} {1,4}  {2,4}  {3,8}  {4,8}  {5,8}  {6,6}  {7,9}' -f $agent.agent, $agent.sent, $agent.received, $agent.sessions, $agent.waitTimeouts, $agent.secondWaits, $agent.coordinatorSilent, $agent.proposalsProceeded }
    if (@($stats.byes).Count -gt 0) {
        ''
        'what the agents said on leaving:'
        foreach ($bye in @($stats.byes)) {
            "  $($bye.from): $($bye.subject)"
            foreach ($line in ($bye.text -split "`n")) { if ($line.Trim()) { "      $line" } }
        }
    }
} | ForEach-Object { ConvertTo-RelayPrintedLine $_ }
