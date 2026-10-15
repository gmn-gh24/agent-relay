#Requires -Version 5.1

<#
    The verbs team and progress, the changed-plan banner and the help lines, the same cases for every engine:
    relay.ps1 under PowerShell 7 and under Windows PowerShell 5.1. Written from sections 1 to 5 of
    work\team-plan\SPEC.md and from nothing else. Every tool call is a real child process. Pester 6. ASCII only.
    The plans in it are sample data: a part named tool-sh or a note that names relay.sh is text, not a tool.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: a variable set in BeforeAll or BeforeEach is read in the It blocks')]
param()

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
    $engineCases = @(Get-RelayTestEngine | ForEach-Object { @{ Engine = $_ } })
}

Describe 'Team verbs on <Engine>' -Tag 'Team' -ForEach $engineCases {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'RelayTestHelpers.ps1')
        $engine = $Engine
        $root = Join-Path $TestDrive "team-$engine"
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $indent = '      '

        # The plan of the contract's example, with the agents of this room as owners. Revision 3.
        # (the last line, end: 3, is added by Write-TeamPlan)
        $defaultPlan = @(
            'plan: 3'
            'updated_utc: 2026-10-10T08:15:00Z'
            'goal: A team view for every agent'
            'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1'
            'part: tool-sh | olivia | todo | - | henry | The verbs in relay.sh'
            'part: tests | jack | todo | tool-ps,tool-sh | - | Tests for both verbs'
            'files: tool-ps | skills/agent-relay/assets/room-package/tools/relay.ps1'
            'files: tests | tests/Relay.Team.Tests.ps1'
            'note: tool-ps | Output must match relay.sh line for line'
        )

        function Write-TeamPlan {
            # A plan file written by hand, UTF-8 without BOM, LF line ends unless asked for CRLF. The last line is
            # end: <revision> of the first plan: line, unless another one is given or none is wanted.
            param([string]$Room, [string[]]$Lines, [switch]$Crlf, [string]$End = '', [switch]$NoEnd)
            $eol = "`n"
            if ($Crlf) { $eol = "`r`n" }
            $all = @($Lines)
            if (-not $NoEnd) {
                if (-not $End) {
                    $first = @($all | Where-Object { $_ -like 'plan:*' })
                    if ($first.Count -gt 0) { $End = $first[0].Substring(5).Trim() }
                }
                $all += "end: $End"
            }
            [System.IO.File]::WriteAllText((Join-Path $Room 'PLAN'), ($all -join $eol) + $eol, $utf8)
        }

        function Write-TeamFile {
            param([string]$Path, [string]$Text)
            [System.IO.File]::WriteAllText($Path, $Text, $utf8)
        }

        function Write-TeamStatus {
            param([string]$Room, [string]$Agent, [string]$State, [string]$Detail = '')
            Write-TeamFile (Join-Path $Room "agents\$Agent\status") "state: $State`ndetail: $Detail`nsince_utc: 2026-10-10T08:00:00Z`ngen: 1`n"
        }

        function Write-TeamMessage {
            # One message file by hand, in the header format the tool writes
            param([string]$Room, [string]$From, [string]$To, [int]$Number, [string]$Type = 'task', [string]$Re = '', [string]$Subject = 'Do the work', [string]$Sent = '2026-10-10T08:00:00Z', [switch]$NoSent)
            $id = '{0}-{1}-{2:0000}' -f $From, $To, $Number
            $sentLine = "sent_utc: $Sent`n"
            if ($NoSent) { $sentLine = '' }
            $text = "---`nid: $id`nfrom: $From`nto: $To`ntype: $Type`nre: $Re`nsubject: $Subject`n${sentLine}expects: reply`n---`nText of $id.`n"
            Write-TeamFile (Join-Path $Room ('agents\{0}\inbox\{1}-{2:0000}.md' -f $To, $From, $Number)) $text
            return $id
        }

        function Read-TeamKeyValue {
            param([string]$Path)
            $map = @{}
            if (-not (Test-Path -LiteralPath $Path)) { return $map }
            foreach ($line in ([System.IO.File]::ReadAllText($Path) -replace "`r", '') -split "`n") {
                $at = $line.IndexOf([char]':')
                if ($at -gt 0) { $map[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim() }
            }
            return $map
        }

        function Read-TeamFileLine {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            $text = ([System.IO.File]::ReadAllText($Path) -replace "`r", '').TrimEnd("`n")
            if ($text -eq '') { return @() }
            return @($text -split "`n")
        }

        function Get-TeamLine {
            param([string]$Text)
            return @(($Text -replace "`r", '').TrimEnd("`n") -split "`n")
        }

        function Join-TeamLine {
            param([string[]]$Lines)
            return (@($Lines) -join "`n")
        }

        function Get-TeamSection {
            # The lines from a heading to the empty line that ends the block, heading included
            param([string[]]$Lines, [string]$Heading)
            $at = [array]::IndexOf($Lines, $Heading)
            if ($at -lt 0) { return @() }
            $block = New-Object System.Collections.Generic.List[string]
            for ($index = $at; $index -lt $Lines.Count -and $Lines[$index] -ne ''; $index++) { $block.Add($Lines[$index]) }
            return @($block.ToArray())
        }

        function Get-TeamAgentBlock {
            # The AGENTS rows of one agent: its row and the sub-lines under it
            param([string[]]$Lines, [string]$Display)
            $agents = @(Get-TeamSection $Lines 'AGENTS')
            $block = New-Object System.Collections.Generic.List[string]
            $inside = $false
            foreach ($line in ($agents | Select-Object -Skip 1)) {
                if ($line -match '^  \S') { $inside = ($line -match ('^  ' + [regex]::Escape($Display) + ' ')) }
                if ($inside) { $block.Add($line) }
            }
            return @($block.ToArray())
        }

        function Format-TeamPart {
            param([string]$Id, [string]$Status, [string]$Owner, [string]$Title)
            return ('  ' + $Id.PadRight(12) + '  ' + $Status.PadRight(8) + '  ' + $Owner.PadRight(9) + '  ' + $Title)
        }

        function Format-TeamAgent {
            param([string]$Display, [string]$State, [string]$Role)
            return ('  ' + $Display.PadRight(9) + '  ' + $State.PadRight(12) + '  ' + $Role)
        }

        function Get-TeamUtc {
            param([string]$Text)
            return [DateTime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
        }

        function Get-TeamTree {
            # Every file of a folder with a fingerprint of its content and its time
            param([string]$Path)
            $map = @{}
            $hash = [System.Security.Cryptography.SHA256]::Create()
            foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)) {
                $map[$file.FullName.Substring($Path.Length)] = ([BitConverter]::ToString($hash.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName)))) + ' ' + $file.LastWriteTimeUtc.Ticks
            }
            $hash.Dispose()
            return $map
        }

        function Get-TeamTreeChange {
            # The files that appeared, vanished or changed between two trees, sorted
            param($Before, $After)
            $names = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
            return @($names | Where-Object { -not ($Before.ContainsKey($_) -and $After.ContainsKey($_) -and $Before[$_] -eq $After[$_]) })
        }

        function Invoke-Team {
            param([string]$Agent, [string[]]$Words, [hashtable]$Environment = @{})
            return (Invoke-RelayTool -Room $room -Agent $Agent -Engine $engine -Words $Words -Environment $Environment)
        }

        function Set-TeamWaitLease {
            # A fake lease of this test process: a live wait of the agent, so a verb ends with its own NEXT
            # line and no keep-waiting warning (the pid is this host, which lives for the whole test)
            param([string]$Agent)
            [System.IO.File]::WriteAllText((Join-Path $room "agents\$Agent\wait.lease"), ("token: test`ngen: 1`nhost: {0}`npid: {1}`n" -f [Environment]::MachineName, $PID))
        }

        function Get-TeamRawOutput {
            # The bytes the tool printed, carriage returns kept (Wait-RelayTool takes them out)
            param([string]$Agent, [string[]]$Words)
            $handle = Start-RelayTool -Room $room -Agent $Agent -Engine $engine -Words $Words
            $null = $handle.Process.WaitForExit(120000)
            $handle.Process.WaitForExit()
            return [string]$handle.Output.Result
        }

        function Send-TeamNote {
            # A plain note from one agent to another, through the tool
            param([string]$From, [string]$To, [string]$Text = "Hello`n`nA note.")
            return (Send-RelayTestMessage -Room $room -Agent $From -Engine $engine -Words @('note', $To) -Text $Text)
        }

        function Get-TeamExpectedPartBlock {
            # The PARTS block of the default plan
            return @(
                'PARTS'
                (Format-TeamPart 'tool-ps' 'doing' 'Emma' 'The verbs in relay.ps1')
                ($indent + 'reviewer: Henry')
                ($indent + 'files: skills/agent-relay/assets/room-package/tools/relay.ps1')
                ($indent + 'note: Output must match relay.sh line for line')
                (Format-TeamPart 'tool-sh' 'todo' 'Olivia' 'The verbs in relay.sh')
                ($indent + 'reviewer: Henry')
                (Format-TeamPart 'tests' 'todo' 'Jack' 'Tests for both verbs')
                ($indent + 'depends on: tool-ps, tool-sh')
                ($indent + 'files: tests/Relay.Team.Tests.ps1')
            )
        }

        function Confirm-TeamBanner {
            # The banner block sits directly before the final NEXT: line: an empty line, the banner, the PARTS block,
            # one empty line, NEXT:
            param([string[]]$Lines, [string]$Revision, [string[]]$Parts)
            $banner = [array]::IndexOf($Lines, "=== the team plan changed: plan $Revision ===")
            $banner | Should -BeGreaterThan 0
            $Lines[$banner - 1] | Should -BeExactly ''
            $block = @($Parts)
            Join-TeamLine $Lines[($banner + 1)..($banner + $block.Count)] | Should -BeExactly (Join-TeamLine $block)
            $Lines[$banner + $block.Count + 1] | Should -BeExactly ''
            $Lines[$banner + $block.Count + 2] | Should -Match '^NEXT: '
            $Lines.Count | Should -Be ($banner + $block.Count + 3)
        }
        # A template room: five agents, one of them retired later, one free seat, everybody introduced
        $template = (New-RelayTestRoom -Root $root -RoomId 'template' -Extra @{ open_seats = 1 } -Agents @(
                [ordered]@{ name = 'adam'; role = 'scout'; kind = 'generic'; transport = 'same-pc' }
                [ordered]@{ name = 'emma'; role = 'tester'; kind = 'generic'; transport = 'same-pc' }
                [ordered]@{ name = 'henry'; role = 'writer'; kind = 'generic'; transport = 'same-pc' }
                [ordered]@{ name = 'jack'; role = 'reviewer'; kind = 'generic'; transport = 'same-pc' }
                [ordered]@{ name = 'zoe'; role = 'spare'; kind = 'generic'; transport = 'same-pc' }
            )).Path
        foreach ($agent in 'olivia', 'adam', 'emma', 'henry', 'jack', 'zoe') {
            $started = Invoke-RelayTool -Room $template -Agent $agent -Engine $engine -Words @('start', 'test-product', 'test-model', 'low')
            if ($started.ExitCode -ne 0) { throw "start failed for $agent on ${engine}: $($started.Output) $($started.Error)" }
        }
        $null = Invoke-RelayTool -Room $template -Agent 'olivia' -Engine $engine -Words @('check')
        # zoe has left; henry has not listened yet; emma and jack have a direct line to each other
        Write-TeamFile (Join-Path $template 'agents\zoe\retired') "retired`n"
        foreach ($pair in @(@('olivia', 'working'), @('adam', 'working'), @('emma', 'listening'), @('jack', 'working'))) { Write-TeamStatus $template $pair[0] $pair[1] }
        Remove-Item -LiteralPath (Join-Path $template 'agents\henry\status') -Force
        Write-TeamFile (Join-Path $template 'agents\emma\lines') "jack`n"
        Write-TeamFile (Join-Path $template 'agents\jack\lines') "emma`n"
    }

    BeforeEach {
        $room = Copy-RelayTestRoom -Template $template -Target (Join-Path $root ('room-' + (New-RelayTestId)))
        # The room clock: everybody was heard from just now
        foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $room 'agents') -Directory)) {
            $alive = Join-Path $folder.FullName 'alive'
            if (Test-Path -LiteralPath $alive) { [System.IO.File]::SetLastWriteTimeUtc($alive, [DateTime]::UtcNow) }
        }
    }

    Context 'progress' {
        It 'prints exactly two lines and exits 0' {
            Set-TeamWaitLease 'emma'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines.Count | Should -Be 2
            $lines[0] | Should -BeExactly 'PROGRESS noted: Writing the verbs'
            $lines[1] | Should -Match '^NEXT: carry on\. The team sees it with: \S.* team$'
        }

        It 'names in its NEXT line the same command that help shows' {
            $help = Invoke-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('help')
            ($help.Output -match '(?m)^  (?<call>.+?) team +\S') | Should -BeTrue
            $call = $Matches['call']
            Set-TeamWaitLease 'emma'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            (Get-TeamLine $result.Output)[1] | Should -BeExactly "NEXT: carry on. The team sees it with: $call team"
        }

        It 'appends one line of utc time, a bar and the text to the progress file of the agent' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $lines = @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))
            $lines.Count | Should -Be 1
            $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| Writing the verbs$'
            $stamp = Get-TeamUtc ($lines[0].Substring(0, 20))
            [Math]::Abs(([DateTime]::UtcNow - $stamp).TotalSeconds) | Should -BeLessThan 120
        }

        It 'adds every call as a new last line' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'First step'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Second step'
            $lines = @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match ' \| First step$'
            $lines[1] | Should -Match ' \| Second step$'
        }

        It 'keeps only the last 20 lines when the file holds <Before> and one is added' -ForEach @(
            @{ Before = 19; Expected = 20 }
            @{ Before = 20; Expected = 20 }
            @{ Before = 25; Expected = 20 }
        ) {
            Write-TeamFile (Join-Path $room 'agents\emma\progress') ((@(1..$Before | ForEach-Object { '2026-10-10T07:00:{0:00}Z | old {1}' -f ($_ % 60), $_ }) -join "`n") + "`n")
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'The newest line'
            $lines = @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))
            $lines.Count | Should -Be $Expected
            $lines[$lines.Count - 1] | Should -Match ' \| The newest line$'
            # the 19 youngest of the old lines stay; with fewer old lines than that, all of them
            $kept = [Math]::Min($Before, 19)
            $lines[0] | Should -Match (' \| old {0}$' -f ($Before - $kept + 1))
        }

        It 'takes the first non-empty line of the draft and drops what a subject drops: <Name>' -ForEach @(
            @{ Name = 'the rest of the draft is ignored'; Draft = "Plain line`nSecond line`nThird line"; Expected = 'Plain line' }
            @{ Name = 'empty lines in front are skipped'; Draft = "`n`nFirst real line`nrest"; Expected = 'First real line' }
            @{ Name = 'a leading #'; Draft = "# Heading text`nmore"; Expected = 'Heading text' }
            @{ Name = 'several leading #'; Draft = "## Heading two`nmore"; Expected = 'Heading two' }
            @{ Name = 'a leading subject:'; Draft = "subject: Done with part A`nbody"; Expected = 'Done with part A' }
            @{ Name = 'a leading # and subject:'; Draft = "## Subject: both`nbody"; Expected = 'both' }
        ) {
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $Draft
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly "PROGRESS noted: $Expected"
            @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))[0] | Should -Match (' \| ' + [regex]::Escape($Expected) + '$')
            $result.Output | Should -Not -Match 'Second line|more|rest|body'
        }

        It 'cuts a line of <Length> characters to <Expected>' -ForEach @(
            @{ Length = 199; Expected = 199; Letter = '' }
            @{ Length = 200; Expected = 200; Letter = '' }
            @{ Length = 201; Expected = 200; Letter = '' }
            @{ Length = 250; Expected = 200; Letter = '' }
            @{ Length = 250; Expected = 200; Letter = 'e-acute' }
        ) {
            if ($Letter -eq 'e-acute') { $line = ([string][char]0x00E9) * $Length }
            else { $line = -join (1..$Length | ForEach-Object { [string]($_ % 10) }) }
            $wanted = $line.Substring(0, $Expected)
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $line
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly "PROGRESS noted: $wanted"
            $saved = @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))[0]
            $saved.Substring(23) | Should -BeExactly $wanted
        }

        It 'cleans the line like a header: <Name>' -ForEach @(
            @{ Name = 'control characters become spaces'; Draft = "tab`there bell$([char]7)here esc$([char]27)there"; Expected = 'tab here bell here esc there' }
            @{ Name = 'several control characters in a row make one space'; Draft = "a`t`t$([char]7)b"; Expected = 'a b' }
            @{ Name = 'several spaces make one'; Draft = 'a     b      c'; Expected = 'a b c' }
            @{ Name = 'blanks at both ends are trimmed'; Draft = '   padded   text   '; Expected = 'padded text' }
            @{ Name = 'blanks around the # signs and after subject: go too'; Draft = "  ##   Subject:    spaced out"; Expected = 'spaced out' }
        ) {
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $Draft
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly "PROGRESS noted: $Expected"
            @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))[0].Substring(23) | Should -BeExactly $Expected
        }

        It 'collapses the spaces before it cuts to 200 characters' {
            $line = ('x' * 195) + (' ' * 10) + 'abcdefghij'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $line
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly ('PROGRESS noted: ' + ('x' * 195) + ' abcd')
        }

        It 'refuses a line of which nothing is left: <Name>' -ForEach @(
            @{ Name = 'only a #'; Draft = '#' }
            @{ Name = 'only # signs and blanks'; Draft = '##  ' }
            @{ Name = 'only subject:'; Draft = 'subject:' }
            @{ Name = 'only # and Subject:'; Draft = '# Subject:   ' }
        ) {
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $Draft
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'there is nothing to send: '
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\progress') | Should -BeFalse
        }

        It 'refuses a line that looks like a secret, keeps the draft, and has no override word' {
            $key = 'AKIA' + ('ABCDEFGH' * 2)
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text "The key is $key in the config"
            $before = Get-TeamTree $room
            $blocked = Invoke-Team 'emma' @('progress')
            $blocked.ExitCode | Should -Be 1
            Join-TeamLine (Get-TeamLine $blocked.Output) | Should -BeExactly (Join-TeamLine @('ERROR: the text looks like it contains an AWS access key id; nothing was noted', 'NEXT: take the secret out of the line and run the same command again'))
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md'))) | Should -Match 'The key is AKIA'
            $forced = Invoke-Team 'emma' @('progress', 'allow-secret')
            $forced.ExitCode | Should -Be 1
            $forced.Output | Should -Not -Match 'PROGRESS noted'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\progress') | Should -BeFalse
            @(Get-TeamTreeChange $before (Get-TeamTree $room) | Where-Object { $_ -like '*\inbox\*' -or $_ -like '*\status' -or $_ -like '*\journal' }).Count | Should -Be 0
        }
        It 'keeps a bar and text that every shell would mangle' {
            $text = 'a | b $HOME `n "q" ' + [char]0x00E9
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $text
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly "PROGRESS noted: $text"
            @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))[0].Substring(23) | Should -BeExactly $text
        }

        It 'refuses <Name> with the usual error and writes nothing' -ForEach @(
            @{ Name = 'a missing draft'; Draft = $null }
            @{ Name = 'an empty draft'; Draft = '' }
            @{ Name = 'a draft of empty lines'; Draft = "`n`n`n" }
        ) {
            if ($null -ne $Draft) { Write-TeamFile (Join-Path $room 'agents\emma\draft.md') $Draft }
            $result = Invoke-Team 'emma' @('progress')
            $result.ExitCode | Should -Be 1
            $lines = Get-TeamLine $result.Output
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match '^ERROR: there is nothing to send: .*draft\.md is missing or empty$'
            $lines[1] | Should -BeExactly 'NEXT: write your progress line into that file with your file tool and run the same command again'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\progress') | Should -BeFalse
        }

        It 'sets the status to working with the text as detail' {
            Write-TeamStatus $room 'emma' 'listening'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $status = Read-TeamKeyValue (Join-Path $room 'agents\emma\status')
            $status['state'] | Should -Be 'working'
            $status['detail'] | Should -Be 'Writing the verbs'
        }

        It 'adds a journal line made of the word progress and the text' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $journal = @(Read-TeamFileLine (Join-Path $room 'agents\emma\journal'))
            $journal[$journal.Count - 1] | Should -Match '^\S+ progress Writing the verbs$'
        }

        It 'clears the draft' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text "Writing the verbs`nand more"
            $draft = Join-Path $room 'agents\emma\draft.md'
            if (Test-Path -LiteralPath $draft) { ([System.IO.File]::ReadAllText($draft)).Trim() | Should -BeExactly '' }
        }

        It 'sends no message and touches no inbox' {
            $before = Get-TeamTree $room
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $result.ExitCode | Should -Be 0
            $changed = @(Get-TeamTreeChange $before (Get-TeamTree $room))
            @($changed | Where-Object { $_ -like '*\inbox\*' }).Count | Should -Be 0
            $result.Output | Should -Not -Match 'SENT '
        }

        It 'works for the coordinator too' {
            $result = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('progress') -Text 'Planning the next step'
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly 'PROGRESS noted: Planning the next step'
            @(Read-TeamFileLine (Join-Path $room 'agents\olivia\progress'))[0] | Should -Match ' \| Planning the next step$'
        }

        It 'works in a room without a plan and with a plan alike' {
            Test-Path -LiteralPath (Join-Path $room 'PLAN') | Should -BeFalse
            (Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'No plan yet').ExitCode | Should -Be 0
            Write-TeamPlan $room $defaultPlan
            (Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'A plan now').ExitCode | Should -Be 0
        }
    }

    Context 'team: the plan file' {
        It 'prints the header, the goal and the PARTS block of a plan' {
            Write-TeamPlan $room $defaultPlan
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines[0] | Should -BeExactly '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='
            $lines[1] | Should -BeExactly 'goal: A team view for every agent'
            $lines[2] | Should -BeExactly ''
            Join-TeamLine (Get-TeamSection $lines 'PARTS') | Should -BeExactly (Join-TeamLine (Get-TeamExpectedPartBlock))
        }

        It 'prints the whole contract layout for a caller with a direct line' {
            Write-TeamPlan $room $defaultPlan
            Set-TeamWaitLease 'emma'
            $result = Invoke-Team 'emma' @('team')
            $result.ExitCode | Should -Be 0
            $expected = @(
                '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='
                'goal: A team view for every agent'
                ''
            ) + (Get-TeamExpectedPartBlock) + @(
                ''
                'AGENTS'
                (Format-TeamAgent 'Adam' 'working' 'scout')
                (Format-TeamAgent 'Emma' 'listening' 'tester')
                ($indent + 'parts: tool-ps')
                (Format-TeamAgent 'Henry' 'not started' 'writer')
                (Format-TeamAgent 'Jack' 'working' 'reviewer')
                ($indent + 'parts: tests')
                (Format-TeamAgent 'Olivia' 'working' 'coordinator')
                ($indent + 'parts: tool-sh')
                ''
                'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Jack.'
                'NEXT: carry on.'
            )
            Join-TeamLine (Get-TeamLine $result.Output) | Should -BeExactly (Join-TeamLine $expected)
        }

        It 'ends with the YOU line and then NEXT: carry on.' {
            Write-TeamPlan $room $defaultPlan
            Set-TeamWaitLease 'jack'
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines[$lines.Count - 1] | Should -BeExactly 'NEXT: carry on.'
            $lines[$lines.Count - 2] | Should -Match '^YOU: '
            $lines[$lines.Count - 3] | Should -BeExactly ''
        }

        It 'ignores lines that do not start with a known key' {
            $noise = @(
                ''
                '# a comment'
                'foo: bar | baz'
                'partner: tool-ps | somebody | todo | - | - | Not a part'
                'filesystem: tool-ps | C:\Windows'
                'notes: tool-ps | Not a note'
            )
            Write-TeamPlan $room ($defaultPlan[0..5] + $noise + $defaultPlan[6..8])
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            Join-TeamLine (Get-TeamSection (Get-TeamLine $result.Output) 'PARTS') | Should -BeExactly (Join-TeamLine (Get-TeamExpectedPartBlock))
            $result.Output | Should -Not -Match 'Not a |somebody|C:\\Windows'
            (Get-TeamLine $result.Output)[1] | Should -BeExactly 'goal: A team view for every agent'
        }

        It 'does not rely on the order between the groups of lines' {
            $shuffled = @(
                'note: tool-ps | Output must match relay.sh line for line'
                'files: tool-ps | skills/agent-relay/assets/room-package/tools/relay.ps1'
                'files: tests | tests/Relay.Team.Tests.ps1'
                'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1'
                'part: tool-sh | olivia | todo | - | henry | The verbs in relay.sh'
                'part: tests | jack | todo | tool-ps,tool-sh | - | Tests for both verbs'
                'goal: A team view for every agent'
                'updated_utc: 2026-10-10T08:15:00Z'
                'plan: 3'
            )
            Write-TeamPlan $room $defaultPlan
            $ordered = (Invoke-Team 'jack' @('team')).Output
            Write-TeamPlan $room $shuffled
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeExactly $ordered
        }

        It 'reads a plan with CRLF line ends like one with LF line ends' {
            Write-TeamPlan $room $defaultPlan
            $lf = (Invoke-Team 'jack' @('team')).Output
            Write-TeamPlan $room $defaultPlan -Crlf
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeExactly $lf
            # not a single carriage return from the plan reaches the output on its own
            [regex]::IsMatch((Get-TeamRawOutput 'jack' @('team')), "`r(?!`n)") | Should -BeFalse
        }

        It 'carries text beyond ASCII from the plan to the output unchanged' {
            $goal = 'Caf' + [char]0x00E9 + ' ' + [char]0x65E5 + [char]0x672C
            Write-TeamPlan $room (@($defaultPlan[0..1]) + @("goal: $goal") + @($defaultPlan[3..8]))
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output)[1] | Should -BeExactly "goal: $goal"
        }

        It 'works without a PLAN file: no plan yet, one empty line, then AGENTS' {
            Set-TeamWaitLease 'jack'
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines[0] | Should -BeExactly '=== team in room template: no plan yet ==='
            $lines[1] | Should -BeExactly ''
            $lines[2] | Should -BeExactly 'AGENTS'
            $result.Output | Should -Not -Match '(?m)^goal:'
            $result.Output | Should -Not -Match '(?m)^PARTS$'
            $lines[$lines.Count - 1] | Should -BeExactly 'NEXT: carry on.'
            $result.Output | Should -Match '(?m)^YOU: Jack\. Your parts: none\. You may write directly to: Olivia, Emma\.$'
        }

        It 'puts exactly one empty line before PARTS, AGENTS and YOU: and none anywhere else' {
            Write-TeamPlan $room $defaultPlan
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $empty = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -eq '' })
            $empty.Count | Should -Be 3
            foreach ($at in $empty) { $lines[$at + 1] | Should -Match '^(PARTS|AGENTS|YOU: )' }
            [System.IO.File]::Delete((Join-Path $room 'PLAN'))
            $noPlan = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $emptyNoPlan = @(0..($noPlan.Count - 1) | Where-Object { $noPlan[$_] -eq '' })
            $emptyNoPlan.Count | Should -Be 2
            foreach ($at in $emptyNoPlan) { $noPlan[$at + 1] | Should -Match '^(AGENTS|YOU: )' }
            @($noPlan | Where-Object { $_ -match '^      parts: ' }).Count | Should -Be 0
            $noPlan | Should -Contain 'YOU: Jack. Your parts: none. You may write directly to: Olivia, Emma.'
        }

        It 'treats <Name> as no plan' -ForEach @(
            @{ Name = 'an empty PLAN file'; Lines = @() }
            @{ Name = 'a PLAN without a plan: line'; Lines = @('updated_utc: 2026-10-10T08:15:00Z', 'goal: A goal', 'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1') }
        ) {
            if (@($Lines).Count -eq 0) { Write-TeamFile (Join-Path $room 'PLAN') '' } else { Write-TeamPlan $room $Lines -NoEnd }
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: no plan yet ==='
            $result.Output | Should -Not -Match '(?m)^PARTS$'
            $result.Output | Should -Not -Match 'The verbs in relay'
        }

        It 'prints no name with the mark (coordinator)' {
            Write-TeamPlan $room $defaultPlan
            foreach ($agent in 'olivia', 'emma') { (Invoke-Team $agent @('team')).Output | Should -Not -Match '\(coordinator\)' }
        }
    }

    Context 'team: reading the plan' {
        It 'ignores a part line with fewer than six fields or an empty id, and a files or note line without a part or a value' {
            Write-TeamPlan $room $defaultPlan
            $normal = (Invoke-Team 'jack' @('team')).Output
            $junk = @(
                'part: lonely'
                'part: tool-ps | emma | doing'
                'part: five | emma | todo | - | henry'
                'part:  | emma | todo | - | henry | Empty id'
                'files: tool-ps'
                'files: tool-ps | '
                'files: no-such-part | src/x.txt'
                'note: tool-ps'
                'note: tool-ps | '
                'note: no-such-part | A note for nobody'
                'files:'
            )
            Write-TeamPlan $room ($defaultPlan[0..5] + $junk + $defaultPlan[6..8])
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeExactly $normal
        }

        It 'takes everything after the fifth bar as the title when there are more than six fields' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Bars', 'part: bars | emma | todo | - | - | Title | with | bars')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly (Format-TeamPart 'bars' 'todo' 'Emma' 'Title | with | bars')
        }

        It 'prints a status that is not one of the five as it is written' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Odd', 'part: odd | emma | paused | - | - | Odd status', 'part: odd2 | emma | stuck-in-the-mud | - | - | Long odd status')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly (Format-TeamPart 'odd' 'paused' 'Emma' 'Odd status')
            $rows[2] | Should -BeExactly (Format-TeamPart 'odd2' 'stuck-in-the-mud' 'Emma' 'Long odd status')
        }

        It 'prints an owner who is retired with the display of its seat, a reviewer who is not in the room and a depends id of no part as written' {
            $seat = Join-Path $room 'agents\zoe\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', 'display: Zo')
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Strangers', 'part: far | zoe | todo | missing-part | phantom | Strange')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'far' 'todo' 'Zo' 'Strange'), ($indent + 'depends on: missing-part'), ($indent + 'reviewer: Phantom')))
        }

        It 'drops carriage returns and trims the blanks of every field' {
            Write-TeamPlan $room $defaultPlan
            $expected = (Invoke-Team 'jack' @('team')).Output
            Write-TeamPlan $room @(
                'plan:   3  '
                'updated_utc:   2026-10-10T08:15:00Z  '
                'goal:    A team view for every agent   '
                'part:   tool-ps   |   emma  | doing |  -  |  henry   |   The verbs in relay.ps1   '
                'part: tool-sh | olivia | todo | - | henry | The verbs in relay.sh'
                'part: tests | jack | todo | tool-ps,tool-sh | - | Tests for both verbs'
                'files: tool-ps | skills/agent-relay/assets/room-package/tools/relay.ps1  '
                'files: tests | tests/Relay.Team.Tests.ps1'
                'note: tool-ps |   Output must match relay.sh line for line  '
            ) -Crlf -End '3'
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeExactly $expected
        }

        It 'counts the first of two equal keys: <Name>' -ForEach @(
            @{ Name = 'goal'; Lines = @('plan: 3', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: The first goal', 'goal: The second goal'); Header = '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='; Goal = 'goal: The first goal' }
            @{ Name = 'updated_utc'; Lines = @('plan: 3', 'updated_utc: 2026-10-10T08:15:00Z', 'updated_utc: 2027-01-01T00:00:00Z', 'goal: One goal'); Header = '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='; Goal = 'goal: One goal' }
            @{ Name = 'plan'; Lines = @('plan: 3', 'plan: 9', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: One goal'); Header = '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='; Goal = 'goal: One goal' }
        ) {
            Write-TeamPlan $room $Lines -End '3'
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines[0] | Should -BeExactly $Header
            $lines[1] | Should -BeExactly $Goal
        }

        It 'counts the first end: line: <Name>' -ForEach @(
            @{ Name = 'a right one first'; Ends = @('end: 3', 'end: 7'); Complete = $true }
            @{ Name = 'a wrong one first'; Ends = @('end: 7', 'end: 3'); Complete = $false }
        ) {
            Write-TeamPlan $room ($defaultPlan + $Ends) -NoEnd
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            if ($Complete) { (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: plan 3, 2026-10-10T08:15:00Z ===' }
            else { (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: the plan is being written, run team again ===' }
        }

        It 'prints unknown for a missing updated_utc and - for a missing goal' {
            Write-TeamPlan $room @('plan: 3', 'part: tool-ps | emma | doing | - | henry | The verbs in relay.ps1')
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines[0] | Should -BeExactly '=== team in room template: plan 3, unknown ==='
            $lines[1] | Should -BeExactly 'goal: -'
        }

        It 'treats a plan: value of <Value> as no plan' -ForEach @(
            @{ Value = '0' }
            @{ Value = '-2' }
            @{ Value = 'abc' }
            @{ Value = '3.5' }
            @{ Value = '' }
        ) {
            Write-TeamPlan $room (@("plan: $Value") + $defaultPlan[1..8]) -End $Value
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: no plan yet ==='
            $result.Output | Should -Not -Match '(?m)^PARTS$'
        }

        It 'prints "the plan is being written" for a plan with <Name>, after trying three times' -ForEach @(
            @{ Name = 'no end: line'; Mode = 'none' }
            @{ Name = 'an end: line of another revision'; Mode = 'other' }
        ) {
            # What the waiting costs: pairs of calls, one in a room without a PLAN file, which prints the same shape and
            # reads nothing three times (a complete plan costs more work than a half written one), and one with the half
            # written plan, back to back so that both calls of a pair meet the same load. A shared machine running six
            # suites at once slows a burst of calls by a second or more (with the smallest of three calls of each kind,
            # a CI runner measured differences from 0.95 to 4.16 seconds); the median of five pairs is not moved by
            # two pairs caught in a burst.
            [System.IO.File]::Delete((Join-Path $room 'agents\jack\state'))
            $differences = New-Object System.Collections.Generic.List[double]
            $result = $null
            foreach ($pair in 1..5) {
                [System.IO.File]::Delete((Join-Path $room 'PLAN'))
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Invoke-Team 'jack' @('team')
                $watch.Stop()
                $baseSeconds = $watch.Elapsed.TotalSeconds
                if ($Mode -eq 'none') { Write-TeamPlan $room $defaultPlan -NoEnd } else { Write-TeamPlan $room $defaultPlan -End '2' }
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $result = Invoke-Team 'jack' @('team')
                $watch.Stop()
                $differences.Add($watch.Elapsed.TotalSeconds - $baseSeconds)
            }
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines[0] | Should -BeExactly '=== team in room template: the plan is being written, run team again ==='
            $lines[1] | Should -BeExactly ''
            $lines[2] | Should -BeExactly 'AGENTS'
            $result.Output | Should -Not -Match '(?m)^PARTS$'
            $result.Output | Should -Match '(?m)^YOU: Jack\. Your parts: none\.'
            $result.Output | Should -Not -Match '(?m)^      parts: '
            # Consistent with a second between each of three reads (two seconds more than a call that does not wait).
            # It does not count the reads: that would need the tool to say when it reads. The margins are wide enough for
            # the scheduling of a shared machine, narrow enough to tell a call that waits from one that does not, or
            # waits far too long.
            $extra = @($differences | Sort-Object)[2]
            $extra | Should -BeGreaterThan 1.2
            $extra | Should -BeLessThan 4.0
            (Read-TeamKeyValue (Join-Path $room 'agents\jack\state')).ContainsKey('plan_seen') | Should -BeFalse
        }

        It 'reads a half written plan again and prints it when it is complete by then' {
            # Evidence, not proof, of a second read: the call took about a second longer than one that does not wait. A tool
            # that began reading late could pass without a retry; when the difference is small the test says it has nothing.
            Write-TeamPlan $room $defaultPlan
            $baseSeconds = @(1..2 | ForEach-Object {
                    $watch = [System.Diagnostics.Stopwatch]::StartNew()
                    $null = Invoke-Team 'jack' @('team')
                    $watch.Stop()
                    $watch.Elapsed.TotalSeconds
                } | Sort-Object)[0]
            [System.IO.File]::Delete((Join-Path $room 'agents\jack\state'))
            Write-TeamPlan $room $defaultPlan -NoEnd
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $waiting = Start-RelayTool -Room $room -Agent 'jack' -Engine $engine -Words @('team')
            Start-Sleep -Milliseconds 1000
            Write-TeamPlan $room $defaultPlan
            $result = Wait-RelayTool -Handle $waiting -TimeoutSeconds 60
            $clock.Stop()
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='
            if (($clock.Elapsed.TotalSeconds - $baseSeconds) -lt 0.6) { Set-ItResult -Skipped -Because 'the tool read the plan for the first time after it was complete: no second read to prove' }
        }
    }

    Context 'team: PARTS' {
        It 'prints the parts in the order of the file' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Order'
                'part: zeta | emma | todo | - | - | Zeta part'
                'part: alpha | jack | todo | - | - | Alpha part'
                'part: mid | henry | todo | - | - | Mid part'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'zeta' 'todo' 'Emma' 'Zeta part'), (Format-TeamPart 'alpha' 'todo' 'Jack' 'Alpha part'), (Format-TeamPart 'mid' 'todo' 'Henry' 'Mid part')))
        }

        It 'sets the columns: two spaces, id to 12, two spaces, status to 8, two spaces, owner to 9, two spaces, title' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Columns', 'part: ab | emma | review | - | - | The title')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly ('  ' + 'ab' + (' ' * 10) + '  ' + 'review' + (' ' * 2) + '  ' + 'Emma' + (' ' * 5) + '  ' + 'The title')
        }

        It 'does not cut a value that is longer than its column' {
            $title = 'A title that is a good deal longer than any column of the table could hold, and it stays whole'
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Long'
                'part: a-very-long-part-id-24 | longername1 | blocked | - | longername2 | ' + $title
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly ('  a-very-long-part-id-24' + '  ' + 'blocked ' + '  ' + 'Longername1' + '  ' + $title)
            $rows[2] | Should -BeExactly ($indent + 'reviewer: Longername2')
        }

        It 'passes every one of the five statuses through' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Statuses'
                'part: p1 | emma | todo | - | - | One'
                'part: p2 | emma | doing | - | - | Two'
                'part: p3 | emma | review | - | - | Three'
                'part: p4 | emma | done | - | - | Four'
                'part: p5 | emma | blocked | - | - | Five'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine ($rows | Select-Object -Skip 1) | Should -BeExactly (Join-TeamLine @(
                    (Format-TeamPart 'p1' 'todo' 'Emma' 'One'), (Format-TeamPart 'p2' 'doing' 'Emma' 'Two'), (Format-TeamPart 'p3' 'review' 'Emma' 'Three'),
                    (Format-TeamPart 'p4' 'done' 'Emma' 'Four'), (Format-TeamPart 'p5' 'blocked' 'Emma' 'Five')))
        }

        It 'prints a sub-line only when the part has that value' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Sub-lines'
                'part: bare | emma | todo | - | - | Nothing under it'
                'part: onlynote | emma | todo | - | - | Only a note'
                'part: onlydep | emma | todo | bare | - | Only a dependency'
                'part: onlyrev | emma | todo | - | henry | Only a reviewer'
                'part: onlyfile | emma | todo | - | - | Only a file'
                'note: onlynote | Careful'
                'files: onlyfile | src/one.txt'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine ($rows | Select-Object -Skip 1) | Should -BeExactly (Join-TeamLine @(
                    (Format-TeamPart 'bare' 'todo' 'Emma' 'Nothing under it')
                    (Format-TeamPart 'onlynote' 'todo' 'Emma' 'Only a note'), ($indent + 'note: Careful')
                    (Format-TeamPart 'onlydep' 'todo' 'Emma' 'Only a dependency'), ($indent + 'depends on: bare')
                    (Format-TeamPart 'onlyrev' 'todo' 'Emma' 'Only a reviewer'), ($indent + 'reviewer: Henry')
                    (Format-TeamPart 'onlyfile' 'todo' 'Emma' 'Only a file'), ($indent + 'files: src/one.txt')))
        }

        It 'orders the sub-lines depends on, reviewer, files, note; joins ids and patterns; one note per line' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Sub-lines'
                'note: main | Second note comes second'
                'files: main | docs/*.md'
                'part: dep-a | jack | done | - | - | A'
                'part: dep-b | jack | done | - | - | B'
                'part: main | emma | doing | dep-b,dep-a | henry | Main'
                'files: main | src/b.txt'
                'note: main | Third note'
                'files: dep-a | x/*'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @(
                    'PARTS'
                    (Format-TeamPart 'dep-a' 'done' 'Jack' 'A')
                    ($indent + 'files: x/*')
                    (Format-TeamPart 'dep-b' 'done' 'Jack' 'B')
                    (Format-TeamPart 'main' 'doing' 'Emma' 'Main')
                    ($indent + 'depends on: dep-b, dep-a')
                    ($indent + 'reviewer: Henry')
                    ($indent + 'files: docs/*.md, src/b.txt')
                    ($indent + 'note: Second note comes second')
                    ($indent + 'note: Third note')))
        }
        It 'prints "nobody" for an owner of - and no reviewer line for a reviewer of -' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Nobody', 'part: free | - | todo | - | - | Nobody has it')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'free' 'todo' 'nobody' 'Nobody has it')))
        }

        It 'prints an owner or reviewer who is not in the room with the first letter in upper case' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Strangers', 'part: far | ghost | todo | - | phantom | Somebody else')
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $rows = @(Get-TeamSection (Get-TeamLine $result.Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'far' 'todo' 'Ghost' 'Somebody else'), ($indent + 'reviewer: Phantom')))
            $result.Output | Should -Not -Match '(?m)^  Ghost +\S+ +\S+$'
            $result.Output | Should -Match '(?m)^YOU: Jack\. Your parts: none\.'
        }

        It 'prints the display name of the seat, and the name with a capital when the seat has none' {
            $seat = Join-Path $room 'agents\jack\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', 'display: Jay')
            $seat = Join-Path $room 'agents\emma\seat'
            Write-TeamFile $seat ((([System.IO.File]::ReadAllText($seat)) -replace "(?m)^display: .*`n", ''))
            Write-TeamPlan $room $defaultPlan
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'henry' @('team')).Output) 'PARTS')
            $rows | Should -Contain (Format-TeamPart 'tests' 'todo' 'Jay' 'Tests for both verbs')
            $rows | Should -Contain (Format-TeamPart 'tool-ps' 'doing' 'Emma' 'The verbs in relay.ps1')
        }
    }

    Context 'team: AGENTS' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'lists every agent that is not retired and not a free seat, the coordinator included, sorted by name' {
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $rows = @(Get-TeamSection $lines 'AGENTS' | Where-Object { $_ -match '^  \S' } | ForEach-Object { ($_.Trim() -split ' +')[0] })
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('Adam', 'Emma', 'Henry', 'Jack', 'Olivia'))
        }

        It 'sorts by name, not by the display name' {
            $seat = Join-Path $room 'agents\adam\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', 'display: Zed')
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $rows = @(Get-TeamSection $lines 'AGENTS' | Where-Object { $_ -match '^  \S' } | ForEach-Object { ($_.Trim() -split ' +')[0] })
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('Zed', 'Emma', 'Henry', 'Jack', 'Olivia'))
        }

        It 'lists a free seat once somebody has claimed it, like who' {
            $seatName = @(Get-RelayTestOpenSeat -Room $room)[0]
            $seatName | Should -Not -BeNullOrEmpty
            $before = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            @($before | Where-Object { $_ -match ('^  ' + $seatName.Substring(0, 1).ToUpperInvariant() + $seatName.Substring(1) + ' ') }).Count | Should -Be 0
            Write-TeamFile (Join-Path $room "agents\$seatName\claim") "claimed`n"
            $seat = Read-TeamKeyValue (Join-Path $room "agents\$seatName\seat")
            $display = $seat['display']
            if (-not $display) { $display = $seatName.Substring(0, 1).ToUpperInvariant() + $seatName.Substring(1) }
            @((Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Where-Object { $_ -match ('^  ' + [regex]::Escape($display) + ' +not started') }).Count | Should -Be 1
        }
        It 'prints the state of the status file padded to 12, and the role of the seat' {
            Write-TeamStatus $room 'adam' 'paused'
            $seat = Join-Path $room 'agents\emma\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^role: .*$', 'role: a role set on the seat')
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Adam' 'paused' 'scout')
            $lines | Should -Contain (Format-TeamAgent 'Emma' 'listening' 'a role set on the seat')
        }

        It 'prints "not started" for an agent without a status file' {
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Henry' 'not started' 'writer')
        }

        It 'prints STALE for an agent that is listening but silent for longer than stale_minutes' {
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddMinutes(-60))
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Emma' 'STALE' 'tester')
        }

        It 'prints only listening agents as STALE' {
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\jack\alive'), [DateTime]::UtcNow.AddMinutes(-60))
            $lines = Get-TeamLine (Invoke-Team 'emma' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Jack' 'working' 'reviewer')
            $lines | Should -Contain (Format-TeamAgent 'Emma' 'listening' 'tester')
        }

        It 'takes the limit from stale_minutes of the room: <Name>' -ForEach @(
            @{ Name = 'a wide limit keeps a listening agent alive'; Limit = 120; Age = 60; Expected = 'listening' }
            @{ Name = 'a narrow limit makes it stale'; Limit = 1; Age = 30; Expected = 'STALE' }
        ) {
            $file = Join-Path $room 'ROOM'
            Write-TeamFile $file (([System.IO.File]::ReadAllText($file)) -replace '(?m)^stale_minutes: .*$', "stale_minutes: $Limit")
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddMinutes(-$Age))
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Emma' $Expected 'tester')
        }

        It 'prints the parts an agent owns, in the order of the file, and none for an agent without parts' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Owners'
                'part: zz | emma | todo | - | - | Last id first'
                'part: aa | emma | todo | - | - | First id last'
                'part: mm | jack | todo | - | - | Jack''s'
            )
            $lines = Get-TeamLine (Invoke-Team 'henry' @('team')).Output
            Join-TeamLine (Get-TeamAgentBlock $lines 'Emma') | Should -BeExactly (Join-TeamLine @((Format-TeamAgent 'Emma' 'listening' 'tester'), ($indent + 'parts: zz, aa')))
            Join-TeamLine (Get-TeamAgentBlock $lines 'Henry') | Should -BeExactly (Format-TeamAgent 'Henry' 'not started' 'writer')
        }

        It 'prints the last line of the progress file with its time, and nothing for an agent without one' {
            Write-TeamFile (Join-Path $room 'agents\emma\progress') "2026-10-10T07:00:00Z | An older line`n2026-10-10T08:30:15Z | The newest line | with a bar`n"
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            Join-TeamLine (Get-TeamAgentBlock $lines 'Emma') | Should -BeExactly (Join-TeamLine @(
                    (Format-TeamAgent 'Emma' 'listening' 'tester')
                    ($indent + 'progress: The newest line | with a bar  (2026-10-10T08:30:15Z)')
                    ($indent + 'parts: tool-ps')))
            @(Get-TeamAgentBlock $lines 'Adam').Count | Should -Be 1
        }

        It 'shows what progress wrote' {
            $null = Send-RelayTestMessage -Room $room -Agent 'jack' -Engine $engine -Words @('progress') -Text 'Tests are half written'
            $stamp = (@(Read-TeamFileLine (Join-Path $room 'agents\jack\progress'))[0]).Substring(0, 20)
            $lines = Get-TeamLine (Invoke-Team 'emma' @('team')).Output
            $lines | Should -Contain ($indent + "progress: Tests are half written  ($stamp)")
            $lines | Should -Contain (Format-TeamAgent 'Jack' 'working' 'reviewer')
        }

        Context 'the open task of an agent' {
            It 'is the one with the smallest sent_utc, not the smallest id' {
                $null = Write-TeamMessage $room 'olivia' 'emma' 1 -Subject 'Later one' -Sent '2026-10-10T08:10:00Z'
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'Earlier one' -Sent '2026-10-10T08:05:00Z'
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                $lines | Should -Contain ($indent + 'doing: olivia-emma-0002  Earlier one')
                $lines | Should -Not -Contain ($indent + 'doing: olivia-emma-0001  Later one')
            }

            It 'is the one with the smaller id when two were sent at the same time' {
                $null = Write-TeamMessage $room 'olivia' 'emma' 3 -Subject 'Third' -Sent '2026-10-10T08:05:00Z'
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'Second' -Sent '2026-10-10T08:05:00Z'
                (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain ($indent + 'doing: olivia-emma-0002  Second')
            }

            It 'is printed between the row of the agent and its progress and parts lines' {
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'Second' -Sent '2026-10-10T08:05:00Z'
                Write-TeamFile (Join-Path $room 'agents\emma\progress') "2026-10-10T08:30:15Z | Working`n"
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                Join-TeamLine (Get-TeamAgentBlock $lines 'Emma') | Should -BeExactly (Join-TeamLine @(
                        (Format-TeamAgent 'Emma' 'listening' 'tester')
                        ($indent + 'doing: olivia-emma-0002  Second')
                        ($indent + 'progress: Working  (2026-10-10T08:30:15Z)')
                        ($indent + 'parts: tool-ps')))
            }

            It 'is left out when there is none' {
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                @($lines | Where-Object { $_ -like "$($indent)doing:*" }).Count | Should -Be 0
            }

            It 'belongs to the agent it was sent to' {
                $null = Write-TeamMessage $room 'olivia' 'jack' 1 -Subject 'For Jack' -Sent '2026-10-10T08:05:00Z'
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                $lines | Should -Contain ($indent + 'doing: olivia-jack-0001  For Jack')
                @(Get-TeamAgentBlock $lines 'Emma' | Where-Object { $_ -like "$($indent)doing:*" }).Count | Should -Be 0
            }

            It 'only counts a task, not <Type>' -ForEach @(
                @{ Type = 'a question' ; Word = 'question' }
                @{ Type = 'a proposal'; Word = 'proposal' }
                @{ Type = 'a note'; Word = 'note' }
            ) {
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Type $Word -Subject 'Not a task' -Sent '2026-10-10T08:05:00Z'
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                @($lines | Where-Object { $_ -like "$($indent)doing:*" }).Count | Should -Be 0
            }

            It 'is dropped once a <Word> of that agent names it, and the next oldest takes its place' -ForEach @(
                @{ Word = 'result' }
                @{ Word = 'answer' }
            ) {
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'First' -Sent '2026-10-10T08:05:00Z'
                $null = Write-TeamMessage $room 'olivia' 'emma' 3 -Subject 'Second' -Sent '2026-10-10T08:06:00Z'
                $null = Write-TeamMessage $room 'emma' 'olivia' 7 -Type $Word -Re 'olivia-emma-0002' -Subject 'Done with the first'
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                $lines | Should -Contain ($indent + 'doing: olivia-emma-0003  Second')
                $null = Write-TeamMessage $room 'emma' 'olivia' 8 -Type $Word -Re 'olivia-emma-0003' -Subject 'Done with the second'
                $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
                @($lines | Where-Object { $_ -like "$($indent)doing:*" }).Count | Should -Be 0
            }

            It 'stays open when only a note of that agent names it' {
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'First' -Sent '2026-10-10T08:05:00Z'
                $null = Write-TeamMessage $room 'emma' 'olivia' 7 -Type 'note' -Re 'olivia-emma-0002' -Subject 'About the first'
                (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain ($indent + 'doing: olivia-emma-0002  First')
            }

            It 'stays open when a result of another agent names it' {
                $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'First' -Sent '2026-10-10T08:05:00Z'
                $null = Write-TeamMessage $room 'henry' 'olivia' 7 -Type 'result' -Re 'olivia-emma-0002' -Subject 'Henry is not Emma'
                (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain ($indent + 'doing: olivia-emma-0002  First')
            }
        }
    }

    Context 'team: YOU' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'names a caller with a direct line: the coordinator first, then the lines of the file in its order' {
            Write-TeamFile (Join-Path $room 'agents\emma\lines') "henry`njack`n"
            (Get-TeamLine (Invoke-Team 'emma' @('team')).Output) | Should -Contain 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Henry, Jack.'
            Write-TeamFile (Join-Path $room 'agents\emma\lines') "jack`nhenry`n"
            (Get-TeamLine (Invoke-Team 'emma' @('team')).Output) | Should -Contain 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Jack, Henry.'
        }

        It 'names only the coordinator for a caller without a direct line, and "none" for a caller without parts' {
            (Get-TeamLine (Invoke-Team 'henry' @('team')).Output) | Should -Contain 'YOU: Henry. Your parts: none. You may write directly to: Olivia.'
        }

        It 'lists the parts of the caller in the order of the file' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Owners'
                'part: zz | jack | todo | - | - | Last id first'
                'part: aa | emma | todo | - | - | Not Jack''s'
                'part: mm | jack | todo | - | - | Jack''s second'
            )
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain 'YOU: Jack. Your parts: zz, mm. You may write directly to: Olivia, Emma.'
        }

        It 'leaves out empty entries, the caller itself, the coordinator a second time and a name already listed' {
            Write-TeamFile (Join-Path $room 'agents\emma\lines') "jack`n`nolivia`njack`nemma`nhenry`nhenry`n"
            (Get-TeamLine (Invoke-Team 'emma' @('team')).Output) | Should -Contain 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Jack, Henry.'
        }
        It 'names display names, not agent names' {
            $seat = Join-Path $room 'agents\emma\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', 'display: Em')
            $seat = Join-Path $room 'agents\olivia\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', 'display: Liv')
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain 'YOU: Jack. Your parts: tests. You may write directly to: Liv, Em.'
        }

        It 'says "You may write to everybody." for the coordinator, who is not an agent with lines' {
            Write-TeamFile (Join-Path $room 'agents\olivia\lines') "jack`n"
            (Get-TeamLine (Invoke-Team 'olivia' @('team')).Output) | Should -Contain 'YOU: Olivia. Your parts: tool-sh. You may write to everybody.'
        }

        It 'works for the coordinator like for everybody else' {
            $result = Invoke-Team 'olivia' @('team')
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: plan 3, 2026-10-10T08:15:00Z ==='
            Join-TeamLine (Get-TeamSection (Get-TeamLine $result.Output) 'PARTS') | Should -BeExactly (Join-TeamLine (Get-TeamExpectedPartBlock))
        }
    }

    Context 'team: what it changes' {
        It 'writes the heartbeat of the caller and the revision as plan_seen, and nothing else' {
            Write-TeamPlan $room $defaultPlan
            $stateBefore = Read-TeamKeyValue (Join-Path $room 'agents\emma\state')
            $before = Get-TeamTree $room
            $result = Invoke-Team 'emma' @('team')
            $result.ExitCode | Should -Be 0
            $changed = @(Get-TeamTreeChange $before (Get-TeamTree $room))
            $changed | Should -Contain '\agents\emma\state'
            Join-TeamLine @($changed | Where-Object { @('\agents\emma\state', '\agents\emma\alive') -notcontains $_ }) | Should -BeExactly ''
            $stateAfter = Read-TeamKeyValue (Join-Path $room 'agents\emma\state')
            $stateAfter['plan_seen'] | Should -Be '3'
            foreach ($key in $stateBefore.Keys) { $stateAfter[$key] | Should -Be $stateBefore[$key] }
        }

        It 'writes only the heartbeat of the caller when the revision was stored already' {
            Write-TeamPlan $room $defaultPlan
            $null = Invoke-Team 'emma' @('team')
            $stateBefore = [System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\state'))
            $before = Get-TeamTree $room
            (Invoke-Team 'emma' @('team')).ExitCode | Should -Be 0
            Join-TeamLine @(Get-TeamTreeChange $before (Get-TeamTree $room) | Where-Object { @('\agents\emma\alive', '\agents\emma\state') -notcontains $_ }) | Should -BeExactly ''
            [System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\state')) | Should -BeExactly $stateBefore
        }

        It 'writes only the heartbeat of the caller in a room without a plan' {
            $stateBefore = [System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\state'))
            $before = Get-TeamTree $room
            (Invoke-Team 'emma' @('team')).ExitCode | Should -Be 0
            Join-TeamLine @(Get-TeamTreeChange $before (Get-TeamTree $room) | Where-Object { @('\agents\emma\alive', '\agents\emma\state') -notcontains $_ }) | Should -BeExactly ''
            [System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\state')) | Should -BeExactly $stateBefore
        }

        It 'touches the alive file of the caller, as who does' {
            Write-TeamPlan $room $defaultPlan
            $alive = Join-Path $room 'agents\jack\alive'
            [System.IO.File]::SetLastWriteTimeUtc($alive, [DateTime]::UtcNow.AddMinutes(-60))
            (Invoke-Team 'jack' @('team')).ExitCode | Should -Be 0
            ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($alive)).TotalSeconds | Should -BeLessThan 120
        }

        It 'never writes the plan' {
            Write-TeamPlan $room $defaultPlan
            $plan = Join-Path $room 'PLAN'
            $stamp = [System.IO.File]::GetLastWriteTimeUtc($plan).Ticks
            $bytes = [System.IO.File]::ReadAllBytes($plan)
            $null = Invoke-Team 'emma' @('team')
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $null = Send-TeamNote 'olivia' 'emma'
            $null = Invoke-Team 'emma' @('check')
            $null = Invoke-Team 'olivia' @('team')
            [System.IO.File]::GetLastWriteTimeUtc($plan).Ticks | Should -Be $stamp
            [System.IO.File]::ReadAllBytes($plan) | Should -Be $bytes
        }
        It 'stores the revision for the coordinator too' {
            Write-TeamPlan $room $defaultPlan
            $null = Invoke-Team 'olivia' @('team')
            (Read-TeamKeyValue (Join-Path $room 'agents\olivia\state'))['plan_seen'] | Should -Be '3'
        }

        It 'prints no "changed" banner for a revision the agent has not seen' {
            Write-TeamPlan $room $defaultPlan
            $result = Invoke-Team 'emma' @('team')
            $result.Output | Should -Not -Match 'the team plan changed'
        }
    }
    Context 'A changed plan is shown once' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'shows the banner and the PARTS block directly before the final NEXT: line when a check delivers' {
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $message = @($lines | Where-Object { $_ -like '--- olivia-emma-0001 *' })
            $message.Count | Should -Be 1
            [array]::IndexOf($lines, $message[0]) | Should -BeLessThan ([array]::IndexOf($lines, '=== the team plan changed: plan 3 ==='))
            Confirm-TeamBanner $lines '3' (Get-TeamExpectedPartBlock)
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state'))['plan_seen'] | Should -Be '3'
        }

        It 'prints the banner after the messages, the standing rules and the open requests' {
            Add-Content -LiteralPath (Join-Path $room 'DECISIONS.md') -Value '| 2026-10-10 | Reports go to the coordinator only. |' -Encoding Ascii
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'emma') -Text "Count the files`n`nCount the files in the work folder."
            $lines = Get-TeamLine (Invoke-Team 'emma' @('check')).Output
            $task = [array]::IndexOf($lines, @($lines | Where-Object { $_ -like '--- olivia-emma-0001 *' })[0])
            $rules = [array]::IndexOf($lines, @($lines | Where-Object { $_ -like '=== standing rules and owner decisions, new since you last looked*' })[0])
            $open = [array]::IndexOf($lines, @($lines | Where-Object { $_ -like 'open requests you still owe a reply to: *' })[0])
            $banner = [array]::IndexOf($lines, '=== the team plan changed: plan 3 ===')
            $task | Should -BeGreaterOrEqual 0
            $rules | Should -BeGreaterThan $task
            $open | Should -BeGreaterThan $rules
            $banner | Should -BeGreaterThan $open
            Confirm-TeamBanner $lines '3' (Get-TeamExpectedPartBlock)
        }
        It 'prints the PARTS block of the banner exactly as team prints it' {
            $null = Send-TeamNote 'olivia' 'emma'
            $lines = Get-TeamLine (Invoke-Team 'emma' @('check')).Output
            $fromBanner = Get-TeamSection $lines 'PARTS'
            $viaTeam = Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS'
            Join-TeamLine $fromBanner | Should -BeExactly (Join-TeamLine $viaTeam)
        }

        It 'shows it with wait too' {
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('wait', '1') @{ RELAY_MINUTE_SECONDS = '2' }
            $result.ExitCode | Should -Be 0
            Confirm-TeamBanner (Get-TeamLine $result.Output) '3' (Get-TeamExpectedPartBlock)
        }

        It 'shows it once: the next delivery has no banner' {
            $null = Send-TeamNote 'olivia' 'emma'
            $null = Invoke-Team 'emma' @('check')
            $null = Send-TeamNote 'olivia' 'emma' "Second`n`nAnother note."
            $result = Invoke-Team 'emma' @('check')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '--- olivia-emma-0002 '
            $result.Output | Should -Not -Match 'the team plan changed'
        }

        It 'shows it again when the revision is higher' {
            $null = Send-TeamNote 'olivia' 'emma'
            $null = Invoke-Team 'emma' @('check')
            Write-TeamPlan $room (@('plan: 4') + $defaultPlan[1..2] + @('part: tool-ps | emma | review | - | henry | The verbs in relay.ps1'))
            $null = Send-TeamNote 'olivia' 'emma' "Second`n`nAnother note."
            $result = Invoke-Team 'emma' @('check')
            $result.Output | Should -Match '(?m)^=== the team plan changed: plan 4 ===$'
            $result.Output | Should -Match ('(?m)^' + [regex]::Escape((Format-TeamPart 'tool-ps' 'review' 'Emma' 'The verbs in relay.ps1')) + '$')
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state'))['plan_seen'] | Should -Be '4'
        }

        It 'does not show it for a revision that is not higher than the one seen: <Revision>' -ForEach @(
            @{ Revision = 3 }
            @{ Revision = 2 }
        ) {
            Write-TeamFile (Join-Path $room 'agents\emma\state') (([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\state'))) + "plan_seen: 3`n")
            Write-TeamPlan $room (@("plan: $Revision") + $defaultPlan[1..8])
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.Output | Should -Match '--- olivia-emma-0001 '
            $result.Output | Should -Not -Match 'the team plan changed'
        }

        It 'does not show it after team has stored the revision' {
            $null = Invoke-Team 'emma' @('team')
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.Output | Should -Match '--- olivia-emma-0001 '
            $result.Output | Should -Not -Match 'the team plan changed'
        }

        It 'does not show it in a room without a plan' {
            Remove-Item -LiteralPath (Join-Path $room 'PLAN') -Force
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.Output | Should -Match '--- olivia-emma-0001 '
            $result.Output | Should -Not -Match 'the team plan changed'
        }

        It 'never shows it to the coordinator' {
            $null = Send-TeamNote 'emma' 'olivia' "Question`n`nA note for the coordinator."
            $result = Invoke-Team 'olivia' @('check')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '--- emma-olivia-0002 '
            $result.Output | Should -Not -Match 'the team plan changed'
        }

        It 'does not end a wait by itself, and shows the banner with the next thing that does' {
            $waiting = Start-RelayTool -Room $room -Agent 'emma' -Engine $engine -Words @('wait', '1') -Environment @{ RELAY_MINUTE_SECONDS = '4' }
            Start-Sleep -Seconds 1
            Write-TeamPlan $room (@('plan: 4') + $defaultPlan[1..8])
            $ended = Wait-RelayTool -Handle $waiting -TimeoutSeconds 60
            $ended.ExitCode | Should -Be 0
            $ended.Output | Should -Match 'nothing arrived in 1 minutes'
            $ended.Output | Should -Not -Match 'the team plan changed'
            $state = Read-TeamKeyValue (Join-Path $room 'agents\emma\state')
            $state.ContainsKey('plan_seen') | Should -BeFalse
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.Output | Should -Match '(?m)^=== the team plan changed: plan 4 ===$'
        }

        It 'does not show it, and keeps plan_seen, while the plan is half written' {
            Write-TeamPlan $room $defaultPlan -NoEnd
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '--- olivia-emma-0001 '
            $result.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state')).ContainsKey('plan_seen') | Should -BeFalse
            Write-TeamPlan $room $defaultPlan
            $null = Send-TeamNote 'olivia' 'emma' "Second`n`nAnother note."
            $later = Invoke-Team 'emma' @('check')
            Confirm-TeamBanner (Get-TeamLine $later.Output) '3' (Get-TeamExpectedPartBlock)
        }
        It 'does not show it, and does not store the revision, when a check finds nothing' {
            $result = Invoke-Team 'emma' @('check')
            $result.ExitCode | Should -Be 3
            $result.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state')).ContainsKey('plan_seen') | Should -BeFalse
        }

        It 'shows it once with start, directly before the NEXT: line and after the standing rules' {
            Set-TeamWaitLease 'emma'
            $first = Invoke-Team 'emma' @('start')
            $first.ExitCode | Should -Be 0
            $lines = Get-TeamLine $first.Output
            $banner = [array]::IndexOf($lines, '=== the team plan changed: plan 3 ===')
            $banner | Should -BeGreaterThan 0
            $rules = @($lines | Where-Object { $_ -like '=== standing rules and owner decisions*' })
            $rules.Count | Should -Be 1
            [array]::IndexOf($lines, $rules[0]) | Should -BeLessThan $banner
            Confirm-TeamBanner $lines '3' (Get-TeamExpectedPartBlock)
            @($lines | Where-Object { $_ -like 'NEXT: *' }).Count | Should -Be 1
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state'))['plan_seen'] | Should -Be '3'
            $second = Invoke-Team 'emma' @('start')
            $second.Output | Should -Not -Match 'the team plan changed'
        }

        It 'does not show it to the coordinator with start either' {
            $result = Invoke-Team 'olivia' @('start')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'the team plan changed'
        }
    }

    Context 'Blanks and characters' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'prints no line that ends with a blank' {
            Write-TeamFile (Join-Path $room 'agents\emma\progress') "2026-10-10T08:30:15Z | Working`n"
            $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'A task' -Sent '2026-10-10T08:05:00Z'
            foreach ($agent in 'emma', 'olivia') {
                $result = Invoke-Team $agent @('team')
                @(Get-TeamLine $result.Output | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
            }
            [System.IO.File]::Delete((Join-Path $room 'PLAN'))
            @(Get-TeamLine (Invoke-Team 'emma' @('team')).Output | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
        }

        It 'trims a space and a tab from a value, and nothing else' {
            $nbsp = [string][char]0x00A0
            Write-TeamPlan $room (@('plan: 3', 'updated_utc: 2026-10-10T08:15:00Z', "goal:`t  Tabbed goal  `t", ('part: nb | emma | todo | - | - | ' + $nbsp + 'Edges' + $nbsp)))
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $lines[1] | Should -BeExactly 'goal: Tabbed goal'
            $lines | Should -Contain (Format-TeamPart 'nb' 'todo' 'Emma' ($nbsp + 'Edges' + $nbsp))
        }

        It 'pads by characters, not by bytes: <Name>' -ForEach @(
            @{ Name = 'an accented display name'; Display = ('Jos' + [char]0x00E9) }
            @{ Name = 'a display name in another script'; Display = ([string][char]0x65E5 + [char]0x672C) }
        ) {
            $seat = Join-Path $room 'agents\jack\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', "display: $Display")
            $lines = Get-TeamLine (Invoke-Team 'henry' @('team')).Output
            $lines | Should -Contain (Format-TeamPart 'tests' 'todo' $Display 'Tests for both verbs')
            $lines | Should -Contain (Format-TeamAgent $Display 'working' 'reviewer')
        }

        It 'pads by characters when a display name holds a character of two UTF-16 halves' {
            $display = 'Zo' + [char]::ConvertFromUtf32(0x1F600)
            $seat = Join-Path $room 'agents\jack\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace '(?m)^display: .*$', "display: $display")
            $lines = Get-TeamLine (Invoke-Team 'henry' @('team')).Output
            # three characters: six spaces make the column nine wide, then the two of the separator
            $lines | Should -Contain ('  ' + 'tests'.PadRight(12) + '  ' + 'todo'.PadRight(8) + '  ' + $display + (' ' * 6) + '  Tests for both verbs')
            $lines | Should -Contain ('  ' + $display + (' ' * 6) + '  ' + 'working'.PadRight(12) + '  reviewer')
        }

        It 'does not cut a progress line inside a character of two halves' {
            $emoji = [char]::ConvertFromUtf32(0x1F600)
            $line = ('x' * 199) + $emoji + 'yy'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text $line
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly ('PROGRESS noted: ' + ('x' * 199) + $emoji)
        }
    }

    Context 'progress: the file and the record' {
        It 'ends with its own error and keeps the draft when the progress file cannot be written' {
            $null = New-Item -ItemType Directory -Path (Join-Path $room 'agents\emma\progress')
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $result.ExitCode | Should -Be 2
            Join-TeamLine (Get-TeamLine $result.Output) | Should -BeExactly (Join-TeamLine @('ERROR: could not write your progress file', 'NEXT: check that the room folder is reachable and writable, then run the same command again'))
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md'))) | Should -Match 'Writing the verbs'
        }

        It 'still notes the line when the <Name> cannot be written' -ForEach @(
            @{ Name = 'status file'; Blocked = 'status' }
            @{ Name = 'journal'; Blocked = 'journal' }
            @{ Name = 'status file and the journal'; Blocked = 'both' }
        ) {
            if ($Blocked -ne 'journal') { [System.IO.File]::Delete((Join-Path $room 'agents\emma\status')); $null = New-Item -ItemType Directory -Path (Join-Path $room 'agents\emma\status') }
            if ($Blocked -ne 'status') { [System.IO.File]::Delete((Join-Path $room 'agents\emma\journal')); $null = New-Item -ItemType Directory -Path (Join-Path $room 'agents\emma\journal') }
            Set-TeamWaitLease 'emma'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $result.ExitCode | Should -Be 0
            Join-TeamLine (Get-TeamLine $result.Output) | Should -Match '^PROGRESS noted: Writing the verbs\nNEXT: carry on\. The team sees it with: \S.* team$'
            @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))[0] | Should -Match ' \| Writing the verbs$'
            $draft = Join-Path $room 'agents\emma\draft.md'
            if (Test-Path -LiteralPath $draft) { ([System.IO.File]::ReadAllText($draft)).Trim() | Should -BeExactly '' }
        }

        It 'refuses a line with a secret after the 200th character, and one that straddles the cut: <Name>' -ForEach @(
            @{ Name = 'entirely after the cut'; Prefix = 205 }
            @{ Name = 'across the cut'; Prefix = 190 }
        ) {
            $key = 'AKIA' + ('ABCDEFGH' * 2)
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text (('x' * $Prefix) + ' ' + $key)
            $result = Invoke-Team 'emma' @('progress')
            $result.ExitCode | Should -Be 1
            Join-TeamLine (Get-TeamLine $result.Output) | Should -BeExactly (Join-TeamLine @('ERROR: the text looks like it contains an AWS access key id; nothing was noted', 'NEXT: take the secret out of the line and run the same command again'))
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md'))) | Should -Match 'AKIA'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\progress') | Should -BeFalse
        }
        It 'keeps two calls with the same text, in the order they were made' {
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Same text'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Same text'
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Another text'
            $lines = @(Read-TeamFileLine (Join-Path $room 'agents\emma\progress'))
            $lines.Count | Should -Be 3
            $lines[0].Substring(23) | Should -BeExactly 'Same text'
            $lines[1].Substring(23) | Should -BeExactly 'Same text'
            $lines[2].Substring(23) | Should -BeExactly 'Another text'
        }

        It 'reads the record back from the last line that holds a bar: <Name>' -ForEach @(
            @{ Name = 'a last line without a bar is passed over'; Content = "2026-10-10T07:00:00Z | Older`n2026-10-10T08:30:15Z | The good one`nnot a record at all`n"; Expected = 'progress: The good one  (2026-10-10T08:30:15Z)' }
            @{ Name = 'the text is cut at the first bar only'; Content = "2026-10-10T08:30:15Z | one | two | three`n"; Expected = 'progress: one | two | three  (2026-10-10T08:30:15Z)' }
            @{ Name = 'a file without a single bar gives no progress line'; Content = "just words`nmore words`n"; Expected = '' }
            @{ Name = 'an empty file gives no progress line'; Content = ''; Expected = '' }
        ) {
            Write-TeamPlan $room $defaultPlan
            Write-TeamFile (Join-Path $room 'agents\emma\progress') $Content
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            $emma = @(Get-TeamAgentBlock $lines 'Emma' | Where-Object { $_ -like "$($indent)progress:*" })
            if ($Expected) { Join-TeamLine $emma | Should -BeExactly ($indent + $Expected) } else { $emma.Count | Should -Be 0 }
        }
    }

    Context 'team: names, roles and who is an agent' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'shows an empty owner, reviewer or depends field as -' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Empty', 'part: empty |  | todo |  |  | Nothing set')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'empty' 'todo' 'nobody' 'Nothing set')))
        }

        It 'ignores a second part with an id that was seen already' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Twice'
                'part: same | emma | todo | - | - | The first one'
                'part: same | jack | done | - | henry | The second one'
                'part: other | jack | todo | - | - | Another'
                'files: same | one.txt'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'henry' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'same' 'todo' 'Emma' 'The first one'), ($indent + 'files: one.txt'), (Format-TeamPart 'other' 'todo' 'Jack' 'Another')))
        }

        It 'takes the role of the seat, else of the card, else "no role recorded"' {
            $seat = Join-Path $room 'agents\emma\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace "(?m)^role: .*`n", '')
            $seat = Join-Path $room 'agents\jack\seat'
            Write-TeamFile $seat (([System.IO.File]::ReadAllText($seat)) -replace "(?m)^role: .*`n", '')
            $card = Join-Path $room 'agents\jack\card'
            Write-TeamFile $card (([System.IO.File]::ReadAllText($card)) -replace "(?m)^role: .*`n", '')
            $lines = Get-TeamLine (Invoke-Team 'henry' @('team')).Output
            $lines | Should -Contain (Format-TeamAgent 'Emma' 'listening' 'tester')
            $lines | Should -Contain (Format-TeamAgent 'Jack' 'working' 'no role recorded')
        }

        It 'sorts a task without sent_utc before every task that has one' {
            $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject 'Dated' -Sent '2026-10-10T07:00:00Z'
            $null = Write-TeamMessage $room 'olivia' 'emma' 3 -Subject 'Undated' -NoSent
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain ($indent + 'doing: olivia-emma-0003  Undated')
        }

        It 'does not list a free seat that has a card file with nothing in it, and lists one whose card has a line' {
            $seatName = @(Get-RelayTestOpenSeat -Room $room)[0]
            $display = $seatName.Substring(0, 1).ToUpperInvariant() + $seatName.Substring(1)
            Write-TeamFile (Join-Path $room "agents\$seatName\card") "`n  `n"
            @((Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Where-Object { $_ -match ('^  ' + [regex]::Escape($display) + ' ') }).Count | Should -Be 0
            Write-TeamFile (Join-Path $room "agents\$seatName\card") "name: $seatName`n"
            @((Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Where-Object { $_ -match ('^  ' + [regex]::Escape($display) + ' +not started') }).Count | Should -Be 1
        }

        It 'lists among the names you may write to only those with a folder that is not retired' {
            Write-TeamFile (Join-Path $room 'agents\emma\lines') "zoe`nghost`nadam`njack`n"
            (Get-TeamLine (Invoke-Team 'emma' @('team')).Output) | Should -Contain 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Adam, Jack.'
        }
    }

    Context 'team: STALE and the room clock' {
        BeforeEach { Write-TeamPlan $room $defaultPlan }

        It 'counts stale_minutes times 60 seconds: <Limit> minutes, silent for <Age> seconds' -ForEach @(
            @{ Limit = 5; Age = 280; Expected = 'listening' }
            @{ Limit = 5; Age = 320; Expected = 'STALE' }
            @{ Limit = 2; Age = 100; Expected = 'listening' }
            @{ Limit = 2; Age = 140; Expected = 'STALE' }
        ) {
            $file = Join-Path $room 'ROOM'
            Write-TeamFile $file (([System.IO.File]::ReadAllText($file)) -replace '(?m)^stale_minutes: .*$', "stale_minutes: $Limit")
            [System.IO.File]::SetLastWriteTimeUtc((Join-Path $room 'agents\emma\alive'), [DateTime]::UtcNow.AddSeconds(-$Age))
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain (Format-TeamAgent 'Emma' $Expected 'tester')
        }

        It 'keeps listening for an agent without an alive file' {
            [System.IO.File]::Delete((Join-Path $room 'agents\emma\alive'))
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) | Should -Contain (Format-TeamAgent 'Emma' 'listening' 'tester')
        }
    }

    Context 'team and progress: the gates and the banner outside a delivery' {
        It 'refuses both verbs like who before the agent has introduced itself' {
            $id = New-RelayTestId
            $fresh = (New-RelayTestRoom -Root (Join-Path $root "fresh-$id") -RoomId "fresh-$id").Path
            foreach ($verb in 'team', 'progress') {
                $result = Invoke-RelayTool -Room $fresh -Agent 'emma' -Engine $engine -Words @($verb)
                $result.ExitCode | Should -Be 1
                $result.Output | Should -Match 'not introduced yourself'
                $result.Output | Should -Match 'NEXT: run this first: .* start'
            }
        }

        It 'refuses both verbs like who when <Name>' -ForEach @(
            @{ Name = 'the room is closed'; Kind = 'closed' }
            @{ Name = 'the caller is retired'; Kind = 'retired' }
            @{ Name = 'the caller is stopped'; Kind = 'stopped' }
            @{ Name = 'a newer session has replaced the caller'; Kind = 'replaced' }
        ) {
            Write-TeamPlan $room $defaultPlan
            switch ($Kind) {
                'replaced' { Write-TeamFile (Join-Path $room 'agents\emma\gen') "2`n" }
                'closed' { Write-TeamFile (Join-Path $room 'CLOSED') "closed`n" }
                'retired' { Write-TeamFile (Join-Path $room 'agents\emma\retired') "retired`n" }
                'stopped' { Write-TeamFile (Join-Path $room 'agents\emma\control') "state: stop`n" }
            }
            $who = Invoke-Team 'emma' @('who')
            $who.ExitCode | Should -Not -Be 0
            $team = Invoke-Team 'emma' @('team')
            $team.ExitCode | Should -Be $who.ExitCode
            $team.Output | Should -Not -Match '(?m)^AGENTS$'
            $result = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('progress') -Text 'Writing the verbs'
            $result.ExitCode | Should -Be $who.ExitCode
            $result.Output | Should -Not -Match 'PROGRESS noted'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\progress') | Should -BeFalse
        }

        It 'shows no banner and keeps plan_seen when the caller is stopped' {
            Write-TeamPlan $room $defaultPlan
            Write-TeamFile (Join-Path $room 'agents\emma\control') "state: stop`n"
            $null = Send-TeamNote 'olivia' 'emma'
            $result = Invoke-Team 'emma' @('check')
            $result.ExitCode | Should -Be 5
            $result.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state')).ContainsKey('plan_seen') | Should -BeFalse
        }

        It 'shows no banner and keeps plan_seen when the waits of a loop agent end with nothing' {
            Write-TeamPlan $room $defaultPlan
            $fast = @{ RELAY_MINUTE_SECONDS = '1' }
            $first = Invoke-Team 'emma' @('wait', '2') $fast
            $first.ExitCode | Should -Be 0
            $first.Output | Should -Match 'nothing arrived in 2 minutes'
            $second = Invoke-Team 'emma' @('wait', '2') $fast
            $second.ExitCode | Should -Be 0
            $second.Output | Should -Match 'nothing arrived in 2 minutes'
            $first.Output + $second.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state')).ContainsKey('plan_seen') | Should -BeFalse
        }

        It 'shows no banner and keeps plan_seen when a wait is paused or held, and when a proposal falls due' {
            Write-TeamPlan $room $defaultPlan
            $state = Join-Path $room 'agents\emma\state'
            $control = Join-Path $room 'agents\emma\control'
            Write-TeamFile $control "state: pause`nnote: owner is looking`n"
            $paused = Invoke-Team 'emma' @('wait', '5')
            $paused.Output | Should -Match '=== you are paused ==='
            $null = Send-TeamNote 'olivia' 'emma'
            $held = Invoke-Team 'emma' @('wait', '3') @{ RELAY_MINUTE_SECONDS = '1' }
            $held.ExitCode | Should -Be 0
            $held.Output | Should -Match 'nothing arrived in 3 minutes'
            $paused.Output + $held.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue $state).ContainsKey('plan_seen') | Should -BeFalse
            Write-TeamFile $control "state: run`nnote: `n"
            $null = Invoke-Team 'emma' @('check')
            $null = Invoke-Team 'emma' @('check')
            $fast = @{ RELAY_MINUTE_SECONDS = '2' }
            $null = Send-RelayTestMessage -Room $room -Agent 'emma' -Engine $engine -Words @('propose', '1') -Text "Rename a file`n`nI will rename notes.txt."
            $null = Invoke-Team 'olivia' @('check')
            Write-TeamFile $state (([System.IO.File]::ReadAllText($state)) -replace '(?m)^plan_seen: .*\n', '')
            $due = Invoke-Team 'emma' @('wait', '10') $fast
            $due.Output | Should -Match 'no objection to your proposal'
            $due.Output | Should -Not -Match 'the team plan changed'
            (Read-TeamKeyValue $state).ContainsKey('plan_seen') | Should -BeFalse
        }

        It 'counts a plan_seen that is <Name> as 0' -ForEach @(
            @{ Name = 'not a number'; Line = 'plan_seen: abc' }
            @{ Name = 'empty'; Line = 'plan_seen: ' }
        ) {
            Write-TeamPlan $room $defaultPlan
            $state = Join-Path $room 'agents\emma\state'
            Write-TeamFile $state (([System.IO.File]::ReadAllText($state)) + "$Line`n")
            $null = Send-TeamNote 'olivia' 'emma'
            (Invoke-Team 'emma' @('check')).Output | Should -Match '(?m)^=== the team plan changed: plan 3 ===$'
        }
    }

    Context 'team: the size of a revision' {
        It 'reads a revision of nine digits as a plan' {
            Write-TeamPlan $room (@('plan: 999999999') + $defaultPlan[1..8])
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output)[0] | Should -BeExactly '=== team in room template: plan 999999999, 2026-10-10T08:15:00Z ==='
        }

        It 'reads a revision of ten digits as no plan' {
            Write-TeamPlan $room (@('plan: 1000000000') + $defaultPlan[1..8])
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            (Get-TeamLine $result.Output)[0] | Should -BeExactly '=== team in room template: no plan yet ==='
            $result.Output | Should -Not -Match '(?m)^PARTS$'
        }
    }

    Context 'team: one reader for every tool (R20 to R23)' {
        It 'ignores lines whose key is not in lower case, has blanks before it or between it and the colon (R20)' {
            Write-TeamPlan $room $defaultPlan
            $normal = (Invoke-Team 'jack' @('team')).Output
            $noise = @(
                'Plan: 9'
                ' part: indented | emma | todo | - | - | Indented'
                'part : spaced | emma | todo | - | - | Spaced'
                'Goal: Capital goal'
                'PART: shout | emma | todo | - | - | Shouted'
            )
            Write-TeamPlan $room ($noise + $defaultPlan) -End '3'
            $result = Invoke-Team 'jack' @('team')
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeExactly $normal
        }

        It 'sees no plan in a file whose only plan: line starts with a capital (R20)' {
            Write-TeamPlan $room @('Plan: 3', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Capital', 'part: tool-ps | emma | doing | - | henry | The verbs') -End '3'
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output)[0] | Should -BeExactly '=== team in room template: no plan yet ==='
        }

        It 'reads a revision as a number: plan: 007 with end: 7 is plan 7 (R21)' {
            Write-TeamPlan $room (@('plan: 007') + $defaultPlan[1..8]) -End '7'
            (Get-TeamLine (Invoke-Team 'jack' @('team')).Output)[0] | Should -BeExactly '=== team in room template: plan 7, 2026-10-10T08:15:00Z ==='
            (Read-TeamKeyValue (Join-Path $room 'agents\jack\state'))['plan_seen'] | Should -Be '7'
        }

        It 'shows the banner of plan: 007 as plan 7 (R21)' {
            Write-TeamPlan $room (@('plan: 007') + $defaultPlan[1..8]) -End '7'
            $null = Send-TeamNote 'olivia' 'emma'
            $lines = Get-TeamLine (Invoke-Team 'emma' @('check')).Output
            $lines | Should -Contain '=== the team plan changed: plan 7 ==='
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\state'))['plan_seen'] | Should -Be '7'
        }

        It 'prints a name that is no agent with a capital only when it starts with a to z (R22): <Name>' -ForEach @(
            @{ Name = 'a plain name'; Owner = 'eva'; Shown = 'Eva' }
            @{ Name = 'an accented first letter'; Owner = ([string][char]0x00E9 + 'va'); Shown = ([string][char]0x00E9 + 'va') }
            @{ Name = 'a digit first'; Owner = '1abc'; Shown = '1abc' }
        ) {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Names', "part: far | $Owner | todo | - | - | Far away")
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly (Format-TeamPart 'far' 'todo' $Shown 'Far away')
        }

        It 'keeps blanks around a bar inside a title: only its two ends are trimmed (R23)' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Titles', 'part: t1 | emma | todo | - | - |   a  |  b  ')
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            $rows[1] | Should -BeExactly (Format-TeamPart 't1' 'todo' 'Emma' 'a  |  b')
        }

        It 'prints no blank at the end of a part without a title, or of a task without a subject' {
            Write-TeamPlan $room @('plan: 1', 'updated_utc: 2026-10-10T08:15:00Z', 'goal: Empty', ('part: e1 | emma | todo | - | - | '))
            $null = Write-TeamMessage $room 'olivia' 'emma' 2 -Subject '' -Sent '2026-10-10T08:05:00Z'
            $lines = Get-TeamLine (Invoke-Team 'jack' @('team')).Output
            @($lines | Where-Object { $_ -match '[ \t]$' }).Count | Should -Be 0
            $lines | Should -Contain ('  ' + 'e1'.PadRight(12) + '  ' + 'todo'.PadRight(8) + '  ' + 'Emma')
            $lines | Should -Contain ($indent + 'doing: olivia-emma-0002')
        }

        It 'does not take a lines entry wrapped in vertical tabs for a recipient: only a space and a tab are trimmed' {
            $vt = [string][char]11
            Write-TeamPlan $room $defaultPlan
            Write-TeamFile (Join-Path $room 'agents\emma\lines') ($vt + 'jack' + $vt + "`nhenry`n")
            (Get-TeamLine (Invoke-Team 'emma' @('team')).Output) | Should -Contain 'YOU: Emma. Your parts: tool-ps. You may write directly to: Olivia, Henry.'
        }
    }

    Context 'team: names and ids without regard to case (R24, T2)' {
        It 'counts an owner or reviewer written in capitals as the agent: display, parts: lines and Your parts (R24)' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Names'
                'part: a | emma | todo | - | henry | First'
                'part: b | Emma | todo | - | Jack | Second'
                'part: c | JACK | todo | - | - | Third'
            )
            $lines = Get-TeamLine (Invoke-Team 'emma' @('team')).Output
            $parts = @(Get-TeamSection $lines 'PARTS')
            Join-TeamLine $parts | Should -BeExactly (Join-TeamLine @(
                    'PARTS'
                    (Format-TeamPart 'a' 'todo' 'Emma' 'First')
                    ($indent + 'reviewer: Henry')
                    (Format-TeamPart 'b' 'todo' 'Emma' 'Second')
                    ($indent + 'reviewer: Jack')
                    (Format-TeamPart 'c' 'todo' 'Jack' 'Third')))
            Join-TeamLine (Get-TeamAgentBlock $lines 'Emma') | Should -BeExactly (Join-TeamLine @((Format-TeamAgent 'Emma' 'listening' 'tester'), ($indent + 'parts: a, b')))
            Join-TeamLine (Get-TeamAgentBlock $lines 'Jack') | Should -BeExactly (Join-TeamLine @((Format-TeamAgent 'Jack' 'working' 'reviewer'), ($indent + 'parts: c')))
            $lines | Should -Contain 'YOU: Emma. Your parts: a, b. You may write directly to: Olivia, Jack.'
        }

        It 'shows a name that is no agent as written, and with a capital first letter only when it is all in lower case (R24, R22)' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Strangers'
                'part: x | emma | todo | - | EVA | Upper'
                'part: y | emma | todo | - | eva | Lower'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @(
                    'PARTS'
                    (Format-TeamPart 'x' 'todo' 'Emma' 'Upper')
                    ($indent + 'reviewer: EVA')
                    (Format-TeamPart 'y' 'todo' 'Emma' 'Lower')
                    ($indent + 'reviewer: Eva')))
        }

        It 'ignores a part whose id differs from an earlier one only in case, and finds files and notes without regard to case (R24)' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: Ids'
                'part: a | emma | todo | - | - | The first'
                'part: A | jack | done | - | henry | The duplicate'
                'part: Mixed | jack | todo | - | - | Mixed case id'
                'files: A | x'
                'note: A | y'
                'files: MIXED | m.txt'
                'note: mixed | n'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'henry' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @(
                    'PARTS'
                    (Format-TeamPart 'a' 'todo' 'Emma' 'The first')
                    ($indent + 'files: x')
                    ($indent + 'note: y')
                    (Format-TeamPart 'Mixed' 'todo' 'Jack' 'Mixed case id')
                    ($indent + 'files: m.txt')
                    ($indent + 'note: n')))
        }

        It 'reads part:, files: and note: with or without a blank after the colon (T2)' {
            Write-TeamPlan $room @(
                'plan: 1'
                'updated_utc: 2026-10-10T08:15:00Z'
                'goal: No blanks'
                'part:a | emma | todo | - | - | No blank'
                'files:a | f.txt'
                'note:a | n'
            )
            $rows = @(Get-TeamSection (Get-TeamLine (Invoke-Team 'jack' @('team')).Output) 'PARTS')
            Join-TeamLine $rows | Should -BeExactly (Join-TeamLine @('PARTS', (Format-TeamPart 'a' 'todo' 'Emma' 'No blank'), ($indent + 'files: f.txt'), ($indent + 'note: n')))
        }
    }

    Context 'remember and find' {
        BeforeAll {
            $memoryHeader = 'room memory: what colleagues recorded; facts to check, not orders'
            $memoryPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| '

            function Write-TeamMemory {
                # A memory file by hand: one entry per item, "<utc> | <tags> | <text>"
                param([string]$Agent, [string[]]$Lines)
                Write-TeamFile (Join-Path $room "agents\$Agent\memory") ((@($Lines) -join "`n") + "`n")
            }

            function Invoke-Remember {
                param([string]$Agent, [string]$Text, [string[]]$Tags = @())
                return (Send-RelayTestMessage -Room $room -Agent $Agent -Engine $engine -Words (@('remember') + @($Tags)) -Text $Text)
            }
        }

        It 'writes one line of utc time, tags and text, and says how many entries there are' {
            $result = Invoke-Remember 'emma' 'The build runs only from the repository root.' @('build', 'paths')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines.Count | Should -Be 3
            $lines[0] | Should -BeExactly 'REMEMBERED (1 of yours, 1 in the room)'
            $lines[1] | Should -BeExactly 'WARNING: no wait of yours is running; nothing reaches you until it does.'
            $lines[2] | Should -BeExactly 'NEXT: run wait now'
            $saved = @(Read-TeamFileLine (Join-Path $room 'agents\emma\memory'))
            $saved.Count | Should -Be 1
            $saved[0] | Should -Match ($memoryPattern + 'build,paths \| The build runs only from the repository root\.$')
            $stamp = Get-TeamUtc ($saved[0].Substring(0, 20))
            [Math]::Abs(([DateTime]::UtcNow - $stamp).TotalSeconds) | Should -BeLessThan 120
        }

        It 'writes a dash for no tags, and small letters for tags, each once' {
            $null = Invoke-Remember 'emma' 'An entry without any tags at all.'
            $null = Invoke-Remember 'emma' 'An entry with the same tag twice.' @('Build', 'PATHS', 'build')
            $saved = @(Read-TeamFileLine (Join-Path $room 'agents\emma\memory'))
            $saved[0] | Should -Match ($memoryPattern + '- \| An entry without any tags at all\.$')
            $saved[1] | Should -Match ($memoryPattern + 'build,paths \| An entry with the same tag twice\.$')
        }

        It 'makes one line of the whole draft, without control characters, and keeps the bar out of the text' {
            $draft = "First line of it`n`n   second`tline " + [char]7 + "here | and more`r`nlast"
            $result = Invoke-Remember 'emma' $draft
            $result.ExitCode | Should -Be 0
            $saved = @(Read-TeamFileLine (Join-Path $room 'agents\emma\memory'))
            $saved.Count | Should -Be 1
            $saved[0].Substring(27) | Should -BeExactly 'First line of it second line here / and more last'
        }

        It 'sets the status, adds a journal line and clears the draft' {
            $null = Invoke-Remember 'emma' 'The cache folder is rebuilt on every start.'
            (Read-TeamKeyValue (Join-Path $room 'agents\emma\status'))['state'] | Should -Be 'working'
            $journal = @(Read-TeamFileLine (Join-Path $room 'agents\emma\journal'))
            $journal[$journal.Count - 1] | Should -Match '^\S+ remember The cache folder is rebuilt on every start\.$'
            $draft = Join-Path $room 'agents\emma\draft.md'
            if (Test-Path -LiteralPath $draft) { ([System.IO.File]::ReadAllText($draft)).Trim() | Should -BeExactly '' }
        }

        It 'sends no message and touches no inbox' {
            $before = Get-TeamTree $room
            $null = Invoke-Remember 'emma' 'The cache folder is rebuilt on every start.'
            @(Get-TeamTreeChange $before (Get-TeamTree $room) | Where-Object { $_ -like '*\inbox\*' -or $_ -like '*/inbox/*' }).Count | Should -Be 0
        }

        It 'takes a text of <Length> characters: <Taken>' -ForEach @(
            @{ Length = 14; Taken = $false }
            @{ Length = 15; Taken = $true }
            @{ Length = 500; Taken = $true }
            @{ Length = 501; Taken = $false }
        ) {
            $text = -join (1..$Length | ForEach-Object { [string][char](97 + ($_ % 26)) })
            $result = Invoke-Remember 'emma' $text
            $memory = Join-Path $room 'agents\emma\memory'
            if ($Taken) {
                $result.ExitCode | Should -Be 0
                @(Read-TeamFileLine $memory)[0].Substring(27) | Should -BeExactly $text
            }
            else {
                $result.ExitCode | Should -Be 1
                if ($Length -gt 500) { $result.Output | Should -Match ("(?m)^ERROR: your entry is $Length characters; the limit is 500 \(15 to 500 characters, up to 5 tags\); nothing was remembered$") }
                else { $result.Output | Should -Match ("(?m)^ERROR: the text is too (short|long).*: $Length characters, (15 at least|500 at most); nothing was remembered$") }
                $result.Output | Should -Match '(?m)^NEXT: write the finding '
                Test-Path -LiteralPath $memory | Should -BeFalse
            }
        }

        It 'refuses more than 5 tags and takes 5 once the repeated ones are left out' {
            $many = Invoke-Remember 'emma' 'Too many tags for one entry here.' @('a', 'b', 'c', 'd', 'e', 'f')
            $many.ExitCode | Should -Be 1
            (Get-TeamLine $many.Output)[0] | Should -BeExactly 'ERROR: remember takes 5 tags at most, not 6; nothing was remembered'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\memory') | Should -BeFalse
            $five = Invoke-Remember 'emma' 'Five tags once the repeat is gone.' @('a', 'b', 'c', 'd', 'e', 'A')
            $five.ExitCode | Should -Be 0
            @(Read-TeamFileLine (Join-Path $room 'agents\emma\memory'))[0] | Should -Match ($memoryPattern + 'a,b,c,d,e \| ')
        }

        It 'refuses a tag that is no plain word and writes nothing' {
            $result = Invoke-Remember 'emma' 'A tag with a slash in it here.' @('a/b')
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '(?m)^ERROR: '
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\memory') | Should -BeFalse
        }

        It 'refuses a text that looks like a secret, keeps the draft, and has no override word' {
            $key = 'AKIA' + ('ABCDEFGH' * 2)
            Set-RelayTestDraft -Room $room -Agent 'emma' -Text "The key is $key in the config"
            $blocked = Invoke-Team 'emma' @('remember')
            $blocked.ExitCode | Should -Be 1
            Join-TeamLine (Get-TeamLine $blocked.Output) | Should -BeExactly (Join-TeamLine @('ERROR: the text looks like it contains an AWS access key id; nothing was remembered', 'NEXT: take the secret out of the text and run the same command again'))
            ([System.IO.File]::ReadAllText((Join-Path $room 'agents\emma\draft.md'))) | Should -Match 'The key is AKIA'
            $forced = Invoke-Team 'emma' @('remember', 'allow-secret')
            $forced.ExitCode | Should -Be 1
            $forced.Output | Should -Not -MatchExactly 'REMEMBERED'
            Test-Path -LiteralPath (Join-Path $room 'agents\emma\memory') | Should -BeFalse
        }

        It 'refuses what any agent has recorded already, whatever the case and the blanks, and writes nothing' {
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | build | The build needs the repository root.')
            $result = Invoke-Remember 'jack' "the BUILD needs   the`nrepository root."
            $result.ExitCode | Should -Be 0
            Join-TeamLine (Get-TeamLine $result.Output) | Should -Match '^ALREADY RECORDED by Emma at 2026-10-10T08:00:00Z\nWARNING: no wait of yours is running; nothing reaches you until it does\.\nNEXT: run wait now$'
            Test-Path -LiteralPath (Join-Path $room 'agents\jack\memory') | Should -BeFalse
        }

        It 'keeps only the last 200 lines when the file holds <Before> and one is added' -ForEach @(
            @{ Before = 199; Expected = 200 }
            @{ Before = 200; Expected = 200 }
            @{ Before = 230; Expected = 200 }
        ) {
            Write-TeamMemory 'emma' @(1..$Before | ForEach-Object { '2026-10-10T07:{0:00}:{1:00}Z | - | old entry number {2}' -f [Math]::Floor($_ / 60), ($_ % 60), $_ })
            $result = Invoke-Remember 'emma' 'The newest entry of them all.'
            $result.ExitCode | Should -Be 0
            $lines = @(Read-TeamFileLine (Join-Path $room 'agents\emma\memory'))
            $lines.Count | Should -Be $Expected
            $lines[$lines.Count - 1] | Should -Match ' \| The newest entry of them all\.$'
            $lines[0] | Should -Match (' \| old entry number {0}$' -f ($Before - [Math]::Min($Before, 199) + 1))
        }

        It 'shows another agent the entry, with its author, under the fixed header' {
            $null = Invoke-Remember 'emma' 'The build runs only from the repository root.' @('build')
            $found = Invoke-Team 'jack' @('find', 'build')
            $found.ExitCode | Should -Be 0
            $lines = Get-TeamLine $found.Output
            $lines.Count | Should -Be 4
            $lines[0] | Should -BeExactly $memoryHeader
            $lines[1] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z Emma \[build\] The build runs only from the repository root\.$'
            $lines[2] | Should -BeExactly 'WARNING: no wait of yours is running; nothing reaches you until it does.'
            $lines[3] | Should -BeExactly 'NEXT: run wait now'
        }

        It 'puts a tag hit before a hit in the text only, then the newest first, case aside' {
            Write-TeamMemory 'emma' @(
                '2026-10-10T08:00:00Z | build | Oldest, tagged.'
                '2026-10-10T08:05:00Z | - | Newer, the BUILD word in the text.'
            )
            Write-TeamMemory 'adam' @('2026-10-10T08:10:00Z | - | Newest, build in the text.', 'not a memory line at all', '2026-10-10T09:00:00Z | - | ')
            $lines = Get-TeamLine (Invoke-Team 'jack' @('find', 'Build')).Output
            Join-TeamLine $lines | Should -BeExactly (Join-TeamLine @(
                    $memoryHeader
                    '2026-10-10T08:00:00Z Emma [build] Oldest, tagged.'
                    '2026-10-10T08:10:00Z Adam [-] Newest, build in the text.'
                    '2026-10-10T08:05:00Z Emma [-] Newer, the BUILD word in the text.'
                    'WARNING: no wait of yours is running; nothing reaches you until it does.'
                    ($lines[$lines.Count - 1])
                ))
        }

        It 'takes tag:<name> as that tag exactly' {
            Write-TeamMemory 'emma' @(
                '2026-10-10T08:00:00Z | tests | Tagged tests.'
                '2026-10-10T08:01:00Z | testsuite | Tagged testsuite.'
                '2026-10-10T08:02:00Z | - | The word tests in the text.'
            )
            $lines = Get-TeamLine (Invoke-Team 'jack' @('find', 'tag:TESTS')).Output
            $lines.Count | Should -Be 4
            $lines[1] | Should -BeExactly '2026-10-10T08:00:00Z Emma [tests] Tagged tests.'
        }

        It 'wants every word, and falls back to any word under its own line' {
            Write-TeamMemory 'emma' @(
                '2026-10-10T08:00:00Z | - | The cache lives in the temp folder.'
                '2026-10-10T08:01:00Z | - | The cache is cleared at night.'
                '2026-10-10T08:02:00Z | - | The logs live in the temp folder.'
            )
            $all = Get-TeamLine (Invoke-Team 'jack' @('find', 'cache', 'temp')).Output
            $all.Count | Should -Be 4
            $all[1] | Should -BeExactly '2026-10-10T08:00:00Z Emma [-] The cache lives in the temp folder.'
            $any = Get-TeamLine (Invoke-Team 'jack' @('find', 'night', 'logs')).Output
            Join-TeamLine $any[0..3] | Should -BeExactly (Join-TeamLine @(
                    $memoryHeader
                    'no entry has all words; closest matches:'
                    '2026-10-10T08:02:00Z Emma [-] The logs live in the temp folder.'
                    '2026-10-10T08:01:00Z Emma [-] The cache is cleared at night.'
                ))
            $any.Count | Should -Be 6
        }

        It 'says when nothing matches any word' {
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | - | The cache lives in the temp folder.')
            $result = Invoke-Team 'jack' @('find', 'printer')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $lines.Count | Should -Be 3
            $lines[0] | Should -BeExactly 'nothing recorded matches'
            $lines[1] | Should -BeExactly 'WARNING: no wait of yours is running; nothing reaches you until it does.'
            $lines[2] | Should -BeExactly 'NEXT: run wait now'
        }

        It 'shows the 10 newest entries without words, newest first' {
            Write-TeamMemory 'emma' @(1..12 | ForEach-Object { '2026-10-10T08:{0:00}:00Z | - | Entry number {0} of twelve.' -f $_ })
            $lines = Get-TeamLine (Invoke-Team 'jack' @('find')).Output
            $lines[0] | Should -BeExactly $memoryHeader
            $lines[1] | Should -BeExactly '2026-10-10T08:12:00Z Emma [-] Entry number 12 of twelve.'
            $lines[10] | Should -BeExactly '2026-10-10T08:03:00Z Emma [-] Entry number 3 of twelve.'
            @($lines | Where-Object { $_ -like '2026-*' }).Count | Should -Be 10
            $lines[$lines.Count - 1] | Should -Match '^NEXT: '
        }

        It 'prints what another agent wrote without its control characters' {
            Write-TeamMemory 'emma' @("2026-10-10T08:00:00Z | - | Bell$([char]7) and escape$([char]27)[2J in the text.")
            $result = Invoke-Team 'jack' @('find', 'bell')
            $result.Output | Should -Not -Match "[\x07\x1B]"
            (Get-TeamLine $result.Output)[1] | Should -BeExactly '2026-10-10T08:00:00Z Emma [-] Bell and escape[2J in the text.'
        }

        It 'tells about new entries once: at start, with a delivery, and not again' {
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | build | First entry of emma.')
            $started = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $at = [array]::IndexOf($started, 'room memory: 1 entries, 1 new - run: find <words> before you start or ask')
            $at | Should -BeGreaterThan 0
            $started[$at + 1] | Should -BeExactly '  2026-10-10T08:00:00Z Emma [build] First entry of emma.'
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | build | First entry of emma.', '2026-10-10T08:01:00Z | - | Second entry of emma.')
            $null = Send-TeamNote 'olivia' 'jack'
            $delivered = Get-TeamLine (Invoke-Team 'jack' @('wait', '1')).Output
            $at = [array]::IndexOf($delivered, 'room memory: 2 entries, 1 new - run: find <words> before you start or ask')
            $at | Should -BeGreaterThan 0
            $delivered[$at + 1] | Should -BeExactly '  2026-10-10T08:01:00Z Emma [-] Second entry of emma.'
            $delivered[$at + 2] | Should -Not -Match 'First entry'
            $null = Send-TeamNote 'olivia' 'jack'
            $again = Invoke-Team 'jack' @('check')
            $again.Output | Should -Match 'new message'
            $again.Output | Should -Not -Match 'room memory:'
            # start says how much there is, with nothing new to show
            $restarted = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $at = [array]::IndexOf($restarted, 'room memory: 2 entries, 0 new - run: find <words> before you start or ask')
            $at | Should -BeGreaterThan 0
            $restarted[$at + 1] | Should -Not -Match 'entry of emma'
        }

        It 'shows the three newest new entries and never the agent''s own' {
            Write-TeamMemory 'emma' @(1..5 | ForEach-Object { '2026-10-10T08:0{0}:00Z | - | Entry {0} of emma.' -f $_ })
            Write-TeamMemory 'jack' @('2026-10-10T09:00:00Z | - | Entry of jack himself.')
            $lines = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $at = [array]::IndexOf($lines, 'room memory: 6 entries, 5 new - run: find <words> before you start or ask')
            $at | Should -BeGreaterThan 0
            Join-TeamLine $lines[($at + 1)..($at + 3)] | Should -BeExactly (Join-TeamLine @('  2026-10-10T08:05:00Z Emma [-] Entry 5 of emma.', '  2026-10-10T08:04:00Z Emma [-] Entry 4 of emma.', '  2026-10-10T08:03:00Z Emma [-] Entry 3 of emma.'))
            $lines[$at + 4] | Should -Not -Match 'Entry'
        }

        It 'prints no memory line while the room remembers nothing' {
            (Invoke-Team 'jack' @('start')).Output | Should -Not -Match 'room memory:'
            $null = Send-TeamNote 'olivia' 'jack'
            (Invoke-Team 'jack' @('check')).Output | Should -Not -Match 'room memory:'
        }

        It 'tells about new entries before a question is sent' {
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | - | The answer may be here already.')
            $asked = Send-RelayTestMessage -Room $room -Agent 'jack' -Engine $engine -Words @('ask') -Text "Where?`n`nWhere is it?"
            $asked.ExitCode | Should -Be 0
            $lines = Get-TeamLine $asked.Output
            $lines | Should -Contain 'room memory: 1 entries, 1 new - run: find <words> before you start or ask'
            $lines | Should -Contain '  2026-10-10T08:00:00Z Emma [-] The answer may be here already.'
            $asked.Output | Should -Match 'SENT jack-olivia-\d+ \(question\)'
        }

        It 'goes on telling about new entries once an author''s file is at its 200 lines, and after it shrank' {
            function Get-EmmaLine { param([int]$From, [int]$To) return @($From..$To | ForEach-Object { '2026-10-10T{0:D2}:{1:D2}:00Z | - | Entry {2} of emma.' -f [int][Math]::Floor($_ / 60), ($_ % 60), $_ }) }
            Write-TeamMemory 'emma' (Get-EmmaLine 1 200)
            $null = Invoke-Team 'jack' @('start')
            # At the cap the oldest line goes for each new one: the number of entries stays 200
            Write-TeamMemory 'emma' (Get-EmmaLine 2 201)
            $lines = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $at = [array]::IndexOf($lines, 'room memory: 200 entries, 1 new - run: find <words> before you start or ask')
            $at | Should -BeGreaterThan 0
            $lines[$at + 1] | Should -BeExactly '  2026-10-10T03:21:00Z Emma [-] Entry 201 of emma.'
            $lines[$at + 2] | Should -Not -Match 'of emma'
            # A file that shrank does not turn old entries into new ones, and the next entry is new again
            Write-TeamMemory 'emma' ((Get-EmmaLine 150 201) + (Get-EmmaLine 202 202))
            $lines = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $lines | Should -Contain 'room memory: 53 entries, 1 new - run: find <words> before you start or ask'
            $lines | Should -Contain '  2026-10-10T03:22:00Z Emma [-] Entry 202 of emma.'
            # The entry seen last is gone: what is newer than its time is new
            Write-TeamMemory 'emma' @((Get-EmmaLine 150 201) + (Get-EmmaLine 203 204))
            $lines = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $lines | Should -Contain 'room memory: 54 entries, 2 new - run: find <words> before you start or ask'
        }

        It 'takes the count an earlier tool kept as everything seen so far, and tells about what comes after' {
            $null = Invoke-Team 'jack' @('start')
            $state = Join-Path $room 'agents\jack\state'
            Write-TeamFile $state (([System.IO.File]::ReadAllText($state)).TrimEnd() + "`nmemory_seen: 3`n")
            Write-TeamMemory 'emma' @(1..5 | ForEach-Object { '2026-10-10T08:0{0}:00Z | - | Entry {0} of emma.' -f $_ })
            $first = Invoke-Team 'jack' @('start')
            $first.ExitCode | Should -Be 0
            Get-TeamLine $first.Output | Should -Contain 'room memory: 5 entries, 0 new - run: find <words> before you start or ask'
            Write-TeamMemory 'emma' @(1..6 | ForEach-Object { '2026-10-10T08:0{0}:00Z | - | Entry {0} of emma.' -f $_ })
            $lines = Get-TeamLine (Invoke-Team 'jack' @('start')).Output
            $lines | Should -Contain 'room memory: 6 entries, 1 new - run: find <words> before you start or ask'
            $lines | Should -Contain '  2026-10-10T08:06:00Z Emma [-] Entry 6 of emma.'
        }

        It 'keeps the memory hint of a question that an empty draft stopped for the question that is sent' {
            Write-TeamMemory 'emma' @('2026-10-10T08:00:00Z | - | The answer may be here already.')
            $empty = Invoke-Team 'jack' @('ask')
            $empty.ExitCode | Should -Not -Be 0
            $empty.Output | Should -Match 'nothing to send'
            $empty.Output | Should -Not -Match 'room memory:'
            $asked = Send-RelayTestMessage -Room $room -Agent 'jack' -Engine $engine -Words @('ask') -Text "Where?`n`nWhere is it?"
            $asked.ExitCode | Should -Be 0
            Get-TeamLine $asked.Output | Should -Contain 'room memory: 1 entries, 1 new - run: find <words> before you start or ask'
        }

        It 'gives the tip to remember with a report only while the agent has recorded nothing' {
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'adam') -Text "First`n`nDo it."
            $first = Get-TeamLine (Send-RelayTestMessage -Room $room -Agent 'adam' -Engine $engine -Words @('report') -Text "Done`n`n1. Result: done.").Output
            $first[$first.Count - 3] | Should -BeExactly 'tip: remember durable findings for your teammates'
            $first[$first.Count - 2] | Should -BeExactly 'WARNING: no wait of yours is running; nothing reaches you until it does.'
            $first[$first.Count - 1] | Should -BeExactly 'NEXT: run wait now'
            $null = Invoke-Remember 'adam' 'Something adam learned that lasts.'
            $null = Send-RelayTestMessage -Room $room -Agent 'olivia' -Engine $engine -Words @('task', 'adam') -Text "Second`n`nDo it."
            $second = Send-RelayTestMessage -Room $room -Agent 'adam' -Engine $engine -Words @('report') -Text "Done`n`n1. Result: done."
            $second.ExitCode | Should -Be 0
            $second.Output | Should -Not -Match 'tip: remember'
        }
    }

    Context 'Help' {
        It 'has the team and memory lines between who and bye, in the column of the others' {
            $result = Invoke-RelayTool -Room $room -Agent '' -Engine $engine -Words @('help')
            $result.ExitCode | Should -Be 0
            $lines = Get-TeamLine $result.Output
            $who = @($lines | Where-Object { $_ -match '^  .+? who {2,}\S' })
            $who.Count | Should -Be 1
            $at = [array]::IndexOf($lines, $who[0])
            $lines[$at + 1] | Should -Match '^  .+? team {2,}the plan, who does which part, and where everybody stands$'
            $lines[$at + 2] | Should -Match '^  .+? progress {2,}tell the team where you stand, in one line \(draft file\); wakes nobody$'
            $lines[$at + 3] | Should -Match '^  .+? remember \[tag \.\.\.\] {2,}keep a finding for the whole team \(draft file, 15 to 500 characters, up to 5 tags\); wakes nobody$'
            $lines[$at + 4] | Should -Match '^  .+? find \[word\|tag:name \.\.\.\] {2,}search what the team keeps; do it before you start or ask$'
            $lines[$at + 5] | Should -Match '^  .+? bye {2,}\S'
            # the same column as the lines around them: the text starts where the text of who starts
            $column = $who[0].IndexOf('who is in the room')
            $lines[$at + 1].IndexOf('the plan, who does') | Should -Be $column
            $lines[$at + 2].IndexOf('tell the team where') | Should -Be $column
            $lines[$at + 3].IndexOf('keep a finding') | Should -Be $column
            $lines[$at + 4].IndexOf('search what the team') | Should -Be $column
            $lines[$at + 5].IndexOf('leave the room') | Should -Be $column
        }

        It 'spells the call the same in all of its lines' {
            $lines = Get-TeamLine (Invoke-RelayTool -Room $room -Agent '' -Engine $engine -Words @('help')).Output
            $calls = @($lines | ForEach-Object { if ($_ -match '^  (?<call>.+?) (who|team|progress|remember \[tag|find \[word|bye)[ \]|a-z:.]* {2,}') { $Matches['call'] } } | Sort-Object -Unique)
            $calls.Count | Should -Be 1
            @($lines | Where-Object { $_ -match '^  .+? (who|team|progress|remember \[tag|find \[word|bye)[ \]|a-z:.]* {2,}' }).Count | Should -Be 6
        }
    }
}
