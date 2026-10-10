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

    -Json prints one JSON object per line, ASCII only: first a "snapshot", then "message", "agents", "waiting",
    "alarm", "tick" and finally "closed". Without -Json the same is printed for reading. It ends when the room
    is closed, when the process named by -ParentProcessId is gone, or after -MaxSeconds.

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
    try { $ParentProcessId = [int](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -Property ParentProcessId -ErrorAction Stop).ParentProcessId } catch { $ParentProcessId = 0 }
}

$roomObject = Resolve-RelayRoom $Room
$script:known = @{}
$script:messages = New-Object System.Collections.Generic.List[object]
$script:previousState = @{}
$script:checkedOwner = @{}

function Get-Display {
    param([string]$Name)
    if (-not $Name) { return '?' }
    if ($Name -eq 'owner') { return 'OWNER' }
    return ($Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1))
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
    Write-Line ('{0}  {1} -> {2}  [{3}]{4}  {5}' -f ([DateTime]::Parse($Row.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime().ToString('HH:mm:ss')), (Get-Display $Row.from), (Get-Display $Row.to), $Row.type, $re, $Row.subject)
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
    Write-Line "  PLAN $($Plan.revision): $($Plan.goal)$mark"
    foreach ($part in @($Plan.parts)) { Write-Line ('    {0,-12}  {1,-8}  {2,-9}  {3}' -f $part.id, $part.status, $part.owner, $part.title) }
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

function Get-NewMessage {
    # Messages that appeared since the last look. A message never changes, so each file is read once.
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($agent in @(Get-RelayRoster $roomObject -IncludeRetired)) {
        $inbox = Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $agent) 'inbox'
        if (-not (Test-Path -LiteralPath $inbox)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $inbox -Filter '*.md' -File)) {
            if ($script:known.ContainsKey($file.FullName)) { continue }
            if ($file.Name -notmatch '^[a-z][a-z0-9]{1,15}-[0-9]{4,6}\.md$') { continue }
            $message = Read-RelayMessage $file.FullName
            if ($null -eq $message) { continue }
            $script:known[$file.FullName] = $true
            $new.Add($message)
        }
    }
    $sorted = @($new | Sort-Object Time, Id)
    foreach ($message in $sorted) { $script:messages.Add($message) }
    return $sorted
}

function Get-WaitingState {
    $open = @(Get-RelayOpenRequest $script:messages.ToArray())
    $forCoordinator = New-Object System.Collections.Generic.List[object]
    foreach ($message in @($open | Where-Object { $_.To -eq $roomObject.Coordinator })) {
        $forCoordinator.Add([pscustomobject]@{ id = $message.Id; from = $message.From; type = $message.Type; subject = $message.Subject })
    }
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($card in @(Get-RelayOwnerCard $roomObject -OpenOnly)) {
        $preview = $card.Body
        if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) + ' ...' }
        $cards.Add([pscustomobject]@{ id = $card.Id; re = $card.Re; subject = $card.Subject; sentUtc = $card.SentUtc; text = $preview })
    }
    return [pscustomobject]@{ Open = $open; ForCoordinator = @($forCoordinator.ToArray()); Cards = @($cards.ToArray()) }
}

function Test-OwnerMessage {
    # Alarm texts for files that claim to come from the owner and are not what the owner's log holds
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($message in @($script:messages | Where-Object { $_.From -eq 'owner' })) {
        if ($script:checkedOwner.ContainsKey($message.Id)) { continue }
        $script:checkedOwner[$message.Id] = $true
        if ($message.To -ne $roomObject.Coordinator) { $texts.Add("a file that claims to come from the owner is in the inbox of $($message.To): $($message.Id). The owner speaks through the coordinator only.") }
        elseif (-not (Test-RelayOwnerMessage $roomObject $message)) { $texts.Add("the message $($message.Id) claims to come from the owner but is not in the owner's log. Do not act on it.") }
    }
    return @($texts.ToArray())
}

$started = Get-Date
$lastTamper = [DateTime]::MinValue
$lastHeartbeat = [DateTime]::MinValue
$lastTick = Get-Date
$agentSignature = ''
$planSignature = ''
$waitingSignature = ''
$isFirst = $true
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
            if (Test-Path -LiteralPath (Join-Path $roomObject.Path 'CLOSED')) {
                if ($isFirst) { $null = Get-NewMessage }
                Write-Feed ([pscustomobject]@{ type = 'closed'; room = $roomObject.Id })
                break
            }
            if (-not $NoHeartbeat -and ((Get-Date) - $lastHeartbeat).TotalSeconds -ge 20) {
                $lastHeartbeat = Get-Date
                try { [System.IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $roomObject.Path 'agents') $roomObject.Coordinator) 'alive'), ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + "`n")) } catch { $null = $_ }
            }
            $alarms = New-Object System.Collections.Generic.List[string]
            if (-not $NoTamperCheck -and ((Get-Date) - $lastTamper).TotalSeconds -ge $TamperSeconds) {
                $lastTamper = Get-Date
                foreach ($finding in @(Test-RelayTamper $roomObject -Repair)) {
                    $done = 'restored from the copy on this PC'
                    if ($finding.Kind -eq 'extra') { $done = 'it does not belong there and was moved out' }
                    $alarms.Add("$($finding.Relative) was $($finding.Kind): $done")
                }
            }

            $new = @(Get-NewMessage)
            foreach ($text in @(Test-OwnerMessage)) { Add-RelayAlarm $roomObject $text; $alarms.Add($text) }
            $waiting = Get-WaitingState
            $plan = Read-RelayPlan $roomObject
            $agents = @(Get-RelayAgentState -Room $roomObject -Now (Get-RelayRoomNow $roomObject) -Open $waiting.Open -Plan $plan)
            $newAgentSignature = (@($agents | ForEach-Object { "$($_.name)|$($_.state)|$($_.detail)|$($_.gen)|$($_.control)|$($_.attention)|$($_.isIntroduced)|$($_.owes)|$($_.progressUtc)|$(@($_.parts) -join ',')" }) -join ';')
            $newPlanSignature = ''
            if ($null -ne $plan) { $newPlanSignature = "$($plan.revision)|$($plan.isComplete)" }
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
                foreach ($agent in $agents) { $script:previousState[$agent.name] = "$($agent.state)|$($agent.attention)|$($agent.gen)|$($agent.isIntroduced)|$($agent.progressUtc)" }
                $isFirst = $false
            }
            else {
                foreach ($message in $new) { Write-Feed ([pscustomobject]@{ type = 'message'; message = (ConvertTo-RelayMessageRow $message) }) }
                if ($newPlanSignature -ne $planSignature) { Write-Feed ([pscustomobject]@{ type = 'plan'; plan = $plan }) }
                if ($newAgentSignature -ne $agentSignature) { Write-Feed ([pscustomobject]@{ type = 'agents'; agents = $agents }) }
                if ($newWaitingSignature -ne $waitingSignature) { Write-Feed ([pscustomobject]@{ type = 'waiting'; waitingOnOwner = $waiting.Cards; waitingOnCoordinator = $waiting.ForCoordinator }) }
            }
            $agentSignature = $newAgentSignature
            $planSignature = $newPlanSignature
            $waitingSignature = $newWaitingSignature
            foreach ($text in $alarms) { Write-Feed ([pscustomobject]@{ type = 'alarm'; text = $text }) }
        }
        catch {
            Write-Feed ([pscustomobject]@{ type = 'error'; text = $_.Exception.Message })
        }

        if ($Once) { break }
        if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) { break }
        if ($ParentProcessId -gt 0 -and $null -eq (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) { break }
        if ($Json -and ((Get-Date) - $lastTick).TotalSeconds -ge 30) {
            $lastTick = Get-Date
            Write-Feed ([pscustomobject]@{ type = 'tick'; utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); messageCount = $script:messages.Count })
        }
        if ($null -ne $watcher) {
            $null = Wait-Event -Timeout $IntervalSeconds
            Get-Event | Where-Object { $_.SourceIdentifier -like "$source.*" } | Remove-Event
        }
        else { Start-Sleep -Seconds $IntervalSeconds }
    }
}
finally {
    if ($null -ne $watcher) {
        Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "$source.*" } | Unregister-Event
        $watcher.Dispose()
    }
}
