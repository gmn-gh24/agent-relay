#Requires -Version 5.1

<#
.SYNOPSIS
    Looks at one agent's memory file and removes lines from it, keeping an evidence copy and writing a record.

.DESCRIPTION
    Room memory (agents/<name>/memory) is written by the agents and has no canonical copy on this PC, so the tamper
    check neither compares nor restores it. A line that is not an entry (it is skipped and counted by
    Get-RelayMemory.ps1 and shown on the board), or an entry that is planted or altered, is dealt with here:

    -List      Every line with its number and what it is: ENTRY, or MALFORMED (not "<utc> | <tags> | <text>").
               Nothing is changed.
    -Line      Remove these line numbers (as -List shows them).
    -Malformed Remove every line that is not an entry.

    Before anything is removed the whole file is copied to evidence\ in this room's folder on this PC, and a line
    goes into the alarm log of the room (what was removed, from whom, how many lines, where the copy is). The file
    in the room is replaced in one step. A file that is a link in the room is never touched.

    Treat what was removed as evidence of an agent that wrote what it should not (or of a hand edit by the owner):
    ask the agent, and tell the owner.

.PARAMETER Room
    Room id or room folder.

.PARAMETER Agent
    The agent whose memory file it is.

.PARAMETER List
    Show the lines, change nothing.

.PARAMETER Line
    Line numbers to remove.

.PARAMETER Malformed
    Remove every line that is not an entry.

.EXAMPLE
    .\Repair-RelayMemory.ps1 -Room 2026-10-10-docs -Agent emma -List

.EXAMPLE
    .\Repair-RelayMemory.ps1 -Room 2026-10-10-docs -Agent emma -Line 14

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Agent,
    [switch]$List,
    [ValidateRange(1, 1000000)][int[]]$Line = @(),
    [switch]$Malformed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$stampPattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
$roomObject = Resolve-RelayRoom $Room
$name = ConvertTo-RelayAsciiLower $Agent
if (@(Get-RelayRoster $roomObject -IncludeRetired) -cnotcontains $name) { throw "There is no agent '$name' in room $($roomObject.Id)" }
if (-not $List -and @($Line).Count -eq 0 -and -not $Malformed) { throw 'Give -List, -Line <numbers> or -Malformed' }
$file = Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $name) 'memory'
if (Test-RelayLinkedPath -Root $roomObject.Path -Path $file) { throw "The memory file of $name is behind a link in the room: nothing was read or changed. The owner must remove the link." }
if (-not [System.IO.File]::Exists($file)) { throw "$name has no memory file" }

function Get-LineKind {
    param([string]$Text)
    if (-not $Text.Trim()) { return 'BLANK' }
    $first = $Text.IndexOf(' | ', [System.StringComparison]::Ordinal)
    $second = -1
    if ($first -ge 0) { $second = $Text.IndexOf(' | ', $first + 3, [System.StringComparison]::Ordinal) }
    if ($second -lt 0) { return 'MALFORMED' }
    $stamp = $Text.Substring(0, $first).Trim()
    if ($stamp -cnotmatch $stampPattern -or $null -eq (ConvertFrom-RelayUtc $stamp)) { return 'MALFORMED' }
    if (-not $Text.Substring($first + 3, $second - $first - 3).Trim() -or -not $Text.Substring($second + 3).Trim()) { return 'MALFORMED' }
    return 'ENTRY'
}

$original = Read-RelayTextStrict $file
$lines = @($original -split "`n")
# A final empty piece is the end of the last line, not a line
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }

if ($List) {
    "MEMORY FILE of ${name} in room $($roomObject.Id): $($lines.Count) line(s). Unverified: written by the agent, checked by nobody."
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $shown = ConvertTo-RelayPrintedLine $lines[$index]
        if ($shown.Length -gt 140) { $shown = $shown.Substring(0, 140) + ' ...' }
        '{0,5}  {1,-9} {2}' -f ($index + 1), (Get-LineKind $lines[$index]), $shown
    }
    "NEXT: remove lines with -Line <numbers> or -Malformed; an evidence copy is kept first."
    return
}

$remove = New-Object System.Collections.Generic.List[int]
foreach ($number in @($Line)) {
    if ($number -gt $lines.Count) { throw "The file has $($lines.Count) line(s): there is no line $number" }
    if (-not $remove.Contains($number)) { $remove.Add($number) }
}
if ($Malformed) {
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ((Get-LineKind $lines[$index]) -eq 'MALFORMED' -and -not $remove.Contains($index + 1)) { $remove.Add($index + 1) }
    }
}
if ($remove.Count -eq 0) { 'NOTHING TO REMOVE: no line matched.'; return }

if (-not $PSCmdlet.ShouldProcess("$name memory: $($remove.Count) line(s)", 'Remove, after an evidence copy')) { return }
$stampFile = Format-RelayUtc -Format 'yyyyMMddTHHmmssZ'
$evidenceFolder = Join-Path $roomObject.Local 'evidence'
if (-not (Test-Path -LiteralPath $evidenceFolder)) { $null = New-Item -ItemType Directory -Path $evidenceFolder -Force }
# Several repairs may fall in one second: each keeps its own copy, the second one as -2, the next as -3
$evidence = ''
for ($copy = 1; $copy -le 1000; $copy++) {
    $suffix = ''
    if ($copy -gt 1) { $suffix = "-$copy" }
    $candidate = Join-Path $evidenceFolder "memory-$name-$stampFile$suffix.txt"
    if (-not [System.IO.File]::Exists($candidate)) { $evidence = $candidate; break }
}
if (-not $evidence) { throw "There is no free name for the evidence copy under $evidenceFolder" }
[System.IO.File]::WriteAllBytes($evidence, [System.IO.File]::ReadAllBytes($file))
$kept = New-Object System.Collections.Generic.List[string]
for ($index = 0; $index -lt $lines.Count; $index++) { if (-not $remove.Contains($index + 1)) { $kept.Add($lines[$index]) } }
$text = ''
if ($kept.Count -gt 0) { $text = ($kept -join "`n") + "`n" }
Write-RelayRoomByte -Path $file -Bytes (ConvertTo-RelayTextByte $text)
$numbers = (@($remove | Sort-Object) -join ',')
Add-RelayAlarm $roomObject "MEMORY repaired: line(s) $numbers removed from the memory file of $name; evidence copy $evidence"
"REMOVED $($remove.Count) line(s) ($numbers) from the memory file of $name. Evidence copy of the whole file: $evidence"
"NEXT: ask $name how the line(s) came to be there (a planted or altered entry is an injection into every agent that reads room memory), and tell the owner."
