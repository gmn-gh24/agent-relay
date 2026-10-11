#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a room from the room package and an answers file, and writes the start prompt for each agent.

.DESCRIPTION
    Creates <rooms_root>\<room id>\ with the protocol reference, the tools, one folder per agent (the coordinator
    included) holding its instructions and wrappers, and the standing-rules file. Everything only this PC may
    write is also kept as a canonical copy under .local\rooms\<room id>\canon, which the feed compares against.
    The start prompt of every agent is saved as PROMPT-<name>.txt in the room; the first one goes to the clipboard.

    The answers file is JSON; references\startup-interview.md describes every field. Minimal example:

        {
          "job": "Run the unit tests of the toy calculator and report what fails",
          "room_name": "toy calculator tests",
          "rooms_root": "C:\\temp\\agent-relay",
          "authority": "within-task",
          "coordinator": { "kind": "claude-code" },
          "open_seats": 0,
          "agents": [
            { "role": "tester", "kind": "codex", "transport": "same-pc",
              "task": "Run the tests and report.", "done_when": "A report with the test output is sent.",
              "roots": [ { "root": "C:\\temp\\toy", "may": [ "tests/*" ] } ] }
          ]
        }

    The room folder is named after "room_name": the project, script or task in a few words
    ("toy calculator tests" becomes toy-calculator-tests). Without it the first words of the job are used.
    Today's date is added only when a room of that name already exists.

    "agents" names each agent in advance and gives each its own start prompt. "open_seats" adds seats nobody is
    named for: one join prompt (PROMPT-JOIN.txt) serves any agent on any machine that reaches the room folder;
    each takes the next free seat, says what it is in its introduction, and gets its task as a message. A room
    needs at least one of the two.

    Every answer is checked before anything is built (agent kinds, kinds of work, names, work files). A room that
    cannot be finished leaves nothing behind: its folder and this PC's folder of it are removed again. A folder
    of this PC for the same room id that an earlier attempt left is not built on: it is refused.

.PARAMETER AnswersFile
    Path of the JSON answers file.

.PARAMETER NoClipboard
    Do not put the first start prompt on the clipboard (the tests use this).

.PARAMETER PassThru
    Return an object (room id, path, names, prompts) instead of the text summary.

.EXAMPLE
    .\New-RelayRoom.ps1 -AnswersFile C:\temp\answers.json

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AnswersFile,
    [switch]$NoClipboard,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

if (-not (Test-Path -LiteralPath $AnswersFile)) { throw "No answers file: $AnswersFile" }
$answers = ConvertFrom-RelayJson (Read-RelayText $AnswersFile)

$job = ([string](Get-RelayProperty $answers 'job' '')).Trim()
if (-not $job) { throw 'The answers file needs "job": one line that says what this room is for' }
$job = ConvertTo-RelayHeaderText $job

$roomsRoot = ([string](Get-RelayProperty $answers 'rooms_root' 'C:\temp\agent-relay')).TrimEnd('\', '/')
# This PC's folders of its rooms: one that is there already belongs to a room of that id, or is left from one
$localRooms = Join-Path (Get-RelayLocalRoot) 'rooms'

# A room is named after what it is for: the project, script or task. "room_name" says it in a few words; without
# it the first words of the job do. A date is added only where it tells two rooms of the same name apart.
# "room_id" is the whole name as given, for the owner who wants one exactly.
$roomId = ([string](Get-RelayProperty $answers 'room_id' '')).Trim().ToLowerInvariant()
if (-not $roomId) {
    $nameSource = ([string](Get-RelayProperty $answers 'room_name' '')).Trim()
    if (-not $nameSource) { $nameSource = $job }
    $baseName = ConvertTo-RelayRoomSlug $nameSource
    $known = @(Get-RelayRoomIndex | ForEach-Object { [string]$_.id })
    $roomId = $baseName
    $attempt = 1
    while ((Test-Path -LiteralPath (Join-Path $roomsRoot $roomId)) -or ($known -contains $roomId) -or (Test-Path -LiteralPath (Join-Path $localRooms $roomId))) {
        $roomId = '{0}-{1}' -f $baseName, (Format-RelayUtc -Time (Get-Date) -Format 'yyyy-MM-dd')
        if ($attempt -gt 1) { $roomId = "$roomId-$attempt" }
        $attempt++
    }
}
if ($roomId -notmatch '^[a-z0-9][a-z0-9-]{2,60}$') { throw "The room id '$roomId' may hold lower-case letters, digits and dashes only (3 to 61 characters)" }

$authority = [string](Get-RelayProperty $answers 'authority' 'within-task')
if (@('within-task', 'report-after', 'owner-approves') -notcontains $authority) { throw "Authority '$authority' is not one of within-task, report-after, owner-approves" }
$agentAnswers = @(Get-RelayProperty $answers 'agents' @())
$openSeats = [int](Get-RelayProperty $answers 'open_seats' 0)
if ($openSeats -lt 0 -or $openSeats -gt 200) { throw '"open_seats" is a number from 0 to 200' }
if ($agentAnswers.Count -lt 1 -and $openSeats -lt 1) { throw 'The answers file needs at least one entry under "agents", or "open_seats" of 1 or more' }

$roomPath = Get-RelayNormalPath (Join-Path $roomsRoot $roomId)
# What is put into a command line for somebody to paste cannot hold a double quote or a line break
Assert-RelayPastePath $roomPath 'The room folder'
Assert-RelayPastePath ([string](Get-RelayProperty $answers 'reach_path' '')) 'The path other machines reach the room by (reach_path)'
if (Test-Path -LiteralPath $roomPath) { throw "The room folder already exists: $roomPath. Choose another room_id, or resume that room." }
foreach ($entry in @(Get-RelayRoomIndex)) { if ($entry.id -eq $roomId) { throw "A room with the id '$roomId' is already in the room index ($($entry.path)). Choose another room_id." } }
# The first tamper pass of a room built on such a folder would put its old seats and prompts into the new room
$localRoom = Join-Path $localRooms $roomId
if (Test-Path -LiteralPath $localRoom) { throw "This PC already keeps a folder for a room '$roomId' that is not in its room index: $localRoom. It is left from an earlier attempt or from a room that was taken out of the index, and a new room would take over its seats. Remove that folder, or choose another room_id." }

# The room folder as other machines reach it. A share's server is named by its address: an agent on another
# subnet may not resolve the name this PC uses.
$reachPath = ([string](Get-RelayProperty $answers 'reach_path' '')).TrimEnd('\', '/')
if (-not $reachPath) { $reachPath = Resolve-RelayRemotePath $roomPath }
Assert-RelayPastePath $reachPath 'The path other machines reach the room by (reach_path)'

# Every answer is checked before anything is built: a typo found halfway would leave half a room
$coordinatorAnswer = Get-RelayProperty $answers 'coordinator' ([pscustomobject]@{})
$coordinatorKind = [string](Get-RelayProperty $coordinatorAnswer 'kind' 'claude-code')
Assert-RelayAgentKind $coordinatorKind 'The kind of the coordinator'
$coordinatorSpec = ConvertTo-RelaySeatSpec -Agent ([pscustomobject]@{
        role      = 'coordinator'
        kind      = $coordinatorKind
        transport = 'same-pc'
        machine   = [Environment]::MachineName
    }) -RoomId $roomId -DevRoomPath $roomPath
$specs = New-Object System.Collections.Generic.List[object]
foreach ($agentAnswer in $agentAnswers) {
    Assert-RelayAgentKind ([string](Get-RelayProperty $agentAnswer 'kind' 'generic'))
    $spec = ConvertTo-RelaySeatSpec -Agent $agentAnswer -RoomId $roomId -DevRoomPath $roomPath -RemoteRoomPath $reachPath
    $null = Get-RelayWorkKind ([string]$spec['work'])
    $specs.Add($spec)
}
$workFiles = @(Get-RelayProperty $answers 'work_files' @() | ForEach-Object { [string]$_ })
foreach ($sourcePath in $workFiles) { if (-not (Test-Path -LiteralPath $sourcePath)) { throw "A work file to stage does not exist: $sourcePath" } }

# Names: the coordinator first, then the agents in the order given
$taken = New-Object System.Collections.Generic.List[string]
$coordinatorName = Select-RelayName -Machine ([Environment]::MachineName) -Role 'coordinator' -Taken @() -Wanted ([string](Get-RelayProperty $coordinatorAnswer 'name' '')) -Transient
$taken.Add($coordinatorName)
$names = New-Object System.Collections.Generic.List[string]
$wanted = @($specs | ForEach-Object { [string]$_['wanted_name'] })
foreach ($spec in $specs) {
    $name = Select-RelayName -Machine $spec['machine'] -Role $spec['role'] -Taken $taken.ToArray() -Wanted $spec['wanted_name'] -Reserved $wanted
    $taken.Add($name)
    $names.Add($name)
}

$isBuilt = $false
try {
    foreach ($folder in $roomPath, (Join-Path $roomPath 'tools'), (Join-Path $roomPath 'agents'), (Join-Path $roomPath 'files'), (Join-Path $roomPath 'work')) {
        $null = New-Item -ItemType Directory -Path $folder -Force
    }
    $package = Get-RelayPackageRoot
    $packageVersion = (Read-RelayText (Join-Path $package 'VERSION')).Trim()
    $roomInfo = [ordered]@{
        room           = $roomId
        protocol       = '3'
        package        = $packageVersion
        job            = $job
        coordinator    = $coordinatorName
        authority      = $authority
        created_utc    = (Format-RelayUtc)
        stale_minutes  = [int](Get-RelayProperty $answers 'stale_minutes' 5)
        pickup_minutes = [int](Get-RelayProperty $answers 'pickup_minutes' 30)
        silent_minutes = [int](Get-RelayProperty $answers 'silent_minutes' 10)
        park_after     = [int](Get-RelayProperty $answers 'park_after' 6)
        proposal_limit = [int](Get-RelayProperty $answers 'proposal_limit' 3)
    }
    # Each agent's tool names its terminal tab after the agent, unless the owner does not want that
    $tabTitles = ([string](Get-RelayProperty $answers 'tab_titles' 'yes')).Trim().ToLowerInvariant()
    if (@('no', 'false', '0') -contains $tabTitles) { $roomInfo['tab_titles'] = 'no' } else { $roomInfo['tab_titles'] = 'yes' }
    $roomInfo['reach'] = $reachPath
    # What the room is comes from this PC's canonical copy: it is written first, and the room object is made from it
    $room = Get-RelayRoomObject -Id $roomId -Path $roomPath
    Write-RelayGuardedText $room 'ROOM' (ConvertTo-RelayKeyValueText $roomInfo)
    $room = Get-RelayRoomObject -Id $roomId -Path $roomPath

    Copy-RelayGuardedFile $room 'PROTOCOL.md' (Join-Path $package 'PROTOCOL.md')
    Copy-RelayGuardedFile $room 'tools/VERSION' (Join-Path $package 'VERSION')
    foreach ($tool in @(Get-ChildItem -LiteralPath (Join-Path $package 'tools') -File)) { Copy-RelayGuardedFile $room "tools/$($tool.Name)" $tool.FullName }

    $decisions = @(
        "# Standing rules and owner decisions: $roomId"
        ''
        'Only the coordinator writes this file. Read it before you ask: what is answered here is not asked again.'
        ''
        '| Date | Rule or decision |'
        '|------|------------------|'
    ) -join "`n"
    Write-RelayGuardedText $room 'DECISIONS.md' ($decisions + "`n")

    $prompts = [ordered]@{}
    $seats = New-Object System.Collections.Generic.List[object]

    # The coordinator's start prompt stays on this PC (Add-RelayAgentSeat writes none into the room)
    $null = Add-RelayAgentSeat -Room $room -Name $coordinatorName -Spec $coordinatorSpec -Generation 1 -IsCoordinator
    $seats.Add([pscustomobject]@{ name = $coordinatorName; role = 'coordinator'; machine = $coordinatorSpec['machine']; kind = $coordinatorSpec['kind']; transport = 'same-pc'; wake = $coordinatorSpec['wake'] })

    for ($position = 0; $position -lt $specs.Count; $position++) {
        $spec = $specs[$position]
        $name = $names[$position]
        $prompts[$name] = Add-RelayAgentSeat -Room $room -Name $name -Spec $spec -Generation 1
        $seats.Add([pscustomobject]@{ name = $name; role = $spec['role']; machine = $spec['machine']; kind = $spec['kind']; transport = $spec['transport']; wake = $spec['wake'] })
    }

    $joinPrompt = ''
    if ($openSeats -gt 0) {
        $opened = Add-RelayOpenSeat -Room $room -Count $openSeats
        $joinPrompt = $opened.Prompt
        foreach ($name in $opened.Names) { $seats.Add([pscustomobject]@{ name = $name; role = '(open seat)'; machine = '-'; kind = 'auto'; transport = '-'; wake = 'auto' }) }
    }

    foreach ($sourcePath in $workFiles) { Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $roomPath 'work') -Recurse -Force }

    # The index last, under its lock: a room is in it only when it is whole, and an index that cannot be read is
    # an error, never an empty list that would lose every other room
    $indexEntry = [pscustomobject]@{ id = $roomId; path = $roomPath; job = $job; coordinator = $coordinatorName; created_utc = $roomInfo['created_utc']; closed_utc = '' }
    Update-RelayRoomIndex -Change {
        param($entries)
        foreach ($other in @($entries)) { if ([string](Get-RelayProperty $other 'id' '') -ceq $roomId) { throw "A room with the id '$roomId' came into the room index while this one was built: this one is not kept" } }
        @($entries) + $indexEntry
    }
    $isBuilt = $true
}
finally {
    if (-not $isBuilt) {
        # What this run made goes again: a half-built room outside the index would only be in the way, and this PC's
        # folder of it would be taken over by the next room of that id
        foreach ($folder in $roomPath, $localRoom) {
            if (-not (Test-Path -LiteralPath $folder)) { continue }
            try { Remove-RelayTree -Path $folder -Confirm:$false }
            catch { Write-Warning "Could not remove $folder after the room could not be built: $($_.Exception.Message)" }
        }
    }
}

# On the clipboard: the join prompt when the room has open seats, otherwise the first agent's start prompt
$copyText = $joinPrompt
$copyLabel = 'the join prompt (the same for every agent that joins)'
if (-not $copyText) {
    $firstName = @($prompts.Keys)[0]
    $copyText = [string]$prompts[$firstName]
    $copyLabel = "the start prompt for $firstName"
}
$isCopied = $false
if (-not $NoClipboard) {
    try { Set-Clipboard -Value $copyText.TrimEnd(); $isCopied = $true } catch { $isCopied = $false }
}
# The coordinator runs its launcher on this PC, not a wrapper in the room
$coordinatorCall = Get-RelayCallLine -RoomPath $roomPath -Name $coordinatorName -Generation '1' -Shell 'powershell' -Launcher $room.Local

if ($PassThru) {
    return [pscustomobject]@{
        Id              = $roomId
        Path            = $roomPath
        Coordinator     = $coordinatorName
        CoordinatorCall = $coordinatorCall
        Seats           = $seats.ToArray()
        Prompts         = $prompts
        JoinPrompt      = $joinPrompt
        IsCopied        = $isCopied
    }
}

"ROOM $roomId created: $roomPath"
"job: $job"
"authority: $authority"
''
foreach ($seat in $seats) { '{0,-10} {1,-22} {2,-18} {3,-22} {4,-8} {5}' -f $seat.name, $seat.role, $seat.machine, $seat.kind, $seat.transport, $seat.wake }
''
"coordinator command: $coordinatorCall <verb>"
foreach ($name in $prompts.Keys) { "start prompt for ${name}: " + (Join-Path $roomPath "PROMPT-$name.txt") }
# What a kind needs from the owner to run the room's commands, once per kind (agent-kinds.json, coordinator_note)
Get-RelayCoordinatorNote -Kind @($seats | ForEach-Object { [string]$_.kind })
if ($joinPrompt) { "join prompt, for any agent ($openSeats free seat(s)): " + (Join-Path $roomPath 'PROMPT-JOIN.txt') }
if ($isCopied) { "on the clipboard: $copyLabel" }
"NEXT: run your own start ($coordinatorCall start <product> <model> <effort>), hand the prompts to the agents' sessions, then wait. Give no work to an agent before its introduction has arrived."
