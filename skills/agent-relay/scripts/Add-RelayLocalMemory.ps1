#Requires -Version 5.1

<#
.SYNOPSIS
    The coordinator's own memory on this PC: lessons kept across rooms and sessions, one dated line each, and a
    search over them.

.DESCRIPTION
    The notes live in <local>\memory\notes.md, in this PC's machine state (<local> is .local in the working copy,
    which .gitignore keeps out of git, %LOCALAPPDATA%\agent-relay for an installed copy, or AGENT_RELAY_LOCAL).
    The file is local and never committed: it is no part of any room, no agent reads it, and nothing in a room
    writes to it. Keep in it what you verified yourself; an agent's note (Get-RelayMemory.ps1) is a claim until
    you have checked it against evidence.

    Each note is one line:

        - <utc> [tag, tag] text

    The text comes from a draft file, never from the command line, and is made one line: control characters are
    taken out and the lines of the draft joined. It must be 15 to 600 characters long. Text that looks like a key
    or a token is refused, and so is a note whose text is already kept (compared without regard to case or
    blanks). The file keeps the newest 500 notes; the oldest go first. It is written whole, through a temporary
    file, and never through a link: a memory folder or notes file that is a link is refused.

.PARAMETER DraftFile
    The text of the note. Default: with -Room, draft.md of that room on this PC (<local>\rooms\<room id>\draft.md,
    the file the coordinator's launcher names as its draft); without it, <local>\memory\draft.md. A file in a room
    folder is refused: any agent can write there. So is a path that leads into a room through a link. A relative
    path is taken against the PowerShell location, once. The notes file itself is refused, including a path
    through a linked folder, because the draft is removed after use.

.PARAMETER Room
    Room id or room folder whose draft holds the text. The note itself is not tied to the room.

.PARAMETER Tags
    Tags for the note: lower-case words of letters, digits, dot, dash or underscore (several in one argument may be
    separated by commas).

.PARAMETER Find
    Print the notes that contain every one of these words, without regard to case, newest first.

.PARAMETER List
    Print the newest 30 notes.

.EXAMPLE
    .\Add-RelayLocalMemory.ps1 -Room 2026-10-10-docs -Tags share, build

.EXAMPLE
    .\Add-RelayLocalMemory.ps1 -Find proxy timeout

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(ParameterSetName = 'Add')][string]$DraftFile = '',
    [Parameter(ParameterSetName = 'Add')][string]$Room = '',
    [Parameter(ParameterSetName = 'Add')][string[]]$Tags = @(),
    [Parameter(Mandatory, ParameterSetName = 'Find')][string[]]$Find,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$List
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$bulletCap = 500
$listCount = 30
$findCap = 100
$minimum = 15
$maximum = 600
# The same high-precision patterns the room tool stops a message on
$secretPatterns = [ordered]@{
    'a private key block'     = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'an AWS access key id'    = 'AKIA[0-9A-Z]{16}'
    'a GitHub token'          = 'gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40}'
    'a Slack token'           = 'xox[baprs]-[A-Za-z0-9-]{20}'
    'an Anthropic API key'    = 'sk-ant-[A-Za-z0-9_-]{20}'
    'a webhook URL'           = 'https://[A-Za-z0-9.-]*webhook\.office\.com/|https://outlook\.office\.com/webhook/|https://hooks\.slack\.com/services/'
    'a signed Logic Apps URL' = 'logic\.azure\.com[^ ]*sig='
    'a JSON web token'        = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
}

function ConvertTo-MemoryKey {
    # What two notes are compared by: the text after the time and the tags, lower case, blanks made one
    param([string]$Line)
    $rest = $Line
    if ($rest.StartsWith('- ', [System.StringComparison]::Ordinal)) {
        $rest = $rest.Substring(2)
        $space = $rest.IndexOf([char]' ')
        if ($space -gt 0) { $rest = $rest.Substring($space + 1) }
        if ($rest.StartsWith('[', [System.StringComparison]::Ordinal)) {
            $close = $rest.IndexOf([char]']')
            if ($close -gt 0) { $rest = $rest.Substring($close + 1) }
        }
    }
    return ((ConvertTo-RelayAsciiLower $rest) -replace '\s+', ' ').Trim().ToLowerInvariant()
}

$local = Get-RelayLocalRoot
$folder = Join-Path $local 'memory'
$notesFile = Join-Path $folder 'notes.md'
# Nothing is read or written through a link: what lies behind one is not this PC's memory
if (Test-RelayLinkedPath -Root $local -Path $notesFile) { throw "Refused: the way to $notesFile goes through a link (a symbolic link or a junction). The memory is kept in a plain folder of this PC's machine state: remove the link, then run this again." }

$header = @('# Coordinator memory', '', 'Local to this PC and never committed. One verified lesson per line: - <utc> [tags] text', '')
$bullets = New-Object System.Collections.Generic.List[string]
foreach ($line in ((Read-RelayTextStrict $notesFile) -split "`n")) {
    if ($line.StartsWith('- ', [System.StringComparison]::Ordinal)) { $bullets.Add($line) }
}

if ($PSCmdlet.ParameterSetName -ne 'Add') {
    $printed = New-Object System.Collections.Generic.List[string]
    $chosen = @()
    if ($List) {
        $chosen = @($bullets.ToArray() | Select-Object -Last $listCount)
        [array]::Reverse($chosen)
        $printed.Add("LOCAL MEMORY: the newest $($chosen.Count) of $($bullets.Count) notes ($notesFile)")
    }
    else {
        $words = @(@($Find) | ForEach-Object { ([string]$_) -split '\s+' } | Where-Object { $_ })
        if ($words.Count -eq 0) { throw 'There is no word to find' }
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($bullet in $bullets) {
            $isMatch = $true
            foreach ($word in $words) { if ($bullet.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $isMatch = $false; break } }
            if ($isMatch) { $hits.Add($bullet) }
        }
        $chosen = @($hits.ToArray())
        [array]::Reverse($chosen)
        $chosen = @($chosen | Select-Object -First $findCap)
        $printed.Add("LOCAL MEMORY: $($hits.Count) of $($bullets.Count) notes contain $($words -join ' ') ($notesFile)")
    }
    foreach ($bullet in $chosen) { $printed.Add($bullet) }
    if ($chosen.Count -eq 0) { $printed.Add('  (none)') }
    $printed.Add('NEXT: use what applies to the job at hand; a note that turned out wrong is corrected by a new one.')
    foreach ($line in $printed) { ConvertTo-RelayPrintedLine $line }
    exit 0
}

# Where the text comes from: this PC, never a room (any agent can write in a room folder)
if ($Room) { $DraftFile = Resolve-RelayDraftPath -Room (Resolve-RelayRoom $Room) -File $DraftFile -What 'note' }
elseif ($DraftFile) {
    $full = Get-RelayNormalPath $DraftFile
    foreach ($entry in @(Get-RelayRoomIndex)) {
        if ($null -eq $entry.PSObject.Properties['path'] -or -not [string]$entry.path -or $null -eq $entry.PSObject.Properties['id']) { continue }
        $roomPath = ''
        try { $roomPath = Get-RelayNormalPath ([string]$entry.path) } catch { continue }
        $null = Resolve-RelayDraftPath -Room ([pscustomobject]@{ Path = $roomPath; Local = (Join-Path (Join-Path $local 'rooms') ([string]$entry.id)) }) -File $full -What 'note'
    }
    $DraftFile = $full
}
else { $DraftFile = Join-Path $folder 'draft.md' }

# The draft is deleted after use; it must never be the notes file, even through a linked folder.
$draftReal = Get-RelayRealPath $DraftFile
$notesReal = Get-RelayRealPath $notesFile
if ($draftReal -and $notesReal -and [string]::Equals($draftReal, $notesReal, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refused: the draft $DraftFile is the notes file itself. Write the note into a separate draft file."
}

$tagList = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Tags)) {
    foreach ($word in @(([string]$item) -split '[,\s]+' | Where-Object { $_ })) {
        $tag = ConvertTo-RelayAsciiLower $word
        if ($tag -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$') { throw "The tag '$(ConvertTo-RelayPrintedLine $word)' is not a tag: use lower-case letters, digits, dot, dash or underscore, at most 32" }
        if (-not $tagList.Contains($tag)) { $tagList.Add($tag) }
    }
}

$draftText = Read-RelayText $DraftFile
$lines = @(($draftText -split "`n") | ForEach-Object { ($_ -replace '^\s*[-*#]+\s*', '').Trim() } | Where-Object { $_ })
# Control characters are taken out (C0 but tab and line feed, DEL, C1, the invisible and direction marks, the line
# and paragraph separators, the byte order mark); every run of blanks becomes one
$text = [regex]::Replace(($lines -join ' '), '[\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]', '')
$text = ($text -replace '\s+', ' ').Trim()
if (-not $text) { throw "There is no note to keep: $DraftFile is missing or empty. Write the note there and run this again." }
$length = Get-RelayTextLength $text
if ($length -lt $minimum -or $length -gt $maximum) { throw "A note is $minimum to $maximum characters; this one has $length. Change $DraftFile and run this again." }
foreach ($name in $secretPatterns.Keys) {
    if ($text -cmatch $secretPatterns[$name]) { throw "Refused: the note looks like it holds $name. A secret is never kept in memory; take it out of $DraftFile and run this again." }
}

$tagMark = ''
if ($tagList.Count -gt 0) { $tagMark = '[' + ($tagList.ToArray() -join ', ') + '] ' }
$bullet = '- ' + (Format-RelayUtc) + ' ' + $tagMark + $text
$key = ConvertTo-MemoryKey $bullet
foreach ($existing in $bullets) {
    if ((ConvertTo-MemoryKey $existing) -ceq $key) {
        Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
        ConvertTo-RelayPrintedLine "ALREADY IN LOCAL MEMORY $existing"
        'NEXT: nothing was added; the draft is cleared.'
        exit 0
    }
}

$bullets.Add($bullet)
$dropped = 0
while ($bullets.Count -gt $bulletCap) { $bullets.RemoveAt(0); $dropped++ }
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { $null = New-Item -ItemType Directory -Path $folder -Force }
# Checked again just before writing: a link made since the first look is not written through either
if (Test-RelayLinkedPath -Root $local -Path $notesFile) { throw "Refused: the way to $notesFile goes through a link (a symbolic link or a junction)." }
Write-RelayTextAtomic $notesFile ((@($header) + @($bullets.ToArray()) -join "`n") + "`n")
Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
ConvertTo-RelayPrintedLine "KEPT $bullet"
if ($dropped -gt 0) { "dropped the oldest $dropped note(s): the file keeps $bulletCap" }
'NEXT: carry on; Add-RelayLocalMemory.ps1 -Find <words> finds it again in a later session.'
