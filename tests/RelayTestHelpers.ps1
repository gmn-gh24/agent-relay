#Requires -Version 5.1

<#
    Dot-sourced by the Pester suites. Runs the room tools as real child processes, one engine at a time:
    ps7 (PowerShell 7), ps5 (Windows PowerShell 5.1) and sh (relay.sh under dash from Git for Windows).
    Works when the suite itself runs under either PowerShell edition. ASCII only.
#>

function Get-RelayTestPath {
    # Folders of the repository, from where this file is: scripts, package, fixtures or repo
    param([Parameter(Mandatory)][ValidateSet('scripts', 'package', 'fixtures', 'repo')][string]$Name)
    $repo = Split-Path -Parent $PSScriptRoot
    switch ($Name) {
        'scripts' { return (Join-Path $repo 'skills\agent-relay\scripts') }
        'package' { return (Join-Path $repo 'skills\agent-relay\assets\room-package') }
        'fixtures' { return (Join-Path $PSScriptRoot 'fixtures') }
        default { return $repo }
    }
}

function Get-RelayTestDash {
    # dash.exe of Git for Windows, or an empty string
    $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $git) {
        $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'usr\bin\dash.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $fallback = 'C:\Program Files\Git\usr\bin\dash.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return ''
}

function Get-RelayTestPwsh {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return (Get-Process -Id $PID).Path }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    $command = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return ''
}

function Get-RelayTestEngine {
    # The engines this machine can run. RELAY_TEST_ENGINES (for example "sh" or "ps7,ps5") narrows the list.
    $engines = New-Object System.Collections.Generic.List[string]
    if (Get-RelayTestPwsh) { $engines.Add('ps7') }
    $engines.Add('ps5')
    if (Get-RelayTestDash) { $engines.Add('sh') }
    if ($env:RELAY_TEST_ENGINES) {
        $wanted = @(([string]$env:RELAY_TEST_ENGINES) -split '[,; ]+' | Where-Object { $_ })
        return @($engines | Where-Object { $wanted -contains $_ })
    }
    return $engines.ToArray()
}

function New-RelayTestId {
    # A short unique word for a folder or room id. A counter kept in BeforeEach would not survive the test.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper: returns a word, changes nothing')]
    param()
    return [guid]::NewGuid().ToString('N').Substring(0, 8)
}

function ConvertTo-RelayTestArgument {
    param([string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-RelayTool {
    # Starts one tool call and returns a handle; Wait-RelayTool collects it
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
    param(
        [Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][AllowEmptyString()][string]$Agent, [Parameter(Mandatory)][string]$Engine,
        [string[]]$Words = @(), [hashtable]$Environment = @{}, [int]$Generation = 1,
        # The way an agent calls: its shell starts the tool and nothing catches the tool's output on the way.
        # The tool then inherits the shell's output instead of being handed one, which Windows treats differently.
        [switch]$ThroughShell
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $arguments = New-Object System.Collections.Generic.List[string]
    if ($ThroughShell) {
        switch ($Engine) {
            'ps7' { $shell = Get-RelayTestPwsh; $prefix = @('-NoProfile', '-NonInteractive') }
            'ps5' { $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $prefix = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') }
            'sh' { $shell = Get-RelayTestDash; $prefix = @() }
            default { throw "Unknown engine '$Engine'" }
        }
        $startInfo.FileName = $shell
        if ($Engine -eq 'sh') {
            $line = "'" + ($shell -replace '\\', '/') + "' '" + ((Join-Path $Room 'tools\relay.sh') -replace '\\', '/') + "' " + (@($Words) -join ' ')
            foreach ($item in '-c', $line) { $arguments.Add($item) }
        }
        else {
            $line = "& '$shell' " + ($prefix -join ' ') + " -File '" + (Join-Path $Room 'tools\relay.ps1') + "' " + (@($Words) -join ' ') + '; exit $LASTEXITCODE'
            foreach ($item in ($prefix + @('-Command', $line))) { $arguments.Add($item) }
        }
    }
    else {
    switch ($Engine) {
        'ps7' {
            $startInfo.FileName = Get-RelayTestPwsh
            foreach ($item in '-NoProfile', '-NonInteractive', '-File', (Join-Path $Room 'tools\relay.ps1')) { $arguments.Add($item) }
        }
        'ps5' {
            $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            foreach ($item in '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Room 'tools\relay.ps1')) { $arguments.Add($item) }
        }
        'sh' {
            $startInfo.FileName = Get-RelayTestDash
            $arguments.Add(((Join-Path $Room 'tools\relay.sh') -replace '\\', '/'))
        }
        default { throw "Unknown engine '$Engine'" }
    }
    foreach ($word in @($Words)) { $arguments.Add($word) }
    }
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-RelayTestArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.WorkingDirectory = $Room
    $variables = $startInfo.EnvironmentVariables
    # Also what would tell the tool which agent session calls: the suite itself may run inside one
    foreach ($name in 'RELAY_NAME', 'RELAY_GEN', 'RELAY_ROOM_ID', 'RELAY_WRAPPER', 'RELAY_DRAFT', 'RELAY_NO_EVENTS', 'RELAY_POLL_SECONDS', 'RELAY_SETTLE_MS', 'RELAY_MINUTE_SECONDS', 'RELAY_SESSION', 'CLAUDE_CODE_SESSION_ID') {
        if ($variables.ContainsKey($name)) { $variables.Remove($name) }
    }
    $variables['RELAY_NAME'] = $Agent
    $variables['RELAY_GEN'] = [string]$Generation
    $variables['RELAY_SETTLE_MS'] = '0'
    $variables['RELAY_POLL_SECONDS'] = '1'
    # The suite runs in somebody's terminal: its tab keeps its title unless a test asks for the naming
    $variables['RELAY_NO_TITLE'] = '1'
    if ($Engine -eq 'ps5' -and $variables.ContainsKey('PSModulePath')) { $variables.Remove('PSModulePath') }
    if ($Engine -eq 'sh') { $variables['PATH'] = (Split-Path -Parent (Get-RelayTestDash)) + ';' + $variables['PATH'] }
    foreach ($key in $Environment.Keys) { $variables[[string]$key] = [string]$Environment[$key] }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    return [pscustomobject]@{
        Process = $process
        Output  = $process.StandardOutput.ReadToEndAsync()
        Error   = $process.StandardError.ReadToEndAsync()
        Engine  = $Engine
        Agent   = $Agent
    }
}

function Wait-RelayTool {
    # Exit code and output of a started tool call; the process is killed when it runs longer than allowed
    param([Parameter(Mandatory)]$Handle, [int]$TimeoutSeconds = 120)
    $timedOut = $false
    if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { $Handle.Process.Kill() } catch { $null = $_ }
        $null = $Handle.Process.WaitForExit(5000)
    }
    else { $Handle.Process.WaitForExit() }
    $output = ''
    $errorText = ''
    try { if ($Handle.Output.Wait(5000)) { $output = [string]$Handle.Output.Result } } catch { $null = $_ }
    try { if ($Handle.Error.Wait(5000)) { $errorText = [string]$Handle.Error.Result } } catch { $null = $_ }
    $code = -999
    if (-not $timedOut) { $code = $Handle.Process.ExitCode }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = ($output -replace "`r", '')
        Error    = ($errorText -replace "`r", '')
        TimedOut = $timedOut
    }
}

function Invoke-RelayTool {
    param(
        [Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][AllowEmptyString()][string]$Agent, [Parameter(Mandatory)][string]$Engine,
        [string[]]$Words = @(), [hashtable]$Environment = @{}, [int]$Generation = 1, [int]$TimeoutSeconds = 120, [switch]$ThroughShell
    )
    $handle = Start-RelayTool -Room $Room -Agent $Agent -Engine $Engine -Words $Words -Environment $Environment -Generation $Generation -ThroughShell:$ThroughShell
    return (Wait-RelayTool -Handle $handle -TimeoutSeconds $TimeoutSeconds)
}

function Set-RelayTestDraft {
    # Writes an agent's draft exactly as given (UTF-8, no BOM)
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
    param([Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][AllowEmptyString()][string]$Agent, [Parameter(Mandatory)][string]$Text, [string]$Path = '')
    if (-not $Path) { $Path = Join-Path $Room "agents\$Agent\draft.md" }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Send-RelayTestMessage {
    # Draft plus verb in one step; returns the tool result
    param(
        [Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][AllowEmptyString()][string]$Agent, [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string[]]$Words, [Parameter(Mandatory)][string]$Text, [hashtable]$Environment = @{}
    )
    Set-RelayTestDraft -Room $Room -Agent $Agent -Text $Text
    return (Invoke-RelayTool -Room $Room -Agent $Agent -Engine $Engine -Words $Words -Environment $Environment)
}

function Read-RelayTestMessage {
    # One message file as an object: header fields plus Body, read byte-exact as UTF-8
    param([Parameter(Mandatory)][string]$Path)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString([System.IO.File]::ReadAllBytes($Path))
    $text = $text -replace "`r", ''
    $end = $text.IndexOf("`n---`n", 3)
    $header = @{}
    foreach ($line in ($text.Substring(4, $end - 3) -split "`n")) {
        $at = $line.IndexOf(':')
        if ($at -gt 0) { $header[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim() }
    }
    $header['Body'] = $text.Substring($end + 5).TrimEnd()
    return $header
}

function Get-RelayTestInbox {
    # File names in one agent's inbox, sorted
    param([Parameter(Mandatory)][string]$Room, [Parameter(Mandatory)][AllowEmptyString()][string]$Agent, [string]$From = '*')
    $inbox = Join-Path $Room "agents\$Agent\inbox"
    if (-not (Test-Path -LiteralPath $inbox)) { return @() }
    return @(Get-ChildItem -LiteralPath $inbox -Filter "$From-*.md" -File | Sort-Object Name | ForEach-Object { $_.Name })
}

function New-RelayTestRoom {
    # A fresh room under $Root with its own machine-state folder; returns what New-RelayRoom returns
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
    param([Parameter(Mandatory)][string]$Root, [string]$RoomId = 'test-room', [object[]]$Agents = @(), [hashtable]$Extra = @{})
    if (-not (Test-Path -LiteralPath $Root)) { $null = New-Item -ItemType Directory -Path $Root -Force }
    if (@($Agents).Count -eq 0) {
        $Agents = @(
            [ordered]@{ name = 'emma'; role = 'tester'; kind = 'generic'; transport = 'same-pc' },
            [ordered]@{ name = 'jack'; role = 'reviewer'; kind = 'generic'; transport = 'same-pc' },
            [ordered]@{ name = 'henry'; role = 'writer'; kind = 'generic'; transport = 'same-pc' }
        )
    }
    $answers = [ordered]@{
        job         = 'Test room'
        room_id     = $RoomId
        rooms_root  = (Join-Path $Root 'rooms')
        authority   = 'within-task'
        coordinator = @{ name = 'olivia'; kind = 'claude-code' }
        agents      = @($Agents)
    }
    foreach ($key in $Extra.Keys) { $answers[[string]$key] = $Extra[$key] }
    $answersFile = Join-Path $Root "answers-$RoomId.json"
    [System.IO.File]::WriteAllText($answersFile, (ConvertTo-Json -InputObject $answers -Depth 8))
    $env:AGENT_RELAY_LOCAL = Join-Path $Root 'local'
    return (& (Join-Path (Get-RelayTestPath scripts) 'New-RelayRoom.ps1') -AnswersFile $answersFile -NoClipboard -PassThru)
}

function Get-RelayTestJoinedName {
    # The name the tool gave a session that ran join, read off its output; empty when it got none
    param([Parameter(Mandatory)]$Result)
    if ($Result.Output -match '=== you are \w+ \(([a-z0-9]+)\), generation') { return $Matches[1] }
    return ''
}

function Get-RelayTestOpenSeat {
    # Names of a room's open seats in the order join hands them out
    param([Parameter(Mandatory)][string]$Room)
    $seats = New-Object System.Collections.Generic.List[object]
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $Room 'agents') -Directory)) {
        $text = [System.IO.File]::ReadAllText((Join-Path $folder.FullName 'seat'))
        if ($text -notmatch '(?m)^open: yes$') { continue }
        $order = 9999
        if ($text -match '(?m)^order: (\d+)$') { $order = [int]$Matches[1] }
        $seats.Add([pscustomobject]@{ Name = $folder.Name; Order = $order })
    }
    return @($seats | Sort-Object Order, Name | ForEach-Object { $_.Name })
}

function Get-RelayTestHostEngine {
    # The engine that matches the PowerShell edition the suite itself runs under
    if ($PSVersionTable.PSVersion.Major -ge 6) { return 'ps7' }
    return 'ps5'
}

function Start-RelayTestScript {
    # Starts one of the coordinator-side scripts as a child process of the same PowerShell edition, with text on
    # its standard input when given. Wait-RelayTool collects it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [AllowEmptyString()][string]$InputText = $null, [hashtable]$Environment = @{})
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path (Get-RelayTestPath scripts) $Script)) + @($Arguments)
    $startInfo.Arguments = (@($all | ForEach-Object { ConvertTo-RelayTestArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    foreach ($key in $Environment.Keys) { $startInfo.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    # Windows PowerShell writes a byte order mark into the child's input when the console input is UTF-8
    $savedEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        $null = $process.Start()
    }
    finally { [Console]::InputEncoding = $savedEncoding }
    $handle = [pscustomobject]@{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
    if ($null -ne $InputText -and $InputText -ne '') {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($InputText)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
    }
    $process.StandardInput.BaseStream.Close()
    return $handle
}

function Invoke-RelayTestScript {
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [AllowEmptyString()][string]$InputText = $null, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 120)
    $handle = Start-RelayTestScript -Script $Script -Arguments $Arguments -InputText $InputText -Environment $Environment
    return (Wait-RelayTool -Handle $handle -TimeoutSeconds $TimeoutSeconds)
}

function Copy-RelayTestRoom {
    # A copy of a prepared room, so every test starts from the same state
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Target)
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force }
    Copy-Item -LiteralPath $Template -Destination $Target -Recurse -Force
    foreach ($lease in @(Get-ChildItem -LiteralPath (Join-Path $Target 'agents') -Recurse -Filter 'wait.lease' -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $lease.FullName -Force }
    # The copy starts with everybody just seen alive, however old the template is: in a slow run a template
    # gets older than the room's silence limit, and every wait would then report a silent coordinator
    $now = [DateTime]::UtcNow
    foreach ($alive in @(Get-ChildItem -LiteralPath (Join-Path $Target 'agents') -Recurse -Filter 'alive' -File -ErrorAction SilentlyContinue)) { $alive.LastWriteTimeUtc = $now }
    return $Target
}
