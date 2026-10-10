#Requires -Version 5.1

<#
.SYNOPSIS
    Names the terminal tab an agent runs in. Started by the room tool as a process of its own.

.DESCRIPTION
    An agent runs the room tool with its output caught and on a hidden console, so the tab is not the tool's
    console: it is the console of the highest parent process that has one. Reaching it means leaving one's own
    console and attaching to another, and Windows then replaces the standard output of the process that does
    it. The room tool must never risk its output (a message printed into nowhere is a lost message), so this
    runs apart from it: nothing here prints, and nothing reads what it would print.

    It is given everything through environment variables:
      RELAY_TAB_TITLE    the title to set
      RELAY_TAB_PARENT   the process id of the room tool that started it
      RELAY_TAB_HOLD     1 = keep the title until that process ends. A program that writes its own title puts
                         its own back; this sets it again every two seconds while the agent waits.

    It names a console only while it is sure whose console that is. The start time of the room tool and the start
    time of the process whose console it names are taken with their ids; before every attach, and again before
    the title is set, both processes must still exist with those start times. Else it ends, and it sets no title
    before the first of these checks: a process number that went to another process is not the one named.

    Best effort and silent: any failure ends it.

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

$ErrorActionPreference = 'Stop'
try {
    # Started from PowerShell 7, Windows PowerShell would look for its own modules in the wrong place
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $env:PSModulePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') + ';' + (Join-Path $PSHOME 'Modules')
    }
    $title = [string]$env:RELAY_TAB_TITLE
    $parentId = 0
    $null = [int]::TryParse([string]$env:RELAY_TAB_PARENT, [ref]$parentId)
    $hold = ([string]$env:RELAY_TAB_HOLD -eq '1')
    if (-not $title -or $parentId -le 0) { exit 0 }
    $parent = Get-Process -Id $parentId -ErrorAction Stop
    $parentStarted = $parent.StartTime

    function Test-RelayTabProcess {
        # True while the process with that id is running and started when it did
        param([int]$ProcessId, [datetime]$Started)
        if ($ProcessId -le 0) { return $false }
        $found = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $found -or $found.HasExited) { return $false }
        try { return ($found.StartTime -eq $Started) } catch { return $false }
    }

    Add-Type -Namespace RelayRoom -Name TabConsole -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetConsoleTitleW(System.Text.StringBuilder lpConsoleTitle, uint nSize);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool SetConsoleTitleW(string lpConsoleTitle);
'@
    $api = [RelayRoom.TabConsole]

    # Upwards from the room tool until a parent has no console (the terminal program itself): the last one that
    # had one holds the tab's console
    $target = 0
    $targetStarted = [datetime]::MinValue
    $current = $parentId
    for ($level = 0; $level -lt 12 -and $current; $level++) {
        $null = $api::FreeConsole()
        if (-not (Test-RelayTabProcess $parentId $parentStarted)) { break }
        $started = [datetime]::MinValue
        try { $started = (Get-Process -Id $current -ErrorAction Stop).StartTime } catch { $null = $_ }
        if ($api::AttachConsole([uint32]$current)) {
            # Not sure whose console that is: the one found before, if any, is the tab's
            if (-not (Test-RelayTabProcess $current $started)) { break }
            $target = $current
            $targetStarted = $started
        }
        elseif ($target) { break }
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$current" -Property ProcessId, ParentProcessId -ErrorAction Stop
        if ($null -eq $process -or -not $process.ParentProcessId -or $process.ParentProcessId -eq $current) { break }
        $current = [int]$process.ParentProcessId
    }
    $null = $api::FreeConsole()
    if (-not $target) { exit 0 }

    if ($targetStarted -eq [datetime]::MinValue) { exit 0 }
    while ($true) {
        # The room tool that asked for this, and the process whose console is named, are still the ones they
        # were (a number that went to another process is not): else this ends, before any attach
        if (-not (Test-RelayTabProcess $parentId $parentStarted)) { break }
        if (-not (Test-RelayTabProcess $target $targetStarted)) { break }
        if (-not $api::AttachConsole([uint32]$target)) { break }
        # The attach took a moment: once more before the title is touched
        if ((Test-RelayTabProcess $parentId $parentStarted) -and (Test-RelayTabProcess $target $targetStarted)) {
            $buffer = New-Object System.Text.StringBuilder 512
            $null = $api::GetConsoleTitleW($buffer, 512)
            if ($buffer.ToString() -ne $title) { $null = $api::SetConsoleTitleW($title) }
        }
        $null = $api::FreeConsole()
        if (-not $hold) { break }
        Start-Sleep -Seconds 2
    }
}
catch { $null = $_ }
exit 0
