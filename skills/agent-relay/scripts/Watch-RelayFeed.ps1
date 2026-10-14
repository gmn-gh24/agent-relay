#Requires -Version 5.1

<#
.SYNOPSIS
    The live feed of a room: every new message, every change of an agent's state, what waits on the owner and
    the coordinator, and alarms. JSON lines for the chat window, or a readable live tail for any terminal.

.DESCRIPTION
    While it runs it also does two jobs that need the coordinator's PC to be present in the room:

    - the tamper check: the tools, the wrappers, every agent's instructions and DECISIONS.md are compared with
      the canonical copies on this PC; a changed file is restored, a file that does not belong is moved out, and
      an alarm is raised. A file that claims to come from the owner but is not in the owner's log raises one too.
    - the coordinator's heartbeat: remote agents see that the coordinator is alive even while it is busy.

    It also keeps two stamps that say it is running. One lies on this PC (feed.state in the room's folder under
    the machine state): the board and the coordinator's tool read it and print NO FEED when it is stale. The other
    is agents\<coordinator>\integrity in the room, rewritten after every whole tamper pass: the agents' tools read
    its age and tell their agent when it is old. The second is only a hint for the agents (anybody can write it);
    the first is what this PC decides by.

    When the room folder cannot be reached (a share that is down, a folder that was moved), the feed says so in
    one alarm, checks and writes nothing in the room, and says so again when the folder is back.

    -Json prints one JSON object per line, ASCII only: first a "snapshot", then "message", "removed" (a message
    whose file is gone from the room), "plan", "agents", "waiting", "alarm", "tick" and finally "closed". Without -Json the same is printed for reading. It ends when the room
    is closed (this PC says so: the CLOSED marker of the canonical copy; a CLOSED that anybody else puts into the room
    is moved out by the tamper check and closes nothing), when the process named by -ParentProcessId is gone, or after -MaxSeconds.

.PARAMETER Room
    Room id or room folder.

.PARAMETER Json
    JSON lines for the chat window.

.PARAMETER Follow
    Readable live tail (the default when -Json is not given).

.PARAMETER Once
    Print the snapshot and end.

.PARAMETER ParentProcessId
    End when this process is gone, so a feed never outlives the session that started it.

.PARAMETER EndWithParent
    The same for the process that started this script, whichever it is (the chat window starts the feed so).

.EXAMPLE
    .\Watch-RelayFeed.ps1 -Room 2026-10-10-docs -Follow

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [switch]$Json,
    [switch]$Follow,
    [switch]$Once,
    [ValidateRange(0, 2147483647)][int]$ParentProcessId = 0,
    [switch]$EndWithParent,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 2,
    [ValidateRange(2, 600)][int]$TamperSeconds = 15,
    [switch]$NoHeartbeat,
    [switch]$NoTamperCheck,
    [ValidateRange(0, 86400)][int]$MaxSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $null = $_ }
if ($Follow -and $Json) { throw 'Give -Json or -Follow, not both' }
if ($EndWithParent -and $ParentProcessId -eq 0) {
    # PowerShell 7 knows its parent on every platform; Windows PowerShell asks WMI
    if ($PSVersionTable.PSVersion.Major -ge 6) { try { $ParentProcessId = [int](Get-Process -Id $PID -ErrorAction Stop).Parent.Id } catch { $ParentProcessId = 0 } }
    if ($ParentProcessId -eq 0) { try { $ParentProcessId = [int](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -Property ParentProcessId -ErrorAction Stop).ParentProcessId } catch { $ParentProcessId = 0 } }
}

$roomObject = Resolve-RelayRoom $Room
# A message is collected when it is first read (the board and the open requests need it) and counts as known only after
# it was printed: a round that fails between the two loses nothing, the next round prints it
$script:collected = @{}
$script:known = @{}
$script:messages = New-Object System.Collections.Generic.List[object]
$script:previousState = @{}
$script:checkedOwner = @{}
$script:pendingAlarms = New-Object System.Collections.Generic.List[string]

function Get-Display {
    param([string]$Name)
    if (-not $Name) { return '?' }
    if ($Name -eq 'owner') { return 'OWNER' }
    return (ConvertTo-RelayDisplayName $Name)
}

function Write-Line {
    param([string]$Text = '')
    # Lines for reading: no control character from a room file, no blank at the end. JSON lines escape instead.
    if (-not $Json) { $Text = ConvertTo-RelayPrintedLine $Text }
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
}

function Write-MessageText {
    param($Row, [int]$Lines = 6)
    $re = ''
    if ($Row.re) { $re = " re $($Row.re)" }
    # The time on this PC's clock; a time that cannot be read is shown as it was written, it ends nothing
    $time = [string]$Row.time
    $parsed = ConvertFrom-RelayUtc $time
    if ($null -ne $parsed) { $time = $parsed.ToLocalTime().ToString('HH:mm:ss') }
    # A header that names another sender, receiver or number than the place of its file
    $mark = ''
    if ($Row.mismatch) { $mark = '   [HEADER DOES NOT MATCH ITS FILE]' }
    Write-Line ('{0}  {1} -> {2}  [{3}]{4}  {5}{6}' -f $time, (Get-Display $Row.from), (Get-Display $Row.to), $Row.type, $re, $Row.subject, $mark)
    $shown = 0
    foreach ($line in ($Row.preview -split "`n")) {
        if (-not $line.Trim()) { continue }
        if ($shown -ge $Lines) { Write-Line "            ... ($($Row.length) characters; id $($Row.id))"; break }
        Write-Line "            $line"
        $shown++
    }
}

function Write-PlanText {
    # The team plan for reading: one line per part
    param($Plan)
    $mark = ''
    if (-not $Plan.isComplete) { $mark = '   [INCOMPLETE]' }
    # Set in the text feed only: the JSON lines keep the fields the chat window knows
    if ($null -ne $Plan.PSObject.Properties['differs'] -and $Plan.differs) { $mark += '   [DIFFERS FROM THE COPY ON THIS PC: the feed puts it back]' }
    Write-Line "  PLAN $($Plan.revision): $($Plan.goal)$mark"
    foreach ($line in @(Format-RelayPlanTable -Parts @($Plan.parts) -Indent '    ')) { Write-Line $line }
}

function Write-Feed {
    # One event: as a JSON line, or as text for reading
    param($Item)
    if ($Json) { Write-Line (ConvertTo-RelayJsonLine $Item); return }
    $clock = (Get-Date).ToString('HH:mm:ss')
    switch ($Item.type) {
        'snapshot' {
            Write-Line "=== room $($Item.room): $($Item.job) ==="
            Write-Line "coordinator: $(Get-Display $Item.coordinator)   authority: $($Item.authority)   $($Item.path)"
            foreach ($agent in @($Item.agents)) {
                if ($agent.isFree) { continue }
                $where = 'not introduced'
                if ($agent.isIntroduced) { $where = "$($agent.computer) $($agent.ipv4), $($agent.elevation), $($agent.product) $($agent.model)" }
                $attention = ''
                if ($agent.attention) { $attention = "   ATTENTION: $($agent.attention)" }
                Write-Line ('  {0,-9} {1,-12} {2,-20} {3}{4}' -f $agent.display, $agent.state, $agent.role, $where, $attention)
            }
            $free = @($Item.agents | Where-Object { $_.isFree })
            if ($free.Count -gt 0) { Write-Line "  free seats ($($free.Count)): $((@($free | ForEach-Object { $_.display })) -join ', ')" }
            if ($null -ne $Item.plan) { Write-PlanText $Item.plan }
            Write-Line ''
            foreach ($row in @($Item.messages)) { Write-MessageText $row 2 }
            if (@($Item.waitingOnOwner).Count -gt 0) {
                Write-Line ''
                Write-Line "WAITING ON THE OWNER ($(@($Item.waitingOnOwner).Count))"
                foreach ($card in @($Item.waitingOnOwner)) { Write-Line "  $($card.id): $($card.subject)" }
            }
            Write-Line ''
        }
        'message' { Write-MessageText $Item.message }
        'removed' { Write-Line "$clock  * the message $($Item.id) is gone from the room (moved out by the tamper check, or deleted)" }
        'plan' {
            if ($null -eq $Item.plan) { Write-Line "$clock  * the team plan is gone" }
            else { Write-Line "$clock  * the team plan changed"; Write-PlanText $Item.plan }
        }
        'agents' {
            foreach ($agent in @($Item.agents)) {
                $now = "$($agent.state)|$($agent.attention)|$($agent.gen)|$($agent.isIntroduced)|$($agent.progressUtc)"
                $before = ''
                if ($script:previousState.ContainsKey($agent.name)) { $before = $script:previousState[$agent.name] }
                if ($before -and $before -ne $now) {
                    $text = "$clock  * $($agent.display): $($agent.state)"
                    if ($agent.detail) { $text += " ($($agent.detail))" }
                    if ($agent.attention) { $text += "   ATTENTION: $($agent.attention)" }
                    Write-Line $text
                }
                $script:previousState[$agent.name] = $now
            }
        }
        'waiting' {
            if (@($Item.waitingOnOwner).Count -gt 0) {
                Write-Line "$clock  WAITING ON THE OWNER ($(@($Item.waitingOnOwner).Count))"
                foreach ($card in @($Item.waitingOnOwner)) { Write-Line "            $($card.id): $($card.subject)" }
            }
            if (@($Item.waitingOnCoordinator).Count -gt 0) { Write-Line "$clock  waiting on the coordinator: $(@($Item.waitingOnCoordinator).Count)" }
        }
        'alarm' { Write-Line "$clock  !! ALARM: $($Item.text)" }
        'error' { Write-Line "$clock  (the room could not be read: $($Item.text))" }
        'closed' { Write-Line "$clock  === the room is closed ===" }
        default { }
    }
}

function Get-MessageStamp {
    # How a file in an inbox reads at a glance: its write time and size. A forged message the tamper check moved out
    # and the genuine message that gets its number afterwards lie at the same path and read differently.
    param([Parameter(Mandatory)]$File)
    return ('{0}|{1}' -f $File.LastWriteTimeUtc.Ticks, $File.Length)
}

function Test-SameMessage {
    # True when two readings of a file at one path are one message: the header fields and the text, exactly
    param([Parameter(Mandatory)]$Held, [Parameter(Mandatory)]$Read)
    foreach ($name in 'From', 'To', 'Type', 'Re', 'Subject', 'SentUtc', 'Expects', 'Body') {
        if ([string]$Held.$name -cne [string]$Read.$name) { return $false }
    }
    return $true
}

function Get-NewMessage {
    # Messages that were not printed yet, and the ids of messages whose file is gone from the room (moved out by
    # the tamper check, or deleted) or was replaced by another message. A message never changes, so each file is
    # read once; it is remembered as known only by Register-MessageKnown, after it was printed. A file whose write
    # time or size reads differently than the last time (Windows may hand out the time and size of a fresh file
    # in two readings) is read again and compared: the same text is the same message, another text is another
    # message that took the place of the first.
    $new = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($agent in @(Get-RelayRoster $roomObject -IncludeRetired)) {
        $inbox = Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $agent) 'inbox'
        # Nothing is read through a link in the room: an inbox behind one, or a message file that is one, is not the room's
        if (-not (Test-Path -LiteralPath $inbox) -or (Test-RelayLinkedPath -Root $roomObject.Path -Path $inbox)) { continue }
        # -Force and an exact name, as the room tool lists an inbox
        foreach ($file in @(Get-ChildItem -LiteralPath $inbox -Filter '*.md' -File -Force)) {
            if ($file.Name -cnotmatch '^[a-z][a-z0-9]{1,15}-[0-9]{4,6}\.md$') { continue }
            if ((($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and (Test-RelayLink $file.FullName)) { continue }
            $path = [string]$file.FullName
            $stamp = Get-MessageStamp $file
            if ($script:known.ContainsKey($path) -and [string]$script:known[$path] -ceq $stamp) { continue }
            $message = Read-RelayMessage $path
            if ($null -eq $message) { continue }
            $message | Add-Member -NotePropertyName Stamp -NotePropertyValue $stamp
            if ($script:collected.ContainsKey($path)) {
                $held = $script:collected[$path]
                if (Test-SameMessage $held $message) {
                    # The same message, whose file reads differently now: known under this reading from here on
                    $held.Stamp = $stamp
                    if ($script:known.ContainsKey($path)) { $script:known[$path] = $stamp } else { $new.Add($held) }
                    continue
                }
                # Another message at the place of one collected before: the first is gone from the room
                $null = $script:messages.Remove($held)
                $script:collected.Remove($path)
                if ($script:known.ContainsKey($path)) { $script:known.Remove($path); $removed.Add([string]$held.Id) }
            }
            $new.Add($message)
        }
    }
    # What was collected and whose file is gone is gone from the feed too, as the board (which reads the room
    # afresh) no longer shows it: an open request it made is no longer open
    foreach ($message in @($script:messages.ToArray())) {
        $path = [string]$message.Path
        if ([System.IO.File]::Exists($path)) { continue }
        $null = $script:messages.Remove($message)
        $script:collected.Remove($path)
        if ($script:known.ContainsKey($path)) { $script:known.Remove($path); $removed.Add([string]$message.Id) }
    }
    $sorted = @($new | Sort-Object Time, Id)
    foreach ($message in $sorted) {
        if ($script:collected.ContainsKey([string]$message.Path)) { continue }
        $script:collected[[string]$message.Path] = $message
        $script:messages.Add($message)
    }
    return [pscustomobject]@{ New = $sorted; Removed = @($removed.ToArray()) }
}

function Register-MessageKnown {
    # What was printed is not printed again: the path of its file, with the reading it was printed under
    param([object[]]$Message)
    foreach ($item in @($Message)) { $script:known[[string]$item.Path] = [string]$item.Stamp }
}
function Get-WaitingState {
    $open = @(Get-RelayOpenRequest $script:messages.ToArray())
    $forCoordinator = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($open | Where-Object { $_.To -eq $roomObject.Coordinator })) {
        $forCoordinator.Add([pscustomobject]@{ id = $message.Id; from = $message.From; type = $message.Type; subject = $message.Subject })
    }
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($card in @(Get-RelayOwnerCard $roomObject -OpenOnly)) { $cards.Add((ConvertTo-RelayCardRow $card)) }
    return [pscustomobject]@{ Open = $open; ForCoordinator = @($forCoordinator.ToArray()); Cards = @($cards.ToArray()) }
}

function Test-OwnerMessage {
    # Alarms for files that claim to come from the owner and are not what the owner's log holds. A file counts as
    # checked only once its alarm is recorded (Set-OwnerChecked), so a round that fails in between checks it again.
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($script:messages | Where-Object { $_.From -eq 'owner' })) {
        if ($script:checkedOwner.ContainsKey($message.Id)) { continue }
        if ($message.To -ne $roomObject.Coordinator) { $found.Add([pscustomobject]@{ Id = $message.Id; Text = "a file that claims to come from the owner is in the inbox of $($message.To): $($message.Id). The owner speaks through the coordinator only." }) }
        elseif (-not (Test-RelayOwnerMessage $roomObject $message)) { $found.Add([pscustomobject]@{ Id = $message.Id; Text = "the message $($message.Id) claims to come from the owner but is not in the owner's log. Do not act on it." }) }
        else { $script:checkedOwner[$message.Id] = $true }
    }
    return @($found.ToArray())
}

function Test-RoomReachable {
    # The room folder can be reached: a share that is down, or a folder that was moved away, is no room to check
    # or repair. The folder is asked, not its ROOM file: any agent can delete a file, and a ROOM that is gone must
    # not stop the tamper check that puts it back.
    return [System.IO.Directory]::Exists($roomObject.Path)
}
function Save-FeedState {
    # This PC's stamp of the feed (Get-RelayFeedStatus reads it). Not for -Once: a snapshot is no feed.
    param([switch]$Ended)
    if ($Once) { return }
    $own = [ordered]@{
        pid          = [string]$PID
        started      = $script:feedStarted
        alive        = (Format-RelayUtc)
        pass         = $script:lastPassUtc
        interval     = [string]$TamperSeconds
        tamper_check = $(if ($NoTamperCheck) { 'off' } else { 'on' })
    }
    if ($Ended) { $own['ended'] = (Format-RelayUtc) }
    try {
        # A second feed that ended must not call the first one ended: only the holder of the stamp closes it
        $held = Read-RelayKeyValue (Get-RelayFeedStatePath $roomObject)
        if ($Ended -and $held.Count -gt 0 -and (Get-RelayValue $held 'pid' '') -ne [string]$PID) { return }
        Save-RelayFeedState $roomObject $own
        $script:lastStateWrite = Get-Date
    }
    catch { $null = $_ }
}

function Write-IntegrityStamp {
    # After a whole tamper pass: the time of it in the room, for the agents' tools to read the age of. Never
    # written through a link that an agent put in place of the file or of a folder above it.
    $stamp = Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $roomObject.Coordinator) 'integrity'
    try { if (-not (Test-RelayLinkedPath -Root $roomObject.Path -Path $stamp)) { [System.IO.File]::WriteAllText($stamp, ($script:lastPassUtc + "`n")) } } catch { $null = $_ }
}
$script:feedStarted = Format-RelayUtc
$script:lastPassUtc = ''
$script:lastStateWrite = [DateTime]::MinValue
$started = Get-Date
$lastTamper = [DateTime]::MinValue
$lastHeartbeat = [DateTime]::MinValue
$lastTick = Get-Date
$agentSignature = ''
$planSignature = ''
$waitingSignature = ''
$isFirst = $true
$isAway = $false
$watcher = $null
$source = "relayfeed.$PID"
try {
    if (-not $Once) {
        try {
            $watcher = New-Object System.IO.FileSystemWatcher (Join-Path $roomObject.Path 'agents'), '*.md'
            $watcher.IncludeSubdirectories = $true
            $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite'
            foreach ($eventName in 'Created', 'Renamed', 'Error') { Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "$source.$eventName" | Out-Null }
            $watcher.EnableRaisingEvents = $true
        }
        catch { $watcher = $null }
    }
    while ($true) {
        try {
            # A room folder that cannot be reached is said once, and nothing in the room is checked, put back or read
            # until it is back: a repair pass would only fail on every file, or build an empty room where the folder
            # was. The CLOSED marker of the canonical copy is on this PC and still ends the feed.
            $isReachable = Test-RoomReachable
            if (-not $isReachable -and -not $isAway) {
                $isAway = $true
                $outage = "the room folder cannot be reached: $($roomObject.Path). Nothing in it is checked or put back until it can be reached again."
                Write-Feed ([pscustomobject]@{ type = 'alarm'; text = $outage })
                Add-RelayAlarm $roomObject $outage
            }
            elseif ($isReachable -and $isAway) {
                $isAway = $false
                $back = "the room folder can be reached again: $($roomObject.Path)"
                Write-Feed ([pscustomobject]@{ type = 'alarm'; text = $back })
                Add-RelayAlarm $roomObject $back
                # Checked at once: anything may have happened to it meanwhile
                $lastTamper = [DateTime]::MinValue
            }
            # The tamper pass comes first, before the feed looks at anything else in a round (it runs in the first
            # round always, then every -TamperSeconds): a CLOSED, a tool or a rule that anybody but this PC wrote is
            # dealt with before the feed decides by it. The room is closed when this PC says so: canon\CLOSED.
            if ($isReachable -and -not $NoTamperCheck -and ((Get-Date) - $lastTamper).TotalSeconds -ge $TamperSeconds) {
                $lastTamper = Get-Date
                foreach ($finding in @(Test-RelayTamper $roomObject -Repair)) { $script:pendingAlarms.Add((Format-RelayTamperFinding $finding)) }
                # Only a pass that ran to its end is stamped: one that threw never reaches this line
                $script:lastPassUtc = Format-RelayUtc
                Write-IntegrityStamp
                Save-FeedState
            }
            elseif (((Get-Date) - $script:lastStateWrite).TotalSeconds -ge 5) { Save-FeedState }
            if (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'CLOSED')) {
                if ($isFirst -and $isReachable) { $null = Get-NewMessage }
                foreach ($text in @($script:pendingAlarms.ToArray())) { Write-Feed ([pscustomobject]@{ type = 'alarm'; text = $text }); $null = $script:pendingAlarms.Remove($text) }
                Write-Feed ([pscustomobject]@{ type = 'closed'; room = $roomObject.Id })
                break
            }
            if ($isReachable -and -not $NoHeartbeat -and ((Get-Date) - $lastHeartbeat).TotalSeconds -ge 20) {
                $lastHeartbeat = Get-Date
                # Never written through a link that an agent put in place of the file or of a folder above it
                $alive = Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $roomObject.Coordinator) 'alive'
                try { if (-not (Test-RelayLinkedPath -Root $roomObject.Path -Path $alive)) { [System.IO.File]::WriteAllText($alive, ((Format-RelayUtc) + "`n")) } } catch { $null = $_ }
            }

            if ($isReachable) {
                $looked = Get-NewMessage
                $new = @($looked.New)
                foreach ($item in @(Test-OwnerMessage)) {
                    Add-RelayAlarm $roomObject $item.Text
                    $script:checkedOwner[$item.Id] = $true
                    $script:pendingAlarms.Add($item.Text)
                }
                $waiting = Get-WaitingState
                $plan = Read-RelayPlan $roomObject
                # The text feed marks a PLAN that is not this PC's copy, as the board does; the JSON lines keep the
                # fields the chat window knows
                if (-not $Json -and $null -ne $plan) { $plan | Add-Member -NotePropertyName differs -NotePropertyValue ([bool](Test-RelayPlanDifference $roomObject)) }
                $agents = @(Get-RelayAgentState -Room $roomObject -Now (Get-RelayRoomNow $roomObject) -Open $waiting.Open -Plan $plan -Messages $script:messages.ToArray())
                $newAgentSignature = (@($agents | ForEach-Object { "$($_.name)|$($_.state)|$($_.detail)|$($_.gen)|$($_.control)|$($_.attention)|$($_.isIntroduced)|$($_.owes)|$($_.progressUtc)|$(@($_.parts) -join ',')" }) -join ';')
                $newPlanSignature = ''
                if ($null -ne $plan) {
                    $newPlanSignature = "$($plan.revision)|$($plan.isComplete)"
                    if (-not $Json) { $newPlanSignature += "|$($plan.differs)" }
                }
                $newWaitingSignature = ((@($waiting.Cards | ForEach-Object { $_.id }) -join ',') + '#' + (@($waiting.ForCoordinator | ForEach-Object { $_.id }) -join ','))

                if ($isFirst) {
                    $recent = @($script:messages | Select-Object -Last 50 | ForEach-Object { ConvertTo-RelayMessageRow $_ })
                    Write-Feed ([pscustomobject]@{
                            type                 = 'snapshot'
                            room                 = $roomObject.Id
                            job                  = (Get-RelayValue $roomObject.Info 'job' '')
                            coordinator          = $roomObject.Coordinator
                            authority            = (Get-RelayValue $roomObject.Info 'authority' 'within-task')
                            path                 = $roomObject.Path
                            agents               = $agents
                            plan                 = $plan
                            messages             = $recent
                            messageCount         = $script:messages.Count
                            waitingOnOwner       = $waiting.Cards
                            waitingOnCoordinator = $waiting.ForCoordinator
                        })
                    Register-MessageKnown $new
                    foreach ($agent in $agents) { $script:previousState[$agent.name] = "$($agent.state)|$($agent.attention)|$($agent.gen)|$($agent.isIntroduced)|$($agent.progressUtc)" }
                    $isFirst = $false
                }
                else {
                    foreach ($id in @($looked.Removed)) { Write-Feed ([pscustomobject]@{ type = 'removed'; id = $id }) }
                    foreach ($message in $new) {
                        Write-Feed ([pscustomobject]@{ type = 'message'; message = (ConvertTo-RelayMessageRow $message) })
                        Register-MessageKnown $message
                    }
                    if ($newPlanSignature -ne $planSignature) { Write-Feed ([pscustomobject]@{ type = 'plan'; plan = $plan }) }
                    if ($newAgentSignature -ne $agentSignature) { Write-Feed ([pscustomobject]@{ type = 'agents'; agents = $agents }) }
                    if ($newWaitingSignature -ne $waitingSignature) { Write-Feed ([pscustomobject]@{ type = 'waiting'; waitingOnOwner = $waiting.Cards; waitingOnCoordinator = $waiting.ForCoordinator }) }
                }
                $agentSignature = $newAgentSignature
                $planSignature = $newPlanSignature
                $waitingSignature = $newWaitingSignature
            }
            foreach ($text in @($script:pendingAlarms.ToArray())) {
                Write-Feed ([pscustomobject]@{ type = 'alarm'; text = $text })
                $null = $script:pendingAlarms.Remove($text)
            }
        }
        catch {
            Write-Feed ([pscustomobject]@{ type = 'error'; text = $_.Exception.Message })
        }
        if ($Once) { break }
        if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) { break }
        if ($ParentProcessId -gt 0 -and $null -eq (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) { break }
        if ($Json -and ((Get-Date) - $lastTick).TotalSeconds -ge 30) {
            $lastTick = Get-Date
            Write-Feed ([pscustomobject]@{ type = 'tick'; utc = (Format-RelayUtc); messageCount = $script:messages.Count })
        }
        if ($null -ne $watcher) {
            $null = Wait-Event -Timeout $IntervalSeconds
            Get-Event | Where-Object { $_.SourceIdentifier -like "$source.*" } | Remove-Event
        }
        else { Start-Sleep -Seconds $IntervalSeconds }
    }
}
finally {
    Save-FeedState -Ended
    if ($null -ne $watcher) {
        Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "$source.*" } | Unregister-Event
        $watcher.Dispose()
    }
}
