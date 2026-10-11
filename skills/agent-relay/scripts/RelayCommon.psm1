#Requires -Version 5.1

<#
    Shared code of the agent-relay scripts on the coordinator's PC: the room index, the canonical copies the
    tamper check compares against, reading messages, the board, the owner's log and cards, the name pool.
    Windows PowerShell 5.1 syntax, ASCII only. Nothing here is copied into a room.
#>

Set-StrictMode -Version Latest

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$script:PackageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\room-package'))
$script:NamePattern = '^[a-z][a-z0-9]{1,15}$'
$script:HasDateKind = $null
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:JsonTables = @{}
# The characters PowerShell takes for a single quote: the apostrophe and U+2018 to U+201B
$script:PowerShellQuotes = '[''' + [char]0x2018 + [char]0x2019 + [char]0x201A + [char]0x201B + ']'
# What a line printed for reading must not carry: C0 and C1 with DEL, the invisible marks U+200B to U+200F, the
# line and paragraph separators, the marks that turn the direction of text, and the byte order mark
$script:PrintedControl = '[\x00-\x1f\x7f-\x9f' + [char]0x200B + '-' + [char]0x200F + [char]0x2028 + [char]0x2029 + [char]0x202A + '-' + [char]0x202E + [char]0x2066 + '-' + [char]0x2069 + [char]0xFEFF + ']'

#region Text and files

function Get-RelayPackageRoot { return $script:PackageRoot }

function Format-RelayUtc {
    # A UTC time as text in a fixed form. Without the invariant culture the colon of the format is the culture's
    # time separator (a dot in fi-FI) and the year that of the culture's calendar (2569 in th-TH).
    param([DateTime]$Time = [DateTime]::UtcNow, [string]$Format = 'yyyy-MM-ddTHH:mm:ssZ')
    return $Time.ToString($Format, $script:Invariant)
}

function ConvertFrom-RelayUtc {
    # A time as Format-RelayUtc writes it (or another ISO 8601 form) as a UTC time; $null when the text is none
    param([string]$Text)
    $parsed = [DateTime]::MinValue
    $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParse([string]$Text, $script:Invariant, $style, [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-RelayDisplayName {
    # An agent's name as people read it: the first letter in upper case
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1))
}

function Resolve-RelayFullPath {
    # A path as .NET reads it: a relative one is taken against the PowerShell location, as a cmdlet would, not
    # against the working folder of the process, which PowerShell does not move along
    param([string]$Path)
    if (-not $Path -or [System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-RelayLink {
    # True when the path is a link of the file system: a symbolic link or a junction. Any agent can make one in
    # the room, and what lies behind it is not the room's. Other reparse points (a cloud file of OneDrive, a
    # deduplicated file) are files like any other; one whose kind cannot be told is taken for a link.
    param([string]$Path)
    $attributes = [System.IO.FileAttributes]::Normal
    try { $attributes = [System.IO.File]::GetAttributes($Path) } catch { return $false }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    try { return (@('SymbolicLink', 'Junction') -contains [string](Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LinkType) }
    catch { return $true }
}

function Test-RelayLinkedPath {
    # True when the path, or a folder between it and the root, is a link. The root itself is not judged: where
    # the owner keeps the rooms is the owner's choice.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    return [bool](Get-RelayLinkInPath -Root $Root -Path $Path)
}

function Get-RelayFileTree {
    # Every file under a folder without entering a link: a linked folder or file is no part of the tree and is
    # listed under Links instead. A folder that cannot be listed is an error.
    param([Parameter(Mandatory)][string]$Path)
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $links = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $top = Resolve-RelayFullPath $Path
    if (Test-RelayLink $top) { $links.Add($top) } else { $pending.Push($top) }
    while ($pending.Count -gt 0) {
        $folder = New-Object System.IO.DirectoryInfo $pending.Pop()
        foreach ($entry in $folder.GetFileSystemInfos()) {
            if ((($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and (Test-RelayLink $entry.FullName)) { $links.Add($entry.FullName); continue }
            if ($entry -is [System.IO.DirectoryInfo]) { $pending.Push($entry.FullName) }
            else { $files.Add([System.IO.FileInfo]$entry) }
        }
    }
    return [pscustomobject]@{ Files = @($files.ToArray()); Links = @($links.ToArray()) }
}

function Remove-RelayTree {
    # Deletes a folder with everything in it, without following a link: each link is removed as a link first,
    # so that nothing behind a junction is deleted (Windows PowerShell 5.1 would recurse into it)
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $full = Resolve-RelayFullPath $Path
    if (-not $PSCmdlet.ShouldProcess($full, 'Delete the folder and everything in it, links as links')) { return }
    foreach ($link in @((Get-RelayFileTree $full).Links)) {
        if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link, $false) }
        else { [System.IO.File]::Delete($link) }
    }
    # A folder that was itself a link is gone with the link
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function Test-RelayWorkingCopy {
    # True when these scripts run from the git working copy of the plugin (a folder marketplace reads the plugin
    # in place); false when they run from a copy that an install made
    return (Test-Path -LiteralPath (Join-Path $script:RepoRoot '.git'))
}

function Get-RelayRepoRoot { return $script:RepoRoot }

function Get-RelayLocalRoot {
    # Machine state that never goes into git: known machines, names, the room index, canonical copies, the
    # owner's log, archives. In the working copy it is <repo>\.local. An installed copy is replaced on every
    # update, so there the state lives in the user's profile instead. AGENT_RELAY_LOCAL overrides both (the
    # tests use that).
    $root = Join-Path $script:RepoRoot '.local'
    if (-not (Test-RelayWorkingCopy)) { $root = Join-Path $env:LOCALAPPDATA 'agent-relay' }
    if ($env:AGENT_RELAY_LOCAL) { $root = [string]$env:AGENT_RELAY_LOCAL }
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
    return $root
}

function Read-RelayTextStrict {
    # A text file as UTF-8 with LF line ends; '' when it does not exist. A file that exists and cannot be read is
    # an error, never an empty text: for whatever is read in order to be written back.
    param([string]$Path)
    $full = Resolve-RelayFullPath $Path
    $reason = ''
    for ($try = 0; $try -lt 6; $try++) {
        try {
            if (-not [System.IO.File]::Exists($full)) { return '' }
            $text = $script:Utf8.GetString([System.IO.File]::ReadAllBytes($full))
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            return ($text -replace "`r", '')
        }
        catch { $reason = $_.Exception.Message; Start-Sleep -Milliseconds 150 }
    }
    throw "Could not read ${Path}: $reason"
}

function Read-RelayText {
    # As Read-RelayTextStrict, with '' also for a file that cannot be read right now: for what is only looked at
    param([string]$Path)
    try { return (Read-RelayTextStrict $Path) } catch { return '' }
}

function Write-RelayText {
    # UTF-8 without BOM (-Bom: with one, which Windows PowerShell 5.1 needs to read a script that is not ASCII).
    # LF line ends unless -Crlf (the cmd wrappers).
    param([string]$Path, [string]$Text, [switch]$Crlf, [switch]$Bom)
    $Path = Resolve-RelayFullPath $Path
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    if ($Crlf) { $normalized = $normalized -replace "`n", "`r`n" }
    $encoding = $script:Utf8
    if ($Bom) { $encoding = New-Object System.Text.UTF8Encoding($true) }
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    for ($try = 0; ; $try++) {
        try { [System.IO.File]::WriteAllText($Path, $normalized, $encoding); return }
        catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 150 }
    }
}

function Write-RelayTextAtomic {
    # A whole file written so that a reader finds the old text or the new one, never a part: a temporary file
    # beside it is moved over it. For this PC's own state (the room index, the name registry).
    param([Parameter(Mandatory)][string]$Path, [string]$Text)
    $Path = Resolve-RelayFullPath $Path
    $temporary = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    Write-RelayText $temporary $Text
    # A reader holds the file for a moment on Windows: the move is tried again, as Write-RelayText does
    for ($try = 0; ; $try++) {
        try {
            # [NullString]: PowerShell hands a plain $null over to a string parameter as an empty string
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($temporary, $Path) }
            return
        }
        catch {
            if ($try -lt 5) { Start-Sleep -Milliseconds 150; continue }
            try { [System.IO.File]::Delete($temporary) } catch { $null = $_ }
            throw
        }
    }
}

function Add-RelayLine {
    param([string]$Path, [string]$Line)
    $Path = Resolve-RelayFullPath $Path
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    for ($try = 0; ; $try++) {
        try { [System.IO.File]::AppendAllText($Path, $Line + "`n", $script:Utf8); return }
        catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 150 }
    }
}

function ConvertTo-RelayHeaderText {
    param([string]$Text)
    return ((($Text -replace '[\x00-\x1F\x7F]', ' ') -replace ' {2,}', ' ').Trim())
}

function ConvertTo-RelayRoomSlug {
    # A room is named after what it is for: the project, script or task, in a few words. This turns such words
    # into a folder name: lower case, dashes, the small words left out, cut at a word, at most 40 characters.
    param([string]$Text)
    $words = @((([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -split ' ' | Where-Object { $_ -and (@('a', 'an', 'the', 'of', 'for', 'to', 'and', 'or', 'on', 'in', 'at', 'by', 'with', 'from', 'its', 'their', 'then', 'this', 'that') -notcontains $_) })
    $slug = ''
    foreach ($word in $words) {
        $next = $word
        if ($slug) { $next = "$slug-$word" }
        if ($next.Length -gt 40) { break }
        $slug = $next
    }
    if (-not $slug -and $words.Count -gt 0) { $slug = $words[0].Substring(0, [Math]::Min(40, $words[0].Length)) }
    if ($slug.Length -lt 3) { $slug = ("room-$slug").Trim('-') }
    return $slug
}

function Read-RelayKeyValue {
    # A file of key: value lines, as Read-RelayKeyValueText reads its text
    param([string]$Path)
    return (Read-RelayKeyValueText (Read-RelayText $Path))
}

function Split-RelayFrontMatter {
    # A text that starts with a header between two --- lines (a message, a card): the header as key: value pairs
    # and the body after it. $null when the text has no such header.
    param([string]$Text)
    $whole = $Text + "`n"
    if (-not $whole.StartsWith("---`n", [System.StringComparison]::Ordinal)) { return $null }
    $end = $whole.IndexOf("`n---`n", 3, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { return $null }
    return [pscustomobject]@{ Header = (Read-RelayKeyValueText ($whole.Substring(4, $end - 3))); Body = $whole.Substring($end + 5).TrimEnd() }
}

function Read-RelayTemplate {
    # A template of the room package by its path in the package. One that is missing or empty is an error: it
    # would write an empty file into the room, an empty START-HERE.md or a wrapper that does nothing.
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Get-RelayPackageRoot) $Name
    $text = Read-RelayTextStrict $path
    if (-not $text.Trim()) { throw "The room package has no template ${Name}: $path is missing or empty" }
    return $text
}

function Get-RelayJsonTable {
    # One of the tables next to these scripts (agent-kinds.json, model-tiers.json, work-kinds.json,
    # relay-names.json), read once and kept: the feed asks for the model tiers of every agent on every round. A
    # table that is missing or cannot be read is an error.
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:JsonTables.ContainsKey($Name)) {
        $path = Join-Path $PSScriptRoot $Name
        $text = Read-RelayTextStrict $path
        if (-not $text.Trim()) { throw "The table $Name is missing or empty: $path" }
        $script:JsonTables[$Name] = ConvertFrom-RelayJson $text
    }
    return $script:JsonTables[$Name]
}

function ConvertTo-RelayKeyValueText {
    param([System.Collections.IDictionary]$Map)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Map.Keys) { $lines.Add(([string]$key) + ': ' + (ConvertTo-RelayHeaderText ([string]$Map[$key]))) }
    return (($lines -join "`n") + "`n")
}

function Get-RelayValue {
    param([System.Collections.IDictionary]$Map, [string]$Key, [string]$Default = '')
    if ($null -ne $Map -and $Map.Contains($Key) -and ([string]$Map[$Key]) -ne '') { return [string]$Map[$Key] }
    return $Default
}

function Get-RelayProperty {
    # A property of an object read from JSON, or the default when it is absent or empty
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [string] -and $property.Value -eq '') { return $Default }
    return $property.Value
}

function ConvertTo-RelayPrintedLine {
    # A line as it is printed for reading: each control character from a room file is replaced by a blank, and no
    # line ends in a blank. Control characters are those of C0 and C1 with DEL (U+0000 to U+001F, U+007F to
    # U+009F: U+009B starts an escape sequence like ESC [ does), the marks that turn the direction of text
    # (U+202A to U+202E, U+2066 to U+2069), the invisible ones (U+200B to U+200F, U+FEFF) and the line and
    # paragraph separators (U+2028, U+2029). JSON output does not pass here: it escapes.
    param([string]$Text)
    return ([regex]::Replace($Text, $script:PrintedControl, ' ')).TrimEnd(' ')
}

function Get-RelayTextLength {
    # Characters, not UTF-16 units: a surrogate pair counts once
    param([string]$Text)
    return ($Text.Length - [regex]::Matches($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]').Count)
}

function Format-RelayColumn {
    # A value padded on the right with spaces up to its width in characters; a longer value is not cut
    param([string]$Text, [int]$Width)
    return ($Text + (' ' * [Math]::Max(0, $Width - (Get-RelayTextLength $Text))))
}

function ConvertTo-RelayAsciiLower {
    # Names and ids of a PLAN are compared without regard to case, a to z only
    param([string]$Text)
    return [regex]::Replace($Text, '[A-Z]', { param($match) $match.Value.ToLowerInvariant() })
}

function Get-RelayBytesHash {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RelayFileHash {
    # Empty string when the file is missing or cannot be read right now
    param([string]$Path)
    $Path = Resolve-RelayFullPath $Path
    for ($try = 0; $try -lt 4; $try++) {
        try {
            if (-not [System.IO.File]::Exists($Path)) { return '' }
            return (Get-RelayBytesHash ([System.IO.File]::ReadAllBytes($Path)))
        }
        catch { Start-Sleep -Milliseconds 150 }
    }
    return ''
}

function Get-RelayFileTimeUtc {
    # -Force: on Linux and macOS a file whose name starts with a dot is hidden, and Get-Item does not see it without
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTimeUtc }
    catch { return [DateTime]::MinValue }
}

function ConvertTo-RelayJsonLine {
    # One line of JSON with every character outside printable ASCII escaped: safe through any code page
    param($Object)
    $json = ConvertTo-Json -InputObject $Object -Compress -Depth 8
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 32 -or $code -gt 126) { $null = $builder.Append(('\u{0:x4}' -f $code)) }
        else { $null = $builder.Append($character) }
    }
    return $builder.ToString()
}

#endregion

#region Room index and lookup

function ConvertFrom-RelayJson {
    # JSON text as objects, with every time left as the text it was written as. PowerShell 7 turns such text into
    # dates unless told otherwise (-DateKind, PowerShell 7.5 and later); Windows PowerShell never does.
    param([string]$Text)
    if ($null -eq $script:HasDateKind) { $script:HasDateKind = (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind') }
    if ($script:HasDateKind) { return (ConvertFrom-Json -InputObject $Text -DateKind String) }
    return (ConvertFrom-Json -InputObject $Text)
}

function Get-RelayRoomIndex {
    # The rooms of this PC. -Strict: an index that exists and cannot be read or parsed is an error, for a caller
    # that writes the index back; without it such an index lists no room.
    param([switch]$Strict)
    $path = Join-Path (Get-RelayLocalRoot) 'rooms.json'
    if ($Strict) { $text = Read-RelayTextStrict $path } else { $text = Read-RelayText $path }
    if (-not $text.Trim()) { return @() }
    # Windows PowerShell hands a JSON array over as one object: piping it gives the entries in both editions
    try { $parsed = ConvertFrom-RelayJson $text }
    catch {
        if ($Strict) { throw "The room index of this PC cannot be parsed, it is not written over: $path ($($_.Exception.Message))" }
        return @()
    }
    return @($parsed | ForEach-Object { $_ })
}

function Save-RelayRoomIndex {
    param([object[]]$Rooms)
    $json = '[]'
    foreach ($entry in @($Rooms)) { if ($null -ne $entry -and $null -ne $entry.PSObject.Properties['path'] -and [string]$entry.path) { $entry.path = Get-RelayNormalPath ([string]$entry.path) } }
    if (@($Rooms).Count -gt 0) { $json = ConvertTo-Json -InputObject @($Rooms) -Depth 6 }
    Write-RelayTextAtomic (Join-Path (Get-RelayLocalRoot) 'rooms.json') ($json + "`n")
}

function Update-RelayRoomIndex {
    # Reads the room index, hands its entries to -Change and saves the entries that come back: one caller at a
    # time on this PC (a named mutex), and an index that cannot be read is an error, never an empty list.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes this PC''s own room index for the script that called it, which asks for confirmation where it should')]
    param([Parameter(Mandatory)][scriptblock]$Change)
    $local = Get-RelayLocalRoot
    $mutexName = 'Global\agent-relay-index-' + (Get-RelayBytesHash ($script:Utf8.GetBytes((Get-RelayNormalPath $local).ToLowerInvariant()))).Substring(0, 16)
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another script of this PC holds the room index: try again' }
        $entries = @(Get-RelayRoomIndex -Strict)
        $changed = @(& $Change $entries)
        Save-RelayRoomIndex $changed
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-RelayNormalPath {
    # The normal form of a path: the full path, no trailing separator (a root keeps its own)
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath((Resolve-RelayFullPath $Path))
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-RelayRoomId {
    param([string]$Id)
    return ($Id -cmatch '^[a-z0-9][a-z0-9-]{0,62}$')
}

function Assert-RelayPastePath {
    # What is put into a command line for somebody to paste cannot hold a double quote or a line break
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [string]$What = 'The path')
    if ($Path -match '["\r\n]') { throw "$What holds a double quote or a line break and cannot be put into a command line: $($Path -replace '[\r\n]+', ' ')" }
}

function ConvertTo-RelayPowerShellLiteral {
    # Text as a PowerShell string in single quotes: a single quote is doubled. PowerShell ends such a string at
    # U+2018, U+2019, U+201A and U+201B as well, so each of them is doubled too.
    param([Parameter(Mandatory)][string]$Text)
    return ("'" + [regex]::Replace($Text, $script:PowerShellQuotes, { param($match) $match.Value + $match.Value }) + "'")
}

function Test-RelayPowerShellQuote {
    # True when the text holds a character PowerShell takes for a single quote
    param([string]$Text)
    return ([regex]::IsMatch([string]$Text, $script:PowerShellQuotes))
}

function ConvertTo-RelayShellLiteral {
    # Text as an sh string in single quotes: a single quote ends the string, is written escaped, and the string goes on
    param([Parameter(Mandatory)][string]$Text)
    return ("'" + $Text.Replace("'", "'\''") + "'")
}

function Get-RelayRoomObject {
    # The paths of a room by its id and its folder. Everything that says what the room is comes from this PC's
    # canonical copy, never from the ROOM file in the room, which every agent can write.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Path)
    $local = Join-Path (Join-Path (Get-RelayLocalRoot) 'rooms') $Id
    $canon = Join-Path $local 'canon'
    $info = Read-RelayKeyValue (Join-Path $canon 'ROOM')
    return [pscustomobject]@{
        Id          = $Id
        Path        = $Path
        Info        = $info
        Coordinator = (Get-RelayValue $info 'coordinator' '')
        Local       = $local
        Canon       = $canon
        Owner       = (Join-Path $local 'owner')
        IsClosed    = (Test-Path -LiteralPath (Join-Path $canon 'CLOSED') -PathType Leaf)
    }
}

function Resolve-RelayRoom {
    # A room by id or by folder. The index of this PC says which rooms there are, and this PC's canonical copy
    # says what each one is: the ROOM file in the room says nothing. An id is taken from the index only; a folder
    # is the folder of an index entry (both as full paths, compared without regard to case).
    param([Parameter(Mandatory)][string]$Room)
    $entry = $null
    $path = ''
    if ($Room -match '[\\/:]') {
        $folder = Get-RelayNormalPath ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Room))
        foreach ($candidate in @(Get-RelayRoomIndex)) {
            if ($null -eq $candidate.PSObject.Properties['path'] -or -not [string]$candidate.path) { continue }
            $candidatePath = ''
            try { $candidatePath = Get-RelayNormalPath ([string]$candidate.path) } catch { continue }
            if ([string]::Equals($candidatePath, $folder, [System.StringComparison]::OrdinalIgnoreCase)) { $entry = $candidate; $path = $candidatePath; break }
        }
        if ($null -eq $entry) { throw "No room at ${folder}: it is not in the room index of this PC" }
    }
    else {
        foreach ($candidate in @(Get-RelayRoomIndex)) {
            if ($null -ne $candidate.PSObject.Properties['id'] -and [string]$candidate.id -ceq $Room) { $entry = $candidate; break }
        }
        if ($null -eq $entry) { throw "No room '$Room': it is not in the room index of this PC" }
        if ($null -eq $entry.PSObject.Properties['path'] -or -not [string]$entry.path) { throw "The room '$Room' is in the index of this PC without a folder" }
        $path = Get-RelayNormalPath ([string]$entry.path)
    }
    $id = [string]$entry.id
    if (-not (Test-RelayRoomId $id)) { throw "The room index of this PC holds an entry whose id '$id' is no room id: refused" }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "The room '$id' is in the index but its folder is not reachable: $path" }
    $object = Get-RelayRoomObject -Id $id -Path $path
    if (-not (Test-Path -LiteralPath (Join-Path $object.Canon 'ROOM') -PathType Leaf)) { throw "The room '$id' has no canonical copy on this PC: it was not created here" }
    return $object
}
function Resolve-RelayHostAddress {
    # The IPv4 address of a host, as text. The name comes back unchanged when it is an address already or
    # cannot be resolved (a host alias of the ssh configuration, for example).
    param([Parameter(Mandatory)][string]$Name)
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($Name, [ref]$parsed)) { return $Name }
    try {
        foreach ($address in [System.Net.Dns]::GetHostAddresses($Name)) {
            if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($address)) { return $address.IPAddressToString }
        }
    }
    catch { $null = $_ }
    return $Name
}

function Resolve-RelayRemotePath {
    # A share path with the server's name replaced by its IPv4 address. An agent on another subnet often cannot
    # resolve the name this PC uses, so every address handed to another machine carries the address. Any other
    # path comes back unchanged.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '^\\\\([^\\]+)(\\.*)?$') { return '\\' + (Resolve-RelayHostAddress $Matches[1]) + [string]$Matches[2] }
    return $Path
}

function Get-RelayReachPath {
    # The room folder as other machines reach it: what the ROOM file records, or the room path with the
    # server's address in place of its name
    param([Parameter(Mandatory)]$Room)
    $recorded = Get-RelayValue $Room.Info 'reach' ''
    if ($recorded) { return $recorded }
    return (Resolve-RelayRemotePath $Room.Path)
}

function Get-RelayCanonicalGeneration {
    # The generation of an agent's current session, from this PC's copy: the room's gen file is the agents' to write
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name)
    $text = (Read-RelayText (Join-Path $Room.Canon "agents/$Name/gen")).Trim()
    $generation = 0
    if ($text -notmatch '^[0-9]{1,6}$' -or -not [int]::TryParse($text, [ref]$generation) -or $generation -lt 1) { throw "This PC's copy has no generation for the agent '$Name': it cannot be taken over" }
    return $generation
}
function Get-RelayRoster {
    # The agents of a room, from this PC's canonical copy: every agent this PC made a seat for has its gen or seat
    # file there, and a retired one its retired marker. The room's agents folder says nothing: any agent can make
    # a folder there, or put a retired marker into another agent's folder.
    param([Parameter(Mandatory)]$Room, [switch]$IncludeRetired)
    $names = New-Object System.Collections.Generic.List[string]
    $agents = Join-Path $Room.Canon 'agents'
    if (Test-Path -LiteralPath $agents -PathType Container) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $agents -Directory -Force)) {
            if ($folder.Name -cnotmatch $script:NamePattern) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName 'gen') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $folder.FullName 'seat') -PathType Leaf)) { continue }
            if (-not $IncludeRetired -and (Test-Path -LiteralPath (Join-Path $folder.FullName 'retired') -PathType Leaf)) { continue }
            $names.Add($folder.Name)
        }
    }
    return @($names | Sort-Object)
}

#endregion

#region Guarded files and the tamper check

function Get-RelayLinkInPath {
    # The outermost link (a symbolic link or a junction) on the way from the root down to the path, the path itself
    # included and the root not; '' when there is none
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $top = Get-RelayNormalPath $Root
    $current = Get-RelayNormalPath $Path
    $found = ''
    $below = $top.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    while ($current.Length -gt $top.Length -and $current.StartsWith($below, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-RelayLink $current) { $found = $current }
        $current = [System.IO.Path]::GetDirectoryName($current)
        if (-not $current) { break }
    }
    return $found
}

function Assert-RelayRoomTarget {
    # What this PC writes into the room never goes through a link that an agent put there: the folder behind it
    # is not the room's, it may be the owner's
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Path)
    if (Test-RelayLinkedPath -Root $Room.Path -Path $Path) { throw "Refused to write ${Path}: the way to it goes through a link in the room (a symbolic link or a junction), and what lies behind a link is not the room's. Remove the link, then run this again." }
}

function Write-RelayGuardedText {
    # The canonical copy on this PC is written first, the room second: the tamper check restores from the first.
    # Nothing is written when the room's file lies behind a link.
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Relative, [string]$Text, [switch]$Crlf)
    $roomTarget = Join-Path $Room.Path $Relative
    Assert-RelayRoomTarget $Room $roomTarget
    Write-RelayText (Join-Path $Room.Canon $Relative) $Text -Crlf:$Crlf
    Write-RelayText $roomTarget $Text -Crlf:$Crlf
}

function Copy-RelayGuardedFile {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$Source)
    $roomTarget = Join-Path $Room.Path $Relative
    Assert-RelayRoomTarget $Room $roomTarget
    foreach ($target in (Join-Path $Room.Canon $Relative), $roomTarget) {
        $folder = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($Source))
    }
}

function Get-RelayGuardedFile {
    # Relative paths (forward slashes) of everything the canonical copy holds
    param([Parameter(Mandatory)]$Room)
    $list = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Room.Canon) {
        $prefix = (Resolve-Path -LiteralPath $Room.Canon).ProviderPath.TrimEnd('\', '/')
        foreach ($file in @(Get-ChildItem -LiteralPath $Room.Canon -File -Recurse -Force)) {
            $list.Add(($file.FullName.Substring($prefix.Length).TrimStart('\', '/') -replace '\\', '/'))
        }
    }
    return @($list | Sort-Object)
}

function Add-RelayAlarm {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Text)
    Add-RelayLine (Join-Path $Room.Local 'alarms.log') ('{0} {1}' -f (Format-RelayUtc), (ConvertTo-RelayHeaderText $Text))
}

function Format-RelayTamperFinding {
    # One finding of Test-RelayTamper as a sentence for people: what the feed and the close of a room print
    param([Parameter(Mandatory)]$Finding)
    if ($Finding.Kind -eq 'link') { return "$($Finding.Relative) is a link in the room (a symbolic link or a junction): nothing behind it was read, restored or moved; the owner must remove the link" }
    $done = 'restored from the copy on this PC'
    if ($Finding.Kind -eq 'extra') { $done = 'it does not belong there and was moved out' }
    if (-not $Finding.Repaired) { $done = 'it could not be put right' }
    return "$($Finding.Relative) was $($Finding.Kind): $done"
}

function Test-RelayTamper {
    # Compares the guarded files in the room with the canonical copies. With -Repair a changed or missing file is
    # restored and a file that does not belong is moved out to this PC. Returns one finding per file. Each file is
    # dealt with by itself: one that cannot be restored or moved out is a finding with Repaired = $false and its
    # reason, and the check goes on with the next. A file that is there and cannot be read is 'unreadable', one
    # that is not there 'missing'. A link in the room (a symbolic link or a junction, which any agent can make) is
    # never followed: nothing behind it is read, restored or moved, and the link is one finding of kind 'link',
    # never repaired, with its alarm.
    param([Parameter(Mandatory)]$Room, [switch]$Repair)
    $findings = New-Object System.Collections.Generic.List[object]
    $known = @{}
    $links = @{}
    $guarded = @()
    $isListed = $true
    try { $guarded = @(Get-RelayGuardedFile $Room) }
    catch {
        # Without the list nothing can be called a stranger: only say so
        $isListed = $false
        Add-RelayAlarm $Room ("TAMPER check could not list the canonical copy: {0}" -f $_.Exception.Message)
    }
    $quarantine = Join-Path $Room.Local 'quarantine'
    $base = $Room.Path
    try { $base = Get-RelayNormalPath $Room.Path } catch { $null = $_ }
    # One finding per link, by its name in the room
    $addLink = {
        param([string]$Link)
        $linkName = $Link
        if ($Link.Length -gt $base.Length -and $Link.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { $linkName = ($Link.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/') }
        if ($links.ContainsKey($linkName)) { return }
        $links[$linkName] = $true
        $findings.Add([pscustomobject]@{ Relative = $linkName; Kind = 'link'; Repaired = $false; Reason = 'a link in the room is not followed' })
    }
    foreach ($relative in $guarded) {
        $known[$relative.ToLowerInvariant()] = $true
        $kind = 'changed'
        try {
            $canonPath = Join-Path $Room.Canon $relative
            $roomPath = Join-Path $Room.Path $relative
            $link = Get-RelayLinkInPath -Root $Room.Path -Path $roomPath
            if ($link) { & $addLink $link; continue }
            $expected = Get-RelayFileHash $canonPath
            $actual = Get-RelayFileHash $roomPath
            if ($expected -eq $actual) { continue }
            # A file the server is still handing over reads as missing for a moment: look twice before an alarm
            Start-Sleep -Milliseconds 300
            $actual = Get-RelayFileHash $roomPath
            if ($expected -eq $actual) { continue }
            if (-not $actual) {
                $kind = 'missing'
                if ([System.IO.File]::Exists($roomPath)) { $kind = 'unreadable' }
            }
            if ($Repair) {
                $folder = Split-Path -Parent $roomPath
                if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
                if ($actual) {
                    $keep = Join-Path $quarantine ('{0}-{1}' -f (Format-RelayUtc -Format 'yyyyMMddTHHmmssZ'), ($relative -replace '[\\/]', '_'))
                    if (-not (Test-Path -LiteralPath $quarantine)) { $null = New-Item -ItemType Directory -Path $quarantine -Force }
                    try { [System.IO.File]::WriteAllBytes($keep, [System.IO.File]::ReadAllBytes($roomPath)) } catch { $null = $_ }
                }
                [System.IO.File]::WriteAllBytes($roomPath, [System.IO.File]::ReadAllBytes($canonPath))
            }
            $findings.Add([pscustomobject]@{ Relative = $relative; Kind = $kind; Repaired = [bool]$Repair; Reason = '' })
        }
        catch { $findings.Add([pscustomobject]@{ Relative = $relative; Kind = $kind; Repaired = $false; Reason = $_.Exception.Message }) }
    }

    # Files that do not belong where only this PC writes: the tools, the wrappers, the markers, the prompts
    if ($isListed) {
        $candidates = New-Object System.Collections.Generic.List[string]
        # At the top of the room: a PLAN, a CLOSED marker, a TRANSCRIPT.md, a prompt or a join command that this PC
        # did not write has no canonical copy and so is not known
        try {
            foreach ($file in @((New-Object System.IO.DirectoryInfo $Room.Path).GetFiles())) {
                if (@('PLAN', 'CLOSED', 'TRANSCRIPT.md', 'join', 'join.cmd', 'join.ps1') -contains $file.Name -or $file.Name -match '^PROMPT-.*\.txt$') { $candidates.Add($file.FullName) }
            }
        }
        catch { Add-RelayAlarm $Room ("TAMPER check could not list the room folder: {0}" -f $_.Exception.Message) }
        $tools = Join-Path $Room.Path 'tools'
        try {
            if (Test-RelayLink $tools) { & $addLink (Get-RelayNormalPath $tools) }
            elseif (Test-Path -LiteralPath $tools -PathType Container) {
                # A link inside the tools folder is listed, never entered
                $tree = Get-RelayFileTree $tools
                foreach ($file in @($tree.Files)) { $candidates.Add($file.FullName) }
                foreach ($link in @($tree.Links)) { & $addLink $link }
            }
        }
        catch { Add-RelayAlarm $Room ("TAMPER check could not list tools: {0}" -f $_.Exception.Message) }
        foreach ($agent in @(Get-RelayRoster $Room -IncludeRetired)) {
            $agentDir = Join-Path (Join-Path $Room.Path 'agents') $agent
            try {
                $link = Get-RelayLinkInPath -Root $Room.Path -Path $agentDir
                if ($link) { & $addLink $link; continue }
                if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) { continue }
                foreach ($name in 'retired', 'lines', 'scope', 'seat', 'control', 'gen') {
                    $path = Join-Path $agentDir $name
                    if (Test-Path -LiteralPath $path) { $candidates.Add($path) }
                }
                # -Force: a folder that is hidden (over SMB a name with a leading dot can be) is still listed
                foreach ($generation in @(Get-ChildItem -LiteralPath $agentDir -Directory -Force -Filter 'g*' | Where-Object { $_.Name -match '^g[0-9]+$' })) {
                    if (Test-RelayLink $generation.FullName) { & $addLink $generation.FullName; continue }
                    foreach ($file in @(Get-ChildItem -LiteralPath $generation.FullName -File -Force)) { $candidates.Add($file.FullName) }
                }
            }
            catch { Add-RelayAlarm $Room ("TAMPER check could not list agents/{0}: {1}" -f $agent, $_.Exception.Message) }
        }
        $prefix = $Room.Path.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        foreach ($path in $candidates) {
            # A name is cut from the room's path only when the file's path really starts with it
            if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = ($path.Substring($prefix.Length) -replace '\\', '/')
            if ($known.ContainsKey($relative.ToLowerInvariant())) { continue }
            # The list is as old as this check: a file this PC has written since (the canonical copy first, as
            # always) belongs here, and is compared with its copy in the next round
            if (Test-Path -LiteralPath (Join-Path $Room.Canon $relative) -PathType Leaf) { continue }
            try {
                # A link is moved nowhere: it is a finding of its own
                $link = Get-RelayLinkInPath -Root $Room.Path -Path $path
                if ($link) { & $addLink $link; continue }
                if ($Repair) {
                    $keep = Join-Path $quarantine ('{0}-{1}' -f (Format-RelayUtc -Format 'yyyyMMddTHHmmssZ'), ($relative -replace '[\\/]', '_'))
                    if (-not (Test-Path -LiteralPath $quarantine)) { $null = New-Item -ItemType Directory -Path $quarantine -Force }
                    Move-Item -LiteralPath $path -Destination $keep -Force -ErrorAction Stop
                }
                $findings.Add([pscustomobject]@{ Relative = $relative; Kind = 'extra'; Repaired = [bool]$Repair; Reason = '' })
            }
            catch { $findings.Add([pscustomobject]@{ Relative = $relative; Kind = 'extra'; Repaired = $false; Reason = $_.Exception.Message }) }
        }
    }
    foreach ($finding in $findings) {
        if ($finding.Kind -eq 'link') { Add-RelayAlarm $Room ("TAMPER link in the room, not followed: {0}" -f $finding.Relative); continue }
        $action = 'found'
        if ($finding.Repaired) { $action = 'restored' }
        if ($finding.Repaired -and $finding.Kind -eq 'extra') { $action = 'moved out' }
        if ($finding.Reason) { Add-RelayAlarm $Room ("TAMPER {0} could not restore: {1}: {2}" -f $finding.Kind, $finding.Relative, $finding.Reason) }
        else { Add-RelayAlarm $Room ("TAMPER {0} {1}: {2}" -f $finding.Kind, $action, $finding.Relative) }
    }
    return @($findings.ToArray())
}
#endregion

#region Messages

function Read-RelayMessage {
    # Sender, receiver and number come from where the file is; the header gives the rest
    param([Parameter(Mandatory)][string]$Path)
    $parts = Split-RelayFrontMatter (Read-RelayText $Path)
    if ($null -eq $parts) { return $null }
    $header = $parts.Header
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $to = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $Path))
    $from = ''
    $number = ''
    if ($fileName -match '^([a-z][a-z0-9]{1,15})-([0-9]{4,6})$') { $from = $Matches[1]; $number = $Matches[2] }
    $fields = @{}
    foreach ($key in 'id', 'from', 'to', 'type', 're', 'subject', 'sent_utc', 'expects') {
        $fields[$key] = ''
        if ($header.Contains($key)) { $fields[$key] = [string]$header[$key] }
    }
    $id = "$from-$to-$number"
    return [pscustomobject]@{
        Id       = $id
        From     = $from
        To       = $to
        Type     = $fields['type']
        Re       = $fields['re']
        Subject  = $fields['subject']
        SentUtc  = $fields['sent_utc']
        Expects  = $fields['expects']
        Body     = $parts.Body
        Path     = $Path
        Time     = (Get-RelayFileTimeUtc $Path)
        Mismatch = ($fields['id'] -cne $id -or $fields['from'] -cne $from -or $fields['to'] -cne $to)
    }
}

function Get-RelayMessage {
    # Every message in the room, oldest first (by the file server's time). Owner cards are separate.
    param([Parameter(Mandatory)]$Room)
    $messages = New-Object System.Collections.Generic.List[object]
    foreach ($agent in @(Get-RelayRoster $Room -IncludeRetired)) {
        $inbox = Join-Path (Join-Path (Join-Path $Room.Path 'agents') $agent) 'inbox'
        if (-not (Test-Path -LiteralPath $inbox)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $inbox -Filter '*.md' -File)) {
            if ($file.Name -notmatch '^[a-z][a-z0-9]{1,15}-[0-9]{4,6}\.md$') { continue }
            $message = Read-RelayMessage $file.FullName
            if ($null -ne $message) { $messages.Add($message) }
        }
    }
    return @($messages | Sort-Object Time, Id)
}

function Add-RelayMessageFile {
    # Writes one message into an inbox the way the room tool does: a free number, an exclusive move into place.
    # With -LogPath (the owner's log) the number comes from that log, never from what lies in the inbox, and the
    # log line (with the hash of the file's bytes) is written before the file is moved into place. That hash is
    # taken of the bytes in memory, never read back from the inbox, where any agent can swap the temporary file:
    # a temporary file that no longer holds those bytes is deleted and nothing is sent. A number a file already
    # has, or the receiver's delivered list already names, is skipped; past 999999 there is no number.
    param(
        [Parameter(Mandatory)][string]$Inbox, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Type, [string]$Re = '', [string]$Subject = '', [string]$Body = '', [string]$Expects = 'none',
        [string]$LogPath = '', [string]$Via = 'chat', [string]$DeliveredPath = ''
    )
    if (-not (Test-Path -LiteralPath $Inbox)) { $null = New-Item -ItemType Directory -Path $Inbox -Force }
    $highest = 0
    $idPattern = '^' + [regex]::Escape("$From-$To-") + '([0-9]{4,6})$'
    if ($LogPath) {
        # A log that cannot be read gives no number: it would start again at 1
        foreach ($line in ((Read-RelayTextStrict $LogPath) -split "`n")) {
            $parts = @($line -split "`t")
            if ($parts.Count -ge 2 -and $parts[1] -cmatch $idPattern) { $seen = [int]$Matches[1]; if ($seen -gt $highest) { $highest = $seen } }
        }
    }
    else {
        foreach ($file in @(Get-ChildItem -LiteralPath $Inbox -Filter "$From-*.md" -File)) {
            if ($file.Name -match '^[a-z][a-z0-9]{1,15}-([0-9]{4,6})\.md$') { $seen = [int]$Matches[1]; if ($seen -gt $highest) { $highest = $seen } }
        }
    }
    $delivered = @{}
    if ($DeliveredPath) { foreach ($line in ((Read-RelayText $DeliveredPath) -split "`n")) { $word = ($line -split ' ')[0]; if ($word) { $delivered[$word] = $true } } }
    $number = $highest + 1
    $blocked = 0
    while ($number -le 999999) {
        $id = '{0}-{1}-{2:0000}' -f $From, $To, $number
        $final = Join-Path $Inbox ('{0}-{1:0000}.md' -f $From, $number)
        if ([System.IO.File]::Exists($final) -or $delivered.ContainsKey($id)) { $number++; continue }
        $header = @(
            '---'
            "id: $id"
            "from: $From"
            "to: $To"
            "type: $Type"
            "re: $Re"
            "subject: $(ConvertTo-RelayHeaderText $Subject)"
            "sent_utc: $(Format-RelayUtc)"
            "expects: $Expects"
            '---'
        ) -join "`n"
        # The text as Write-RelayText writes it: LF line ends, UTF-8 without BOM
        $text = (($header + "`n" + $Body.TrimEnd() + "`n") -replace "`r`n", "`n") -replace "`r", "`n"
        $hash = Get-RelayBytesHash ($script:Utf8.GetBytes($text))
        $temporary = Join-Path $Inbox ('.{0}-{1}.tmp' -f $From, [guid]::NewGuid().ToString('N'))
        Write-RelayText $temporary $text
        if ($LogPath) {
            if ((Get-RelayFileHash $temporary) -ne $hash) {
                try { [System.IO.File]::Delete($temporary) } catch { $null = $_ }
                throw "The message file in $Inbox was changed between writing it and logging it: nothing was sent"
            }
            # A log that cannot be written means no message: the temporary file goes
            try { Add-RelayLine $LogPath ("{0}`t{1}`t{2}`t{3}`t{4}" -f (Format-RelayUtc), $id, $hash, $Via, $Re) }
            catch { [System.IO.File]::Delete($temporary); throw }
        }
        $moved = $false
        try { [System.IO.File]::Move($temporary, $final); $moved = $true } catch { $moved = $false }
        if ($moved) { return $id }
        [System.IO.File]::Delete($temporary)
        if ([System.IO.File]::Exists($final)) { $number++; continue }
        $blocked++
        if ($blocked -ge 5) { throw "Could not create a message in $Inbox" }
        Start-Sleep -Milliseconds 300
    }
    throw "could not find a free message number in $Inbox"
}
function Get-RelayOpenRequest {
    # Tasks, questions and proposals no result or answer names yet, across the whole room
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Messages)
    $closed = @{}
    foreach ($message in $Messages) { if (@('result', 'answer') -contains $message.Type -and $message.Re) { $closed["$($message.From)>$($message.Re)"] = $true } }
    $open = New-Object System.Collections.Generic.List[object]
    foreach ($message in $Messages) {
        if (@('task', 'question', 'proposal') -notcontains $message.Type) { continue }
        if ($closed.ContainsKey("$($message.To)>$($message.Id)")) { continue }
        $open.Add($message)
    }
    return @($open.ToArray())
}

#endregion

#region Owner: log, messages, cards

function Send-RelayOwnerMessage {
    # What the owner typed or decided in the chat window: written to the owner's log on this PC first (the hash is
    # that of the message file's bytes, so header and text are covered together), then delivered to the
    # coordinator's inbox. The coordinator acts on it only when the log confirms it.
    param(
        [Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Text,
        [string]$For = '', [string]$Re = '', [ValidateSet('', 'approved', 'denied')][string]$Decision = '', [string]$Via = 'chat'
    )
    if (-not $Room.Coordinator) { throw 'The room names no coordinator' }
    $body = ($Text -replace "`r", '').Trim()
    if (-not $body) { $body = $Decision }
    if (-not $body) { throw 'There is no text to send' }
    $firstLine = @($body -split "`n")[0]
    if ($firstLine.Length -gt 100) { $firstLine = $firstLine.Substring(0, 100) }
    $subject = $firstLine
    if ($For) { $subject = "for ${For}: $firstLine" }
    if ($Decision) { $subject = "${Decision}: $firstLine" }
    $type = 'note'
    if ($Re) { $type = 'answer' }
    $coordinatorDir = Join-Path (Join-Path $Room.Path 'agents') $Room.Coordinator
    return (Add-RelayMessageFile -Inbox (Join-Path $coordinatorDir 'inbox') -From 'owner' -To $Room.Coordinator -Type $type -Re $Re -Subject $subject -Body $body -Expects 'none' -LogPath (Join-Path $Room.Owner 'log') -Via $Via -DeliveredPath (Join-Path $coordinatorDir 'delivered'))
}

function Test-RelayOwnerMessage {
    # True when the message is in the owner's log with the same bytes: header and text together
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)]$Message)
    $hash = Get-RelayFileHash $Message.Path
    if (-not $hash) { return $false }
    foreach ($line in ((Read-RelayText (Join-Path $Room.Owner 'log')) -split "`n")) {
        $parts = @($line -split "`t")
        if ($parts.Count -ge 3 -and $parts[1] -ceq $Message.Id -and $parts[2] -ceq $hash) { return $true }
    }
    return $false
}
function Get-RelayOwnerCard {
    # Questions the coordinator put to the owner. They live on this PC, not in the room.
    param([Parameter(Mandatory)]$Room, [switch]$OpenOnly)
    $cards = New-Object System.Collections.Generic.List[object]
    $folder = Join-Path $Room.Owner 'cards'
    if (Test-Path -LiteralPath $folder) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.md' -File | Sort-Object Name)) {
            $parts = Split-RelayFrontMatter (Read-RelayText $file.FullName)
            if ($null -eq $parts) { continue }
            $header = $parts.Header
            $answerPath = [System.IO.Path]::ChangeExtension($file.FullName, '.answer')
            $answer = Read-RelayKeyValue $answerPath
            $isOpen = ($answer.Count -eq 0)
            if ($OpenOnly -and -not $isOpen) { continue }
            $cards.Add([pscustomobject]@{
                    Id       = (Get-RelayValue $header 'id' $file.BaseName)
                    Re       = (Get-RelayValue $header 're' '')
                    Subject  = (Get-RelayValue $header 'subject' '')
                    SentUtc  = (Get-RelayValue $header 'sent_utc' '')
                    Body     = $parts.Body
                    IsOpen   = $isOpen
                    Decision = (Get-RelayValue $answer 'decision' '')
                    Via      = (Get-RelayValue $answer 'via' '')
                    Path     = $file.FullName
                })
        }
    }
    return @($cards.ToArray())
}

function Read-RelayKeyValueText {
    param([string]$Text)
    $map = [ordered]@{}
    foreach ($line in ($Text -split "`n")) {
        $at = $line.IndexOf([char]':')
        if ($at -lt 1) { continue }
        $map[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim()
    }
    return $map
}

function Add-RelayOwnerCard {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Subject, [Parameter(Mandatory)][string]$Body, [string]$Re = '')
    $folder = Join-Path $Room.Owner 'cards'
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $number = @(Get-ChildItem -LiteralPath $folder -Filter '*.md' -File).Count + 1
    while (Test-Path -LiteralPath (Join-Path $folder ('{0:0000}.md' -f $number))) { $number++ }
    $id = '{0}-owner-{1:0000}' -f $Room.Coordinator, $number
    $header = @(
        '---'
        "id: $id"
        "from: $($Room.Coordinator)"
        'to: owner'
        'type: question'
        "re: $Re"
        "subject: $(ConvertTo-RelayHeaderText $Subject)"
        "sent_utc: $(Format-RelayUtc)"
        'expects: reply'
        '---'
    ) -join "`n"
    Write-RelayText (Join-Path $folder ('{0:0000}.md' -f $number)) ($header + "`n" + ($Body -replace "`r", '').TrimEnd() + "`n")
    return $id
}

function Complete-RelayOwnerCard {
    # Records the owner's answer to a card: from the chat window, or given in the session
    param(
        [Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$CardId,
        [Parameter(Mandatory)][ValidateSet('approved', 'denied', 'answered', 'withdrawn')][string]$Decision,
        [string]$Via = 'session', [string]$MessageId = ''
    )
    $card = @(Get-RelayOwnerCard $Room | Where-Object { $_.Id -eq $CardId })
    if ($card.Count -eq 0) { throw "No card '$CardId' in room $($Room.Id)" }
    $answer = [ordered]@{ decision = $Decision; via = $Via; at_utc = (Format-RelayUtc); message = $MessageId }
    Write-RelayText ([System.IO.Path]::ChangeExtension($card[0].Path, '.answer')) (ConvertTo-RelayKeyValueText $answer)
    Add-RelayLine (Join-Path $Room.Owner 'log') ("{0}`t{1}`t{2}`t{3}`t{4}" -f (Format-RelayUtc), $CardId, $Decision, $Via, $MessageId)
}

#endregion

#region Board

function Get-RelayRoomNow {
    # "Now" on the clock of wherever the room lives: the time the file server gives a file written this moment.
    # The probe has a new name every time and is only made where nothing is yet, then deleted: a folder or a link
    # of that name that an agent put into the room can neither stop it for good nor turn the write elsewhere.
    # Without a probe it is the clock of this PC.
    param([Parameter(Mandatory)]$Room)
    $probe = Join-Path $Room.Path ('.dev-clock-' + [guid]::NewGuid().ToString('N'))
    try {
        $stream = New-Object System.IO.FileStream($probe, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $stream.WriteByte(10) } finally { $stream.Dispose() }
        try {
            $time = Get-RelayFileTimeUtc $probe
            if ($time -ne [DateTime]::MinValue) { return $time }
        }
        finally { try { [System.IO.File]::Delete($probe) } catch { $null = $_ } }
    }
    catch { $null = $_ }
    return [DateTime]::UtcNow
}

function ConvertTo-RelayMessageRow {
    # A message as the chat window and the board show it: header fields and the start of the text
    param([Parameter(Mandatory)]$Message)
    $preview = $Message.Body
    if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + ' ...' }
    return [pscustomobject]@{
        id       = $Message.Id
        from     = $Message.From
        to       = $Message.To
        type     = $Message.Type
        re       = $Message.Re
        subject  = $Message.Subject
        expects  = $Message.Expects
        sentUtc  = $Message.SentUtc
        time     = (Format-RelayUtc $Message.Time)
        preview  = $preview
        length   = $Message.Body.Length
        mismatch = [bool]$Message.Mismatch
    }
}

function ConvertTo-RelayCardRow {
    # An open card as the board and the chat window show it: its header and the start of its text
    param([Parameter(Mandatory)]$Card)
    $preview = $Card.Body
    if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) + ' ...' }
    return [pscustomobject]@{ id = $Card.Id; re = $Card.Re; subject = $Card.Subject; sentUtc = $Card.SentUtc; text = $preview }
}

function Test-RelayPlanDifference {
    # True when the room's PLAN is not byte for byte this PC's copy, or this PC has no copy
    param([Parameter(Mandatory)]$Room)
    $copy = Get-RelayFileHash (Join-Path $Room.Canon 'PLAN')
    return ((-not $copy) -or ($copy -ne (Get-RelayFileHash (Join-Path $Room.Path 'PLAN'))))
}

function Format-RelayPlanTable {
    # One line per part of a plan, in the order of the parts: id, status, owner and title in columns, -Indent in
    # front. The id column is as wide as the longest id and 12 at least; widths are counted in characters (a
    # surrogate pair counts once), and a value longer than its column is not cut.
    param([AllowEmptyCollection()][object[]]$Parts = @(), [string]$Indent = '  ')
    $idWidth = 12
    foreach ($part in @($Parts)) { $idWidth = [Math]::Max($idWidth, (Get-RelayTextLength ([string]$part.id))) }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($part in @($Parts)) { $lines.Add($Indent + (Format-RelayColumn ([string]$part.id) $idWidth) + '  ' + (Format-RelayColumn ([string]$part.status) 8) + '  ' + (Format-RelayColumn ([string]$part.owner) 9) + '  ' + [string]$part.title) }
    return @($lines.ToArray())
}

function ConvertTo-RelayPlanRevision {
    # A plan revision as a number: one to nine digits, else 0 (no plan)
    param([string]$Text)
    if ($Text -notmatch '^[0-9]{1,9}$') { return 0 }
    return [int]$Text
}

function Read-RelayPlan {
    # The room's PLAN as the room tools read it: $null when the room has no plan, IsComplete false when its
    # end line does not repeat the revision (caught half written, or damaged). -Canonical reads this PC's copy.
    param([Parameter(Mandatory)]$Room, [switch]$Canonical)
    $root = $Room.Path
    if ($Canonical) { $root = $Room.Canon }
    $text = Read-RelayText (Join-Path $root 'PLAN')
    $blank = [char[]]@(' ', "`t")
    $scalar = @{}
    $byId = @{}
    $order = New-Object System.Collections.Generic.List[string]
    $extras = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($text -split "`n")) {
        # A line counts only when it starts with a known key and its colon: nothing before the key, nothing
        # between the key and the colon, lower case
        $at = $line.IndexOf([char]':')
        if ($at -lt 1) { continue }
        $key = $line.Substring(0, $at)
        # Cut at the separators first and trim each field afterwards: a line that ends in a separator has an
        # empty last field
        $raw = $line.Substring($at + 1)
        $value = $raw.Trim($blank)
        if ($key -ceq 'part') {
            $fields = @(($raw -split ' \| ', 6) | ForEach-Object { $_.Trim($blank) })
            if ($fields.Count -lt 6 -or -not $fields[0] -or $byId.ContainsKey($fields[0])) { continue }
            $depends = @()
            if ($fields[3] -and $fields[3] -cne '-') { $depends = @(($fields[3] -split ',') | ForEach-Object { $_.Trim($blank) } | Where-Object { $_ }) }
            $byId[$fields[0]] = [pscustomobject]@{
                id = $fields[0]; owner = $fields[1]; status = $fields[2]; depends = $depends; reviewer = $fields[4]; title = $fields[5]
                files = (New-Object System.Collections.Generic.List[string]); notes = (New-Object System.Collections.Generic.List[string])
            }
            $order.Add($fields[0])
        }
        elseif ($key -ceq 'files' -or $key -ceq 'note') {
            $pair = @(($raw -split ' \| ', 2) | ForEach-Object { $_.Trim($blank) })
            if ($pair.Count -lt 2 -or -not $pair[0] -or -not $pair[1]) { continue }
            $extras.Add([pscustomobject]@{ Key = $key; Part = $pair[0]; Value = $pair[1] })
        }
        elseif (@('plan', 'updated_utc', 'goal', 'end') -ccontains $key -and -not $scalar.ContainsKey($key)) { $scalar[$key] = $value }
    }
    $revision = ConvertTo-RelayPlanRevision ([string]$scalar['plan'])
    if ($revision -eq 0) { return $null }
    foreach ($extra in $extras) {
        if (-not $byId.ContainsKey($extra.Part)) { continue }
        if ($extra.Key -ceq 'files') { $byId[$extra.Part].files.Add($extra.Value) } else { $byId[$extra.Part].notes.Add($extra.Value) }
    }
    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($id in $order) {
        $part = $byId[$id]
        foreach ($name in 'owner', 'reviewer') { if (-not $part.$name) { $part.$name = '-' } }
        $parts.Add([pscustomobject]@{ id = $part.id; owner = $part.owner; status = $part.status; depends = @($part.depends); reviewer = $part.reviewer; title = $part.title; files = @($part.files.ToArray()); notes = @($part.notes.ToArray()) })
    }
    $updated = [string]$scalar['updated_utc']
    if (-not $updated) { $updated = 'unknown' }
    $goal = [string]$scalar['goal']
    if (-not $goal) { $goal = '-' }
    return [pscustomobject]@{
        revision   = $revision
        updatedUtc = $updated
        goal       = $goal
        isComplete = ((ConvertTo-RelayPlanRevision ([string]$scalar['end'])) -eq $revision)
        parts      = @($parts.ToArray())
    }
}

function Get-RelayAgentState {
    # One row per agent: who it is, where it runs, what it is doing and whether somebody must look at it
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][DateTime]$Now, [AllowEmptyCollection()][object[]]$Open = @(), $Plan = $null, [AllowEmptyCollection()][object[]]$Messages = @())
    $now = $Now
    $open = @($Open)
    $staleMinutes = 5
    $parsed = 0
    if ([int]::TryParse((Get-RelayValue $Room.Info 'stale_minutes' '5'), [ref]$parsed)) { $staleMinutes = $parsed }
    # How long a message may lie in an inbox before somebody must look at that agent: a session that ended while
    # it worked says nothing, and its state stays "working" for ever
    $pickupMinutes = 30
    if ([int]::TryParse((Get-RelayValue $Room.Info 'pickup_minutes' '30'), [ref]$parsed) -and $parsed -gt 0) { $pickupMinutes = $parsed }

    $agents = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-RelayRoster $Room -IncludeRetired)) {
        $dir = Join-Path (Join-Path $Room.Path 'agents') $name
        $canonDir = Join-Path (Join-Path $Room.Canon 'agents') $name
        $seat = Read-RelayKeyValue (Join-Path $canonDir 'seat')
        $card = Read-RelayKeyValue (Join-Path $dir 'card')
        $status = Read-RelayKeyValue (Join-Path $dir 'status')
        $control = Get-RelayValue (Read-RelayKeyValue (Join-Path $canonDir 'control')) 'state' 'run'
        $state = Get-RelayValue $status 'state' 'not started'
        $alive = Get-RelayFileTimeUtc (Join-Path $dir 'alive')
        $silent = -1
        if ($alive -ne [DateTime]::MinValue) { $silent = [int][Math]::Max(0, ($now - $alive).TotalMinutes) }
        $isRetired = Test-Path -LiteralPath (Join-Path $canonDir 'retired') -PathType Leaf
        $isStale = ($state -eq 'listening' -and $silent -ge $staleMinutes)
        # A seat nobody is named for: free until an agent given the join prompt takes it
        $isOpen = ((Get-RelayValue $seat 'open' '') -eq 'yes')
        $isFree = ($isOpen -and $card.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $dir 'claim')))
        $attention = ''
        $expected = Get-RelayValue $seat 'expect_computer' ''
        $computer = Get-RelayValue $card 'computer' ''
        if ($isRetired) { $state = 'retired' }
        elseif ($isFree) { $state = 'free seat' }
        elseif ($expected -and $computer -and $expected -ne $computer) { $attention = "introduced itself from $computer, expected ${expected}: check with the owner before giving it work" }
        elseif ($isStale) { $attention = "wait died $silent min ago: owner must restart that session" }
        elseif ($state -eq 'parked') { $attention = 'parked: owner must nudge' }
        elseif ($state -eq 'not started' -and $isOpen) { $attention = 'took a seat but has not introduced itself: owner must look at that session' }
        elseif ($state -eq 'not started') { $attention = 'not started: owner must paste the start prompt' }
        elseif ($control -ne 'run') { $attention = "control: $control" }
        elseif ($name -ne $Room.Coordinator) {
            # What was sent to it and its own tool has not shown it yet
            $shown = @{}
            foreach ($line in ((Read-RelayText (Join-Path $dir 'delivered')) -split "`n")) { $word = ($line -split ' ')[0]; if ($word) { $shown[$word] = $true } }
            $lying = @($Messages | Where-Object { $_.To -eq $name -and -not $shown.ContainsKey([string]$_.Id) })
            if ($lying.Count -gt 0) {
                $oldest = [int][Math]::Max(0, ($now - @($lying | Sort-Object Time)[0].Time).TotalMinutes)
                if ($oldest -ge $pickupMinutes) { $attention = "has not picked up $($lying.Count) message(s) for $oldest min: its session may have ended, owner must look at it" }
            }
        }
        $owes = @($open | Where-Object { $_.To -eq $name })
        # Where it says it stands (the verb progress): the last record, cut at the first separator
        $progress = ''
        $progressUtc = ''
        $records = @(((Read-RelayText (Join-Path $dir 'progress')) -split "`n") | Where-Object { $_.Contains(' | ') })
        if ($records.Count -gt 0) {
            $record = $records[$records.Count - 1]
            $cut = $record.IndexOf(' | ', [System.StringComparison]::Ordinal)
            $progressUtc = $record.Substring(0, $cut)
            $progress = $record.Substring($cut + 3)
        }
        $parts = @()
        if ($null -ne $Plan -and $Plan.isComplete) { $parts = @($Plan.parts | Where-Object { (ConvertTo-RelayAsciiLower ([string]$_.owner)) -ceq $name } | ForEach-Object { $_.id }) }
        $agents.Add([pscustomobject]@{
                name          = $name
                display       = (Get-RelayValue $seat 'display' $name)
                role          = (Get-RelayValue $seat 'role' '')
                machine       = (Get-RelayValue $seat 'machine' '')
                machineCare   = (Get-RelayValue $seat 'machine_care' 'in-use')
                isIntroduced  = ($card.Count -gt 0)
                isOpen        = $isOpen
                isFree        = $isFree
                kind          = (Get-RelayValue $card 'kind' (Get-RelayValue $seat 'kind' ''))
                transport     = (Get-RelayValue $seat 'transport' '')
                wake          = (Get-RelayValue $card 'wake' (Get-RelayValue $seat 'wake' ''))
                gen           = (Read-RelayText (Join-Path $canonDir 'gen')).Trim()
                isCoordinator = ($name -eq $Room.Coordinator)
                state         = $state
                detail        = (Get-RelayValue $status 'detail' '')
                isStale       = $isStale
                silentMinutes = $silent
                control       = $control
                attention     = $attention
                owes          = $owes.Count
                progress      = $progress
                progressUtc   = $progressUtc
                parts         = $parts
                computer      = (Get-RelayValue $card 'computer' '')
                ipv4          = (Get-RelayValue $card 'ipv4' '')
                user          = (Get-RelayValue $card 'user' '')
                elevation     = (Get-RelayValue $card 'elevation' '')
                rights        = (Get-RelayRightsKind (Get-RelayValue $card 'elevation' ''))
                shell         = (((Get-RelayValue $card 'shell' '') -split ';')[0]).Trim()
                shells        = (Get-RelayValue $card 'shells' '')
                agentProcess  = (Get-RelayValue $card 'agent_process' '')
                os            = (Get-RelayValue $card 'os' '')
                hostApp       = (Get-RelayValue $card 'host_app' '')
                product       = (Get-RelayValue $card 'product' '')
                model         = (Get-RelayValue $card 'model' '')
                tier          = (Get-RelayModelTier (Get-RelayValue $card 'model' ''))
                effort        = (Get-RelayValue $card 'effort' '')
            })
    }
    return @($agents.ToArray())
}

function Get-RelayRightsKind {
    # What an agent's introduction says about its rights, as one of four words the coordinator hands out work
    # by: elevated (it can do administrator work itself), can-elevate (it can, when the owner answers a prompt
    # or it may use sudo), none, unknown (not introduced, or a card that does not say)
    param([string]$Elevation)
    $text = ([string]$Elevation).Trim().ToLowerInvariant()
    if (-not $text) { return 'unknown' }
    if ($text -eq 'system' -or $text -eq 'root' -or $text -eq 'administrator' -or $text -like 'elevated*') { return 'elevated' }
    if ($text -like '*can elevate*' -or $text -like '*sudo*') { return 'can-elevate' }
    if ($text -like 'not elevated*' -or $text -like 'not root*') { return 'none' }
    return 'unknown'
}

function Get-RelayModelTier {
    # How strong a model is, read off the name an agent gave in its introduction: light, standard, strong, or
    # unknown. A guide for handing out work (model-tiers.json), not a ranking.
    param([string]$Model)
    $name = ([string]$Model).Trim().ToLowerInvariant()
    if (-not $name -or $name -eq 'unknown') { return 'unknown' }
    $table = Get-RelayJsonTable 'model-tiers.json'
    foreach ($entry in @($table.tiers)) {
        foreach ($word in @($entry.words)) {
            # A word counts where it starts a part of the name: mini in gpt-6-mini, not in gemini
            if ($name -match ('(^|[^a-z0-9])' + [regex]::Escape(([string]$word).ToLowerInvariant()))) { return [string]$entry.tier }
        }
    }
    return 'unknown'
}

function Get-RelayFitNote {
    # One line on whether an agent's model suits a kind of work, and who in the room would suit it better. The
    # lightest model that does a job well is the one to give it to; the strongest gets what needs it.
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name, [string]$Work = 'other')
    $wanted = [string](Get-RelayProperty (Get-RelayWorkKind $Work) 'wants' '')
    $rank = @{ light = 1; standard = 2; strong = 3 }
    if (-not $rank.ContainsKey($wanted)) { return '' }
    $agents = @((Get-RelayBoard $Room).agents | Where-Object { $_.isIntroduced -and -not $_.isCoordinator -and $_.state -ne 'retired' })
    $mine = @($agents | Where-Object { $_.name -eq $Name })
    if ($mine.Count -eq 0) { return '' }
    $agent = $mine[0]
    $label = "$($agent.display) ($($agent.model), effort $($agent.effort))"
    if (-not $rank.ContainsKey([string]$agent.tier)) { return "FIT: $Work wants a $wanted model; $label did not give a model name that model-tiers.json knows: judge it yourself." }
    $others = @($agents | Where-Object { $_.name -ne $Name -and $rank.ContainsKey([string]$_.tier) })
    if ($rank[$agent.tier] -lt $rank[$wanted]) {
        $better = @($others | Where-Object { $rank[$_.tier] -ge $rank[$wanted] } | ForEach-Object { "$($_.display) ($($_.model))" })
        if ($better.Count -gt 0) { return "FIT: $Work wants a $wanted model; $label is $($agent.tier). Better suited in this room: $($better -join ', ')." }
        return "FIT: $Work wants a $wanted model; $label is $($agent.tier), and nobody stronger is in this room. Have its work reviewed, or ask the owner for a stronger agent."
    }
    if ($rank[$agent.tier] -gt $rank[$wanted]) {
        $lighter = @($others | Where-Object { $rank[$_.tier] -ge $rank[$wanted] -and $rank[$_.tier] -lt $rank[$agent.tier] } | ForEach-Object { "$($_.display) ($($_.model))" })
        if ($lighter.Count -gt 0) { return "FIT: $Work needs only a $wanted model; $label is $($agent.tier). A lighter one in this room would do: $($lighter -join ', ')." }
        return "FIT: $Work needs only a $wanted model; $label is $($agent.tier). No lighter one is in this room: it will do, at a higher price."
    }
    return "FIT: $label suits $Work (a $wanted model)."
}

function Get-RelayBoard {
    # Everything the coordinator and the owner need to see about a room, as one object
    param([Parameter(Mandatory)]$Room)
    $now = Get-RelayRoomNow $Room
    $messages = @(Get-RelayMessage $Room)
    # Nothing is open with a retired agent: it owes nothing
    $open = @(Get-RelayOpenRequest $messages | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $Room.Canon 'agents') ([string]$_.To)) 'retired') -PathType Leaf) })
    $plan = Read-RelayPlan $Room
    if ($null -ne $plan) {
        # The room's PLAN against this PC's copy, byte for byte: no copy, or another one, is a difference
        $plan | Add-Member -NotePropertyName differs -NotePropertyValue ([bool](Test-RelayPlanDifference $Room))
    }
    $agents = @(Get-RelayAgentState -Room $Room -Now $now -Open $open -Plan $plan -Messages $messages)

    $openRows = New-Object System.Collections.Generic.List[object]
    foreach ($message in $open) {
        $openRows.Add([pscustomobject]@{
                id         = $message.Id
                from       = $message.From
                to         = $message.To
                type       = $message.Type
                subject    = $message.Subject
                expects    = $message.Expects
                ageMinutes = [int][Math]::Max(0, ($now - $message.Time).TotalMinutes)
                # The header names another sender, receiver or number than the file's place does
                mismatch   = [bool]$message.Mismatch
            })
    }
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($card in @(Get-RelayOwnerCard $Room -OpenOnly)) { $cards.Add((ConvertTo-RelayCardRow $card)) }
    $ownerMessages = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($messages | Where-Object { $_.From -eq 'owner' })) {
        $ownerMessages.Add([pscustomobject]@{ id = $message.Id; to = $message.To; subject = $message.Subject; isVerified = ($message.To -eq $Room.Coordinator -and (Test-RelayOwnerMessage $Room $message)) })
    }
    $alarms = @(((Read-RelayText (Join-Path $Room.Local 'alarms.log')) -split "`n") | Where-Object { $_ })
    $recentAlarms = @()
    if ($alarms.Count -gt 0) { $recentAlarms = @($alarms | Select-Object -Last 10) }
    # The last line of the join log says an agent found no free seat, and there is still none
    $turnedAway = ''
    $lastJoin = @(((Read-RelayText (Join-Path $Room.Path 'join.log')) -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($lastJoin.Count -gt 0 -and $lastJoin[0] -match '^(\S+) full \S+ (.+)$' -and @($agents | Where-Object { $_.isFree }).Count -eq 0) { $turnedAway = "$($Matches[1]), from $($Matches[2])" }

    return [pscustomobject]@{
        room                 = $Room.Id
        path                 = $Room.Path
        job                  = (Get-RelayValue $Room.Info 'job' '')
        coordinator          = $Room.Coordinator
        authority            = (Get-RelayValue $Room.Info 'authority' 'within-task')
        isClosed             = $Room.IsClosed
        agents               = @($agents)
        plan                 = $plan
        open                 = @($openRows.ToArray())
        waitingOnCoordinator = @($openRows.ToArray() | Where-Object { $_.to -eq $Room.Coordinator })
        waitingOnOwner       = @($cards.ToArray())
        ownerMessages        = @($ownerMessages.ToArray())
        alarms               = $recentAlarms
        alarmCount           = $alarms.Count
        messageCount         = $messages.Count
        turnedAway           = $turnedAway
    }
}

#endregion

#region Statistics

function Get-RelayMedian {
    param([AllowEmptyCollection()][double[]]$Values = @())
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    return [Math]::Round($sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)], 1)
}

function Get-RelayStatistic {
    # Numbers for the retro: how long answers took, what was asked twice, what the self-audits and the tamper
    # check found, where time was lost. Times are the file server's.
    param([Parameter(Mandatory)]$Room)
    $messages = @(Get-RelayMessage $Room)
    $byId = @{}
    foreach ($message in $messages) { $byId[$message.Id] = $message }
    $byType = [ordered]@{}
    $sentBy = [ordered]@{}
    foreach ($message in $messages) {
        if (-not $byType.Contains($message.Type)) { $byType[$message.Type] = 0 }
        $byType[$message.Type]++
        if (-not $sentBy.Contains($message.From)) { $sentBy[$message.From] = 0 }
        $sentBy[$message.From]++
    }

    # Requests and how long each waited for its result or answer
    $answerTime = @{}
    foreach ($message in $messages) {
        if (@('result', 'answer') -contains $message.Type -and $message.Re) {
            $key = "$($message.From)>$($message.Re)"
            if (-not $answerTime.ContainsKey($key)) { $answerTime[$key] = $message.Time }
        }
    }
    $requests = New-Object System.Collections.Generic.List[object]
    foreach ($message in $messages) {
        if (@('task', 'question', 'proposal') -notcontains $message.Type) { continue }
        $key = "$($message.To)>$($message.Id)"
        $minutes = -1
        if ($answerTime.ContainsKey($key)) { $minutes = [Math]::Round([Math]::Max(0, ($answerTime[$key] - $message.Time).TotalMinutes), 1) }
        $requests.Add([pscustomobject]@{ id = $message.Id; type = $message.Type; from = $message.From; to = $message.To; subject = $message.Subject; minutes = $minutes })
    }
    $answered = @($requests | Where-Object { $_.minutes -ge 0 })
    $byResponder = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($answered | Group-Object to)) {
        $values = [double[]]@($group.Group | ForEach-Object { $_.minutes })
        $byResponder.Add([pscustomobject]@{ agent = $group.Name; answered = $group.Count; medianMinutes = (Get-RelayMedian $values); maxMinutes = ($values | Measure-Object -Maximum).Maximum })
    }
    $waitedOnCoordinator = 0.0
    foreach ($request in @($answered | Where-Object { $_.to -eq $Room.Coordinator })) { $waitedOnCoordinator += $request.minutes }

    # Cards: how long the owner was waited for
    $waitedOnOwner = 0.0
    $cards = @(Get-RelayOwnerCard $Room)
    foreach ($card in $cards) {
        $answer = Read-RelayKeyValue ([System.IO.Path]::ChangeExtension($card.Path, '.answer'))
        $sent = [DateTime]::MinValue
        $at = [DateTime]::MinValue
        $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal
        if ([DateTime]::TryParse($card.SentUtc, [System.Globalization.CultureInfo]::InvariantCulture, $style, [ref]$sent) -and [DateTime]::TryParse((Get-RelayValue $answer 'at_utc' ''), [System.Globalization.CultureInfo]::InvariantCulture, $style, [ref]$at)) {
            $waitedOnOwner += [Math]::Max(0, ($at - $sent).TotalMinutes)
        }
    }

    # The same question twice from the same agent
    $repeats = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($messages | Where-Object { $_.Type -eq 'question' } | Group-Object { "$($_.From)|" + (($_.Subject.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim()) } | Where-Object { $_.Count -gt 1 })) {
        $repeats.Add([pscustomobject]@{ from = $group.Group[0].From; subject = $group.Group[0].Subject; times = $group.Count; ids = (@($group.Group | ForEach-Object { $_.Id }) -join ', ') })
    }

    # Per agent: what its journal and its delivery record say
    $agents = New-Object System.Collections.Generic.List[object]
    $duplicateDeliveries = 0
    $byes = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-RelayRoster $Room -IncludeRetired)) {
        $dir = Join-Path (Join-Path $Room.Path 'agents') $name
        $journal = @(((Read-RelayText (Join-Path $dir 'journal')) -split "`n") | Where-Object { $_ })
        $count = @{}
        foreach ($line in $journal) {
            $parts = @($line -split ' ')
            if ($parts.Count -ge 2) { if (-not $count.ContainsKey($parts[1])) { $count[$parts[1]] = 0 }; $count[$parts[1]]++ }
        }
        $delivered = @(((Read-RelayText (Join-Path $dir 'delivered')) -split "`n") | Where-Object { $_ } | ForEach-Object { ($_ -split ' ')[0] })
        $duplicates = $delivered.Count - @($delivered | Sort-Object -Unique).Count
        $duplicateDeliveries += $duplicates
        $numbers = @{}
        foreach ($key in 'start', 'timeout', 'parked', 'second-wait', 'coordinator-silent', 'proposal-due') { $numbers[$key] = 0; if ($count.ContainsKey($key)) { $numbers[$key] = $count[$key] } }
        $sentCount = 0
        if ($sentBy.Contains($name)) { $sentCount = $sentBy[$name] }
        $agents.Add([pscustomobject]@{
                agent              = $name
                sent               = $sentCount
                received           = $delivered.Count
                sessions           = $numbers['start']
                waitTimeouts       = $numbers['timeout']
                parked             = $numbers['parked']
                secondWaits        = $numbers['second-wait']
                coordinatorSilent  = $numbers['coordinator-silent']
                proposalsProceeded = $numbers['proposal-due']
                redelivered        = $duplicates
            })
    }
    foreach ($message in @($messages | Where-Object { $_.Type -eq 'bye' })) { $byes.Add([pscustomobject]@{ from = $message.From; subject = $message.Subject; text = $message.Body }) }

    # Scope: what the self-audits flagged, and what the tamper check found
    $outside = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($messages | Where-Object { $_.Type -eq 'result' })) {
        if ($message.Body -match 'self-audit: ([0-9]+) changed since start, ([0-9]+) OUTSIDE') {
            # A number that does not fit counts as 0
            $flagged = 0
            if ([int]::TryParse($Matches[2], [ref]$flagged) -and $flagged -gt 0) { $outside.Add([pscustomobject]@{ id = $message.Id; from = $message.From; outside = $flagged }) }
        }
    }
    $alarms = @(((Read-RelayText (Join-Path $Room.Local 'alarms.log')) -split "`n") | Where-Object { $_ })

    $minutesTotal = 0
    if ($messages.Count -gt 1) { $minutesTotal = [Math]::Round(($messages[-1].Time - $messages[0].Time).TotalMinutes, 1) }
    $slowest = @($answered | Sort-Object minutes -Descending | Select-Object -First 5)
    $allMinutes = [double[]]@($answered | ForEach-Object { $_.minutes })
    $maxMinutes = 0
    if ($allMinutes.Count -gt 0) { $maxMinutes = ($allMinutes | Measure-Object -Maximum).Maximum }
    return [pscustomobject]@{
        room                       = $Room.Id
        job                        = (Get-RelayValue $Room.Info 'job' '')
        package                    = (Get-RelayValue $Room.Info 'package' '')
        minutesFromFirstToLast     = $minutesTotal
        messages                   = $messages.Count
        byType                     = $byType
        requests                   = $requests.Count
        answered                   = $answered.Count
        unanswered                 = ($requests.Count - $answered.Count)
        replyMedianMinutes         = (Get-RelayMedian $allMinutes)
        replyMaxMinutes            = $maxMinutes
        byResponder                = @($byResponder.ToArray())
        slowest                    = $slowest
        waitedOnCoordinatorMinutes = [Math]::Round($waitedOnCoordinator, 1)
        waitedOnOwnerMinutes       = [Math]::Round($waitedOnOwner, 1)
        ownerCards                 = $cards.Count
        repeatedQuestions          = @($repeats.ToArray())
        redelivered                = $duplicateDeliveries
        reportsWithChangesOutside  = @($outside.ToArray())
        alarms                     = $alarms.Count
        agents                     = @($agents.ToArray())
        byes                       = @($byes.ToArray())
    }
}

#endregion

#region Names and agent kinds

function Get-RelayAgentKind {
    # The profile of one agent kind from agent-kinds.json; unknown kinds get the generic profile
    param([string]$Kind = 'generic')
    $all = Get-RelayJsonTable 'agent-kinds.json'
    $kindProfile = $all.PSObject.Properties[$Kind]
    if ($null -eq $kindProfile) { $kindProfile = $all.PSObject.Properties['generic'] }
    return $kindProfile.Value
}

function Get-RelayWorkKind {
    # The method lines and report shape for one kind of work from work-kinds.json
    param([string]$Work = 'other')
    $all = Get-RelayJsonTable 'work-kinds.json'
    $entry = $all.PSObject.Properties[$Work]
    if ($null -eq $entry) { throw ("The kind of work '$Work' is not one of " + ((@($all.PSObject.Properties | ForEach-Object { $_.Name })) -join ', ')) }
    return $entry.Value
}

function Select-RelayName {
    # A name for one seat. The same machine and role keeps its name across jobs; in one room every name starts
    # with a different letter. The registry of names (names.json) is written back whole, so one that exists and
    # cannot be read or parsed is an error, never an empty registry.
    param([Parameter(Mandatory)][string]$Machine, [Parameter(Mandatory)][string]$Role, [string[]]$Taken = @(), [string]$Wanted = '')
    $pool = Get-RelayJsonTable 'relay-names.json'
    $registryPath = Join-Path (Get-RelayLocalRoot) 'names.json'
    $registry = @{}
    $registryText = Read-RelayTextStrict $registryPath
    if ($registryText.Trim()) {
        $parsed = $null
        try { $parsed = ConvertFrom-RelayJson $registryText }
        catch { throw "The name registry of this PC cannot be parsed, it is not written over: $registryPath ($($_.Exception.Message))" }
        foreach ($property in $parsed.PSObject.Properties) { $registry[$property.Name] = [string]$property.Value }
    }
    $key = ('{0}|{1}' -f $Machine.Trim().ToLowerInvariant(), $Role.Trim().ToLowerInvariant())
    $usedLetters = @{}
    foreach ($name in @($Taken)) { if ($name) { $usedLetters[$name.Substring(0, 1).ToLowerInvariant()] = $true } }
    $avoid = @{}
    foreach ($name in @($pool.avoid)) { $avoid[([string]$name).ToLowerInvariant()] = $true }

    $choice = ''
    $candidate = $Wanted.Trim().ToLowerInvariant()
    if ($candidate) {
        if ($candidate -notmatch $script:NamePattern) { throw "'$Wanted' cannot be an agent name: lower-case letters and digits, 2 to 16 characters" }
        # Words the room tool takes as something else when they stand where a name can stand
        if (@('owner', 'all', 'approve', 'deny', 'open', 'rules', 'new', 'off') -contains $candidate) { throw "'$Wanted' is reserved: the room tool reads it as a word of its commands, never as a name" }
        if ($usedLetters.ContainsKey($candidate.Substring(0, 1))) { throw "'$Wanted' starts with a letter another agent of this room already has" }
        $choice = $candidate
    }
    if (-not $choice -and $registry.ContainsKey($key)) {
        $candidate = $registry[$key]
        if (-not $usedLetters.ContainsKey($candidate.Substring(0, 1))) { $choice = $candidate }
    }
    if (-not $choice) {
        # Pass 1: a free first letter and a name no other seat owns. Pass 2: a free first letter. Pass 3: a room
        # with more agents than letters shares letters. After that: a pool name with a number. No upper limit.
        $owned = @{}
        foreach ($value in $registry.Values) { $owned[$value] = $true }
        $takenNames = @{}
        foreach ($name in @($Taken)) { if ($name) { $takenNames[$name.ToLowerInvariant()] = $true } }
        foreach ($pass in 1, 2, 3) {
            foreach ($name in @($pool.names)) {
                $candidate = ([string]$name).ToLowerInvariant()
                if ($avoid.ContainsKey($candidate) -or $takenNames.ContainsKey($candidate)) { continue }
                if ($pass -le 2 -and $usedLetters.ContainsKey($candidate.Substring(0, 1))) { continue }
                if ($pass -eq 1 -and $owned.ContainsKey($candidate)) { continue }
                $choice = $candidate
                break
            }
            if ($choice) { break }
        }
        for ($suffix = 2; -not $choice -and $suffix -lt 1000; $suffix++) {
            foreach ($name in @($pool.names)) {
                $candidate = ([string]$name).ToLowerInvariant() + $suffix
                if ($candidate -match $script:NamePattern -and -not $takenNames.ContainsKey($candidate)) { $choice = $candidate; break }
            }
        }
    }
    if (-not $choice) { throw 'The name pool is exhausted' }
    $registry[$key] = $choice
    $ordered = [ordered]@{}
    foreach ($entry in ($registry.Keys | Sort-Object)) { $ordered[$entry] = $registry[$entry] }
    Write-RelayTextAtomic $registryPath ((ConvertTo-Json -InputObject $ordered -Depth 3) + "`n")
    return $choice
}

function Get-RelayCallLine {
    # The command prefix an agent types, for the shell it calls from and the room path as that agent sees it. The
    # coordinator's call line is its launcher on this PC: -Launcher names the folder that holds relay.ps1 and relay.cmd.
    param([Parameter(Mandatory)][string]$RoomPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Generation, [string]$Shell = 'powershell', [string]$Launcher = '')
    $base = $RoomPath.TrimEnd('\', '/')
    Assert-RelayPastePath $base 'The room folder'
    if ($Launcher) {
        $folder = $Launcher.TrimEnd('\', '/')
        Assert-RelayPastePath $folder 'The folder of the launcher'
        if ($Shell -eq 'cmd') { return '"' + $folder + '\relay.cmd"' }
        $wrapper = "$folder\relay.ps1"
        if ($Shell -eq 'bash') { $wrapper = $wrapper -replace '\\', '/'; return ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-RelayShellLiteral $wrapper)) }
        return ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-RelayPowerShellLiteral $wrapper))
    }
    if ($Shell -eq 'sh') {
        $wrapper = "$base/agents/$Name/g$Generation/relay"
        # A leading ~ only expands outside quotes
        if ($wrapper -match '^[A-Za-z0-9_./~-]+$') { return "sh $wrapper" }
        return ('sh ' + (ConvertTo-RelayShellLiteral $wrapper))
    }
    $wrapper = "$base\agents\$Name\g$Generation\relay.cmd"
    if ($Shell -eq 'cmd') { return '"' + $wrapper + '"' }
    # PowerShell and Git Bash start the .ps1 wrapper with powershell -File: no cmd.exe in between, so the
    # caller's working folder survives even when it is on a share (cmd.exe cannot stand in one)
    $wrapper = "$base\agents\$Name\g$Generation\relay.ps1"
    if ($Shell -eq 'bash') { $wrapper = $wrapper -replace '\\', '/'; return ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-RelayShellLiteral $wrapper)) }
    return ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-RelayPowerShellLiteral $wrapper))
}
#endregion

#region Seats

function Expand-RelayTemplate {
    # Every {{KEY}} of the template replaced by its value, all in one pass: a value that holds {{ANOTHER}} (text
    # that came from the room, for example) stays as it is. A key the values do not name stays in the text; keys
    # are compared with regard to case.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    foreach ($key in $Values.Keys) { $map[[string]$key] = [string]$Values[$key] }
    return [regex]::Replace($Text, '\{\{([A-Za-z0-9_]+)\}\}', {
            param($match)
            $name = $match.Groups[1].Value
            if ($map.ContainsKey($name)) { return $map[$name] }
            return $match.Value
        })
}

function ConvertTo-RelayBulletList {
    param($Items, [string]$Empty = '(nothing listed)')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Items)) { if ($null -ne $item -and ([string]$item).Trim()) { $lines.Add('- ' + ([string]$item).Trim()) } }
    if ($lines.Count -eq 0) { return $Empty }
    return ($lines -join "`n")
}

function ConvertTo-RelaySeatSpec {
    # One agent of an answers file with every default filled in from its agent kind
    param(
        [Parameter(Mandatory)]$Agent, [Parameter(Mandatory)][string]$RoomId, [Parameter(Mandatory)][string]$DevRoomPath,
        # The room folder as other machines reach it (the server by address); the path on this PC when left out
        [string]$RemoteRoomPath = ''
    )
    $kindName = [string](Get-RelayProperty $Agent 'kind' 'generic')
    $kind = Get-RelayAgentKind $kindName
    $transport = [string](Get-RelayProperty $Agent 'transport' 'same-pc')
    if (@('same-pc', 'share', 'ssh') -notcontains $transport) { throw "Transport '$transport' is not one of same-pc, share, ssh" }
    if ($transport -eq 'ssh') { throw 'the SSH bridge is not built yet: use share or same-pc' }
    $os = [string](Get-RelayProperty $Agent 'os' '')
    if (-not $os) { $os = 'windows'; if ($transport -eq 'ssh') { $os = 'linux' } }
    if (@('windows', 'linux') -notcontains $os) { throw "OS '$os' is not one of windows, linux" }
    $shell = [string](Get-RelayProperty $Agent 'shell' (Get-RelayProperty $kind.shell $os 'powershell'))
    if ($os -eq 'linux') { $shell = 'sh' }
    if (@('powershell', 'cmd', 'bash', 'sh') -notcontains $shell) { throw "Shell '$shell' is not one of powershell, cmd, bash, sh" }
    $wake = [string](Get-RelayProperty $Agent 'wake' $kind.wake)
    if (@('background', 'loop', 'manual') -notcontains $wake) { throw "Wake mode '$wake' is not one of background, loop, manual" }
    $roomPath = [string](Get-RelayProperty $Agent 'room_path' '')
    $sshTarget = ''
    $sshRemoteRoom = ''
    if ($transport -eq 'ssh') {
        $ssh = Get-RelayProperty $Agent 'ssh' $null
        $sshTarget = [string](Get-RelayProperty $ssh 'target' '')
        if ($sshTarget -notmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$' -and $sshTarget -notmatch '^[A-Za-z0-9._-]+$') { throw "An ssh agent needs ssh.target as user@host or a host alias, not '$sshTarget'" }
        $remoteRoot = [string](Get-RelayProperty $ssh 'remote_root' '~/agent-relay')
        if ($remoteRoot -notmatch '^[A-Za-z0-9_./~-]+$') { throw "ssh.remote_root may hold letters, digits and . _ / ~ - only, not '$remoteRoot'" }
        $sshRemoteRoom = $remoteRoot.TrimEnd('/') + '/' + $RoomId
        if (-not $roomPath) { $roomPath = $sshRemoteRoom }
    }
    if (-not $roomPath) {
        $roomPath = $DevRoomPath
        # A machine on another subnet may not resolve the server's name: it gets the address
        if ($transport -eq 'share') { $roomPath = Resolve-RelayRemotePath $DevRoomPath; if ($RemoteRoomPath) { $roomPath = $RemoteRoomPath } }
    }
    $machine = [string](Get-RelayProperty $Agent 'machine' '')
    if (-not $machine) { $machine = [Environment]::MachineName; if ($sshTarget) { $machine = $sshTarget } }
    # The same for an ssh target: user@name becomes user@address; an alias the ssh configuration knows stays
    if ($sshTarget -match '^(?:([A-Za-z0-9._-]+)@)?([A-Za-z0-9._-]+)$') {
        $sshUser = [string]$Matches[1]
        $sshHost = Resolve-RelayHostAddress $Matches[2]
        $sshTarget = $sshHost
        if ($sshUser) { $sshTarget = "$sshUser@$sshHost" }
    }
    # A machine is disposable only when the owner said so for this job. Nothing else sets it: not the machine's
    # name, not an earlier job, not the list of known machines.
    $machineCare = [string](Get-RelayProperty $Agent 'machine_care' 'in-use')
    if (@('in-use', 'disposable') -notcontains $machineCare) { throw "machine_care '$machineCare' is not one of in-use, disposable" }
    return [ordered]@{
        wanted_name     = [string](Get-RelayProperty $Agent 'name' '')
        role            = [string](Get-RelayProperty $Agent 'role' 'agent')
        machine         = $machine
        machine_care    = $machineCare
        machine_notes   = [string](Get-RelayProperty $Agent 'machine_notes' '')
        expect_computer = [string](Get-RelayProperty $Agent 'computer' '')
        work            = [string](Get-RelayProperty $Agent 'work' 'other')
        expertise       = @(Get-RelayProperty $Agent 'expertise' @())
        standards       = @(Get-RelayProperty $Agent 'standards' @())
        doc_tools       = @(Get-RelayProperty $Agent 'doc_tools' @())
        kind            = $kindName
        transport       = $transport
        os              = $os
        shell           = $shell
        wake            = $wake
        wait_minutes    = [int](Get-RelayProperty $Agent 'wait_minutes' $kind.wait_minutes)
        park_after      = [int](Get-RelayProperty $Agent 'park_after' $kind.park_after)
        draft           = [string](Get-RelayProperty $Agent 'draft' $kind.draft)
        prompt_extra    = [string]$kind.prompt_extra
        room_path       = $roomPath
        ssh_target      = $sshTarget
        ssh_remote_room = $sshRemoteRoom
        task            = [string](Get-RelayProperty $Agent 'task' '(the coordinator sends your first task as a message)')
        done_when       = [string](Get-RelayProperty $Agent 'done_when' '(stated in each task)')
        non_goals       = @(Get-RelayProperty $Agent 'non_goals' @())
        roots           = @(Get-RelayProperty $Agent 'roots' @())
        may             = @(Get-RelayProperty $Agent 'may' @())
        propose_ok      = @(Get-RelayProperty $Agent 'propose_ok' @())
        ask_first       = @(Get-RelayProperty $Agent 'ask_first' @())
        never           = @(Get-RelayProperty $Agent 'never' @())
    }
}

function Get-RelayStartPrompt {
    # What the owner pastes into the agent's session: who it is and the one command to run. The coordinator's call
    # is its launcher on this PC (-Launcher: the folder that holds it).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [int]$Generation = 1, [string]$Launcher = '')
    $display = ConvertTo-RelayDisplayName $Name
    # For PowerShell the path is written with forward slashes: the same line then works in Git Bash too. Not for
    # a path with a character PowerShell takes for a single quote: quoted for sh, it would end the string there.
    $shell = [string]$Spec['shell']
    $isDual = ($shell -eq 'powershell' -and -not (Test-RelayPowerShellQuote ([string]$Spec['room_path'])) -and -not $Launcher)
    if ($isDual) { $shell = 'bash' }
    $call = Get-RelayCallLine -RoomPath $Spec['room_path'] -Name $Name -Generation ([string]$Generation) -Shell $shell -Launcher $Launcher
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("You are $display, the $($Spec['role']) on a job that several coding agents work on for the same owner. Your instructions are in a shared folder, the `"room`". Run this one command now. Replace the three words at the end with your agent product as exactly as you know it (for example claude-code-cli or codex-cli), your model, and your reasoning effort setting if your session shows one; write unknown where you do not know:")
    $lines.Add('')
    $lines.Add("$call start <product> <model> <effort>")
    $lines.Add('')
    if ($isDual) {
        $lines.Add('The line works as it is in PowerShell and in Git Bash.')
        $lines.Add('')
    }
    $lines.Add('It prints who you are, your assignment with its limits, and what to do next. From then on every command you run there ends with a NEXT: line: do what it says. Stay inside your assignment and ask before anything beyond it. Never type message text on the command line: the output tells you which file to write it into.')
    if ($Spec['prompt_extra']) { $lines.Add(''); $lines.Add([string]$Spec['prompt_extra']) }
    if ($Generation -gt 1) { $lines.Add(''); $lines.Add("You take over from an earlier session of $display that has ended. The start command prints the requests it left open: continue from there, and do not redo what its messages already report as done.") }
    return ($lines -join "`n") + "`n"
}

function Add-RelayAgentSeat {
    # Writes everything this PC provides for one generation of one agent, canonical copy first, and returns the
    # start prompt for that agent
    param(
        [Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Spec,
        [int]$Generation = 1, [switch]$IsCoordinator,
        # The same session gets a new assignment: its generation, its pause or stop state and its prompt stay
        [switch]$Reassign
    )
    $display = ConvertTo-RelayDisplayName $Name
    $base = "agents/$Name"
    $coordinatorDisplay = ConvertTo-RelayDisplayName $Room.Coordinator
    $launcher = ''
    if ($IsCoordinator) { $launcher = $Room.Local }
    $call = Get-RelayCallLine -RoomPath $Spec['room_path'] -Name $Name -Generation ([string]$Generation) -Shell $Spec['shell'] -Launcher $launcher
    $separator = '\'
    if ($Spec['os'] -eq 'linux') { $separator = '/' }
    # An open seat: nobody is named for it. The agent that takes it with join says what it is, and its tool
    # fills in what depends on that (how it is called, how it waits, where its draft is).
    $isOpen = ($Spec.Contains('open') -and [bool]$Spec['open'])

    $seat = [ordered]@{
        name            = $Name
        display         = $display
        role            = $Spec['role']
        machine         = $Spec['machine']
        machine_care    = $Spec['machine_care']
        expect_computer = $Spec['expect_computer']
        transport       = $Spec['transport']
        kind            = $Spec['kind']
        os              = $Spec['os']
        shell           = $Spec['shell']
        wake            = $Spec['wake']
        wait_minutes    = $Spec['wait_minutes']
        park_after      = $Spec['park_after']
        draft           = ([string]$Spec['draft']).Replace('{name}', $Name)
        room_path       = $Spec['room_path']
        ssh_target      = $Spec['ssh_target']
        ssh_remote_room = $Spec['ssh_remote_room']
    }
    if ($isOpen) { $seat['open'] = 'yes'; $seat['order'] = [string]$Spec['order'] }
    Write-RelayGuardedText $Room "$base/seat" (ConvertTo-RelayKeyValueText $seat)
    if (-not $Reassign) {
        Write-RelayGuardedText $Room "$base/gen" "$Generation`n"
        Write-RelayGuardedText $Room "$base/control" "state: run`nnote: `n"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Room.Canon "$base/lines"))) { Write-RelayGuardedText $Room "$base/lines" '' }

    $scope = New-Object System.Collections.Generic.List[string]
    $rootLines = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($Spec['roots'])) {
        $folder = [string](Get-RelayProperty $root 'root' '')
        if (-not $folder) { continue }
        $scope.Add("root: $folder")
        $patterns = @(Get-RelayProperty $root 'may' @())
        foreach ($pattern in $patterns) { $scope.Add("may: $pattern") }
        if ($patterns.Count -gt 0) { $rootLines.Add("- ``$folder``: you may change " + ((@($patterns | ForEach-Object { "``$_``" })) -join ', ') + '. The rest of this folder is read-only for you.') }
        else { $rootLines.Add("- ``$folder``: read-only for you.") }
    }
    $scopeText = ''
    if ($scope.Count -gt 0) { $scopeText = ($scope -join "`n") + "`n" }
    Write-RelayGuardedText $Room "$base/scope" $scopeText
    $rootsText = 'No work folder is assigned: your tasks say where to look.'
    if ($rootLines.Count -gt 0) { $rootsText = ($rootLines -join "`n") + "`n`nEverything outside these folders is off limits unless a list below says otherwise." }

    $waitLine = 'Run it as a background command: its exit wakes you.'
    if ($Spec['wake'] -eq 'loop') { $waitLine = "It returns within $($Spec['wait_minutes']) minute(s); when it says nothing arrived, run it again." }
    if ($Spec['wake'] -eq 'manual') { $waitLine = 'Do not wait: run `check` when the owner tells you to look.' }
    $agentFolder = $Spec['room_path'].TrimEnd('\', '/') + $separator + 'agents' + $separator + $Name
    $draftText = $agentFolder + $separator + 'draft.md'
    # A draft kept in the working folder carries the agent's name: two agents may share that folder
    $draftName = ([string]$Spec['draft']).Replace('{name}', $Name)
    if ($draftName) { $draftText = "$draftName   (in your working folder)" }
    # The coordinator's draft is a file on this PC, next to its launcher: nobody else can put a text there
    if ($IsCoordinator) { $draftText = Join-Path $Room.Local 'draft.md' }
    # The machine of an open seat has no name until the agent on it has introduced itself
    $machineLabel = "``$($Spec['machine'])``"
    if (([string]$Spec['machine']).StartsWith('(', [System.StringComparison]::Ordinal)) { $machineLabel = 'the machine you run on' }
    $machineCare = "**" + $machineLabel.Substring(0, 1).ToUpperInvariant() + $machineLabel.Substring(1) + " is a machine in use. It is not a test machine.** Treat everything on it that your task does not name as somebody's working state. Without the owner's approval (ask first) you do not: restart it or shut it down; install, update or remove software; change system settings, services, features, drivers, scheduled tasks, firewall or network settings; stop processes you did not start; delete or move files outside your assigned paths."
    if ($Spec['machine_care'] -eq 'disposable') {
        $machineCare = "**The owner has declared $machineLabel disposable for this job, and for this job only.** You may change it as the task needs. This says nothing about any other machine or any later job. Before a restart, say what you are about to do, so that no other agent working on it is cut off."
    }
    if ($Spec['machine_notes']) { $machineCare += "`n`nFrom the owner about this machine: $($Spec['machine_notes'])" }

    # Role and method: concrete and checkable. What steers an agent is the standards it must follow, the
    # habit of verifying, and the checks to run before reporting; praise for its skill does not.
    $work = Get-RelayWorkKind $Spec['work']
    $persona = "You work on this job as its **$($Spec['role'])**."
    $field = @($Spec['expertise'] | Where-Object { $_ })
    if ($field.Count -gt 0) { $persona += ' Your field here: ' + ($field -join ', ') + '.' }
    $persona += ' You are the expert for this part of the job, and what marks an expert here is checking instead of guessing and getting it right the first time, not speed.'
    $method = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($work.method)) { $method.Add([string]$line) }
    $standards = @($Spec['standards'] | Where-Object { $_ })
    if ($standards.Count -gt 0) { $method.Add('These standards outrank your habits. Read them before you start: ' + ((@($standards | ForEach-Object { "``$_``" })) -join ', ') + '.') }
    $docTools = @($Spec['doc_tools'] | Where-Object { $_ })
    $verify = 'Verify before you assert. When you are not sure how an API, a command, a library or a tool behaves, look it up or try it before you build on it.'
    if ($docTools.Count -gt 0) { $verify += ' You have ' + ($docTools -join ' and ') + ' for this: use them.' }
    else { $verify += ' Use whatever documentation tool you have: a documentation server, web search, the built-in help.' }
    $method.Add($verify)
    $method.Add('Say what you could not verify: write `not verified:` in front of it in your report. A guess presented as a fact is the one thing a report must not contain.')
    $method.Add('Before you report, run the checks named under "Done when" and read your own work once more.')
    $reportLines = New-Object System.Collections.Generic.List[string]
    $position = 0
    foreach ($line in @($work.report)) { $position++; $reportLines.Add("$position. $line") }
    $values = [ordered]@{
        DISPLAY             = $display
        NAME                = $Name
        GEN                 = [string]$Generation
        ROOM_ID             = $Room.Id
        ROOM_PATH           = $Spec['room_path']
        JOB                 = (Get-RelayValue $Room.Info 'job' '')
        AUTHORITY           = (Get-RelayValue $Room.Info 'authority' 'within-task')
        COORDINATOR_DISPLAY = $coordinatorDisplay
        CALL                = $call
        DRAFT               = $draftText
        ATTACH              = ($agentFolder + $separator + 'attach')
        WAIT_LINE           = $waitLine
        ROLE                = $Spec['role']
        TASK                = $Spec['task']
        DONE_WHEN           = $Spec['done_when']
        MACHINE_CARE        = $machineCare
        PERSONA             = $persona
        METHOD              = (ConvertTo-RelayBulletList $method.ToArray())
        REPORT              = ($reportLines -join "`n")
        NON_GOALS          = (ConvertTo-RelayBulletList $Spec['non_goals'] '(nothing listed: when in doubt whether something belongs to the task, it does not)')
        ROOTS               = $rootsText
        MAY                 = (ConvertTo-RelayBulletList $Spec['may'] '- What the task plainly needs inside the assigned paths, and reading anything you need to understand it.')
        PROPOSE_OK          = (ConvertTo-RelayBulletList $Spec['propose_ok'] '(nothing: ask first instead)')
        ASK_FIRST           = (ConvertTo-RelayBulletList $Spec['ask_first'] '- Everything the START-HERE list "Ask first" names.')
        NEVER               = (ConvertTo-RelayBulletList $Spec['never'] '- Push, publish, deploy or send anything outside this room.
- Read, print or pass on a password, key, token or code.
- Change another agent''s files, or anything in the room folder except your draft and attach folder.')
        FILE_NOTE           = ''
    }
    # A seat nobody is named for: how its agent calls the tool is known only when it does, so the tool fills these
    # in when it prints the text. An agent that opens the file itself is told so.
    if ($isOpen) {
        foreach ($key in 'CALL', 'DRAFT', 'ATTACH', 'WAIT_LINE', 'ROOM_PATH') { $values[$key] = '{{' + $key + '}}' }
        $values['FILE_NOTE'] = ' (In the file itself some commands and paths stand in double braces: your command fills them in when it prints this text, so read it with `start`.)'
    }
    $startTemplate = 'START-HERE.md.tmpl'
    $assignmentTemplate = 'ASSIGNMENT.md.tmpl'
    if ($IsCoordinator) { $startTemplate = 'COORDINATOR.md.tmpl'; $assignmentTemplate = '' }
    Write-RelayGuardedText $Room "$base/START-HERE.md" (Expand-RelayTemplate (Read-RelayTemplate $startTemplate) $values)
    if ($assignmentTemplate) { Write-RelayGuardedText $Room "$base/ASSIGNMENT.md" (Expand-RelayTemplate (Read-RelayTemplate $assignmentTemplate) $values) }
    Write-RelaySeatWrapper -Room $Room -Name $Name -Generation ([string]$Generation)
    foreach ($folder in 'inbox', 'attach') {
        $path = Join-Path (Join-Path (Join-Path $Room.Path 'agents') $Name) $folder
        if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType Directory -Path $path -Force }
    }
    # The first session of an open seat comes in through the join prompt, which is the same for every agent
    $prompt = ''
    if (-not $Reassign -and -not ($isOpen -and $Generation -eq 1)) {
        $prompt = Get-RelayStartPrompt -Name $Name -Spec $Spec -Generation $Generation -Launcher $launcher
        # The coordinator's prompt stays on this PC: it names the launcher, which lies nowhere else
        if (-not $IsCoordinator) { Write-RelayGuardedText $Room "PROMPT-$Name.txt" $prompt }
        Write-RelayText (Join-Path (Join-Path $Room.Local 'prompts') "PROMPT-$Name-g$Generation.txt") $prompt
    }
    if ($IsCoordinator) { Write-RelayLauncher -Room $Room -Name $Name -Generation ([string]$Generation) }
    # The answers this seat was built from stay on this PC, so a replacement session gets the same assignment
    $kept = [ordered]@{}
    foreach ($key in $Spec.Keys) { $kept[[string]$key] = $Spec[$key] }
    Write-RelayText (Join-Path (Join-Path $Room.Local 'specs') "$Name.json") ((ConvertTo-Json -InputObject $kept -Depth 8) + "`n")
    return $prompt
}

function Write-RelayLauncher {
    # The coordinator's launcher pair, relay.ps1 and relay.cmd, in this PC's own folder of the room: it runs the
    # tool of the canonical copy, not the one in the room, where every agent can write. Only relay.ps1 names the
    # room folder, and it is written with a BOM: Windows PowerShell 5.1 reads a script without one in the ANSI
    # code page, which garbles a folder with a letter outside ASCII. relay.cmd holds no path at all (cmd reads a
    # batch file in the OEM code page) and hands over to relay.ps1 next to it.
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Generation)
    Assert-RelayPastePath $Room.Path 'The room folder'
    $quoted = ConvertTo-RelayPowerShellLiteral $Room.Path
    $values = @{
        DISPLAY      = (ConvertTo-RelayDisplayName $Name)
        NAME         = $Name
        GEN          = $Generation
        ROOM_ID      = $Room.Id
        # The room folder inside single quotes: every quote of it doubled
        ROOM_PATH_PS = $quoted.Substring(1, $quoted.Length - 2)
    }
    Write-RelayText (Join-Path $Room.Local 'relay.cmd') (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\coordinator.cmd.tmpl') $values) -Crlf
    Write-RelayText (Join-Path $Room.Local 'relay.ps1') (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\coordinator.ps1.tmpl') $values) -Bom
}
function Write-RelayKindTable {
    # tools/kinds in the room: how each agent kind waits, as key: value lines the room tools read. The agent on
    # a seat taken with join names its product only when it arrives.
    param([Parameter(Mandatory)]$Room)
    $all = Get-RelayJsonTable 'agent-kinds.json'
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($kind in $all.PSObject.Properties) {
        $lines.Add("$($kind.Name).wake: $($kind.Value.wake)")
        $lines.Add("$($kind.Name).wait_minutes: $($kind.Value.wait_minutes)")
        $lines.Add("$($kind.Name).park_after: $($kind.Value.park_after)")
        $lines.Add("$($kind.Name).draft: $($kind.Value.draft)")
        $lines.Add("$($kind.Name).hint: " + (ConvertTo-RelayHeaderText ([string]$kind.Value.prompt_extra)))
    }
    Write-RelayGuardedText $Room 'tools/kinds' (($lines -join "`n") + "`n")
}

function Write-RelayJoinWrapper {
    # The room's join commands, one per way of calling: join.ps1 (powershell -File), join.cmd, join (sh)
    param([Parameter(Mandatory)]$Room)
    $values = @{ ROOM_ID = $Room.Id }
    Write-RelayGuardedText $Room 'join.cmd' (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\join.cmd.tmpl') $values) -Crlf
    Write-RelayGuardedText $Room 'join.ps1' (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\join.ps1.tmpl') $values)
    Write-RelayGuardedText $Room 'join' (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\join.tmpl') $values)
}

function Write-RelaySeatWrapper {
    # The wrappers of one generation of one agent, from the package's templates: -Generation, or the current one
    # of this PC's copy when it is left out
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name, [string]$Generation = '')
    $number = $Generation
    if (-not $number) { $number = (Read-RelayText (Join-Path $Room.Canon "agents/$Name/gen")).Trim() }
    if ($number -notmatch '^[0-9]+$') { return }
    $values = @{ DISPLAY = (ConvertTo-RelayDisplayName $Name); NAME = $Name; GEN = $number; ROOM_ID = $Room.Id }
    Write-RelayGuardedText $Room "agents/$Name/g$number/relay.cmd" (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\relay.cmd.tmpl') $values) -Crlf
    Write-RelayGuardedText $Room "agents/$Name/g$number/relay.ps1" (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\relay.ps1.tmpl') $values)
    Write-RelayGuardedText $Room "agents/$Name/g$number/relay" (Expand-RelayTemplate (Read-RelayTemplate 'wrappers\relay.tmpl') $values)
}

function Get-RelayJoinPrompt {
    # What the owner pastes into every agent that should join the room: the same text for all of them
    param([Parameter(Mandatory)]$Room)
    # Every address in the prompt is the one other machines reach: a share's server by its address, not its name
    $base = (Get-RelayReachPath $Room).TrimEnd('\', '/')
    Assert-RelayPastePath $base 'The room folder'
    $forward = $base -replace '\\', '/'
    $shellFolder = $forward
    if ($base.StartsWith('\\', [System.StringComparison]::Ordinal) -or $base -match '^[A-Za-z]:') { $shellFolder = '<this folder as your machine reaches it>' }
    $lines = @(
        'You are asked to join a work room: a shared folder through which several coding agents work on one job for the same owner. Another agent, the coordinator, hands out the tasks and answers questions.'
        ''
        "Room folder: $base"
        ''
        '1. Run ONE of these now, the one for your shell. The three words at the end say what you are: your agent product as exactly as you know it (claude-code-cli, codex-cli, codex-app, gemini-cli, cursor-agent, copilot-cli, or its name as one word), your model, and your reasoning effort setting if your session or its configuration shows one (low, medium, high, ...). Write unknown where you do not know; do not guess. Type the words themselves, without the angle brackets, for example: claude-code-cli sonnet-5.5 medium'
        ''
        "   Windows, PowerShell (Windows PowerShell or pwsh) or Git Bash:  powershell -NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-RelayPowerShellLiteral "$forward/join.ps1") <product> <model> <effort>"
        "   Windows, cmd:                                                  `"$base\join.cmd`" <product> <model> <effort>"
        "   Linux or macOS, sh:                                            sh $(ConvertTo-RelayShellLiteral "$shellFolder/join") <product> <model> <effort>"
        ''
        '2. The command gives you a name and introduces you to the coordinator: what kind of agent you are, the computer and its address, the user, whether you run elevated, and your shell. It reads these off the machine; you add nothing. Then it prints your instructions and your own command. From then on use only that command; do not run join a second time.'
        ''
        '3. Every output ends with a NEXT: line. Do what it says. Your first task arrives as a message.'
        ''
        'Until a task arrives, change nothing on this machine: it is in use, not a test machine. Stay inside what a task assigns and ask before anything beyond it. Never type message text on the command line: the output tells you which file to write it into. If the command cannot reach the room folder: check once whether the folder exists, then stop and tell your owner the exact error. Do not try other paths unless your owner gives you one.'
    )
    return ($lines -join "`n") + "`n"
}

function Add-RelayOpenSeat {
    # Adds seats nobody is named for. An agent given the join prompt takes the next free one and says what it is
    # in its introduction; its task comes afterwards as a message. Returns the new names and the join prompt.
    param([Parameter(Mandatory)]$Room, [ValidateRange(1, 200)][int]$Count = 1)
    Write-RelayJoinWrapper $Room
    Write-RelayKindTable $Room

    $taken = New-Object System.Collections.Generic.List[string]
    $order = 0
    foreach ($name in @(Get-RelayRoster $Room -IncludeRetired)) {
        $taken.Add($name)
        # The order of a seat from this PC's copy: the room's seat file is the agents' to write
        $seat = Read-RelayKeyValue (Join-Path (Join-Path (Join-Path $Room.Canon 'agents') $name) 'seat')
        $existing = 0
        if ([int]::TryParse((Get-RelayValue $seat 'order' '0'), [ref]$existing) -and $existing -gt $order) { $order = $existing }
    }
    $transport = 'same-pc'
    if ($Room.Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { $transport = 'share' }
    $names = New-Object System.Collections.Generic.List[string]
    for ($added = 0; $added -lt $Count; $added++) {
        $order++
        $spec = ConvertTo-RelaySeatSpec -Agent ([pscustomobject]@{ role = 'agent'; machine = "(open seat $order)"; kind = 'generic'; transport = $transport }) -RoomId $Room.Id -DevRoomPath $Room.Path -RemoteRoomPath (Get-RelayReachPath $Room)
        $spec['kind'] = 'auto'
        $spec['wake'] = 'auto'
        $spec['open'] = $true
        $spec['order'] = $order
        $name = Select-RelayName -Machine '(open seat)' -Role "seat $order" -Taken $taken.ToArray()
        $taken.Add($name)
        $names.Add($name)
        $null = Add-RelayAgentSeat -Room $Room -Name $name -Spec $spec -Generation 1
    }
    $prompt = Get-RelayJoinPrompt $Room
    Write-RelayGuardedText $Room 'PROMPT-JOIN.txt' $prompt
    Write-RelayText (Join-Path (Join-Path $Room.Local 'prompts') 'PROMPT-JOIN.txt') $prompt
    return [pscustomobject]@{ Names = @($names.ToArray()); Prompt = $prompt }
}

function Read-RelaySeatSpec {
    # The answers one seat was built from, as Add-RelayAgentSeat takes them
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Join-Path $Room.Local 'specs') "$Name.json"
    $text = Read-RelayText $path
    if (-not $text.Trim()) { throw "No saved answers for the agent '$Name' in room $($Room.Id): $path" }
    $parsed = ConvertFrom-RelayJson $text
    $spec = [ordered]@{}
    foreach ($property in $parsed.PSObject.Properties) {
        if (@('non_goals', 'roots', 'may', 'propose_ok', 'ask_first', 'never', 'expertise', 'standards', 'doc_tools') -contains $property.Name) { $spec[$property.Name] = @($property.Value | ForEach-Object { $_ }) }
        else { $spec[$property.Name] = $property.Value }
    }
    return $spec
}

function Merge-RelaySeatSpec {
    # Saved answers of a seat with the fields of a new assignment laid over them. What says who the agent is and
    # how it is reached (name, kind, transport, paths, open seat) is never taken from the new answers.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [Parameter(Mandatory)]$Answers)
    foreach ($key in 'role', 'work', 'task', 'done_when', 'machine_care', 'machine_notes') {
        if ($null -ne $Answers.PSObject.Properties[$key]) { $Spec[$key] = [string]$Answers.$key }
    }
    foreach ($key in 'expertise', 'standards', 'doc_tools', 'non_goals', 'roots', 'may', 'propose_ok', 'ask_first', 'never') {
        if ($null -ne $Answers.PSObject.Properties[$key]) { $Spec[$key] = @($Answers.$key | ForEach-Object { $_ }) }
    }
    if (@('in-use', 'disposable') -notcontains [string]$Spec['machine_care']) { throw "machine_care '$($Spec['machine_care'])' is not one of in-use, disposable" }
    $null = Get-RelayWorkKind ([string]$Spec['work'])
    return $Spec
}

function Update-RelayRoomPackage {
    # Brings the tools, the protocol reference, the agent-kind table and the join wrappers of a running room up
    # to this plugin's package, canonical copy first. A room keeps the package it was created with unless this
    # is called. Returns the relative paths that changed.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Room)
    $package = Get-RelayPackageRoot
    $changed = New-Object System.Collections.Generic.List[string]
    $pairs = New-Object System.Collections.Generic.List[object]
    $pairs.Add(@('PROTOCOL.md', (Join-Path $package 'PROTOCOL.md')))
    $pairs.Add(@('tools/VERSION', (Join-Path $package 'VERSION')))
    foreach ($tool in @(Get-ChildItem -LiteralPath (Join-Path $package 'tools') -File)) { $pairs.Add(@("tools/$($tool.Name)", $tool.FullName)) }
    foreach ($pair in $pairs) {
        if ((Get-RelayFileHash (Join-Path $Room.Canon $pair[0])) -eq (Get-RelayFileHash $pair[1])) { continue }
        if ($PSCmdlet.ShouldProcess("$($Room.Id): $($pair[0])", 'Replace with the file of the plugin package')) { Copy-RelayGuardedFile $Room $pair[0] $pair[1]; $changed.Add($pair[0]) }
    }
    $hasJoin = Test-Path -LiteralPath (Join-Path $Room.Canon 'join.cmd')
    $roster = @(Get-RelayRoster $Room -IncludeRetired)
    $generated = New-Object System.Collections.Generic.List[string]
    foreach ($relative in 'tools/kinds', 'join.cmd', 'join.ps1', 'join') { $generated.Add($relative) }
    foreach ($name in $roster) {
        $generation = (Read-RelayText (Join-Path $Room.Canon "agents/$name/gen")).Trim()
        foreach ($wrapper in 'relay.cmd', 'relay.ps1', 'relay') { $generated.Add("agents/$name/g$generation/$wrapper") }
    }
    $before = (@($generated | ForEach-Object { Get-RelayFileHash (Join-Path $Room.Canon $_) }) -join '|')
    if ($PSCmdlet.ShouldProcess("$($Room.Id): tools/kinds, the join wrappers and every agent's wrappers", 'Write again from the plugin package')) {
        Write-RelayKindTable $Room
        if ($hasJoin) { Write-RelayJoinWrapper $Room }
        foreach ($name in $roster) { Write-RelaySeatWrapper $Room $name }
        $after = (@($generated | ForEach-Object { Get-RelayFileHash (Join-Path $Room.Canon $_) }) -join '|')
        if ($before -ne $after) { $changed.Add('tools/kinds, join wrappers, agent wrappers') }
    }
    # The coordinator's launcher on this PC, from the package's templates and the canonical generation
    $coordinatorGeneration = (Read-RelayText (Join-Path $Room.Canon "agents/$($Room.Coordinator)/gen")).Trim()
    if ($Room.Coordinator -and $coordinatorGeneration -match '^[0-9]+$') {
        $launcherBefore = (Get-RelayFileHash (Join-Path $Room.Local 'relay.ps1')) + '|' + (Get-RelayFileHash (Join-Path $Room.Local 'relay.cmd'))
        if ($PSCmdlet.ShouldProcess("$($Room.Id): the coordinator's launcher", 'Write again from the plugin package')) {
            Write-RelayLauncher -Room $Room -Name $Room.Coordinator -Generation $coordinatorGeneration
            if (((Get-RelayFileHash (Join-Path $Room.Local 'relay.ps1')) + '|' + (Get-RelayFileHash (Join-Path $Room.Local 'relay.cmd'))) -ne $launcherBefore) { $changed.Add('the coordinator''s launcher') }
        }
    }
    # Each agent's instructions, written again from the package's templates and the answers its seat was built
    # from: the next taker of a free seat reads the current text, an agent in the room does at its next start
    foreach ($name in @(Get-RelayRoster $Room)) {
        if ($name -eq $Room.Coordinator) { continue }
        $spec = $null
        try { $spec = Read-RelaySeatSpec $Room $name } catch { continue }
        $generation = 1
        $null = [int]::TryParse((Read-RelayText (Join-Path $Room.Canon "agents/$name/gen")).Trim(), [ref]$generation)
        $relative = "agents/$name/START-HERE.md"
        $hashBefore = Get-RelayFileHash (Join-Path $Room.Canon $relative)
        if ($PSCmdlet.ShouldProcess("$($Room.Id): $relative", 'Write again from the plugin package')) {
            $null = Add-RelayAgentSeat -Room $Room -Name $name -Spec $spec -Generation $generation -Reassign
            if ((Get-RelayFileHash (Join-Path $Room.Canon $relative)) -ne $hashBefore) { $changed.Add($relative) }
        }
    }
    if ($hasJoin) {
        $prompt = Get-RelayJoinPrompt $Room
        # This PC's copy says whether the prompt is old: the room's file is the agents' to write. A room file that
        # is not that copy is written again with it, as the tamper check would.
        $canonPrompt = Join-Path $Room.Canon 'PROMPT-JOIN.txt'
        $isCurrent = ((Read-RelayText $canonPrompt).TrimEnd() -eq $prompt.TrimEnd()) -and ((Get-RelayFileHash $canonPrompt) -eq (Get-RelayFileHash (Join-Path $Room.Path 'PROMPT-JOIN.txt')))
        if (-not $isCurrent -and $PSCmdlet.ShouldProcess("$($Room.Id): PROMPT-JOIN.txt", 'Write again from the plugin package')) {
            Write-RelayGuardedText $Room 'PROMPT-JOIN.txt' $prompt
            Write-RelayText (Join-Path (Join-Path $Room.Local 'prompts') 'PROMPT-JOIN.txt') $prompt
            $changed.Add('PROMPT-JOIN.txt')
        }
    }
    $version = (Read-RelayText (Join-Path $package 'VERSION')).Trim()
    if ((Get-RelayValue $Room.Info 'package' '') -ne $version -and $PSCmdlet.ShouldProcess("$($Room.Id): ROOM", "Record package $version")) {
        $info = [ordered]@{}
        foreach ($key in $Room.Info.Keys) { $info[$key] = $Room.Info[$key] }
        $info['package'] = $version
        Write-RelayGuardedText $Room 'ROOM' (ConvertTo-RelayKeyValueText $info)
        $changed.Add('ROOM')
    }
    return @($changed.ToArray())
}

function Switch-RelaySeatKind {
    # Changes the agent kind of saved answers and takes the new kind's defaults for how it calls and waits
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [Parameter(Mandatory)][string]$Kind)
    $profileOfKind = Get-RelayAgentKind $Kind
    $Spec['kind'] = $Kind
    $Spec['wake'] = [string]$profileOfKind.wake
    $Spec['wait_minutes'] = [int]$profileOfKind.wait_minutes
    $Spec['park_after'] = [int]$profileOfKind.park_after
    $Spec['draft'] = [string]$profileOfKind.draft
    $Spec['prompt_extra'] = [string]$profileOfKind.prompt_extra
    if ($Spec['os'] -ne 'linux') { $Spec['shell'] = [string](Get-RelayProperty $profileOfKind.shell 'windows' 'powershell') }
    return $Spec
}

#endregion

#region Script helpers (round 5)

function Get-RelayAgentKindName {
    # The agent kinds agent-kinds.json knows, in the order of the file
    return @((Get-RelayJsonTable 'agent-kinds.json').PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-RelayAgentKind {
    # An agent kind given in an answers file or on a command line is one that agent-kinds.json knows: a typo would
    # otherwise give the agent the generic profile without a word. The 'auto' of an open seat is set by the
    # scripts themselves and never passes here.
    param([string]$Kind, [string]$What = 'The agent kind')
    $known = @(Get-RelayAgentKindName)
    if ($known -notcontains $Kind) { throw "$What '$Kind' is not one of $($known -join ', ')" }
}

function Get-RelayCoordinatorNote {
    # What agent-kinds.json has the coordinator tell the owner about an agent kind (its coordinator_note), once
    # per kind, in the order the kinds come
    param([string[]]$Kind = @())
    $notes = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($name in @($Kind)) {
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $note = [string](Get-RelayProperty (Get-RelayAgentKind $name) 'coordinator_note' '')
        if ($note) { $notes.Add($note) }
    }
    return @($notes.ToArray())
}

function Add-RelayLinePair {
    # Opens a direct line between two agents, both ways: each name goes into the other's lines file, canonical
    # copy first. A lines file of this PC that cannot be read is an error, never an empty list: the lines it
    # held would be lost when it is written back.
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second)
    foreach ($direction in @(@($First, $Second), @($Second, $First))) {
        $path = "agents/$($direction[0])/lines"
        $existing = @(((Read-RelayTextStrict (Join-Path $Room.Canon $path)) -split "`n") | Where-Object { $_.Trim() })
        if ($existing -notcontains $direction[1]) { Write-RelayGuardedText $Room $path ((@($existing + $direction[1]) -join "`n") + "`n") }
    }
}

function Test-RelayPathWithin {
    # True when a path is the folder itself or lies below it: both as full paths in normal form, compared without
    # regard to case
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)
    $top = (Get-RelayNormalPath $Folder).TrimEnd('\', '/')
    $full = Get-RelayNormalPath $Path
    if ([string]::Equals($full, $top, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($top + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelayLinkTarget {
    # Where a link points, as a full path; '' when that cannot be read
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        # Windows PowerShell 5.1 gives the target as a list, PowerShell 7 as one text
        $target = [string](@($item.Target | Where-Object { $_ }) | Select-Object -First 1)
        if (-not $target) { return '' }
        if ($target.StartsWith('\??\', [System.StringComparison]::Ordinal)) { $target = $target.Substring(4) }
        # A link to a share comes back as UNC\server\share in Windows PowerShell 5.1
        if ($target.StartsWith('UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $target = '\\' + $target.Substring(4) }
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), $target) }
        return [System.IO.Path]::GetFullPath($target)
    }
    catch { return '' }
}

function Get-RelayRealPath {
    # A full path with each link on it replaced by where that link points, from the root down; '' when a link on
    # it cannot be followed. Forty links on one way are taken for a loop.
    param([Parameter(Mandatory)][string]$Path)
    $current = Get-RelayNormalPath $Path
    for ($hop = 0; $hop -lt 40; $hop++) {
        $root = [System.IO.Path]::GetPathRoot($current)
        $parts = @($current.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })
        $walked = $root
        $isFollowed = $false
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $walked = [System.IO.Path]::Combine($walked, $parts[$index])
            if (-not (Test-RelayLink $walked)) { continue }
            $target = Get-RelayLinkTarget $walked
            if (-not $target) { return '' }
            foreach ($part in @($parts | Select-Object -Skip ($index + 1))) { $target = [System.IO.Path]::Combine($target, $part) }
            $current = Get-RelayNormalPath $target
            $isFollowed = $true
            break
        }
        if (-not $isFollowed) { return $current }
    }
    return ''
}

function Resolve-RelayDraftPath {
    # Where the text of a card, a rule or an owner's message is read from: this PC, never the room, where any agent
    # can write. Without -File: draft.md of the room on this PC. A file that is named is made absolute once,
    # against the PowerShell location, so that the same path is read and removed. A file inside the room folder is
    # refused, also when the way to it, or to the room, goes through a link: where a link really leads decides.
    param([Parameter(Mandatory)]$Room, [string]$File = '', [string]$What = 'text')
    $default = Join-Path $Room.Local 'draft.md'
    if (-not $File) { return $default }
    $full = Get-RelayNormalPath $File
    $roomPath = Get-RelayNormalPath $Room.Path
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add($full)
    $folders = New-Object System.Collections.Generic.List[string]
    $folders.Add($roomPath)
    if (Test-RelayLinkedPath -Root ([System.IO.Path]::GetPathRoot($full)) -Path $full) {
        $real = Get-RelayRealPath $full
        if (-not $real) { throw "The file $full is reached through a link that cannot be followed: give the path of the file itself" }
        $paths.Add($real)
    }
    if (Test-RelayLinkedPath -Root ([System.IO.Path]::GetPathRoot($roomPath)) -Path $roomPath) {
        $realRoom = Get-RelayRealPath $roomPath
        if ($realRoom) { $folders.Add($realRoom) }
    }
    foreach ($path in $paths) {
        foreach ($folder in $folders) {
            if (Test-RelayPathWithin -Path $path -Folder $folder) { throw "The file $full lies inside the room folder, where any agent can write: no $What is made from it. Put the text outside the room (default: $default)" }
        }
    }
    return $full
}

#endregion

Export-ModuleMember -Function *-Relay*
