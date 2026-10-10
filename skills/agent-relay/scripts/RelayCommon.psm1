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

#region Text and files

function Get-RelayPackageRoot { return $script:PackageRoot }

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

function Read-RelayText {
    param([string]$Path)
    for ($try = 0; $try -lt 6; $try++) {
        try {
            if (-not [System.IO.File]::Exists($Path)) { return '' }
            $text = $script:Utf8.GetString([System.IO.File]::ReadAllBytes($Path))
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            return ($text -replace "`r", '')
        }
        catch { Start-Sleep -Milliseconds 150 }
    }
    return ''
}

function Write-RelayText {
    # UTF-8 without BOM. LF line ends unless -Crlf (the cmd wrappers).
    param([string]$Path, [string]$Text, [switch]$Crlf)
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    if ($Crlf) { $normalized = $normalized -replace "`n", "`r`n" }
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    for ($try = 0; ; $try++) {
        try { [System.IO.File]::WriteAllText($Path, $normalized, $script:Utf8); return }
        catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 150 }
    }
}

function Add-RelayLine {
    param([string]$Path, [string]$Line)
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
    param([string]$Path)
    $map = [ordered]@{}
    foreach ($line in ((Read-RelayText $Path) -split "`n")) {
        $at = $line.IndexOf(':')
        if ($at -lt 1) { continue }
        $map[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim()
    }
    return $map
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
    # A line as it is printed for reading: each control character (U+0000 to U+001F, U+007F) from a room file is
    # replaced by a blank, and no line ends in a blank. JSON output does not pass here: it escapes.
    param([string]$Text)
    return ([regex]::Replace($Text, '[\x00-\x1f\x7f]', ' ')).TrimEnd(' ')
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
    for ($try = 0; $try -lt 4; $try++) {
        try {
            if (-not [System.IO.File]::Exists($Path)) { return '' }
            return (Get-RelayBytesHash ([System.IO.File]::ReadAllBytes($Path)))
        }
        catch { Start-Sleep -Milliseconds 150 }
    }
    return ''
}

function Get-RelayTextHash {
    param([string]$Text)
    return (Get-RelayBytesHash ($script:Utf8.GetBytes((($Text -replace "`r", '')).TrimEnd())))
}

function Get-RelayFileTimeUtc {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc }
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
    $path = Join-Path (Get-RelayLocalRoot) 'rooms.json'
    $text = Read-RelayText $path
    if (-not $text.Trim()) { return @() }
    # Windows PowerShell hands a JSON array over as one object: piping it gives the entries in both editions
    $parsed = ConvertFrom-RelayJson $text
    return @($parsed | ForEach-Object { $_ })
}

function Save-RelayRoomIndex {
    param([object[]]$Rooms)
    $json = '[]'
    if (@($Rooms).Count -gt 0) { $json = ConvertTo-Json -InputObject @($Rooms) -Depth 6 }
    Write-RelayText (Join-Path (Get-RelayLocalRoot) 'rooms.json') ($json + "`n")
}

function Resolve-RelayRoom {
    # A room by id (from the index) or by folder. Returns its paths on this PC.
    param([Parameter(Mandatory)][string]$Room)
    $path = ''
    if (Test-Path -LiteralPath (Join-Path $Room 'ROOM')) { $path = (Resolve-Path -LiteralPath $Room).ProviderPath.TrimEnd('\', '/') }
    else {
        foreach ($entry in @(Get-RelayRoomIndex)) { if ($entry.id -eq $Room) { $path = [string]$entry.path } }
        if (-not $path) { throw "No room '$Room': it is neither a room folder nor an id in the room index" }
        if (-not (Test-Path -LiteralPath (Join-Path $path 'ROOM'))) { throw "The room '$Room' is in the index but its folder is not reachable: $path" }
    }
    $info = Read-RelayKeyValue (Join-Path $path 'ROOM')
    $id = Get-RelayValue $info 'room' (Split-Path -Leaf $path)
    $local = Join-Path (Join-Path (Get-RelayLocalRoot) 'rooms') $id
    return [pscustomobject]@{
        Id          = $id
        Path        = $path
        Info        = $info
        Coordinator = (Get-RelayValue $info 'coordinator' '')
        Local       = $local
        Canon       = (Join-Path $local 'canon')
        Owner       = (Join-Path $local 'owner')
        IsClosed    = (Test-Path -LiteralPath (Join-Path $path 'CLOSED'))
    }
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

function Get-RelayRoster {
    param([Parameter(Mandatory)]$Room, [switch]$IncludeRetired)
    $names = New-Object System.Collections.Generic.List[string]
    $agents = Join-Path $Room.Path 'agents'
    if (Test-Path -LiteralPath $agents) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $agents -Directory)) {
            if ($folder.Name -notmatch $script:NamePattern) { continue }
            if (-not $IncludeRetired -and (Test-Path -LiteralPath (Join-Path $folder.FullName 'retired'))) { continue }
            $names.Add($folder.Name)
        }
    }
    return @($names | Sort-Object)
}

#endregion

#region Guarded files and the tamper check

function Write-RelayGuardedText {
    # The canonical copy on this PC is written first, the room second: the tamper check restores from the first
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Relative, [string]$Text, [switch]$Crlf)
    Write-RelayText (Join-Path $Room.Canon $Relative) $Text -Crlf:$Crlf
    Write-RelayText (Join-Path $Room.Path $Relative) $Text -Crlf:$Crlf
}

function Copy-RelayGuardedFile {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$Source)
    foreach ($target in (Join-Path $Room.Canon $Relative), (Join-Path $Room.Path $Relative)) {
        $folder = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($Source))
    }
}

function Clear-RelayGuardedFile {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Relative)
    foreach ($target in (Join-Path $Room.Canon $Relative), (Join-Path $Room.Path $Relative)) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
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
    Add-RelayLine (Join-Path $Room.Local 'alarms.log') ('{0} {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), (ConvertTo-RelayHeaderText $Text))
}

function Test-RelayTamper {
    # Compares the guarded files in the room with the canonical copies. With -Repair a changed or missing file is
    # restored and a file that does not belong is moved out to this PC. Returns one finding per file.
    param([Parameter(Mandatory)]$Room, [switch]$Repair)
    $findings = New-Object System.Collections.Generic.List[object]
    $guarded = @(Get-RelayGuardedFile $Room)
    $known = @{}
    foreach ($relative in $guarded) {
        $known[$relative.ToLowerInvariant()] = $true
        $canonPath = Join-Path $Room.Canon $relative
        $roomPath = Join-Path $Room.Path $relative
        $expected = Get-RelayFileHash $canonPath
        $actual = Get-RelayFileHash $roomPath
        if ($expected -eq $actual) { continue }
        # A file the server is still handing over reads as missing for a moment: look twice before an alarm
        Start-Sleep -Milliseconds 300
        $actual = Get-RelayFileHash $roomPath
        if ($expected -eq $actual) { continue }
        $kind = 'changed'
        if (-not $actual) { $kind = 'missing' }
        if ($Repair) {
            $folder = Split-Path -Parent $roomPath
            if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
            if ($actual) {
                $keep = Join-Path (Join-Path $Room.Local 'quarantine') ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), ($relative -replace '[\\/]', '_'))
                $keepFolder = Split-Path -Parent $keep
                if (-not (Test-Path -LiteralPath $keepFolder)) { $null = New-Item -ItemType Directory -Path $keepFolder -Force }
                try { [System.IO.File]::WriteAllBytes($keep, [System.IO.File]::ReadAllBytes($roomPath)) } catch { $null = $_ }
            }
            [System.IO.File]::WriteAllBytes($roomPath, [System.IO.File]::ReadAllBytes($canonPath))
        }
        $findings.Add([pscustomobject]@{ Relative = $relative; Kind = $kind; Repaired = [bool]$Repair })
    }

    # Files that do not belong where only this PC writes: the tools, the wrappers, the markers
    $candidates = New-Object System.Collections.Generic.List[string]
    # A PLAN, a CLOSED marker or a TRANSCRIPT.md that this PC did not write has no canonical copy and so is not known
    foreach ($name in 'PLAN', 'CLOSED', 'TRANSCRIPT.md') {
        $path = Join-Path $Room.Path $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $candidates.Add($path) }
    }
    $tools = Join-Path $Room.Path 'tools'
    if (Test-Path -LiteralPath $tools) { foreach ($file in @(Get-ChildItem -LiteralPath $tools -File -Recurse -Force)) { $candidates.Add($file.FullName) } }
    foreach ($agent in @(Get-RelayRoster $Room -IncludeRetired)) {
        $agentDir = Join-Path (Join-Path $Room.Path 'agents') $agent
        foreach ($name in 'retired', 'lines', 'scope', 'seat', 'control', 'gen') {
            $path = Join-Path $agentDir $name
            if (Test-Path -LiteralPath $path) { $candidates.Add($path) }
        }
        foreach ($generation in @(Get-ChildItem -LiteralPath $agentDir -Directory -Filter 'g*' | Where-Object { $_.Name -match '^g[0-9]+$' })) {
            foreach ($file in @(Get-ChildItem -LiteralPath $generation.FullName -File -Force)) { $candidates.Add($file.FullName) }
        }
    }
    $prefix = $Room.Path.TrimEnd('\', '/')
    foreach ($path in $candidates) {
        $relative = ($path.Substring($prefix.Length).TrimStart('\', '/') -replace '\\', '/')
        if ($known.ContainsKey($relative.ToLowerInvariant())) { continue }
        if ($Repair) {
            $keep = Join-Path (Join-Path $Room.Local 'quarantine') ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), ($relative -replace '[\\/]', '_'))
            $keepFolder = Split-Path -Parent $keep
            if (-not (Test-Path -LiteralPath $keepFolder)) { $null = New-Item -ItemType Directory -Path $keepFolder -Force }
            try { Move-Item -LiteralPath $path -Destination $keep -Force } catch { $null = $_ }
        }
        $findings.Add([pscustomobject]@{ Relative = $relative; Kind = 'extra'; Repaired = [bool]$Repair })
    }
    foreach ($finding in $findings) {
        $action = 'found'
        if ($finding.Repaired) { $action = 'restored' }
        if ($finding.Repaired -and $finding.Kind -eq 'extra') { $action = 'moved out' }
        Add-RelayAlarm $Room ("TAMPER {0} {1}: {2}" -f $finding.Kind, $action, $finding.Relative)
    }
    return @($findings.ToArray())
}

#endregion

#region Messages

function Read-RelayMessage {
    # Sender, receiver and number come from where the file is; the header gives the rest
    param([Parameter(Mandatory)][string]$Path)
    $text = (Read-RelayText $Path) + "`n"
    if (-not $text.StartsWith("---`n")) { return $null }
    $end = $text.IndexOf("`n---`n", 3)
    if ($end -lt 0) { return $null }
    $header = @{}
    foreach ($line in ($text.Substring(4, $end - 3) -split "`n")) {
        $at = $line.IndexOf(':')
        if ($at -lt 1) { continue }
        $header[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim()
    }
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $to = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $Path))
    $from = ''
    $number = ''
    if ($fileName -match '^([a-z][a-z0-9]{1,15})-([0-9]{4,6})$') { $from = $Matches[1]; $number = $Matches[2] }
    $fields = @{}
    foreach ($key in 'id', 'from', 'to', 'type', 're', 'subject', 'sent_utc', 'expects') {
        $fields[$key] = ''
        if ($header.ContainsKey($key)) { $fields[$key] = [string]$header[$key] }
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
        Body     = $text.Substring($end + 5).TrimEnd()
        Path     = $Path
        Time     = (Get-RelayFileTimeUtc $Path)
        Mismatch = ($fields['id'] -ne $id -or $fields['from'] -ne $from -or $fields['to'] -ne $to)
    }
}

function Get-RelayMessage {
    # Every message in the room, oldest first (by the file server's time). Owner cards are separate.
    param([Parameter(Mandatory)]$Room, [string]$To = '')
    $messages = New-Object System.Collections.Generic.List[object]
    foreach ($agent in @(Get-RelayRoster $Room -IncludeRetired)) {
        if ($To -and $agent -ne $To) { continue }
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
    # Writes one message into an inbox the way the room tool does: first free number, exclusive move into place
    param(
        [Parameter(Mandatory)][string]$Inbox, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Type, [string]$Re = '', [string]$Subject = '', [string]$Body = '', [string]$Expects = 'none'
    )
    if (-not (Test-Path -LiteralPath $Inbox)) { $null = New-Item -ItemType Directory -Path $Inbox -Force }
    $highest = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Inbox -Filter "$From-*.md" -File)) {
        if ($file.Name -match '^[a-z][a-z0-9]{1,15}-([0-9]{4,6})\.md$' -and [int]$Matches[1] -gt $highest) { $highest = [int]$Matches[1] }
    }
    $number = $highest + 1
    $blocked = 0
    for ($attempt = 0; $attempt -lt 500; $attempt++) {
        $id = '{0}-{1}-{2:0000}' -f $From, $To, $number
        $final = Join-Path $Inbox ('{0}-{1:0000}.md' -f $From, $number)
        if ([System.IO.File]::Exists($final)) { $number++; continue }
        $header = @(
            '---'
            "id: $id"
            "from: $From"
            "to: $To"
            "type: $Type"
            "re: $Re"
            "subject: $(ConvertTo-RelayHeaderText $Subject)"
            "sent_utc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            "expects: $Expects"
            '---'
        ) -join "`n"
        $temporary = Join-Path $Inbox ('.{0}-{1}.tmp' -f $From, [guid]::NewGuid().ToString('N'))
        Write-RelayText $temporary ($header + "`n" + $Body.TrimEnd() + "`n")
        $moved = $false
        try { [System.IO.File]::Move($temporary, $final); $moved = $true } catch { $moved = $false }
        if ($moved) { return $id }
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        if ([System.IO.File]::Exists($final)) { $number++; continue }
        $blocked++
        if ($blocked -ge 5) { throw "Could not create a message in $Inbox" }
        Start-Sleep -Milliseconds 300
    }
    throw "Could not find a free message number in $Inbox"
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
    # What the owner typed or decided in the chat window: written to the owner's log on this PC first, then
    # delivered to the coordinator's inbox. The coordinator acts on it only when the log confirms it.
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
    $inbox = Join-Path (Join-Path (Join-Path $Room.Path 'agents') $Room.Coordinator) 'inbox'
    $id = Add-RelayMessageFile -Inbox $inbox -From 'owner' -To $Room.Coordinator -Type $type -Re $Re -Subject $subject -Body $body -Expects 'none'
    Add-RelayLine (Join-Path $Room.Owner 'log') ("{0}`t{1}`t{2}`t{3}`t{4}" -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $id, (Get-RelayTextHash $body), $Via, $Re)
    return $id
}

function Test-RelayOwnerMessage {
    # True when the message is in the owner's log with the same text
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)]$Message)
    $hash = Get-RelayTextHash $Message.Body
    foreach ($line in ((Read-RelayText (Join-Path $Room.Owner 'log')) -split "`n")) {
        $parts = @($line -split "`t")
        if ($parts.Count -ge 3 -and $parts[1] -eq $Message.Id -and $parts[2] -eq $hash) { return $true }
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
            $text = (Read-RelayText $file.FullName) + "`n"
            $end = $text.IndexOf("`n---`n", 3)
            if (-not $text.StartsWith("---`n") -or $end -lt 0) { continue }
            $header = Read-RelayKeyValueText ($text.Substring(4, $end - 3))
            $answerPath = [System.IO.Path]::ChangeExtension($file.FullName, '.answer')
            $answer = Read-RelayKeyValue $answerPath
            $isOpen = ($answer.Count -eq 0)
            if ($OpenOnly -and -not $isOpen) { continue }
            $cards.Add([pscustomobject]@{
                    Id       = (Get-RelayValue $header 'id' $file.BaseName)
                    Re       = (Get-RelayValue $header 're' '')
                    Subject  = (Get-RelayValue $header 'subject' '')
                    SentUtc  = (Get-RelayValue $header 'sent_utc' '')
                    Body     = $text.Substring($end + 5).TrimEnd()
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
        $at = $line.IndexOf(':')
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
        "sent_utc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
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
    $answer = [ordered]@{ decision = $Decision; via = $Via; at_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); message = $MessageId }
    Write-RelayText ([System.IO.Path]::ChangeExtension($card[0].Path, '.answer')) (ConvertTo-RelayKeyValueText $answer)
    Add-RelayLine (Join-Path $Room.Owner 'log') ("{0}`t{1}`t{2}`t{3}`t{4}" -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $CardId, $Decision, $Via, $MessageId)
}

#endregion

#region Board

function Get-RelayRoomNow {
    # "Now" on the clock of wherever the room lives: the time the file server gives a file written this moment
    param([Parameter(Mandatory)]$Room)
    $probe = Join-Path $Room.Path '.dev-clock'
    try {
        [System.IO.File]::WriteAllText($probe, [DateTime]::UtcNow.ToString('o'))
        $time = Get-RelayFileTimeUtc $probe
        if ($time -ne [DateTime]::MinValue) { return $time }
    }
    catch { $null = $_ }
    return [DateTime]::UtcNow
}

function ConvertTo-RelayMessageRow {
    # A message as the chat window and the board show it: header fields and the start of the text
    param([Parameter(Mandatory)]$Message, [int]$PreviewLength = 400)
    $preview = $Message.Body
    if ($preview.Length -gt $PreviewLength) { $preview = $preview.Substring(0, $PreviewLength) + ' ...' }
    return [pscustomobject]@{
        id       = $Message.Id
        from     = $Message.From
        to       = $Message.To
        type     = $Message.Type
        re       = $Message.Re
        subject  = $Message.Subject
        expects  = $Message.Expects
        sentUtc  = $Message.SentUtc
        time     = $Message.Time.ToString('yyyy-MM-ddTHH:mm:ssZ')
        preview  = $preview
        length   = $Message.Body.Length
        mismatch = [bool]$Message.Mismatch
    }
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
        $at = $line.IndexOf(':')
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
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][DateTime]$Now, [AllowEmptyCollection()][object[]]$Open = @(), $Plan = $null)
    $now = $Now
    $open = @($Open)
    $staleMinutes = 5
    $parsed = 0
    if ([int]::TryParse((Get-RelayValue $Room.Info 'stale_minutes' '5'), [ref]$parsed)) { $staleMinutes = $parsed }

    $agents = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-RelayRoster $Room -IncludeRetired)) {
        $dir = Join-Path (Join-Path $Room.Path 'agents') $name
        $seat = Read-RelayKeyValue (Join-Path $dir 'seat')
        $card = Read-RelayKeyValue (Join-Path $dir 'card')
        $status = Read-RelayKeyValue (Join-Path $dir 'status')
        $control = Get-RelayValue (Read-RelayKeyValue (Join-Path $dir 'control')) 'state' 'run'
        $state = Get-RelayValue $status 'state' 'not started'
        $alive = Get-RelayFileTimeUtc (Join-Path $dir 'alive')
        $silent = -1
        if ($alive -ne [DateTime]::MinValue) { $silent = [int][Math]::Max(0, ($now - $alive).TotalMinutes) }
        $isRetired = Test-Path -LiteralPath (Join-Path $dir 'retired')
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
        $owes = @($open | Where-Object { $_.To -eq $name })
        # Where it says it stands (the verb progress): the last record, cut at the first separator
        $progress = ''
        $progressUtc = ''
        $records = @(((Read-RelayText (Join-Path $dir 'progress')) -split "`n") | Where-Object { $_.Contains(' | ') })
        if ($records.Count -gt 0) {
            $record = $records[$records.Count - 1]
            $cut = $record.IndexOf(' | ')
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
                gen           = (Read-RelayText (Join-Path $dir 'gen')).Trim()
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
    $table = ConvertFrom-RelayJson (Read-RelayText (Join-Path $PSScriptRoot 'model-tiers.json'))
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
    $open = @(Get-RelayOpenRequest $messages)
    $plan = Read-RelayPlan $Room
    if ($null -ne $plan) {
        # The room's PLAN against this PC's copy, byte for byte: no copy, or another one, is a difference
        $copy = Get-RelayFileHash (Join-Path $Room.Canon 'PLAN')
        $differs = (-not $copy) -or ($copy -ne (Get-RelayFileHash (Join-Path $Room.Path 'PLAN')))
        $plan | Add-Member -NotePropertyName differs -NotePropertyValue ([bool]$differs)
    }
    $agents = @(Get-RelayAgentState -Room $Room -Now $now -Open $open -Plan $plan)

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
            })
    }
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($card in @(Get-RelayOwnerCard $Room -OpenOnly)) {
        $preview = $card.Body
        if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) + ' ...' }
        $cards.Add([pscustomobject]@{ id = $card.Id; re = $card.Re; subject = $card.Subject; sentUtc = $card.SentUtc; text = $preview })
    }
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
        if ($message.Body -match 'self-audit: ([0-9]+) changed since start, ([0-9]+) OUTSIDE') { if ([int]$Matches[2] -gt 0) { $outside.Add([pscustomobject]@{ id = $message.Id; from = $message.From; outside = [int]$Matches[2] }) } }
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
    $all = ConvertFrom-RelayJson (Read-RelayText (Join-Path $PSScriptRoot 'agent-kinds.json'))
    $kindProfile = $all.PSObject.Properties[$Kind]
    if ($null -eq $kindProfile) { $kindProfile = $all.PSObject.Properties['generic'] }
    return $kindProfile.Value
}

function Get-RelayWorkKind {
    # The method lines and report shape for one kind of work from work-kinds.json
    param([string]$Work = 'other')
    $all = ConvertFrom-RelayJson (Read-RelayText (Join-Path $PSScriptRoot 'work-kinds.json'))
    $entry = $all.PSObject.Properties[$Work]
    if ($null -eq $entry) { throw ("The kind of work '$Work' is not one of " + ((@($all.PSObject.Properties | ForEach-Object { $_.Name })) -join ', ')) }
    return $entry.Value
}

function Select-RelayName {
    # A name for one seat. The same machine and role keeps its name across jobs; in one room every name starts
    # with a different letter.
    param([Parameter(Mandatory)][string]$Machine, [Parameter(Mandatory)][string]$Role, [string[]]$Taken = @(), [string]$Wanted = '')
    $pool = ConvertFrom-RelayJson (Read-RelayText (Join-Path $PSScriptRoot 'relay-names.json'))
    $registryPath = Join-Path (Get-RelayLocalRoot) 'names.json'
    $registry = @{}
    $registryText = Read-RelayText $registryPath
    if ($registryText.Trim()) { foreach ($property in (ConvertFrom-RelayJson $registryText).PSObject.Properties) { $registry[$property.Name] = [string]$property.Value } }
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
    Write-RelayText $registryPath ((ConvertTo-Json -InputObject $ordered -Depth 3) + "`n")
    return $choice
}

function Get-RelayCallLine {
    # The command prefix an agent types, for the shell it calls from and the room path as that agent sees it
    param([Parameter(Mandatory)][string]$RoomPath, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Generation, [string]$Shell = 'powershell')
    $base = $RoomPath.TrimEnd('\', '/')
    if ($Shell -eq 'sh') {
        $wrapper = "$base/agents/$Name/g$Generation/relay"
        # A leading ~ only expands outside quotes
        if ($wrapper -match '^[A-Za-z0-9_./~-]+$') { return "sh $wrapper" }
        return "sh '$wrapper'"
    }
    $wrapper = "$base\agents\$Name\g$Generation\relay.cmd"
    if ($Shell -eq 'cmd') { return '"' + $wrapper + '"' }
    # PowerShell and Git Bash start the .ps1 wrapper with powershell -File: no cmd.exe in between, so the
    # caller's working folder survives even when it is on a share (cmd.exe cannot stand in one)
    $wrapper = "$base\agents\$Name\g$Generation\relay.ps1"
    if ($Shell -eq 'bash') { $wrapper = $wrapper -replace '\\', '/' }
    return "powershell -NoProfile -ExecutionPolicy Bypass -File '$wrapper'"
}

#endregion

#region Seats

function Expand-RelayTemplate {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $result = $Text
    foreach ($key in $Values.Keys) { $result = $result.Replace('{{' + [string]$key + '}}', [string]$Values[$key]) }
    return $result
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
    # What the owner pastes into the agent's session: who it is and the one command to run
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Spec, [int]$Generation = 1)
    $display = $Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1)
    # For PowerShell the path is written with forward slashes: the same line then works in Git Bash too
    $shell = [string]$Spec['shell']
    if ($shell -eq 'powershell') { $shell = 'bash' }
    $call = Get-RelayCallLine -RoomPath $Spec['room_path'] -Name $Name -Generation ([string]$Generation) -Shell $shell
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("You are $display, the $($Spec['role']) on a job that several coding agents work on for the same owner. Your instructions are in a shared folder, the `"room`". Run this one command now. Replace the three words at the end with your agent product as exactly as you know it (for example claude-code-cli or codex-cli), your model, and your reasoning effort setting if your session shows one; write unknown where you do not know:")
    $lines.Add('')
    $lines.Add("$call start <product> <model> <effort>")
    $lines.Add('')
    if ($Spec['shell'] -eq 'powershell') {
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
    $package = Get-RelayPackageRoot
    $display = $Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1)
    $base = "agents/$Name"
    $coordinator = $Room.Coordinator
    $coordinatorDisplay = $coordinator.Substring(0, 1).ToUpperInvariant() + $coordinator.Substring(1)
    $call = Get-RelayCallLine -RoomPath $Spec['room_path'] -Name $Name -Generation ([string]$Generation) -Shell $Spec['shell']
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
    # The machine of an open seat has no name until the agent on it has introduced itself
    $machineLabel = "``$($Spec['machine'])``"
    if (([string]$Spec['machine']).StartsWith('(')) { $machineLabel = 'the machine you run on' }
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
    }
    if ($isOpen) { foreach ($key in 'CALL', 'DRAFT', 'ATTACH', 'WAIT_LINE', 'ROOM_PATH') { $values[$key] = '{{' + $key + '}}' } }
    $startTemplate = 'START-HERE.md.tmpl'
    $assignmentTemplate = 'ASSIGNMENT.md.tmpl'
    if ($IsCoordinator) { $startTemplate = 'COORDINATOR.md.tmpl'; $assignmentTemplate = '' }
    Write-RelayGuardedText $Room "$base/START-HERE.md" (Expand-RelayTemplate (Read-RelayText (Join-Path $package $startTemplate)) $values)
    if ($assignmentTemplate) { Write-RelayGuardedText $Room "$base/ASSIGNMENT.md" (Expand-RelayTemplate (Read-RelayText (Join-Path $package $assignmentTemplate)) $values) }
    Write-RelayGuardedText $Room "$base/g$Generation/relay.cmd" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.cmd.tmpl')) $values) -Crlf
    Write-RelayGuardedText $Room "$base/g$Generation/relay.ps1" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.ps1.tmpl')) $values)
    Write-RelayGuardedText $Room "$base/g$Generation/relay" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.tmpl')) $values)
    foreach ($folder in 'inbox', 'attach') {
        $path = Join-Path (Join-Path (Join-Path $Room.Path 'agents') $Name) $folder
        if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType Directory -Path $path -Force }
    }
    # The first session of an open seat comes in through the join prompt, which is the same for every agent
    $prompt = ''
    if (-not $Reassign -and -not ($isOpen -and $Generation -eq 1)) {
        $prompt = Get-RelayStartPrompt -Name $Name -Spec $Spec -Generation $Generation
        Write-RelayText (Join-Path $Room.Path "PROMPT-$Name.txt") $prompt
        Write-RelayText (Join-Path (Join-Path $Room.Local 'prompts') "PROMPT-$Name-g$Generation.txt") $prompt
    }
    # The answers this seat was built from stay on this PC, so a replacement session gets the same assignment
    $kept = [ordered]@{}
    foreach ($key in $Spec.Keys) { $kept[[string]$key] = $Spec[$key] }
    Write-RelayText (Join-Path (Join-Path $Room.Local 'specs') "$Name.json") ((ConvertTo-Json -InputObject $kept -Depth 8) + "`n")
    return $prompt
}

function Write-RelayKindTable {
    # tools/kinds in the room: how each agent kind waits, as key: value lines the room tools read. The agent on
    # a seat taken with join names its product only when it arrives.
    param([Parameter(Mandatory)]$Room)
    $all = ConvertFrom-RelayJson (Read-RelayText (Join-Path $PSScriptRoot 'agent-kinds.json'))
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
    $package = Get-RelayPackageRoot
    $values = @{ ROOM_ID = $Room.Id }
    Write-RelayGuardedText $Room 'join.cmd' (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\join.cmd.tmpl')) $values) -Crlf
    Write-RelayGuardedText $Room 'join.ps1' (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\join.ps1.tmpl')) $values)
    Write-RelayGuardedText $Room 'join' (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\join.tmpl')) $values)
}

function Write-RelaySeatWrapper {
    # The wrappers of one agent's current generation, written again from the package's templates
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Name)
    $package = Get-RelayPackageRoot
    $generation = (Read-RelayText (Join-Path $Room.Canon "agents/$Name/gen")).Trim()
    if ($generation -notmatch '^[0-9]+$') { return }
    $values = @{ DISPLAY = ($Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1)); NAME = $Name; GEN = $generation; ROOM_ID = $Room.Id }
    Write-RelayGuardedText $Room "agents/$Name/g$generation/relay.cmd" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.cmd.tmpl')) $values) -Crlf
    Write-RelayGuardedText $Room "agents/$Name/g$generation/relay.ps1" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.ps1.tmpl')) $values)
    Write-RelayGuardedText $Room "agents/$Name/g$generation/relay" (Expand-RelayTemplate (Read-RelayText (Join-Path $package 'wrappers\relay.tmpl')) $values)
}

function Get-RelayJoinPrompt {
    # What the owner pastes into every agent that should join the room: the same text for all of them
    param([Parameter(Mandatory)]$Room)
    # Every address in the prompt is the one other machines reach: a share's server by its address, not its name
    $base = (Get-RelayReachPath $Room).TrimEnd('\', '/')
    $forward = $base -replace '\\', '/'
    $shellFolder = $forward
    if ($base.StartsWith('\\') -or $base -match '^[A-Za-z]:') { $shellFolder = '<this folder as your machine reaches it>' }
    $lines = @(
        'You are asked to join a work room: a shared folder through which several coding agents work on one job for the same owner. Another agent, the coordinator, hands out the tasks and answers questions.'
        ''
        "Room folder: $base"
        ''
        '1. Run ONE of these now, the one for your shell. The three words at the end say what you are: your agent product as exactly as you know it (claude-code-cli, codex-cli, codex-app, gemini-cli, cursor-agent, copilot-cli, or its name as one word), your model, and your reasoning effort setting if your session or its configuration shows one (low, medium, high, ...). Write unknown where you do not know; do not guess. Type the words themselves, without the angle brackets, for example: claude-code-cli sonnet-5.5 medium'
        ''
        "   Windows, PowerShell (Windows PowerShell or pwsh) or Git Bash:  powershell -NoProfile -ExecutionPolicy Bypass -File '$forward/join.ps1' <product> <model> <effort>"
        "   Windows, cmd:                                                  `"$base\join.cmd`" <product> <model> <effort>"
        "   Linux or macOS, sh:                                            sh '$shellFolder/join' <product> <model> <effort>"
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
        $seat = Read-RelayKeyValue (Join-Path (Join-Path (Join-Path $Room.Path 'agents') $name) 'seat')
        $existing = 0
        if ([int]::TryParse((Get-RelayValue $seat 'order' '0'), [ref]$existing) -and $existing -gt $order) { $order = $existing }
    }
    $transport = 'same-pc'
    if ($Room.Path.StartsWith('\\')) { $transport = 'share' }
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
    Write-RelayText (Join-Path $Room.Path 'PROMPT-JOIN.txt') $prompt
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
        $promptPath = Join-Path $Room.Path 'PROMPT-JOIN.txt'
        if ((Read-RelayText $promptPath).TrimEnd() -ne $prompt.TrimEnd() -and $PSCmdlet.ShouldProcess("$($Room.Id): PROMPT-JOIN.txt", 'Write again from the plugin package')) {
            Write-RelayText $promptPath $prompt
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

Export-ModuleMember -Function *-Relay*
