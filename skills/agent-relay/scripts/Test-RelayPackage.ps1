#Requires -Version 5.1

<#
.SYNOPSIS
    Conformance run of the room package: the three engines talk to each other in one room and must agree.

.DESCRIPTION
    Builds a throw-away room on this PC and runs, with every tool call a real child process:

    1. A scripted conversation between three agents and the coordinator in which every seat uses a different
       engine (relay.ps1 under PowerShell 7, relay.ps1 under Windows PowerShell 5.1, relay.sh under dash), with
       a task, a question, a proposal, results and a note to all. Every engine must then see the same set of
       messages with the same headers and the same text, and nobody may owe anything.
    2. The team plan: a plan written by hand into the room, progress lines from two seats on different engines,
       the changed plan shown once with the next delivery, and team from every seat, which must print the same
       on every engine apart from the YOU: line.
    3. A load run: three senders, one per engine, send -Messages messages each to the coordinator at the same
       time. Nothing may be lost, no id may appear twice, and one wait per receiver must deliver every message
       exactly once.

    An engine that is not installed is left out and named. Exit code 0 when everything agrees, 1 otherwise.

.PARAMETER Messages
    Messages per sender in the load run. Default 50.

.PARAMETER WorkFolder
    Where the throw-away room is built. Default: a new folder under the temp folder. Only a folder this run made
    is removed again, and only after a run that went through and agreed; a folder that was there before is kept.

.PARAMETER Keep
    Keep the work folder also on success.

.EXAMPLE
    .\Test-RelayPackage.ps1

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only. Uses the process runner of the test suite (tests\RelayTestHelpers.ps1),
    so it runs from the git working copy of the plugin.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 500)][int]$Messages = 50,
    [string]$WorkFolder = '',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helpers = Join-Path $PSScriptRoot '..\..\..\tests\RelayTestHelpers.ps1'
if (-not (Test-Path -LiteralPath $helpers)) { throw "The conformance run needs the test helpers of the working copy: $helpers" }
. $helpers
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

if (-not $WorkFolder) { $WorkFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('relay-conformance-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
# Only a folder this run makes is removed again: one that was there before may hold anything
$isOwnFolder = -not (Test-Path -LiteralPath $WorkFolder)
$isCompleted = $false
$savedLocal = $env:AGENT_RELAY_LOCAL
$failures = New-Object System.Collections.Generic.List[string]
$checks = 0

function Assert-That {
    param([bool]$Condition, [string]$What)
    $script:checks++
    if (-not $Condition) { $script:failures.Add($What); "  FAIL  $What" }
}

function Get-MessageGraph {
    # Every message of the room as "id|type|re|expects|subject|hash of the text", sorted: what all sides must agree on
    param([string]$RoomPath)
    $lines = New-Object System.Collections.Generic.List[string]
    $sha = [System.Security.Cryptography.SHA256]::Create()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RoomPath 'agents') -Recurse -Filter '*.md' -File | Where-Object { $_.Directory.Name -eq 'inbox' })) {
        $message = Read-RelayTestMessage $file.FullName
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($message['Body']))) -replace '-', '').Substring(0, 16)
        $lines.Add(('{0}|{1}|{2}|{3}|{4}|{5}' -f $message['id'], $message['type'], $message['re'], $message['expects'], $message['subject'], $hash))
    }
    return @($lines | Sort-Object)
}

try {
    $engines = @(Get-RelayTestEngine)
    "engines: $($engines -join ', ')"
    foreach ($missing in @('ps7', 'ps5', 'sh') | Where-Object { $engines -notcontains $_ }) { "  NOT INSTALLED, left out: $missing" }
    if ($engines.Count -lt 2) { throw 'The conformance run needs at least two engines' }

    # One seat per engine; the coordinator takes the first engine, the agents take the engines in turn
    $names = @('emma', 'jack', 'henry')
    $engineOf = @{ olivia = $engines[0] }
    for ($index = 0; $index -lt $names.Count; $index++) { $engineOf[$names[$index]] = $engines[($index + 1) % $engines.Count] }
    $created = New-RelayTestRoom -Root $WorkFolder -RoomId 'conformance'
    $room = $created.Path
    "room: $room"
    foreach ($name in @('olivia') + $names) { "  $name uses $($engineOf[$name])" }

    function Invoke-Seat {
        param([string]$Name, [string[]]$Words, [string]$Text = '', [hashtable]$Environment = @{})
        if ($Text) { Set-RelayTestDraft -Room $room -Agent $Name -Text $Text }
        return (Invoke-RelayTool -Room $room -Agent $Name -Engine $engineOf[$Name] -Words $Words -Environment $Environment)
    }

    ''
    '1. Scripted conversation across engines'
    foreach ($name in @('olivia') + $names) { Assert-That ((Invoke-Seat $name @('start', 'conformance', $engineOf[$name], 'none')).ExitCode -eq 0) "$name starts" }
    Assert-That ((Invoke-Seat 'olivia' @('check')).Output -match '=== 3 new message') 'the coordinator receives three introductions'

    $hostile = 'Text with $dollar $(sub) `tick` | pipe "quotes" ''single'' %PATH% & <angle> C:\temp\x and caf' + [char]0x00E9
    Assert-That ((Invoke-Seat 'olivia' @('task', 'emma') "Count the files`n`n$hostile").ExitCode -eq 0) 'task to emma'
    Assert-That ((Invoke-Seat 'olivia' @('task', 'jack') "Review the notes`n`nReview them.").ExitCode -eq 0) 'task to jack'
    Assert-That ((Invoke-Seat 'olivia' @('note', 'all') "House rule`n`nReports go to me.").ExitCode -eq 0) 'note to all'
    $received = Invoke-Seat 'emma' @('check')
    Assert-That ($received.ExitCode -eq 0 -and $received.Output.Contains($hostile)) 'emma reads the task text unchanged'
    Assert-That ((Invoke-Seat 'emma' @('ask') "Which folder?`n`nWhich folder do you mean?").ExitCode -eq 0) 'emma asks'
    Assert-That ((Invoke-Seat 'olivia' @('check')).Output -match 'question from Emma') 'the coordinator sees the question'
    Assert-That ((Invoke-Seat 'olivia' @('reply', 'emma-olivia-0002') "The work folder`n`nThe work folder.").ExitCode -eq 0) 'the coordinator answers'
    Assert-That ((Invoke-Seat 'emma' @('check')).Output -match 'answer from Olivia') 'emma receives the answer'
    Assert-That ((Invoke-Seat 'emma' @('report') "Seven files`n`n1. Result: seven.").ExitCode -eq 0) 'emma reports'
    Assert-That ((Invoke-Seat 'jack' @('check')).Output -match 'task from Olivia') 'jack receives his task'
    Assert-That ((Invoke-Seat 'jack' @('propose', '30') "Fix a typo`n`nI will fix one typo in the notes.").ExitCode -eq 0) 'jack proposes'
    Assert-That ((Invoke-Seat 'olivia' @('check')).Output -match 'proposal from Jack') 'the coordinator sees the proposal'
    Assert-That ((Invoke-Seat 'olivia' @('reply', 'jack-olivia-0002', 'approve')).ExitCode -eq 0) 'the coordinator approves'
    Assert-That ((Invoke-Seat 'jack' @('check')).Output -match 'DO: it was approved') 'jack is told it was approved'
    Assert-That ((Invoke-Seat 'jack' @('report') "Notes reviewed`n`n1. Verdict: fine.").ExitCode -eq 0) 'jack reports'
    Assert-That ((Invoke-Seat 'henry' @('check')).Output -match 'House rule') 'henry receives the note to all'
    Assert-That ((Invoke-Seat 'henry' @('bye') "Leaving`n`nNothing slowed me down.").ExitCode -eq 0) 'henry says bye'
    $null = Invoke-Seat 'olivia' @('check')

    foreach ($name in @('olivia') + $names) {
        if ($name -eq 'henry') { continue }
        $open = Invoke-Seat $name @('show', 'open')
        Assert-That ($open.Output -match 'no open requests') "$name owes nothing at the end ($($engineOf[$name]))"
    }
    $graph = @(Get-MessageGraph $room)
    Assert-That ($graph.Count -eq 15) "the room holds 15 messages (it holds $($graph.Count))"
    foreach ($engine in $engines) {
        # Each engine prints every message; what it prints must carry the header and text the files hold
        $seat = @($engineOf.Keys | Where-Object { $engineOf[$_] -eq $engine })[0]
        foreach ($line in $graph) {
            $id = ($line -split '\|')[0]
            $shown = Invoke-RelayTool -Room $room -Agent $seat -Engine $engine -Words @('show', $id)
            $subject = ($line -split '\|')[4]
            Assert-That ($shown.ExitCode -eq 0 -and $shown.Output.Contains("subject: $subject") -and $shown.Output.Contains("--- $id | ")) "$engine shows $id as the file holds it"
        }
        $hostileShown = Invoke-RelayTool -Room $room -Agent $seat -Engine $engine -Words @('show', 'olivia-emma-0001')
        Assert-That ($hostileShown.Output.Contains($hostile)) "$engine prints the shell-hostile text of olivia-emma-0001 unchanged"
    }

    ''
    '2. Team plan: team and progress across engines'
    $everybody = @('olivia') + $names
    $displayOf = @{}
    foreach ($name in $everybody) { $displayOf[$name] = ConvertTo-RelayDisplayName $name }
    # What team prints for every seat except the YOU: line, one string per seat
    function Get-TeamBody {
        param([string]$Name)
        $result = Invoke-Seat $Name @('team')
        $you = @($result.Output -split "`r?`n" | Where-Object { $_ -like 'YOU:*' }) + ''
        return [pscustomobject]@{ ExitCode = $result.ExitCode; Lines = @($result.Output -split "`r?`n" | Where-Object { $_ -notlike 'YOU:*' }) + ''; You = $you }
    }
    function Assert-TeamAgreement {
        param([string]$Label)
        $bodies = @{}
        foreach ($name in $everybody) { $bodies[$name] = Get-TeamBody $name; Assert-That ($bodies[$name].ExitCode -eq 0) "$Label : team exits 0 for $name ($($engineOf[$name]))" }
        $first = $bodies['olivia'].Lines -join "`n"
        foreach ($name in $names) { Assert-That (($bodies[$name].Lines -join "`n") -ceq $first) "$Label : team of $name ($($engineOf[$name])) equals team of olivia ($($engineOf['olivia'])) apart from YOU:" }
        $script:teamBodies = $bodies
    }
    Assert-TeamAgreement 'no plan'
    $noPlan = $script:teamBodies
    Assert-That ($noPlan['olivia'].Lines[0] -ceq '=== team in room conformance: no plan yet ===') 'team without a plan says so in its first line'
    Assert-That (-not ($noPlan['olivia'].Lines -contains 'PARTS')) 'team without a plan prints no PARTS block'
    Assert-That ($noPlan['olivia'].Lines -contains 'AGENTS') 'team without a plan still prints AGENTS'

    # The coordinator's PC writes the plan; here it is written by hand: UTF-8 without BOM, LF, closed by end:
    $plan = @(
        'plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: A team view for every agent',
        'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1',
        'part: tests | jack | todo | tool-ps | - | Tests for both verbs',
        'files: tool-ps | skills/agent-relay/assets/room-package/tools/relay.ps1',
        'files: tests | tests/Relay.Team.Tests.ps1',
        'note: tool-ps | Output must match relay.sh line for line',
        'end: 1'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $room 'PLAN'), ($plan + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Assert-That ((Invoke-Seat 'olivia' @('task', 'jack') "Second look`n`nLook once more.").ExitCode -eq 0) 'task to jack for the team view'
    $secondTask = @(Get-ChildItem -LiteralPath (Join-Path $room 'agents\jack\inbox') -Filter '*.md' -File | ForEach-Object { Read-RelayTestMessage $_.FullName } | Where-Object { $_['subject'] -ceq 'Second look' })
    Assert-That ($secondTask.Count -eq 1) 'the second task to jack is in his inbox'
    $secondId = ''
    if ($secondTask.Count -eq 1) { $secondId = $secondTask[0]['id'] }

    # progress from two seats on different engines: two lines of output, a progress file, no message
    $before = @(Get-MessageGraph $room).Count
    $progressText = @{ emma = ('Counting $files `ticks` "quotes" ''single'' %PATH% & <angle> C:\temp\x and caf' + [char]0x00E9); jack = 'Reading the notes' }
    foreach ($name in @('emma', 'jack')) {
        $text = $progressText[$name]
        $noted = Invoke-Seat $name @('progress') "$text`n`nThe rest of the draft is ignored."
        $outLines = @($noted.Output -split "`r?`n" | Where-Object { $_ -ne '' })
        Assert-That ($noted.ExitCode -eq 0 -and $outLines.Count -eq 2 -and $outLines[0] -ceq "PROGRESS noted: $text" -and $outLines[1] -match '^NEXT: carry on\. The team sees it with: .+ team$') "$name ($($engineOf[$name])) progress prints its two lines"
        $progressFile = Join-Path $room "agents\$name\progress"
        $recorded = @()
        if (Test-Path -LiteralPath $progressFile) { $recorded = @(Get-Content -LiteralPath $progressFile -Encoding UTF8) }
        Assert-That ($recorded.Count -eq 1 -and $recorded[0] -cmatch ('^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \| ' + [regex]::Escape($text) + '$')) "$name ($($engineOf[$name])) progress file holds one line with the text"
        $statusText = [System.IO.File]::ReadAllText((Join-Path $room "agents\$name\status"))
        Assert-That ($statusText -cmatch '(?m)^state: working\r?$' -and $statusText.Contains("detail: $text")) "$name ($($engineOf[$name])) progress sets the status to working with the text"
        $draftFile = Join-Path $room "agents\$name\draft.md"
        Assert-That ((-not (Test-Path -LiteralPath $draftFile)) -or ([System.IO.File]::ReadAllText($draftFile).Trim() -eq '')) "$name ($($engineOf[$name])) progress clears the draft"
    }
    Assert-That (@(Get-MessageGraph $room).Count -eq $before) 'progress sends no message'
    $none = Invoke-Seat 'henry' @('progress')
    Assert-That ($none.ExitCode -eq 1 -and $none.Output -match 'there is nothing to send') 'progress without a draft is the usual error'

    # A changed plan is shown once, with the next delivery, on every engine that has not run team yet
    foreach ($name in @('emma', 'jack')) {
        Assert-That ((Invoke-Seat 'olivia' @('note', $name) "Plan note`n`nLook at the plan.").ExitCode -eq 0) "note to $name"
        $banner = Invoke-Seat $name @('check')
        $lines = @($banner.Output -split "`r?`n")
        $at = [array]::IndexOf($lines, '=== the team plan changed: plan 1 ===')
        $next = @($lines | Where-Object { $_ -like 'NEXT:*' })
        Assert-That ($banner.ExitCode -eq 0 -and $at -ge 0 -and $lines[$at + 1] -ceq 'PARTS' -and $next.Count -eq 1 -and [array]::IndexOf($lines, $next[0]) -gt $at) "$name ($($engineOf[$name])) is shown the changed plan once, before NEXT:"
        Assert-That ($at -ge 0 -and $next.Count -eq 1 -and $lines[[array]::IndexOf($lines, $next[0]) - 1] -ceq '') "$name ($($engineOf[$name])) the plan block ends with an empty line before NEXT:"
    }

    Assert-TeamAgreement 'with plan'
    $withPlan = $script:teamBodies
    $rows = @(
        '=== team in room conformance: plan 1, 2026-10-10T08:15:00Z ===',
        'goal: A team view for every agent',
        'PARTS',
        ('  {0,-12}  {1,-8}  {2,-9}  {3}' -f 'tool-ps', 'doing', 'Emma', 'The verbs in relay.ps1'),
        '      reviewer: Henry',
        '      files: skills/agent-relay/assets/room-package/tools/relay.ps1',
        '      note: Output must match relay.sh line for line',
        ('  {0,-12}  {1,-8}  {2,-9}  {3}' -f 'tests', 'todo', 'Jack', 'Tests for both verbs'),
        '      depends on: tool-ps',
        '      files: tests/Relay.Team.Tests.ps1',
        'AGENTS',
        ('      progress: ' + $progressText['emma'] + '  ('),
        '      parts: tool-ps',
        ('      doing: ' + $secondId + '  Second look'),
        ('      progress: ' + $progressText['jack'] + '  ('),
        '      parts: tests'
    )
    $teamLines = @($withPlan['olivia'].Lines)
    foreach ($row in $rows) {
        $found = @($teamLines | Where-Object { $_ -ceq $row -or ($row.EndsWith('  (', [System.StringComparison]::Ordinal) -and $_.StartsWith($row, [System.StringComparison]::Ordinal)) })
        Assert-That ($found.Count -ge 1) "team prints the line: $row"
    }
    # The part lines come in the order of the file, and the blocks are separated by exactly one empty line
    $partsAt = [array]::IndexOf($teamLines, 'PARTS')
    $agentsAt = [array]::IndexOf($teamLines, 'AGENTS')
    Assert-That ($partsAt -eq 3 -and $agentsAt -gt $partsAt -and $teamLines[$partsAt - 1] -ceq '' -and $teamLines[$agentsAt - 1] -ceq '' -and $teamLines[$partsAt + 1] -ceq $rows[3]) 'team: header, goal, one empty line, PARTS in file order, one empty line, AGENTS'
    $roleOf = @{ olivia = 'coordinator'; emma = 'tester'; jack = 'reviewer'; henry = 'writer' }
    foreach ($name in $everybody) {
        $agentRows = @($teamLines | Where-Object { $_ -cmatch ('^  ' + $displayOf[$name] + ' +\S.* +' + $roleOf[$name] + '$') })
        Assert-That ($agentRows.Count -eq 1) "team: $($displayOf[$name]) is listed once under AGENTS with the role $($roleOf[$name])"
    }
    Assert-That ($withPlan['emma'].You[0] -ceq 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia.') 'team: the YOU: line of emma'
    Assert-That ($withPlan['jack'].You[0] -ceq 'YOU: Jack. Your parts: tests. You may write directly to: Olivia.') 'team: the YOU: line of jack'
    Assert-That ($withPlan['henry'].You[0] -ceq 'YOU: Henry. Your parts: none. You may write directly to: Olivia.') 'team: the YOU: line of henry'
    Assert-That ($withPlan['olivia'].You[0] -ceq 'YOU: Olivia. Your parts: none. You may write to everybody.') 'team: the YOU: line of the coordinator'
    foreach ($name in @('emma', 'jack')) {
        Assert-That ((Invoke-Seat 'olivia' @('note', $name) "Plan note two`n`nNothing new.").ExitCode -eq 0) "second note to $name"
        Assert-That (-not (Invoke-Seat $name @('check')).Output.Contains('the team plan changed')) "$name ($($engineOf[$name])) is not shown the same plan twice"
    }
    $olivia = Invoke-Seat 'olivia' @('check')
    Assert-That (-not $olivia.Output.Contains('the team plan changed')) 'the coordinator is never shown the changed plan'

    ''
    "3. Load: $($names.Count) senders, $Messages messages each, at the same time"
    $handles = New-Object System.Collections.Generic.List[object]
    $runner = @'
param($Helpers, $Room, $Agent, $Engine, $Count)
. $Helpers
$failed = 0
for ($number = 1; $number -le $Count; $number++) {
    $draft = Join-Path $Room "agents\$Agent\load-draft.md"
    Set-RelayTestDraft -Room $Room -Agent $Agent -Path $draft -Text "load $Agent $number`n`nload body $Agent $number"
    $result = Invoke-RelayTool -Room $Room -Agent $Agent -Engine $Engine -Words @('note') -Environment @{ RELAY_DRAFT = $draft }
    if ($result.ExitCode -ne 0) { $failed++ }
}
exit $failed
'@
    $runnerPath = Join-Path $WorkFolder 'load-runner.ps1'
    [System.IO.File]::WriteAllText($runnerPath, $runner)
    # henry said bye above; a bye does not stop an agent from sending, and all three engines must take part
    $shell = (Get-Process -Id $PID).Path
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $names) {
        # One command line, each argument quoted as the process reads it: Start-Process joins a list with blanks
        # and nothing else, and a temp folder or a repository path with a blank in it would split
        $line = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath, $helpers, $room, $name, $engineOf[$name], [string]$Messages) | ForEach-Object { ConvertTo-RelayTestArgument $_ }) -join ' '
        $startOptions = @{ FilePath = $shell; ArgumentList = $line; PassThru = $true }
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $startOptions['WindowStyle'] = 'Hidden' }
        $handles.Add((Start-Process @startOptions))
    }
    foreach ($process in $handles) {
        $null = $process.WaitForExit(1800000)
        Assert-That ($process.ExitCode -eq 0) "a sender finished with $($process.ExitCode) failed sends"
    }
    $watch.Stop()
    "  sent in $([int]$watch.Elapsed.TotalSeconds) s"
    $inbox = Join-Path $room 'agents\olivia\inbox'
    foreach ($name in $names) {
        $files = @(Get-ChildItem -LiteralPath $inbox -Filter "$name-*.md" -File)
        $bodies = @($files | ForEach-Object { (Read-RelayTestMessage $_.FullName)['Body'] } | Where-Object { $_ -match "^load body $name \d+$" } | Sort-Object -Unique)
        Assert-That ($bodies.Count -eq $Messages) "$name ($($engineOf[$name])): $($bodies.Count) of $Messages messages arrived, each once"
        $ids = @($files | ForEach-Object { (Read-RelayTestMessage $_.FullName)['id'] })
        Assert-That (@($ids | Sort-Object -Unique).Count -eq $ids.Count) "$name ($($engineOf[$name])): no id appears twice"
    }
    Assert-That (@(Get-ChildItem -LiteralPath $inbox -Force | Where-Object { $_.Name -like '.*' }).Count -eq 0) 'no temporary file is left in the inbox'
    $delivery = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engineOf['olivia'] -Words @('check') -TimeoutSeconds 300
    $expected = $names.Count * $Messages
    Assert-That ($delivery.Output -match "=== $expected new message") "one wake delivers all $expected messages (it said: $(@($delivery.Output -split "`n")[0]))"
    $again = Invoke-RelayTool -Room $room -Agent 'olivia' -Engine $engineOf['olivia'] -Words @('check')
    Assert-That ($again.ExitCode -eq 3) 'nothing is delivered a second time'
    $record = @(Get-Content -LiteralPath (Join-Path $room 'agents\olivia\delivered') | ForEach-Object { ($_ -split ' ')[0] })
    Assert-That (@($record | Sort-Object -Unique).Count -eq $record.Count) 'the delivery record holds every id once'

    ''
    if ($failures.Count -eq 0) { "CONFORMANCE PASSED: $checks checks, engines $($engines -join ', ')" }
    else { "CONFORMANCE FAILED: $($failures.Count) of $checks checks"; foreach ($failure in $failures) { "  $failure" } }
    $isCompleted = $true
}
finally {
    $env:AGENT_RELAY_LOCAL = $savedLocal
    # A run that stopped on an error has counted no failure, and still proves nothing: its folder is kept
    if ($isOwnFolder -and $isCompleted -and $failures.Count -eq 0 -and -not $Keep -and (Test-Path -LiteralPath $WorkFolder)) { Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue }
    elseif (Test-Path -LiteralPath $WorkFolder) { "kept for inspection: $WorkFolder" }
}
if ($failures.Count -gt 0) { exit 1 }
exit 0
