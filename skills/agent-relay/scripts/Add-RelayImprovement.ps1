#Requires -Version 5.1

<#
.SYNOPSIS
    Appends the improvement section of a room to PLUGIN-IMPROVEMENTS.md of its project folder.

.DESCRIPTION
    Closing a room includes this section: what the room found and what the owner asked for, kept in the
    project folder of the job so a later session can work the list in the plugin repository. The file is
    appended to, never overwritten: a new file gets the header "# Plugin improvements", every call adds
    one dated section "## Room <id> (closed <date>)" at the end.

    The text comes from the coordinator's draft file on this PC (default: draft.md of the room on this PC,
    <local>\rooms\<room id>\draft.md). A file in the room folder is refused: any agent can write there. So
    is an empty draft, and a draft that holds a line which looks like a secret (a token, a password or an
    api key followed by a value). The draft is removed after use.

    Where the file lives: -ProjectFolder, else the "project_folder" of the room's answers (New-RelayRoom.ps1
    keeps it in the canonical ROOM of the room), else PLUGIN-IMPROVEMENTS.md in the room's folder on this PC
    (<local>\rooms\<room id>), with a warning. What was written where is recorded in
    <local>\rooms\<room id>\improvements.txt (path and date), which Close-RelayRoom.ps1 asks for before it
    closes the room, and the path is printed.

.PARAMETER Room
    Room id or room folder.

.PARAMETER DraftFile
    The section text. Default: draft.md of this room on this PC. A file in the room folder is refused.

.PARAMETER ProjectFolder
    The project folder the PLUGIN-IMPROVEMENTS.md lives in. Wins over the room's answers.

.EXAMPLE
    .\Add-RelayImprovement.ps1 -Room 2026-10-10-docs -ProjectFolder C:\work\plugin

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [string]$DraftFile = '',
    [string]$ProjectFolder = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$roomObject = Resolve-RelayRoom $Room
# Where the text of the section comes from: this PC, never the room (any agent can write in the room folder)
$DraftFile = Resolve-RelayDraftPath -Room $roomObject -File $DraftFile -What 'improvement section'
$section = (Read-RelayText $DraftFile).Trim()
if (-not $section) { throw "There is no improvement section to record: $DraftFile is missing or empty. Write the section there and run this again." }
# Kept simple on purpose: a word that names a secret, then a value after a colon or an equals sign
foreach ($line in ($section -split "`n")) {
    if ($line -match '(?i)\b(token|password|passwd|api[ _-]?key|secret)\b\s*[:=]\s*\S+') { throw "Refused: a line of $DraftFile looks like it holds a secret (a token, a password or an api key with a value). A secret is never kept in an improvements file; take it out and run this again." }
}

$date = Format-RelayUtc -Time (Get-Date) -Format 'yyyy-MM-dd'
if ($ProjectFolder) {
    $file = Join-Path (Get-RelayNormalPath $ProjectFolder) 'PLUGIN-IMPROVEMENTS.md'
}
elseif ([string](Get-RelayValue $roomObject.Info 'project_folder' '')) {
    $file = Join-Path (Get-RelayNormalPath ([string](Get-RelayValue $roomObject.Info 'project_folder' ''))) 'PLUGIN-IMPROVEMENTS.md'
}
else {
    $file = Join-Path $roomObject.Local 'PLUGIN-IMPROVEMENTS.md'
    ConvertTo-RelayPrintedLine "WARNING: no project folder is named for room $($roomObject.Id) (no -ProjectFolder and no project_folder in its answers): the section goes to this PC instead: $file"
}
$folder = Split-Path -Parent $file
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

# Appended, never overwritten: an existing file keeps every byte, a new one gets the header line first
$current = Read-RelayTextStrict $file
$block = "## Room $($roomObject.Id) (closed $date)`n`n$section`n"
if (-not $current) { $updated = "# Plugin improvements`n`n$block" }
else { $updated = $current.TrimEnd() + "`n`n" + $block }
Write-RelayText $file $updated

$record = [ordered]@{ room = $roomObject.Id; path = $file; date = $date }
Write-RelayText (Join-Path $roomObject.Local 'improvements.txt') (ConvertTo-RelayKeyValueText $record)
Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
ConvertTo-RelayPrintedLine "RECORDED improvements for room $($roomObject.Id): $file"
"NEXT: close the room (Close-RelayRoom.ps1 -Room $($roomObject.Id)); it names this file."
