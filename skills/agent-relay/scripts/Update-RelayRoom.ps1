#Requires -Version 5.1

<#
.SYNOPSIS
    Brings the tools of a running room up to this plugin's package.

.DESCRIPTION
    A room keeps the package it was created with: tools, protocol reference, agent-kind table, join wrappers.
    This script replaces them with the current ones, canonical copy first, so the tamper check agrees. Use it
    when a fault in the tools was fixed while a room is running. It writes again, from the package's templates:
    the tools, PROTOCOL.md, the agent-kind table, the join wrappers and PROMPT-JOIN.txt, every agent's wrappers,
    every agent's START-HERE.md and ASSIGNMENT.md (from the answers its seat was built from; the coordinator's
    instructions are not rewritten), and the coordinator's launcher on this PC. The package version in ROOM is
    recorded. Not touched: the agents' names, generations, messages, tasks, state and the files in work\ and
    files\. A command that is running at that moment (a wait) finishes with the tool it started with; every
    later command uses the new one. An agent reads its new instructions at its next start.
.PARAMETER Room
    Room id or room folder.

.EXAMPLE
    .\Update-RelayRoom.ps1 -Room 2026-10-10-docs

.EXAMPLE
    .\Update-RelayRoom.ps1 -Room 2026-10-10-docs -WhatIf

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$roomObject = Resolve-RelayRoom $Room
if ($roomObject.IsClosed) { throw "The room $($roomObject.Id) is closed" }
$changed = @(Update-RelayRoomPackage -Room $roomObject -WhatIf:$WhatIfPreference)
if ($WhatIfPreference) { return }
if ($changed.Count -eq 0) { "UP TO DATE: room $($roomObject.Id) already has this package"; return }
"UPDATED room $($roomObject.Id): " + ($changed -join ', ')
'NEXT: tell the agents in a note what changed for them, if anything did. A wait that is running now finishes with the old tool.'
