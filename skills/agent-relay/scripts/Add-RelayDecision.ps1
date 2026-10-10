#Requires -Version 5.1

<#
.SYNOPSIS
    Appends a standing rule or an owner decision to DECISIONS.md of a room.

.DESCRIPTION
    Only this script writes that file: the canonical copy on this PC first, the room second, so the tamper check
    keeps what is written here and removes what anything else writes. Record the rule first and announce it
    afterwards; every agent is shown new rules at its next delivery and before its next question.

    The text comes from the draft file. Each non-empty line becomes one dated rule; keep a rule to one line that
    stands on its own.

.PARAMETER Room
    Room id or room folder.

.PARAMETER DraftFile
    The text. Default: draft.md of this room on this PC (<local>\rooms\<room id>\draft.md, the file the
    coordinator's launcher names as its draft). A file in the room folder is refused: any agent can write there. A
    relative path is taken against the PowerShell location, once. The file is removed after use.

.PARAMETER Owner
    Mark the lines as decisions of the owner.

.EXAMPLE
    .\Add-RelayDecision.ps1 -Room 2026-10-10-docs -Owner

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [string]$DraftFile = '',
    [switch]$Owner
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

function Resolve-TextFile {
    # Where the text of a rule comes from: this PC, never the room (any agent can write in the room folder). A file
    # given by parameter is made absolute once, against the PowerShell location, and the same path is read and
    # removed; one inside the room folder is refused.
    param($RoomObject, [string]$File)
    $default = Join-Path $RoomObject.Local 'draft.md'
    if (-not $File) { return $default }
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $File))
    $inside = [System.IO.Path]::GetFullPath($RoomObject.Path).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($inside, [System.StringComparison]::OrdinalIgnoreCase)) { throw "The file $full lies inside the room folder, where any agent can write: no rule is made from it. Put the text outside the room (default: $default)" }
    return $full
}

$roomObject = Resolve-RelayRoom $Room
if (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'CLOSED')) { throw "The room $($roomObject.Id) is closed" }
$DraftFile = Resolve-TextFile $roomObject $DraftFile
$rules = @(((Read-RelayText $DraftFile) -split "`n") | ForEach-Object { ConvertTo-RelayHeaderText (($_ -replace '^\s*[-*#]+\s*', '') -replace '\|', '/') } | Where-Object { $_ })
if ($rules.Count -eq 0) { throw "There is no rule to record: $DraftFile is missing or empty. Write one rule per line there and run this again." }

$current = (Read-RelayText (Join-Path $roomObject.Canon 'DECISIONS.md')).TrimEnd()
$date = (Get-Date).ToString('yyyy-MM-dd')
$added = New-Object System.Collections.Generic.List[string]
foreach ($rule in $rules) {
    $text = $rule
    if ($Owner) { $text = "Owner: $rule" }
    $added.Add("| $date | $text |")
}
Write-RelayGuardedText $roomObject 'DECISIONS.md' ($current + "`n" + ($added -join "`n") + "`n")
Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
foreach ($line in $added) { "RECORDED $line" }
'NEXT: announce it: answer the agent that asked, or send a note to all.'
