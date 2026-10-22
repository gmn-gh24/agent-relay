#Requires -Version 5.1

<#
.SYNOPSIS
    Appends the improvement section of a room to PLUGIN-IMPROVEMENTS.md of the plugin's working copy.

.DESCRIPTION
    Closing a room includes this section: what the room found and what the owner asked for, kept in the
    plugin's own repository (the file is feedback about the plugin, not about the job) so a later session
    works the list where the fixes are made. The file is appended to, never overwritten: a new file gets the
    header "# Plugin improvements", every call adds one dated section "## Room <id> (closed <date>)" at the
    end.

    The text comes from the coordinator's draft file on this PC (default: draft.md of the room on this PC,
    <local>\rooms\<room id>\draft.md). A file in the room folder is refused: any agent can write there. So
    is an empty draft, and a draft that holds a line which looks like a secret (a token, a password or an
    api key followed by a value). The draft is removed after use.

    Where the file lives: -ProjectFolder when given (an override), else PLUGIN-IMPROVEMENTS.md at the root of
    the plugin's git working copy (Get-RelayRooms.ps1 says which copy this is; an installed copy has no
    repository), else PLUGIN-IMPROVEMENTS.md in the room's folder on this PC
    (<local>\rooms\<room id>), with a warning. The "project_folder" of the room's answers is the job's folder,
    kept for the record; the notes never go there. What was written where is recorded in
    <local>\rooms\<room id>\improvements.txt (path and date), which Close-RelayRoom.ps1 asks for before it
    closes the room, and the path is printed. A file inside the room folder (also by way of a link), a file
    that is a link, and a draft that is the file itself are refused. The file is written through a handle no
    other writer may open meanwhile; when another room holds it, nothing is recorded and the draft is kept.

.PARAMETER Room
    Room id or room folder.

.PARAMETER DraftFile
    The section text. Default: draft.md of this room on this PC. A file in the room folder is refused.

.PARAMETER ProjectFolder
    A folder whose PLUGIN-IMPROVEMENTS.md gets the section instead of the plugin's working copy (an override
    for a copy that is not a git working copy, or for a file kept elsewhere on purpose).

.EXAMPLE
    .\Add-RelayImprovement.ps1 -Room 2026-10-10-docs

.EXAMPLE
    .\Add-RelayImprovement.ps1 -Room 2026-10-10-docs -ProjectFolder C:\work\plugin-notes

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

$date = Format-RelayUtc -Format 'yyyy-MM-dd'
# The file is the plugin's own backlog: it lives at the root of the plugin's git working copy, where the
# fixes are made. An installed copy has no repository to commit it in, so there the section waits on this PC.
if ($ProjectFolder) {
    $file = Join-Path (Get-RelayNormalPath $ProjectFolder) 'PLUGIN-IMPROVEMENTS.md'
}
elseif (Test-RelayWorkingCopy) {
    $file = Join-Path (Get-RelayRepoRoot) 'PLUGIN-IMPROVEMENTS.md'
}
else {
    $file = Join-Path $roomObject.Local 'PLUGIN-IMPROVEMENTS.md'
    ConvertTo-RelayPrintedLine "WARNING: this copy of the plugin is not a git working copy and no -ProjectFolder was given: the section goes to this PC instead: $file (move it into the plugin repository later)"
}
# The file is written with this PC's rights, so it never lies inside the room, also not by way of a link: an
# agent could put a link in place of it there, and the write would follow it. A file that is a link is refused
# wherever it is.
if (Test-RelayPathInRoom -Room $roomObject -Path $file) { throw "Refused: $file lies inside the room folder, where any agent can write. Name a project folder outside the room (-ProjectFolder)." }
if (Test-RelayLink $file) { throw "Refused: $file is a link. Name the project folder that holds the file itself (-ProjectFolder)." }
# The draft is removed after use: a draft that is the file itself would take the whole file with it
$draftReal = Get-RelayRealPath $DraftFile
$fileReal = Get-RelayRealPath $file
foreach ($pair in @(@($DraftFile, $file), @($draftReal, $fileReal))) {
    if ($pair[0] -and $pair[1] -and [string]::Equals($pair[0], $pair[1], [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refused: the draft $DraftFile is the improvements file itself. Write the section into a draft of its own (default: draft.md of the room on this PC)." }
}
$folder = Split-Path -Parent $file
if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

# Appended, never overwritten: an existing file keeps its sections, a new one gets the header line first. The
# file is read and written through one handle that nobody else may open meanwhile, so that two rooms closing
# into the same project cannot both read the old text and lose each other's section. A file another writer
# holds is tried again for a few seconds, then refused before anything is recorded or the draft is removed.
$block = "## Room $($roomObject.Id) (closed $date)`n`n$section`n"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stream = $null
$reason = ''
for ($try = 0; $try -lt 12 -and $null -eq $stream; $try++) {
    try { $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch { $reason = $_.Exception.Message; Start-Sleep -Milliseconds 250 }
}
if ($null -eq $stream) { throw "Could not open $file for this script alone (another room may be recording its section there): $reason. Nothing was recorded and the draft is kept; run this again." }
try {
    $length = [int]$stream.Length
    $bytes = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
        $count = $stream.Read($bytes, $read, $length - $read)
        if ($count -le 0) { break }
        $read += $count
    }
    $current = $utf8.GetString($bytes, 0, $read)
    if ($current.Length -gt 0 -and $current[0] -eq [char]0xFEFF) { $current = $current.Substring(1) }
    $current = $current -replace "`r", ''
    if (-not $current.Trim()) { $updated = "# Plugin improvements`n`n$block" }
    else { $updated = $current.TrimEnd() + "`n`n" + $block }
    $out = $utf8.GetBytes($updated)
    $stream.Position = 0
    $stream.SetLength(0)
    $stream.Write($out, 0, $out.Length)
    $stream.Flush()
}
finally { $stream.Dispose() }

$record = [ordered]@{ room = $roomObject.Id; path = $file; date = $date }
Write-RelayText (Join-Path $roomObject.Local 'improvements.txt') (ConvertTo-RelayKeyValueText $record)
Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
ConvertTo-RelayPrintedLine "RECORDED improvements for room $($roomObject.Id): $file"
"NEXT: close the room (Close-RelayRoom.ps1 -Room $($roomObject.Id)); it names this file."
