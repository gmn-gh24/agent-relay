#Requires -Version 5.1

<#
.SYNOPSIS
    Writes the team plan of a running room (the PLAN file), changes one part of it, or shows it.

.DESCRIPTION
    The only writer of a room's PLAN. One action per call:

    -PlanFile   Writes the whole plan from a JSON file: goal, and parts with id, owner, status, depends,
                reviewer, title, files and notes. Left out: owner and reviewer are '-', status is 'todo',
                depends, files and notes are empty.
    -Part       Changes one part of the plan the room has: -Status, -Owner, -Reviewer (a name, or '-' for
                nobody) and -Note (adds a note). Give at least one.
    -Show       Prints the PLAN file as it is, or 'NO PLAN in room <id>'. Changes nothing.

    Everything is checked before anything is written. A fault throws 'Plan refused: <what and where>' and the
    room stays as it was. The revision goes up by one with every change; the plan to change is read from the canonical copy. One call writes at a time: it holds the mutex Global\agent-relay-plan-<room id>, and waits for it 30 seconds. The text is written to the canonical
    copy on this PC first and to the room second. The text ends with the line 'end: <revision>', which tells a reader the file is whole. Unless -NoLines is given, direct lines are opened between the
    owner of a part and the owners of the parts it depends on, and between the owner and the reviewer; the
    coordinator needs no line, and lines are only ever added.

.PARAMETER Room
    Room id or room folder.

.PARAMETER PlanFile
    JSON file with the whole plan.

.PARAMETER Part
    Id of the part to change.

.PARAMETER Status
    New status of the part: todo, doing, review, done or blocked.

.PARAMETER Owner
    New owner of the part: an agent's name, or - for nobody.

.PARAMETER Reviewer
    New reviewer of the part: an agent's name, or - for nobody.

.PARAMETER Note
    A note to add to the part.

.PARAMETER NoLines
    Do not open direct lines.

.EXAMPLE
    .\Set-RelayPlan.ps1 -Room 2026-10-10-docs -PlanFile .\plan.json

.EXAMPLE
    .\Set-RelayPlan.ps1 -Room 2026-10-10-docs -Part tool-ps -Status review -Reviewer henry

.EXAMPLE
    .\Set-RelayPlan.ps1 -Room 2026-10-10-docs -Show

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Plan', SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(Mandatory, ParameterSetName = 'Plan')][ValidateNotNullOrEmpty()][string]$PlanFile,
    [Parameter(Mandatory, ParameterSetName = 'Part')][ValidateNotNullOrEmpty()][string]$Part,
    [Parameter(ParameterSetName = 'Part')][string]$Status = '',
    [Parameter(ParameterSetName = 'Part')][string]$Owner = '',
    [Parameter(ParameterSetName = 'Part')][string]$Reviewer = '',
    [Parameter(ParameterSetName = 'Part')][string]$Note = '',
    [Parameter(Mandatory, ParameterSetName = 'Show')][switch]$Show,
    [Parameter(ParameterSetName = 'Plan')][Parameter(ParameterSetName = 'Part')][switch]$NoLines
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$statuses = @('todo', 'doing', 'review', 'done', 'blocked')
$idPattern = '^[a-z0-9-]{1,24}$'

function Get-PlanLength {
    # Characters, not UTF-16 units: a surrogate pair counts once
    param([string]$Text)
    return ($Text.Length - [regex]::Matches($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]').Count)
}

function Format-PlanColumn {
    # A value padded on the right with spaces up to its width in characters; a longer value is not cut
    param([string]$Text, [int]$Width)
    return ($Text + (' ' * [Math]::Max(0, $Width - (Get-PlanLength $Text))))
}

function Assert-PlanText {
    # A text field: text, no line break, no bar, no other control character, within its length in characters.
    # Returns it trimmed of spaces and tabs.
    param([string]$What, $Value, [int]$Min, [int]$Max)
    if ($Value -isnot [string]) { throw "Plan refused: $What must be text" }
    if ($Value -match '[\r\n\u2028\u2029]') { throw "Plan refused: $What must not contain a line break" }
    if ($Value.Contains('|')) { throw "Plan refused: $What must not contain a bar" }
    $text = $Value.Trim(' ', "`t")
    if ($text -match '\p{Cc}') { throw "Plan refused: $What must not contain a control character" }
    $length = Get-PlanLength $text
    if ($length -lt $Min -or $length -gt $Max) { throw "Plan refused: $What must have $Min to $Max characters (it has $length)" }
    return $text
}

function Assert-PlanPerson {
    # '-' or a name of the room's roster. Returns the name in lower case.
    param([string]$What, $Value, [string[]]$Roster)
    $name = (Assert-PlanText $What $Value 1 16).ToLowerInvariant()
    if ($name -ne '-' -and $Roster -notcontains $name) { throw "Plan refused: $What '$name' is not an agent of this room. Agents: $($Roster -join ', ')" }
    return $name
}

function ConvertTo-PlanPart {
    # One part object of the plan file, checked field by field
    param($Entry, [int]$Index, [string[]]$Roster)
    $where = "part #$Index"
    $id = Assert-PlanText "$where id" (Get-RelayProperty $Entry 'id' '') 1 24
    $where = "part '$id'"
    if ($id -cnotmatch $idPattern) { throw "Plan refused: $where id must match $idPattern" }
    $status = Assert-PlanText "$where status" (Get-RelayProperty $Entry 'status' 'todo') 1 16
    $depends = @(Get-RelayProperty $Entry 'depends' @() | ForEach-Object { Assert-PlanText "$where depends entry" $_ 1 24 })
    $files = @(Get-RelayProperty $Entry 'files' @() | ForEach-Object { Assert-PlanText "$where files entry" $_ 1 300 })
    $notes = @(Get-RelayProperty $Entry 'notes' @() | ForEach-Object { Assert-PlanText "$where note" $_ 1 300 })
    return [pscustomobject]@{
        Id       = $id
        Owner    = (Assert-PlanPerson "$where owner" (Get-RelayProperty $Entry 'owner' '-') $Roster)
        Status   = $status
        Depends  = $depends
        Reviewer = (Assert-PlanPerson "$where reviewer" (Get-RelayProperty $Entry 'reviewer' '-') $Roster)
        Title    = (Assert-PlanText "$where title" (Get-RelayProperty $Entry 'title' '') 1 120)
        Files    = $files
        Notes    = $notes
    }
}

function Assert-PlanPartText {
    # Every text of a part as it would be written, the retained ones too. The roster is not checked here.
    param($Item)
    $where = "part '$($Item.Id)'"
    $id = Assert-PlanText "$where id" $Item.Id 1 24
    if ($id -cnotmatch $idPattern) { throw "Plan refused: $where id must match $idPattern" }
    $null = Assert-PlanText "$where status" $Item.Status 1 16
    foreach ($name in $Item.Owner, $Item.Reviewer) { $null = Assert-PlanText "$where owner or reviewer" $name 1 16 }
    $null = Assert-PlanText "$where title" $Item.Title 1 120
    foreach ($entry in @($Item.Depends)) { $null = Assert-PlanText "$where depends entry" $entry 1 24 }
    foreach ($entry in @($Item.Files)) { $null = Assert-PlanText "$where files entry" $entry 1 300 }
    foreach ($entry in @($Item.Notes)) { $null = Assert-PlanText "$where note" $entry 1 300 }
}
function Assert-PlanModel {
    # The checks that concern the plan as a whole
    param([string]$Goal, [object[]]$Parts)
    $null = Assert-PlanText 'goal' $Goal 1 200
    foreach ($item in $Parts) { Assert-PlanPartText $item }
    $seen = @{}
    foreach ($item in $Parts) {
        if ($seen.ContainsKey($item.Id)) { throw "Plan refused: part id '$($item.Id)' is used twice" }
        $seen[$item.Id] = $item
    }
    $owners = @{}
    foreach ($item in $Parts) {
        if ($statuses -cnotcontains $item.Status) { throw "Plan refused: part '$($item.Id)' has status '$($item.Status)'; it must be one of $($statuses -join ', ')" }
        if ($item.Reviewer -ne '-' -and $item.Reviewer -eq $item.Owner) { throw "Plan refused: part '$($item.Id)' has $($item.Owner) as owner and as reviewer" }
        foreach ($dependency in $item.Depends) {
            if ($dependency -eq $item.Id) { throw "Plan refused: part '$($item.Id)' depends on itself" }
            if (-not $seen.ContainsKey($dependency)) { throw "Plan refused: part '$($item.Id)' depends on '$dependency', which is not a part of the plan" }
        }
        foreach ($file in $item.Files) {
            $key = $file.ToLowerInvariant()
            if ($owners.ContainsKey($key) -and $owners[$key] -ne $item.Id) { throw "Plan refused: the files entry '$file' is given to the parts '$($owners[$key])' and '$($item.Id)'" }
            $owners[$key] = $item.Id
        }
    }
    # A cycle: walk the dependencies depth first, remembering the way
    $state = @{}
    $walk = {
        param([string]$Id, [string[]]$Path)
        if ($state[$Id] -eq 'done') { return }
        if ($state[$Id] -eq 'open') { throw "Plan refused: the parts depend on each other in a circle: $((@($Path) + $Id) -join ' -> ')" }
        $state[$Id] = 'open'
        foreach ($next in $seen[$Id].Depends) { & $walk $next (@($Path) + $Id) }
        $state[$Id] = 'done'
    }
    foreach ($item in $Parts) { & $walk $item.Id @() }
}

function Read-PlanFile {
    # A PLAN text as a revision, a goal and the parts. Revision 0 and no parts when it holds no plan: line with a
    # number of up to nine digits. Complete is true when it has an end: line equal to the plan: line and every
    # line is well formed. The first of two equal keys counts, and so does the first part of an id.
    param([string]$Text)
    $plan = [pscustomobject]@{ Revision = 0; Goal = ''; Parts = @(); Complete = $false; UsedUp = $false }
    $list = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    $revisionText = ''
    $endText = ''
    $seenPlan = $false
    $seenEnd = $false
    $seenGoal = $false
    $wellFormed = $true
    foreach ($line in ($Text -split "`n")) {
        # Of two equal keys the first line counts, whatever it holds
        if ($line.StartsWith('plan:')) { if (-not $seenPlan) { $seenPlan = $true; $revisionText = $line.Substring(5).Trim(' ', "`t") }; continue }
        if ($line.StartsWith('end:')) { if (-not $seenEnd) { $seenEnd = $true; $endText = $line.Substring(4).Trim(' ', "`t") }; continue }
        if ($line.StartsWith('goal:')) { if (-not $seenGoal) { $seenGoal = $true; $plan.Goal = $line.Substring(5).Trim(' ', "`t") }; continue }
        $fields = @($line -split ' \| ')
        if ($line.StartsWith('part:')) {
            if ($fields.Count -lt 6) { $wellFormed = $false; continue }
            $first = ($fields[0] -replace '^part:', '').Trim(' ', "`t")
            if ($byId.ContainsKey($first)) { continue }
            $depends = @()
            if ($fields[3].Trim(' ', "`t") -notin '-', '') { $depends = @($fields[3] -split ',' | ForEach-Object { $_.Trim(' ', "`t") }) }
            $item = [pscustomobject]@{ Id = $first; Owner = $fields[1].Trim(' ', "`t"); Status = $fields[2].Trim(' ', "`t"); Depends = $depends; Reviewer = $fields[4].Trim(' ', "`t"); Title = (($fields[5..($fields.Count - 1)] -join ' | ').Trim(' ', "`t")); Files = @(); Notes = @() }
            $list.Add($item)
            $byId[$first] = $item
        }
        elseif ($line.StartsWith('files:') -or $line.StartsWith('note:')) {
            if ($fields.Count -lt 2) { $wellFormed = $false; continue }
            $first = ($fields[0] -replace '^(files|note):', '').Trim(' ', "`t")
            if (-not $byId.ContainsKey($first)) { $wellFormed = $false; continue }
            $value = (($fields[1..($fields.Count - 1)] -join ' | ').Trim(' ', "`t"))
            if ($line.StartsWith('files:')) { $byId[$first].Files += $value } else { $byId[$first].Notes += $value }
        }
    }
    # The counter as written, whatever its length: nine digits that are 999999999 or more mean it is used up. Only
    # the digits 0 to 9 make a number; a first plan: line that holds anything else means the plan cannot be read.
    $revisionDigits = ''
    if ($revisionText -match '^[0-9]+$') {
        $revisionDigits = $revisionText.TrimStart('0')
        if ($revisionDigits.Length -gt 9 -or ($revisionDigits.Length -eq 9 -and [string]::CompareOrdinal($revisionDigits, '999999999') -ge 0)) { $plan.UsedUp = $true; $plan.Revision = 999999999 }
        elseif ($revisionDigits) { $plan.Revision = [int]$revisionDigits }
    }
    $endDigits = ''
    if ($endText -match '^[0-9]+$') { $endDigits = $endText.TrimStart('0') }
    $plan.Parts = $list.ToArray()
    $plan.Complete = ($wellFormed -and $revisionDigits -ne '' -and $endDigits -ne '' -and $endDigits -eq $revisionDigits)
    return $plan
}
function ConvertTo-PlanText {
    param([int]$Revision, [string]$Goal, [object[]]$Parts)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("plan: $Revision")
    $lines.Add('updated_utc: ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))
    $lines.Add("goal: $Goal")
    foreach ($item in $Parts) {
        $depends = '-'
        if (@($item.Depends).Count -gt 0) { $depends = @($item.Depends) -join ',' }
        $lines.Add("part: $($item.Id) | $($item.Owner) | $($item.Status) | $depends | $($item.Reviewer) | $($item.Title)")
    }
    foreach ($item in $Parts) { foreach ($file in $item.Files) { $lines.Add("files: $($item.Id) | $file") } }
    foreach ($item in $Parts) { foreach ($text in $item.Notes) { $lines.Add("note: $($item.Id) | $text") } }
    $lines.Add("end: $Revision")
    return (($lines -join "`n") + "`n")
}

function Get-PlanLinePair {
    # The pairs of agents the plan puts side by side, each as 'a b' with a before b, and whether it is open already
    param([object[]]$Parts, $RoomObject)
    $wanted = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    $byId = @{}
    foreach ($item in $Parts) { $byId[$item.Id] = $item }
    foreach ($item in $Parts) {
        $others = New-Object System.Collections.Generic.List[string]
        foreach ($dependency in $item.Depends) { $others.Add($byId[$dependency].Owner) }
        $others.Add($item.Reviewer)
        foreach ($other in $others) {
            if ($item.Owner -eq '-' -or $other -eq '-' -or $item.Owner -eq $other) { continue }
            if ($item.Owner -eq $RoomObject.Coordinator -or $other -eq $RoomObject.Coordinator) { continue }
            if ([string]::CompareOrdinal($item.Owner, $other) -lt 0) { $null = $wanted.Add("$($item.Owner) $other") } else { $null = $wanted.Add("$other $($item.Owner)") }
        }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in $wanted) {
        $names = $key -split ' '
        $open = $true
        foreach ($direction in @(@($names[0], $names[1]), @($names[1], $names[0]))) {
            $existing = @(((Read-RelayText (Join-Path $RoomObject.Canon "agents/$($direction[0])/lines")) -split "`n") | Where-Object { $_.Trim() })
            if ($existing -notcontains $direction[1]) { $open = $false }
        }
        if (-not $open) { $result.Add($names) }
    }
    return $result.ToArray()
}

$roomObject = Resolve-RelayRoom $Room

if ($Show) {
    $current = Read-RelayText (Join-Path $roomObject.Path 'PLAN')
    if ($current -notmatch '(?m)^plan:') { "NO PLAN in room $($roomObject.Id)"; return }
    ($current.TrimEnd("`n") -split "`n")
    return
}

if ($roomObject.IsClosed) { throw "Plan refused: the room $($roomObject.Id) is closed" }
$roster = @(Get-RelayRoster $roomObject)

# One writer at a time: from before the current plan is read until after the last line file is written
$mutex = New-Object System.Threading.Mutex($false, "Global\agent-relay-plan-$($roomObject.Id)")
$held = $false
try {
    try { $held = $mutex.WaitOne(30000) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw "Plan refused: another Set-RelayPlan is running for room $($roomObject.Id)" }

    # The plan about to be replaced is read from this PC's canonical copy: the room's file may have been tampered with
    $canonPlan = Join-Path $roomObject.Canon 'PLAN'
    $current = Read-PlanFile (Read-RelayText $canonPlan)
    $hasCanon = Test-Path -LiteralPath $canonPlan
    if ($current.UsedUp) { throw "Plan refused: the revision counter of room $($roomObject.Id) is used up" }

    if ($PSCmdlet.ParameterSetName -eq 'Plan') {
        if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) { throw "Plan refused: there is no plan file '$PlanFile'" }
        try { $source = ConvertFrom-RelayJson (Read-RelayText (Resolve-Path -LiteralPath $PlanFile).ProviderPath) }
        catch { throw "Plan refused: the plan file is not valid JSON: $($_.Exception.Message)" }
        if ($null -eq $source -or $source -is [string] -or $source -is [System.Array]) { throw 'Plan refused: the plan file must hold one JSON object with a goal and parts' }
        $goal = Assert-PlanText 'goal' (Get-RelayProperty $source 'goal' '') 1 200
        $parts = @()
        $index = 0
        foreach ($entry in @(Get-RelayProperty $source 'parts' @())) {
            $index++
            $parts += ConvertTo-PlanPart $entry $index $roster
        }
    }
    else {
        if (-not $hasCanon) { throw "Plan refused: room $($roomObject.Id) has no plan; write one first with -PlanFile" }
        if (-not $current.Complete) { throw "Plan refused: the plan of room $($roomObject.Id) cannot be read; write it again with -PlanFile" }
        if (-not $Status -and -not $Owner -and -not $Reviewer -and -not $Note) { throw 'Plan refused: give at least one of -Status, -Owner, -Reviewer, -Note' }
        $goal = $current.Goal
        $parts = @($current.Parts)
        $target = @($parts | Where-Object { $_.Id -eq $Part })
        if ($target.Count -eq 0) { throw "Plan refused: the plan has no part '$Part'. Parts: $((@($parts | ForEach-Object { $_.Id })) -join ', ')" }
        $item = $target[0]
        # The roster is checked for the names this call sets, not for the names the plan already holds
        if ($Status) { $item.Status = Assert-PlanText "part '$Part' status" $Status 1 16 }
        if ($Owner) { $item.Owner = Assert-PlanPerson "part '$Part' owner" $Owner $roster }
        if ($Reviewer) { $item.Reviewer = Assert-PlanPerson "part '$Part' reviewer" $Reviewer $roster }
        if ($Note) { $item.Notes += Assert-PlanText "part '$Part' note" $Note 1 300 }
    }

    Assert-PlanModel -Goal $goal -Parts $parts

    $revision = $current.Revision + 1
    $text = ConvertTo-PlanText -Revision $revision -Goal $goal -Parts $parts
    $pairs = @()
    if (-not $NoLines) { $pairs = @(Get-PlanLinePair -Parts $parts -RoomObject $roomObject) }

    if (-not $PSCmdlet.ShouldProcess("room $($roomObject.Id)", "write plan $revision with $(@($parts).Count) part(s)")) {
        foreach ($pair in $pairs) { $null = $PSCmdlet.ShouldProcess("agents $($pair[0]) and $($pair[1])", 'open a direct line') }
        return
    }

    Write-RelayGuardedText $roomObject 'PLAN' $text
    $opened = New-Object System.Collections.Generic.List[string]
    foreach ($pair in $pairs) {
        if (-not $PSCmdlet.ShouldProcess("agents $($pair[0]) and $($pair[1])", 'open a direct line')) { continue }
        foreach ($direction in @(@($pair[0], $pair[1]), @($pair[1], $pair[0]))) {
            $path = "agents/$($direction[0])/lines"
            $existing = @(((Read-RelayText (Join-Path $roomObject.Canon $path)) -split "`n") | Where-Object { $_.Trim() })
            if ($existing -notcontains $direction[1]) { Write-RelayGuardedText $roomObject $path ((@($existing + $direction[1]) -join "`n") + "`n") }
        }
        $opened.Add("LINE open between $($pair[0]) and $($pair[1])")
    }
    "PLAN $revision for room $($roomObject.Id): $(@($parts).Count) part(s)"
    foreach ($item in $parts) { '  ' + (Format-PlanColumn $item.Id 12) + '  ' + (Format-PlanColumn $item.Status 8) + '  ' + (Format-PlanColumn $item.Owner 9) + '  ' + $item.Title }
    $opened
    'NEXT: the agents are shown the new plan with the next message they receive, or at once with the verb team.'
}
finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}