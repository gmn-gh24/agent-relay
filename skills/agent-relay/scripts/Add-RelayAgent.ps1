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
    -Retire        The agent leaves the room for good. Its messages stay. The exit steps come first (see below).
    -Control       Pauses, resumes or stops one agent (-State pause, run or stop, with an optional -Note).
    -Line          Opens a direct line between two agents (-Line emma -To jack), both ways.
    -OpenSeats     Adds that many seats nobody is named for. Any agent given the room's join prompt
                   (PROMPT-JOIN.txt) takes the next free one and says what it is in its introduction.
    -JoinPrompt    Prints the room's join prompt again; pass -Clipboard to put it on the clipboard.
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
                   To change one list and keep every other field, give only these (with -Assign <name>,
                   never together with the fields above or -AnswersFile): -AddMay <line>, -RemoveMay <line>,
                   -AddRoots '<folder>=<pattern>' (a folder that is a root already gets the patterns added),
                   -RemoveRoots <folder>, -AddProposeOk <line>, -AddAskFirst <line>, -RemoveNever <line>. A
                   line to remove must match a line of the list exactly (case counts); one that is not there
                   is refused, and nothing is written for any name. A line added twice is added once. The
                   result is written the way a full -Assign writes it.

    -Seat          States what the owner said about one agent that cannot see its own model or effort (it joins with
                   unknown): -Seat emma -SetModel gpt-6.1 -SetEffort medium, one or both. The values go into this
                   PC's canonical copy of the seat, win over the agent's own card on the board (printed with "(owner)"),
                   and are used by the tier lines and the FIT line. A later start of the agent does not replace them;
                   -SetModel '' or -SetEffort '' hands the value back to what the agent says. A seat that has not
                   introduced itself is refused.
    -ListModels    Prints the models this PC has seen (every introduction and every -SetModel adds its model once, with
                   its product and the day): the choices to offer the owner. Needs no -Room.

    -Clipboard     Puts the saved start prompt of one agent (its newest generation) on the clipboard. After
                   several -Replace calls in a row only the last prompt is on the clipboard; this puts a named
                   one there, and the owner pastes one prompt at a time.

    The exit steps (-Retire, and -Replace for a session that is still alive): the agent is asked to run
    `remember` and then `bye`, through the coordinator's own launcher, and the script waits for the bye (-WaitMinutes,
    3 by default). An agent that already said bye since its last start, or that never introduced itself, needs no
    request. An agent whose session is not alive (no sign of life for the room's stale minutes) is not waited for:
    the request is left in its inbox, and the exit is recorded as "lost". An agent that is alive and does not
    answer in time keeps its seat and the script says so; -Force -Reason '<why>' goes on regardless and records
    the reason. The exit is recorded in the retired marker (retire) and in exits.log on this PC (both).

    Everything written here goes to the canonical copy on this PC first and to the room second.

.PARAMETER Room
    Room id or room folder.

.PARAMETER WaitMinutes
    How long -Retire and -Replace wait for the bye of an agent that is alive (0 to 60, default 3).

.PARAMETER Force
    Retire or replace without the bye; needs -Reason, which is recorded.

.PARAMETER Reason
    Why the exit steps were skipped with -Force.

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
    # The models list is about this PC, not a room: -ListModels needs no -Room
    [Parameter(Mandatory, ParameterSetName = 'Add')][Parameter(Mandatory, ParameterSetName = 'Assign')][Parameter(Mandatory, ParameterSetName = 'Replace')]
    [Parameter(Mandatory, ParameterSetName = 'Clipboard')][Parameter(Mandatory, ParameterSetName = 'Retire')][Parameter(Mandatory, ParameterSetName = 'Control')]
    [Parameter(Mandatory, ParameterSetName = 'Line')][Parameter(Mandatory, ParameterSetName = 'Open')][Parameter(Mandatory, ParameterSetName = 'Prompt')]
    [Parameter(Mandatory, ParameterSetName = 'Seat')][Parameter(ParameterSetName = 'Models')][ValidateNotNullOrEmpty()][string]$Room,
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
    # Incremental edits of one list: used alone, they keep every other field of the assignment
    [Parameter(ParameterSetName = 'Assign')][string[]]$AddMay,
    [Parameter(ParameterSetName = 'Assign')][string[]]$RemoveMay,
    [Parameter(ParameterSetName = 'Assign')][object[]]$AddRoots,
    [Parameter(ParameterSetName = 'Assign')][string[]]$RemoveRoots,
    [Parameter(ParameterSetName = 'Assign')][string[]]$AddProposeOk,
    [Parameter(ParameterSetName = 'Assign')][string[]]$AddAskFirst,
    [Parameter(ParameterSetName = 'Assign')][string[]]$RemoveNever,
    [Parameter(Mandatory, ParameterSetName = 'Replace')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Replace,
    [Parameter(ParameterSetName = 'Replace')][string]$Kind = '',
    [Parameter(ParameterSetName = 'Replace')][Parameter(ParameterSetName = 'Retire')][ValidateRange(0, 60)][int]$WaitMinutes = 3,
    [Parameter(ParameterSetName = 'Replace')][Parameter(ParameterSetName = 'Retire')][switch]$Force,
    [Parameter(ParameterSetName = 'Replace')][Parameter(ParameterSetName = 'Retire')][string]$Reason = '',
    [Parameter(Mandatory, ParameterSetName = 'Clipboard')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Clipboard,
    [Parameter(Mandatory, ParameterSetName = 'Retire')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Retire,
    # One agent's name, or all: every agent but the coordinator and the retired
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Control,
    [Parameter(Mandatory, ParameterSetName = 'Control')][ValidateSet('pause', 'run', 'stop', 'hold')][string]$State,
    [Parameter(ParameterSetName = 'Control')][string]$Note = '',
    [Parameter(Mandatory, ParameterSetName = 'Line')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Line,
    [Parameter(Mandatory, ParameterSetName = 'Line')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$To,
    [Parameter(Mandatory, ParameterSetName = 'Seat')][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,15}$')][string]$Seat,
    # What the owner stated: a model or an effort as one word, or an empty one to hand the value back to the agent
    [Parameter(ParameterSetName = 'Seat')][AllowEmptyString()][string]$SetModel,
    [Parameter(ParameterSetName = 'Seat')][AllowEmptyString()][string]$SetEffort,
    [Parameter(Mandatory, ParameterSetName = 'Models')][switch]$ListModels,
    [Parameter(Mandatory, ParameterSetName = 'Open')][ValidateRange(1, 200)][int]$OpenSeats,
    [Parameter(Mandatory, ParameterSetName = 'Prompt')][switch]$JoinPrompt,
    [Parameter(ParameterSetName = 'Prompt')]
    [Parameter(ParameterSetName = 'Open')]
    [switch]$CopyJoin
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Models') {
    # The models this PC has seen: the choices to offer the owner for an agent that joined with unknown
    $models = @(Get-RelayKnownModel | Sort-Object { $_.name.ToLowerInvariant() })
    if ($models.Count -eq 0) {
        'No model has been recorded on this PC yet: every introduction and every -Seat <name> -SetModel adds one.'
    }
    else {
        "MODELS seen on this PC ($($models.Count)), in $(Get-RelayKnownModelFile)"
        foreach ($model in $models) { ConvertTo-RelayPrintedLine ('  {0,-30} {1,-16} {2}' -f $model.name, $model.product, $model.date) }
        'NEXT: offer these to the owner, with the effort levels, unknown and other, then record the answer: -Room <id> -Seat <name> -SetModel <model> -SetEffort <effort>.'
    }
    return
}

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

$useClipboard = $PSBoundParameters.ContainsKey('CopyJoin') -and $CopyJoin

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

function Get-AssignLine {
    # The lines an incremental parameter names, each one as given: an empty line is refused
    param([string[]]$Value, [string]$Parameter)
    $lines = @(@($Value) | Where-Object { $null -ne $_ })
    foreach ($line in $lines) { if (-not $line.Trim()) { throw "-$Parameter takes lines of text, not an empty one" } }
    return $lines
}

function Add-AssignLine {
    # The list with each new line at its end; a line that is there already (ordinal, case counts) is not added twice
    param([object[]]$Current, [string[]]$Add)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Current)) { if ($null -ne $line) { $result.Add([string]$line) } }
    foreach ($line in @($Add)) {
        $known = $false
        foreach ($have in $result) { if ([string]::Equals($have, $line, [System.StringComparison]::Ordinal)) { $known = $true; break } }
        if (-not $known) { $result.Add($line) }
    }
    return @($result.ToArray())
}

function Get-AssignLineWithout {
    # The list without the lines named, each of which must be in it exactly (ordinal, case counts)
    param([object[]]$Current, [string[]]$Remove, [string]$List, [string]$Parameter, [string]$Name)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Current)) { if ($null -ne $line) { $result.Add([string]$line) } }
    foreach ($line in @($Remove)) {
        $at = -1
        for ($index = 0; $index -lt $result.Count; $index++) {
            if ([string]::Equals($result[$index], $line, [System.StringComparison]::Ordinal)) { $at = $index; break }
        }
        if ($at -lt 0) { throw "-${Parameter}: '$line' is not in the $List list of ${Name}. Its lines: $(if ($result.Count -gt 0) { ($result | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' })" }
        $result.RemoveAt($at)
    }
    return @($result.ToArray())
}

function Find-AssignRoot {
    # The place of a folder among the roots (a folder compares ordinally, case ignored: Windows paths), or -1
    param([System.Collections.Generic.List[object]]$Roots, [string]$Folder)
    $wanted = $Folder.Trim()
    for ($index = 0; $index -lt $Roots.Count; $index++) {
        $folder = [string]$Roots[$index].root
        if ($folder.Equals($wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $index }
    }
    return -1
}

function Get-IncrementalAnswer {
    # What the incremental parameters make of one seat's saved answers: only the lists they change, each as the whole
    # new list, so that the same merge as a full -Assign writes them. -Lines holds the lines by parameter name.
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Lines, [object[]]$AddedRoots = @(), [string[]]$RemovedRoots = @())
    $fields = [ordered]@{}
    if ($Lines.ContainsKey('AddMay') -or $Lines.ContainsKey('RemoveMay')) {
        $may = @($Spec['may'])
        if ($Lines.ContainsKey('AddMay')) { $may = Add-AssignLine $may $Lines['AddMay'] }
        if ($Lines.ContainsKey('RemoveMay')) { $may = Get-AssignLineWithout $may $Lines['RemoveMay'] 'may' 'RemoveMay' $Name }
        $fields['may'] = $may
    }
    if ($Lines.ContainsKey('AddProposeOk')) { $fields['propose_ok'] = Add-AssignLine @($Spec['propose_ok']) $Lines['AddProposeOk'] }
    if ($Lines.ContainsKey('AddAskFirst')) { $fields['ask_first'] = Add-AssignLine @($Spec['ask_first']) $Lines['AddAskFirst'] }
    if ($Lines.ContainsKey('RemoveNever')) { $fields['never'] = Get-AssignLineWithout @($Spec['never']) $Lines['RemoveNever'] 'never' 'RemoveNever' $Name }
    if (@($AddedRoots).Count -gt 0 -or @($RemovedRoots).Count -gt 0) {
        $roots = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($Spec['roots'])) { if ($null -ne $entry) { $roots.Add((ConvertTo-AssignRoot $entry)) } }
        foreach ($added in @($AddedRoots)) {
            $at = Find-AssignRoot $roots $added.root
            if ($at -lt 0) { $roots.Add($added) }
            else { $roots[$at] = [pscustomobject]@{ root = $roots[$at].root; may = @(Add-AssignLine @($roots[$at].may) @($added.may)) } }
        }
        foreach ($folder in @($RemovedRoots)) {
            $at = Find-AssignRoot $roots $folder
            if ($at -lt 0) { throw "-RemoveRoots: '$folder' is not a root of ${Name}. Its roots: $(if ($roots.Count -gt 0) { ($roots | ForEach-Object { "'$($_.root)'" }) -join ', ' } else { '(none)' })" }
            $roots.RemoveAt($at)
        }
        $fields['roots'] = @($roots.ToArray())
    }
    return [pscustomobject]$fields
}

function Copy-Prompt {
    param([string]$Text, [string]$Name, [bool]$Enabled)
    if (-not $Enabled) { return }
    try { Set-RelayClipboard -Text $Text.TrimEnd(); "on the clipboard: the start prompt for $Name" } catch { $null = $_ }
}

function Get-ByeMessage {
    # The byes an agent sent to the coordinator at or after a time (messages of the room: claims, the sender is the folder)
    param([string]$Name, $Since)
    return @(Get-RelayMessage $roomObject | Where-Object { $_.Type -ceq 'bye' -and $_.From -ceq $Name -and $_.To -ceq $roomObject.Coordinator -and ($null -eq $Since -or $_.Time -ge $Since) })
}

function Invoke-ExitStep {
    # The graceful exit of an agent that is being retired or replaced: it runs `remember`, then `bye`. Returns what
    # happened as one of: none (never introduced), bye (said it), lost (its session is not alive: the request was
    # left in its inbox), forced (-Force). Throws when the agent is alive and does not answer in time.
    param([string]$Name, [string]$Action)
    $dir = Join-Path (Join-Path $roomObject.Path 'agents') $Name
    $card = Read-RelayKeyValue (Join-Path $dir 'card')
    if ($card.Count -eq 0) { return 'none' }
    $started = ConvertFrom-RelayUtc (Get-RelayValue $card 'started_utc' '')
    if ($Force) {
        if (-not $Reason.Trim()) { throw '-Force needs -Reason: say why the exit steps are skipped (it is recorded)' }
        return 'forced'
    }
    if (@(Get-ByeMessage $Name $started).Count -gt 0) { return 'bye' }
    $launcher = Join-Path $roomObject.Local 'relay.ps1'
    if (-not [System.IO.File]::Exists($launcher)) { throw "This PC has no launcher for the room ($launcher): send the exit request yourself (note ${Name}: run remember, then bye), then run this again" }
    $asked = [DateTime]::UtcNow.AddSeconds(-2)
    $text = "exit request`n`nYour seat is ending ($Action). Before you leave, in this order: 1. run remember for your last durable findings (one fact per entry, not a status); 2. run your bye verb, and in its draft say what slowed you down. Do not start anything new. Then stop."
    Write-RelayText (Join-Path $roomObject.Local 'draft.md') $text
    $shell = (Get-Process -Id $PID).Path
    # Windows PowerShell 5.1 turns a native command's error output into a terminating error under Stop
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $launcher note $Name 2>&1 | ForEach-Object { [string]$_ }) }
    finally { $ErrorActionPreference = $savedPreference }
    if ($LASTEXITCODE -ne 0) { throw "The exit request could not be sent ($($output -join ' | ')): send it yourself (note $Name), then run this again" }
    $alive = Get-RelayFileTimeUtc (Join-Path $dir 'alive')
    $now = Get-RelayRoomNow $roomObject
    $staleMinutes = 5
    $parsed = 0
    if ([int]::TryParse((Get-RelayValue $roomObject.Info 'stale_minutes' '5'), [ref]$parsed) -and $parsed -gt 0) { $staleMinutes = $parsed }
    $isAlive = ($alive -ne [DateTime]::MinValue -and ($now - $alive).TotalMinutes -lt $staleMinutes)
    if (-not $isAlive) { return 'lost' }
    $second = 60
    $custom = 0
    if ([int]::TryParse([string]$env:RELAY_MINUTE_SECONDS, [ref]$custom) -and $custom -ge 1) { $second = $custom }
    $until = [DateTime]::UtcNow.AddSeconds($WaitMinutes * $second)
    while ($true) {
        if (@(Get-ByeMessage $Name $asked).Count -gt 0) { return 'bye' }
        if ([DateTime]::UtcNow -ge $until) { break }
        Start-Sleep -Seconds 1
    }
    throw "$Name is alive and has not said bye within $WaitMinutes minute(s). The exit request is in its inbox. NEXT: wait longer (run this again, with -WaitMinutes), tell it in its own session, or go on without the bye: -Force -Reason '<why>'."
}

function Write-ExitRecord {
    param([string]$Name, [string]$Action, [string]$How)
    $detail = $How
    if ($How -eq 'forced') { $detail = "forced: $(ConvertTo-RelayHeaderText $Reason)" }
    if ($How -eq 'lost') { $detail = 'lost: the session was not alive, the exit request was left in its inbox' }
    Add-RelayLine (Join-Path $roomObject.Local 'exits.log') ('{0} {1} {2} exit={3}' -f (Format-RelayUtc), $Action, $Name, $detail)
    return $detail
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
            $spec = ConvertTo-RelaySeatSpec -Agent $entry -RoomId $roomObject.Id -DevRoomPath $roomObject.Path -RemoteRoomPath (Get-RelayReachPath $roomObject) -FallbackRoomPath (Get-RelayReachFallback $roomObject)
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
        # The old session leaves the way an agent leaves: remember, then bye (the coordinator's own session is not asked)
        $exitHow = ''
        if ($name -ne $roomObject.Coordinator) { $exitHow = Invoke-ExitStep -Name $name -Action 'a new session takes over your name' }
        $current = Get-RelayCanonicalGeneration $roomObject $name
        $next = $current + 1
        $prompt = Add-RelayAgentSeat -Room $roomObject -Name $name -Spec $spec -Generation $next -IsCoordinator:($name -eq $roomObject.Coordinator)
        "REPLACED ${name}: generation $next ($($spec['kind'])). The old session is told to stop at its next command."
        if ($exitHow) { "exit of the old session: " + (Write-ExitRecord -Name $name -Action 'replace' -How $exitHow) }
        if ($name -eq $roomObject.Coordinator) {
            # The coordinator's start prompt stays on this PC: there is none in the room to take away
            "NEXT: run your own start with the new launcher: " + (Get-RelayCallLine -RoomPath $roomObject.Path -Name $name -Generation ([string]$next) -Shell 'powershell' -Launcher $roomObject.Local) + ' start <product> <model> <effort>'
        }
        else {
            "start prompt: " + (Join-Path $roomObject.Path "PROMPT-$name.txt")
            Get-RelayCoordinatorNote -Kind @([string]$spec['kind'])
            Copy-Prompt $prompt $name $useClipboard
            if ($useClipboard) { "NEXT: paste the start prompt for $name into the new session (it is on the clipboard now; with several replacements, one prompt at a time: -Clipboard <name> puts a named one back). Its start prints the requests the old session left open." }
            else { "NEXT: paste the start prompt for $name into the new session (-Clipboard $name puts it on the clipboard). Its start prints the requests the old session left open." }
        }
    }
    'Retire' {
        $name = $Retire.ToLowerInvariant()
        Assert-Agent $name
        if ($name -eq $roomObject.Coordinator) { throw 'The coordinator cannot be retired; close the room instead' }
        # The exit steps come first: a retired agent can no longer say bye
        $exitHow = Invoke-ExitStep -Name $name -Action 'you are retired from this room'
        $exitDetail = Write-ExitRecord -Name $name -Action 'retire' -How $exitHow
        Write-RelayGuardedText $roomObject "agents/$name/retired" ("retired_utc: {0}`nexit: {1}`n" -f (Format-RelayUtc), (ConvertTo-RelayHeaderText $exitDetail))
        "RETIRED $name in room $($roomObject.Id) (exit: $exitDetail). Its messages stay; nobody can write to it any more."
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
        $byParameter = [ordered]@{
            Role = 'role'; Work = 'work'; Task = 'task'; DoneWhen = 'done_when'; MachineCare = 'machine_care'; MachineNotes = 'machine_notes'
            Expertise = 'expertise'; Standards = 'standards'; DocTools = 'doc_tools'; NonGoals = 'non_goals'; Roots = 'roots'
            May = 'may'; ProposeOk = 'propose_ok'; AskFirst = 'ask_first'; Never = 'never'
        }
        # The incremental parameters change one list and keep the rest: they work alone, never with a full field
        $incrementalLines = @{}
        foreach ($parameter in 'AddMay', 'RemoveMay', 'AddProposeOk', 'AddAskFirst', 'RemoveNever') {
            if ($PSBoundParameters.ContainsKey($parameter)) { $incrementalLines[$parameter] = Get-AssignLine $PSBoundParameters[$parameter] $parameter }
        }
        $addedRoots = @()
        if ($PSBoundParameters.ContainsKey('AddRoots')) { $addedRoots = @(@($AddRoots) | ForEach-Object { ConvertTo-AssignRoot $_ }) }
        $removedRoots = @()
        if ($PSBoundParameters.ContainsKey('RemoveRoots')) { $removedRoots = @(Get-AssignLine $RemoveRoots 'RemoveRoots') }
        $incremental = @('AddMay', 'RemoveMay', 'AddRoots', 'RemoveRoots', 'AddProposeOk', 'AddAskFirst', 'RemoveNever' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
        if ($incremental) {
            $mixed = @($byParameter.Keys | Where-Object { $PSBoundParameters.ContainsKey($_) })
            if ($AnswersFile) { $mixed += 'AnswersFile' }
            if ($mixed.Count -gt 0) { throw "-AddMay, -RemoveMay, -AddRoots, -RemoveRoots, -AddProposeOk, -AddAskFirst and -RemoveNever change one list and keep every other field: they cannot be combined with the full fields or -AnswersFile (given: -$($mixed -join ', -')). Use one kind or the other." }
        }
        # The assignment: the file's fields first, then every field given as a parameter over them
        $fields = [ordered]@{}
        if ($AnswersFile) {
            if (-not (Test-Path -LiteralPath $AnswersFile)) { throw "No answers file: $AnswersFile" }
            $fromFile = ConvertFrom-RelayJson (Read-RelayText $AnswersFile)
            if ($null -ne $fromFile) { foreach ($property in $fromFile.PSObject.Properties) { $fields[$property.Name] = $property.Value } }
        }
        foreach ($parameter in $byParameter.Keys) {
            if (-not $PSBoundParameters.ContainsKey($parameter)) { continue }
            $value = $PSBoundParameters[$parameter]
            if ($parameter -eq 'Roots') { $value = @(@($value) | ForEach-Object { ConvertTo-AssignRoot $_ }) }
            elseif ($value -is [array]) { $value = @(@($value) | ForEach-Object { [string]$_ }) }
            $fields[$byParameter[$parameter]] = $value
        }
        if ($fields.Count -eq 0 -and -not $incremental) { throw 'Give the assignment: its fields as parameters (-Role, -Work, -Task, -DoneWhen, -Roots, -Never, ...), or -AnswersFile with a JSON file' }
        $answers = [pscustomobject]$fields
        $prepared = New-Object System.Collections.Generic.List[object]
        foreach ($name in $names) {
            $card = $cards[$name]
            $saved = Read-RelaySeatSpec $roomObject $name
            # An incremental edit starts from this seat's own saved lists: every name may differ, and a line that is
            # not there refuses the call before anything is written
            if ($incremental) { $answers = Get-IncrementalAnswer -Spec $saved -Name $name -Lines $incrementalLines -AddedRoots $addedRoots -RemovedRoots $removedRoots }
            $spec = Merge-RelaySeatSpec -Spec $saved -Answers $answers
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
    'Seat' {
        $name = $Seat.ToLowerInvariant()
        if (-not $PSBoundParameters.ContainsKey('SetModel') -and -not $PSBoundParameters.ContainsKey('SetEffort')) { throw 'Give -SetModel and -SetEffort (one or both): the model and the effort the owner stated for this seat (an empty value hands it back to what the agent says)' }
        Assert-Agent $name
        if ($name -eq $roomObject.Coordinator) { throw 'The coordinator states its own model and effort in its start' }
        if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $roomObject.Canon 'agents') $name) 'retired')) { throw "The agent '$name' is retired" }
        $card = Read-RelayKeyValue (Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $name) 'card')
        if ($card.Count -eq 0) { throw "The agent '$name' has not introduced itself yet: what the owner states belongs to an introduction, it does not come before it" }
        # Words typed with blanks become one word, as the join command does for the agent
        $given = [ordered]@{}
        foreach ($pair in @(@('SetModel', 'model'), @('SetEffort', 'effort'))) {
            if (-not $PSBoundParameters.ContainsKey($pair[0])) { continue }
            $value = ([string]$PSBoundParameters[$pair[0]]).Trim() -replace ' +', '-'
            if ($value -and -not (Test-RelayModelName $value)) { throw "'$value' is not a $($pair[1]) name: letters, digits and . _ + : / ( ) - only, up to 64 characters, in one line" }
            $given[$pair[1]] = $value
        }
        # The record of this PC: canonical copy first, the room second; the board reads the first
        $stated = Read-RelayKeyValue (Join-Path (Join-Path (Join-Path $roomObject.Canon 'agents') $name) 'stated')
        $kept = [ordered]@{}
        foreach ($key in 'model', 'effort') {
            if ($given.Contains($key)) { if ($given[$key]) { $kept[$key] = $given[$key] } }
            elseif ((Get-RelayValue $stated $key '')) { $kept[$key] = Get-RelayValue $stated $key '' }
        }
        $kept['stated_utc'] = Format-RelayUtc
        Write-RelayGuardedText $roomObject "agents/$name/stated" (ConvertTo-RelayKeyValueText $kept)
        if ($kept.Contains('model')) { Add-RelayKnownModel -Entry @([pscustomobject]@{ name = [string]$kept['model']; product = (Get-RelayValue $card 'product' '') }) }
        $board = @((Get-RelayBoard (Resolve-RelayRoom $roomObject.Id)).agents | Where-Object { $_.name -eq $name })
        $parts = @()
        if ($board.Count -gt 0) {
            $parts += "model $($board[0].model) " + $(if ($board[0].modelOwner) { '(owner)' } else { '(its own)' })
            $parts += "effort $($board[0].effort) " + $(if ($board[0].effortOwner) { '(owner)' } else { '(its own)' })
        }
        ConvertTo-RelayPrintedLine "SET ${name}: $($parts -join ', ')"
        $spec = Read-RelaySeatSpec $roomObject $name
        $fit = Get-RelayFitNote -Room (Resolve-RelayRoom $roomObject.Id) -Name $name -Work ([string]$spec['work'])
        if ($fit) { ConvertTo-RelayPrintedLine $fit }
        'NEXT: the board and the FIT lines use these values now, and a later start of the agent does not replace them. -SetModel '''' or -SetEffort '''' hands one back to what the agent says.'
    }
    'Clipboard' {
        $name = $Clipboard.ToLowerInvariant()
        Assert-Agent $name
        $newest = $null
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $roomObject.Local 'prompts') -Filter "PROMPT-$name-g*.txt" -File -ErrorAction SilentlyContinue)) {
            $number = 0
            if ($file.Name -match '-g([0-9]+)\.txt$' -and [int]::TryParse($Matches[1], [ref]$number)) {
                if ($null -eq $newest -or $number -gt $newest.Number) { $newest = [pscustomobject]@{ Number = $number; Path = $file.FullName } }
            }
        }
        if ($null -eq $newest) { throw "This PC has no saved start prompt for $name" }
        $text = Read-RelayText $newest.Path
        try { Set-RelayClipboard -Text $text.TrimEnd(); "on the clipboard: the start prompt for $name (generation $($newest.Number))" } catch { throw "The clipboard could not be set: $($_.Exception.Message)" }
        "NEXT: paste it into the session of $name. Nothing else is on the clipboard."
    }
    'Prompt' {
        if (-not $JoinPrompt) { throw 'Give -JoinPrompt' }
        if (-not (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'join.cmd'))) { throw "The room $($roomObject.Id) has no open seats: add some with -OpenSeats <n>" }
        $prompt = Get-RelayJoinPrompt $roomObject
        Write-RelayGuardedText $roomObject 'PROMPT-JOIN.txt' $prompt
        Write-RelayText (Join-Path (Join-Path $roomObject.Local 'prompts') 'PROMPT-JOIN.txt') $prompt
        $prompt.TrimEnd()
        ''
        if ($useClipboard) {
            try { Set-RelayClipboard -Text $prompt.TrimEnd(); 'on the clipboard: the join prompt' }
            catch { 'not on the clipboard' }
        }
        else { 'not on the clipboard' }
        'NEXT: the owner pastes the join prompt into each agent that should join. Give no work to an agent before its introduction has arrived.'
    }
    'Open' {
        $opened = Add-RelayOpenSeat -Room $roomObject -Count $OpenSeats
        $seatCount = $opened.Names.Count
        if ($seatCount -eq 1) { "1 free seat added to room $($roomObject.Id)" }
        else { "$seatCount free seats added to room $($roomObject.Id)" }
        'join prompt, the same for every agent: ' + (Join-Path $roomObject.Path 'PROMPT-JOIN.txt')
        if ($useClipboard) {
            try { Set-RelayClipboard -Text $opened.Prompt.TrimEnd(); 'on the clipboard: the join prompt' }
            catch { 'not on the clipboard' }
        }
        else { 'not on the clipboard' }
        'NEXT: the owner pastes the join prompt into each agent that should join. Give no work to an agent before its introduction has arrived.'
    }
}
