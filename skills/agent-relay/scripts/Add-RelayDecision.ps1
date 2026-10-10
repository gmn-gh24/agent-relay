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
    coordinator's launcher names as its draft). A file in the room folder is refused: any agent can write there. So
    is a path that leads into the room through a link. A relative path is taken against the PowerShell location,
    once. The file is removed after use.

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

$roomObject = Resolve-RelayRoom $Room
if (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'CLOSED')) { throw "The room $($roomObject.Id) is closed" }
# Where the text of a rule comes from: this PC, never the room (any agent can write in the room folder)
$DraftFile = Resolve-RelayDraftPath -Room $roomObject -File $DraftFile -What 'rule'
$rules = @(((Read-RelayText $DraftFile) -split "`n") | ForEach-Object { ConvertTo-RelayHeaderText (($_ -replace '^\s*[-*#]+\s*', '') -replace '\|', '/') } | Where-Object { $_ })
if ($rules.Count -eq 0) { throw "There is no rule to record: $DraftFile is missing or empty. Write one rule per line there and run this again." }

# What is recorded is written back whole: a copy that cannot be read right now is an error, never an empty file,
# which would keep only the new rules
$current = (Read-RelayTextStrict (Join-Path $roomObject.Canon 'DECISIONS.md')).TrimEnd()
$date = Format-RelayUtc -Time (Get-Date) -Format 'yyyy-MM-dd'
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
