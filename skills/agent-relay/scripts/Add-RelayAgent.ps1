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
    -Assign        Gives one or more agents that are already in the room a new assignment. The fields come as
                   parameters (-Role, -Work, -Task, -DoneWhen, -NonGoals, -Roots, -May, -ProposeOk, -AskFirst,
                   -Never, -MachineCare, -MachineNotes, -Expertise, -Standards, -DocTools), or from a JSON file
                   with one agent object (-AnswersFile; a parameter given as well wins over the file). Fields
                   left out stay as they are. Several names (-Assign emma, jack, or emma,jack) get the same
                   assignment; every name is checked before the first is written. This is how an agent that
                   came in through the join prompt gets its role and its limits, once its introduction has
                   shown what and where it is. Its session, name and generation stay; the tool shows it the new
                   assignment with the next message it receives.
                   -Roots takes each folder as '<folder>' (read-only) or '<folder>=<pattern>,<pattern>' (what
                   may change inside it), or as a hashtable @{ root = '<folder>'; may = @('<pattern>') }.
                   Writing the fields on the command line keeps backslashes and dollar signs as they are: a
                   JSON file written through another shell lost both.

    Everything written here goes to the canonical copy on this PC first and to the room second.

.PARAMETER Room
    Room id or room folder.

.PARAMETER NoClipboard
    Do not put the start prompt on the clipboard.

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Replace emma -Kind codex

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Control jack -State pause -Note 'owner is looking at the machine'

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Control all -State hold -Note 'the kit is being restaged: start no run'

.EXAMPLE
    .\Add-RelayAgent.ps1 -Room 2026-10-10-docs -Assign emma, jack -Role tester -Work testing -Task 'Run the suite on the kit in work\kit and report every failure.' -DoneWhen 'A report with the full output is sent.' -Roots 'C:\work\kit=tests/*' -Never 'Change a file under src.'

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(Mandatory, ParameterSetName = 'Add')][Parameter(ParameterSetName = 'Assign')][ValidateNotNullOrEmpty()][string]$AnswersFile,
    # One or more names; a name list typed as one word (emma,jack) is split below
    [Parameter(Mandatory, ParameterSetName = 'Assign')][ValidateNotNullOrEmpty()][string[]]$Assign,
    [Parameter(ParameterSetName = 'Assign')][string]$Role,
    [Parameter(ParameterSetName = 'Assign')][string]$Work,
    [Parameter(ParameterSetName = 'Assign')][string]$Task,
    [Parameter(ParameterSetName = 'Assign')][string]$DoneWhen,
    [Parameter(ParameterSetName = 'Assign')][ValidateSet('in-use', 'disposable')][string]$MachineCare,
    [Parameter(ParameterSetName = 'Assign')][string]$MachineNotes,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$Expertise,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$Standards,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$DocTools,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$NonGoals,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][object[]]$Roots,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$May,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$ProposeOk,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$AskFirst,
    [Parameter(ParameterSetName = 'Assign')][AllowEmptyCollection()][string[]]$Never,
    [Parameter(Mandatory, ParameterSetName = 'Replace')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Replace,
    [Parameter(ParameterSetName = 'Replace')][string]$Kind = '',
    [Parameter(Mandatory, ParameterSetName = 'Retire')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Retire,
    # One agent's name, or all: every agent but the coordinator and the retired
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Control,
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidateSet('pause', 'run', 'stop', 'hold')][string]$State,
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
# Instructions come from this plugin's templates, but the agents run the room's own tool: a room made by a package
# before 3.2.0 has no find and no remember, so a seat written now would start with a command its tool lacks. The
# version is this PC's canonical copy of ROOM, compared as a version.
if (@('Add', 'Replace', 'Assign', 'Open') -contains $PSCmdlet.ParameterSetName) {
    $roomPackage = [string](Get-RelayValue $roomObject.Info 'package' '')
    $parsedPackage = $null
    if (-not [System.Version]::TryParse($roomPackage.Trim(), [ref]$parsedPackage) -or $parsedPackage -lt [System.Version]'3.2.0') {
        $shown = $roomPackage
        if (-not $shown) { $shown = '(none recorded)' }
        throw "ERROR: the room $($roomObject.Id) runs room package $shown, older than 3.2.0: its tool has no find or remember, which the instructions of a new seat use. NEXT: run Update-RelayRoom.ps1 -Room $($roomObject.Id) first, then run this command again."
    }
}
# A hold is read by the room's own tool: one older than package 3.4.0 knows no hold and would read the state
# as a resume, while the coordinator believes the agent is held
if ($PSCmdlet.ParameterSetName -eq 'Control' -and $State -eq 'hold') {
    $roomPackage = [string](Get-RelayValue $roomObject.Info 'package' '')
    $parsedPackage = $null
    if (-not [System.Version]::TryParse($roomPackage.Trim(), [ref]$parsedPackage) -or $parsedPackage -lt [System.Version]'3.4.0') {
        $shown = $roomPackage
        if (-not $shown) { $shown = '(none recorded)' }
        throw "ERROR: the room $($roomObject.Id) runs room package $shown, older than 3.4.0: its tool knows no hold, and an agent would read the state as a resume. NEXT: run Update-RelayRoom.ps1 -Room $($roomObject.Id) first, then run this command again (a pause works on any package)."
    }
}
$all = @(Get-RelayRoster $roomObject -IncludeRetired)

function Assert-Agent {
    param([string]$Name)
    if ($all -notcontains $Name) { throw "There is no agent '$Name' in room $($roomObject.Id). Agents: $($all -join ', ')" }
}

$useClipboard = -not $NoClipboard

function ConvertTo-AssignRoot {
    # One -Roots entry as the answers hold a root: '<folder>', '<folder>=<pattern>,<pattern>', or a hashtable or
    # object with root and may. Patterns are split at commas and semicolons; a folder with '=' in its name goes
    # in as a hashtable.
    param($Entry)
    if ($Entry -is [System.Collections.IDictionary]) {
        $folder = [string]$Entry['root']
        if (-not $folder.Trim()) { throw "A root given as a hashtable needs root = '<folder>' (and may = @('<pattern>') for what may change inside it)" }
        return [pscustomobject]@{ root = $folder.Trim(); may = @(@($Entry['may']) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) }
    }
    if ($Entry -is [string]) {
        $text = $Entry.Trim()
        $at = $text.IndexOf([char]'=')
        if ($at -lt 0) {
            if (-not $text) { throw "A root is a folder: '<folder>' or '<folder>=<pattern>,<pattern>'" }
            return [pscustomobject]@{ root = $text; may = @() }
        }
        $folder = $text.Substring(0, $at).Trim()
        if (-not $folder) { throw "A root is a folder: '<folder>' or '<folder>=<pattern>,<pattern>', not '$Entry'" }
        $patterns = @(($text.Substring($at + 1) -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        return [pscustomobject]@{ root = $folder; may = $patterns }
    }
    $folder = [string](Get-RelayProperty $Entry 'root' '')
    if (-not $folder.Trim()) { throw "A root needs a folder: give it as '<folder>', '<folder>=<pattern>,<pattern>', or @{ root = '<folder>'; may = @('<pattern>') }" }
    return [pscustomobject]@{ root = $folder.Trim(); may = @(@(Get-RelayProperty $Entry 'may' @()) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) }
}

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
        # The names too: a wanted name that is reserved, malformed or taken in the third entry must not leave two added
        $taken = New-Object System.Collections.Generic.List[string]
        foreach ($name in $all) { $taken.Add($name) }
        $names = New-Object System.Collections.Generic.List[string]
        $wanted = @($specs | ForEach-Object { [string]$_['wanted_name'] })
        foreach ($spec in $specs) {
            $name = Select-RelayName -Machine $spec['machine'] -Role $spec['role'] -Taken $taken.ToArray() -Wanted $spec['wanted_name'] -Reserved $wanted
            $taken.Add($name)
            $names.Add($name)
        }
        $lastPrompt = ''
        $lastName = ''
        for ($index = 0; $index -lt $specs.Count; $index++) {
            $spec = $specs[$index]
            $name = $names[$index]
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
        $names = @()
        if ($name -eq 'all') {
            # Every agent but the coordinator and the retired: a free seat too, so that whoever takes it starts held
            $names = @($all | Where-Object { $_ -ne $roomObject.Coordinator -and -not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $roomObject.Canon 'agents') $_) 'retired')) })
            if ($names.Count -eq 0) { throw "There is no agent in room $($roomObject.Id) to control" }
        }
        else {
            Assert-Agent $name
            if ($name -eq $roomObject.Coordinator) { throw 'The coordinator is not paused, held or stopped through the room' }
            $names = @($name)
        }
        foreach ($one in $names) { Write-RelayGuardedText $roomObject "agents/$one/control" ("state: {0}`nnote: {1}`n" -f $State, (ConvertTo-RelayHeaderText $Note)) }
        $who = $names -join ', '
        $target = $name
        "CONTROL ${who}: $State. The agent learns it at its next command; a waiting agent within seconds."
        switch ($State) {
            'pause' { "NEXT: resume it with -Control $target -State run when the reason is gone." }
            'hold' { "NEXT: every verb of the agent prints the hold first, its check exits 7 while it lasts, and messages still reach it. Release it with -Control $target -State run." }
            'stop' { "NEXT: give it a new session with -Replace $target, or retire it with -Retire $target." }
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
        # Every name is checked before anything is read or written: a typo in the second must not leave the
        # first changed. A list typed as one word (emma,jack) is split here.
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($given in @($Assign)) {
            foreach ($piece in (([string]$given) -split '[,; ]+')) {
                $name = $piece.Trim().ToLowerInvariant()
                if (-not $name) { continue }
                if ($name -notmatch '^[a-z][a-z0-9]{1,15}$') { throw "'$piece' is no agent name" }
                if (-not $names.Contains($name)) { $names.Add($name) }
            }
        }
        if ($names.Count -eq 0) { throw 'Give at least one agent name with -Assign' }
        $cards = [ordered]@{}
        foreach ($name in $names) {
            Assert-Agent $name
            if ($name -eq $roomObject.Coordinator) { throw 'The coordinator has no assignment to change' }
            if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $roomObject.Canon 'agents') $name) 'retired')) { throw "The agent '$name' is retired" }
            $card = Read-RelayKeyValue (Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $name) 'card')
            if ($card.Count -eq 0) { throw "The agent '$name' has not introduced itself yet: an assignment follows the introduction, it does not come before it" }
            $cards[$name] = $card
        }
        # The assignment: the file's fields first, then every field given as a parameter over them
        $fields = [ordered]@{}
        if ($AnswersFile) {
            if (-not (Test-Path -LiteralPath $AnswersFile)) { throw "No answers file: $AnswersFile" }
            $fromFile = ConvertFrom-RelayJson (Read-RelayText $AnswersFile)
            if ($null -ne $fromFile) { foreach ($property in $fromFile.PSObject.Properties) { $fields[$property.Name] = $property.Value } }
        }
        $byParameter = [ordered]@{
            Role = 'role'; Work = 'work'; Task = 'task'; DoneWhen = 'done_when'; MachineCare = 'machine_care'; MachineNotes = 'machine_notes'
            Expertise = 'expertise'; Standards = 'standards'; DocTools = 'doc_tools'; NonGoals = 'non_goals'; Roots = 'roots'
            May = 'may'; ProposeOk = 'propose_ok'; AskFirst = 'ask_first'; Never = 'never'
        }
        foreach ($parameter in $byParameter.Keys) {
            if (-not $PSBoundParameters.ContainsKey($parameter)) { continue }
            $value = $PSBoundParameters[$parameter]
            if ($parameter -eq 'Roots') { $value = @(@($value) | ForEach-Object { ConvertTo-AssignRoot $_ }) }
            elseif ($value -is [array]) { $value = @(@($value) | ForEach-Object { [string]$_ }) }
            $fields[$byParameter[$parameter]] = $value
        }
        if ($fields.Count -eq 0) { throw 'Give the assignment: its fields as parameters (-Role, -Work, -Task, -DoneWhen, -Roots, -Never, ...), or -AnswersFile with a JSON file' }
        $answers = [pscustomobject]$fields
        $prepared = New-Object System.Collections.Generic.List[object]
        foreach ($name in $names) {
            $card = $cards[$name]
            $spec = Merge-RelaySeatSpec -Spec (Read-RelaySeatSpec $roomObject $name) -Answers $answers
            # An agent that came in through the join prompt: its machine is known from its introduction, which the agent
            # wrote; its control characters go before the name is kept anywhere
            if (([string]$spec['machine']).StartsWith('(', [System.StringComparison]::Ordinal)) { $spec['machine'] = ConvertTo-RelayHeaderText (Get-RelayValue $card 'computer' ([string]$spec['machine'])) }
            $prepared.Add([pscustomobject]@{ Name = $name; Spec = $spec })
        }
        foreach ($entry in $prepared) {
            $name = $entry.Name
            $spec = $entry.Spec
            $current = Get-RelayCanonicalGeneration $roomObject $name
            $null = Add-RelayAgentSeat -Room $roomObject -Name $name -Spec $spec -Generation $current -Reassign
            ConvertTo-RelayPrintedLine "ASSIGNED ${name}: $($spec['role']) ($($spec['work'])) on $($spec['machine']), machine $($spec['machine_care'])"
            # Whether this agent's model suits that kind of work, and who in the room would suit it better. The model
            # and effort come from the agents' introductions: room text.
            $fit = Get-RelayFitNote -Room (Resolve-RelayRoom $roomObject.Id) -Name $name -Work ([string]$spec['work'])
            if ($fit) { ConvertTo-RelayPrintedLine $fit }
        }
        $assigned = $names -join ', '
        $firstName = $names[0]
        "NEXT: send $assigned the task now (write your draft, then run your command with: task $firstName). The tool shows each of them the new assignment together with that message."
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
