#Requires -Version 5.1

<#
.SYNOPSIS
    Adds an agent to a running room, replaces an agent's session, retires an agent, pauses or stops one, or
    opens a direct line between two agents.

.DESCRIPTION
    One action per call:

    -AnswersFile   Adds the agent or agents described in a JSON file (one agent object, or {"agents": [...]},
                   the same fields as in the answers file of New-RelayRoom.ps1). A room has no upper limit. Every
                   entry is checked before the first is added; an empty "agents" list and an agent kind that
                   agent-kinds.json does not know are refused.
    -Replace       A new session takes over an agent's name: the generation goes up by one, new wrappers and a
                   new start prompt are written, and the old session is told to stop the next time it calls the
                   tool. -Kind switches the agent kind for the new session (one that agent-kinds.json knows).
    -Retire        The agent leaves the room for good. Its messages stay.
    -Control       Pauses, resumes or stops one agent (-State pause, run or stop, with an optional -Note).
    -Line          Opens a direct line between two agents (-Line emma -To jack), both ways.
    -OpenSeats     Adds that many seats nobody is named for. Any agent given the room's join prompt
                   (PROMPT-JOIN.txt) takes the next free one and says what it is in its introduction.
    -JoinPrompt    Prints the room's join prompt again and puts it on the clipboard.
    -Assign        Gives an agent that is already in the room a new assignment from a JSON file with one agent
                   object: role, work, expertise, standards, doc_tools, task, done_when, non_goals, roots, may,
                   propose_ok, ask_first, never, machine_care, machine_notes. Fields left out stay as they are.
                   This is how an agent that came in through the join prompt gets its role and its limits, once
                   its introduction has shown what and where it is. Its session, name and generation stay; the
                   tool shows it the new assignment with the next message it receives.

    Everything written here goes to the canonical copy on this PC first and to the room second.

.PARAMETER Room
    Room id or room folder.

.PARAMETER NoClipboard
    Do not put the start prompt on the clipboard.

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Replace emma -Kind codex

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Control jack -State pause -Note 'owner is looking at the machine'

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(Mandatory, ParameterSetName = 'Add')][Parameter(Mandatory, ParameterSetName = 'Assign')][ValidateNotNullOrEmpty()][string]$AnswersFile,
    [Parameter(Mandatory, ParameterSetName = 'Assign')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Assign,
    [Parameter(Mandatory, ParameterSetName = 'Replace')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Replace,
    [Parameter(ParameterSetName = 'Replace')][string]$Kind = '',
    [Parameter(Mandatory, ParameterSetName = 'Retire')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Retire,
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Control,
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidateSet('pause', 'run', 'stop')][string]$State,
    [Parameter(ParameterSetName = 'Control')][string]$Note = '',
    [Parameter(Mandatory, ParameterSetName = 'Line')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Line,
    [Parameter(Mandatory, ParameterSetName = 'Line')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$To,
    [Parameter(Mandatory, ParameterSetName = 'Open')][ValidateRange(1, 200)][int]$OpenSeats,
    [Parameter(Mandatory, ParameterSetName = 'Prompt')][switch]$JoinPrompt,
    [switch]$NoClipboard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$roomObject = Resolve-RelayRoom $Room
if ($roomObject.IsClosed) { throw "The room $($roomObject.Id) is closed" }
$all = @(Get-RelayRoster $roomObject -IncludeRetired)

function Assert-Agent {
    param([string]$Name)
    if ($all -notcontains $Name) { throw "There is no agent '$Name' in room $($roomObject.Id). Agents: $($all -join ', ')" }
}

$useClipboard = -not $NoClipboard

function Copy-Prompt {
    param([string]$Text, [string]$Name, [bool]$Enabled)
    if (-not $Enabled) { return }
    try { Set-Clipboard -Value $Text.TrimEnd(); "on the clipboard: the start prompt for $Name" } catch { $null = $_ }
}

switch ($PSCmdlet.ParameterSetName) {
    'Add' {
        if (-not (Test-Path -LiteralPath $AnswersFile)) { throw "No answers file: $AnswersFile" }
        $answers = ConvertFrom-RelayJson (Read-RelayText $AnswersFile)
        # {"agents": [...]} or one agent object; an "agents" list with nobody in it adds nobody, not a default seat
        if ($null -ne $answers -and $null -ne $answers.PSObject.Properties['agents']) {
            $entries = @(Get-RelayProperty $answers 'agents' @())
            if ($entries.Count -eq 0) { throw "The answers file $AnswersFile has an empty `"agents`" list: name at least one agent" }
        }
        else { $entries = @($answers) }
        # Every entry is checked before the first one is added: a typo in the third must not leave two added
        $specs = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $entries) {
            Assert-RelayAgentKind ([string](Get-RelayProperty $entry 'kind' 'generic'))
            $spec = ConvertTo-RelaySeatSpec -Agent $entry -RoomId $roomObject.Id -DevRoomPath $roomObject.Path -RemoteRoomPath (Get-RelayReachPath $roomObject)
            $null = Get-RelayWorkKind ([string]$spec['work'])
            $specs.Add($spec)
        }
        $taken = New-Object System.Collections.Generic.List[string]
        foreach ($name in $all) { $taken.Add($name) }
        $lastPrompt = ''
        $lastName = ''
        foreach ($spec in $specs) {
            $name = Select-RelayName -Machine $spec['machine'] -Role $spec['role'] -Taken $taken.ToArray() -Wanted $spec['wanted_name']
            $taken.Add($name)
            $lastPrompt = Add-RelayAgentSeat -Room $roomObject -Name $name -Spec $spec -Generation 1
            $lastName = $name
            "ADDED $name ($($spec['role']), $($spec['kind']), $($spec['transport'])) to room $($roomObject.Id)"
            "start prompt: " + (Join-Path $roomObject.Path "PROMPT-$name.txt")
        }
        # What a kind needs from the owner to run the room's commands, once per kind
        Get-RelayCoordinatorNote -Kind @($specs | ForEach-Object { [string]$_['kind'] })
        if ($lastName) { Copy-Prompt $lastPrompt $lastName $useClipboard }
        'NEXT: hand each start prompt to its agent''s session. Give no work to an agent before its introduction has arrived.'
    }
    'Replace' {
        $name = $Replace.ToLowerInvariant()
        Assert-Agent $name
        $spec = Read-RelaySeatSpec $roomObject $name
        if ($Kind) {
            Assert-RelayAgentKind $Kind
            $spec = Switch-RelaySeatKind -Spec $spec -Kind $Kind
        }
        # The generation and the retirement come from this PC's canonical copy: the room's files are the agents' to write
        $canonDir = Join-Path (Join-Path $roomObject.Canon 'agents') $name
        if (Test-Path -LiteralPath (Join-Path $canonDir 'retired')) { throw "The agent '$name' is retired; add a new agent instead" }
        $current = Get-RelayCanonicalGeneration $roomObject $name
        $next = $current + 1
        $prompt = Add-RelayAgentSeat -Room $roomObject -Name $name -Spec $spec -Generation $next -IsCoordinator:($name -eq $roomObject.Coordinator)
        "REPLACED ${name}: generation $next ($($spec['kind'])). The old session is told to stop at its next command."
        if ($name -eq $roomObject.Coordinator) {
            # The coordinator's start prompt stays on this PC: there is none in the room to take away
            "NEXT: run your own start with the new launcher: " + (Get-RelayCallLine -RoomPath $roomObject.Path -Name $name -Generation ([string]$next) -Shell 'powershell' -Launcher $roomObject.Local) + ' start <product> <model> <effort>'
        }
        else {
            "start prompt: " + (Join-Path $roomObject.Path "PROMPT-$name.txt")
            Get-RelayCoordinatorNote -Kind @([string]$spec['kind'])
            Copy-Prompt $prompt $name $useClipboard
            'NEXT: paste the start prompt into the new session. Its start prints the requests the old session left open.'
        }
    }
    'Retire' {
        $name = $Retire.ToLowerInvariant()
        Assert-Agent $name
        if ($name -eq $roomObject.Coordinator) { throw 'The coordinator cannot be retired; close the room instead' }
        Write-RelayGuardedText $roomObject "agents/$name/retired" ("retired_utc: {0}`n" -f (Format-RelayUtc))
        "RETIRED $name in room $($roomObject.Id). Its messages stay; nobody can write to it any more."
        "NEXT: give what $name was working on to another agent, if anything is left, and tell the agents who worked with it in a note."
    }
    'Control' {
        $name = $Control.ToLowerInvariant()
        Assert-Agent $name
        if ($name -eq $roomObject.Coordinator) { throw 'The coordinator is not paused or stopped through the room' }
        Write-RelayGuardedText $roomObject "agents/$name/control" ("state: {0}`nnote: {1}`n" -f $State, (ConvertTo-RelayHeaderText $Note))
        "CONTROL ${name}: $State. The agent learns it at its next command; a waiting agent within seconds."
        switch ($State) {
            'pause' { "NEXT: resume it with -Control $name -State run when the reason is gone." }
            'stop' { "NEXT: give it a new session with -Replace $name, or retire it with -Retire $name." }
            default { 'NEXT: carry on; it goes on with its work at its next command.' }
        }
    }
    'Line' {
        $first = $Line.ToLowerInvariant()
        $second = $To.ToLowerInvariant()
        Assert-Agent $first
        Assert-Agent $second
        if ($first -eq $second) { throw 'A line needs two different agents' }
        Add-RelayLinePair -Room $roomObject -First $first -Second $second
        "LINE open between $first and $second, both ways."
        'NEXT: tell both of them in a note what the line is for.'
    }
    'Assign' {
        $name = $Assign.ToLowerInvariant()
        Assert-Agent $name
        if ($name -eq $roomObject.Coordinator) { throw 'The coordinator has no assignment to change' }
        $agentDir = Join-Path (Join-Path $roomObject.Path 'agents') $name
        if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $roomObject.Canon 'agents') $name) 'retired')) { throw "The agent '$name' is retired" }
        if (-not (Test-Path -LiteralPath $AnswersFile)) { throw "No answers file: $AnswersFile" }
        $card = Read-RelayKeyValue (Join-Path $agentDir 'card')
        if ($card.Count -eq 0) { throw "The agent '$name' has not introduced itself yet: an assignment follows the introduction, it does not come before it" }
        $spec = Merge-RelaySeatSpec -Spec (Read-RelaySeatSpec $roomObject $name) -Answers (ConvertFrom-RelayJson (Read-RelayText $AnswersFile))
        # An agent that came in through the join prompt: its machine is known from its introduction, which the agent
        # wrote; its control characters go before the name is kept anywhere
        if (([string]$spec['machine']).StartsWith('(', [System.StringComparison]::Ordinal)) { $spec['machine'] = ConvertTo-RelayHeaderText (Get-RelayValue $card 'computer' ([string]$spec['machine'])) }
        $current = Get-RelayCanonicalGeneration $roomObject $name
        $null = Add-RelayAgentSeat -Room $roomObject -Name $name -Spec $spec -Generation $current -Reassign
        ConvertTo-RelayPrintedLine "ASSIGNED ${name}: $($spec['role']) ($($spec['work'])) on $($spec['machine']), machine $($spec['machine_care'])"
        # Whether this agent's model suits that kind of work, and who in the room would suit it better. The model
        # and effort come from the agents' introductions: room text.
        $fit = Get-RelayFitNote -Room (Resolve-RelayRoom $roomObject.Id) -Name $name -Work ([string]$spec['work'])
        if ($fit) { ConvertTo-RelayPrintedLine $fit }
        "NEXT: send $name its task now (write your draft, then run your command with: task $name). Its tool shows it the new assignment together with that message."
    }
    'Prompt' {
        if (-not $JoinPrompt) { throw 'Give -JoinPrompt' }
        if (-not (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'join.cmd'))) { throw "The room $($roomObject.Id) has no open seats: add some with -OpenSeats <n>" }
        $prompt = Get-RelayJoinPrompt $roomObject
        Write-RelayGuardedText $roomObject 'PROMPT-JOIN.txt' $prompt
        Write-RelayText (Join-Path (Join-Path $roomObject.Local 'prompts') 'PROMPT-JOIN.txt') $prompt
        $prompt.TrimEnd()
        ''
        if ($useClipboard) { try { Set-Clipboard -Value $prompt.TrimEnd(); 'on the clipboard: the join prompt' } catch { $null = $_ } }
        'NEXT: the owner pastes the join prompt into each agent that should join. Give no work to an agent before its introduction has arrived.'
    }
    'Open' {
        $opened = Add-RelayOpenSeat -Room $roomObject -Count $OpenSeats
        "OPEN SEATS added to room $($roomObject.Id): " + ($opened.Names -join ', ')
        'join prompt, the same for every agent: ' + (Join-Path $roomObject.Path 'PROMPT-JOIN.txt')
        if ($useClipboard) { try { Set-Clipboard -Value $opened.Prompt.TrimEnd(); 'on the clipboard: the join prompt' } catch { $null = $_ } }
        'NEXT: the owner pastes the join prompt into each agent that should join. Give no work to an agent before its introduction has arrived.'
    }
}
