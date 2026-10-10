#Requires -Version 5.1

<#
.SYNOPSIS
    The owner's voice in a room: a message typed in the chat window, or the answer to a card.

.DESCRIPTION
    Run by the chat window, never by the coordinator. The text is read from standard input (or -TextFile), so
    nothing the owner types passes through a command line. It is written to the owner's log on this PC first
    and then delivered to the coordinator's inbox; the coordinator acts on it only when the log confirms it,
    and passes it on to the agent it is meant for.

.PARAMETER Room
    Room id or room folder.

.PARAMETER For
    The agent the message is meant for (typed as @name in the chat window). The coordinator passes it on.

.PARAMETER Approve
    Id of the card the owner approves. Text is optional.

.PARAMETER Deny
    Id of the card the owner denies. Text is optional.

.PARAMETER Answer
    Id of the card the owner answers in words. Text is required.

.PARAMETER TextFile
    Read the text from this file instead of standard input. A relative path is taken against the PowerShell location.

.EXAMPLE
    'Use the staging share, not production.' | .\Send-RelayOwner.ps1 -Room 2026-10-10-docs -For emma

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only. Output: one line "SENT <id>".
#>

[CmdletBinding(DefaultParameterSetName = 'Message')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(ParameterSetName = 'Message')][string]$For = '',
    [Parameter(Mandatory, ParameterSetName = 'Approve')][string]$Approve,
    [Parameter(Mandatory, ParameterSetName = 'Deny')][string]$Deny,
    [Parameter(Mandatory, ParameterSetName = 'Answer')][string]$Answer,
    [string]$TextFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$roomObject = Resolve-RelayRoom $Room
if (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'CLOSED')) { throw "The room $($roomObject.Id) is closed" }

$text = ''
if ($TextFile) {
    # A relative path is taken against the PowerShell location, once
    $TextFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $TextFile))
    $text = Read-RelayText $TextFile
}
elseif ([Console]::IsInputRedirected) {
    # Bytes, decoded here as UTF-8: the console's input code page must not get a say
    $stream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    $stream.CopyTo($buffer)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($buffer.ToArray())
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
}
$text = ($text -replace "`r", '').Trim()

switch ($PSCmdlet.ParameterSetName) {
    'Message' {
        if (-not $text) { throw 'There is no text to send' }
        $target = $For.Trim().TrimStart('@').ToLowerInvariant()
        if ($target) {
            if (@(Get-RelayRoster $roomObject) -notcontains $target) { throw "There is no active agent '$target' in room $($roomObject.Id)" }
            if ($target -eq $roomObject.Coordinator) { $target = '' }
        }
        $id = Send-RelayOwnerMessage -Room $roomObject -Text $text -For $target
        "SENT $id"
    }
    default {
        $cardId = $Approve
        $decision = 'approved'
        if ($PSCmdlet.ParameterSetName -eq 'Deny') { $cardId = $Deny; $decision = 'denied' }
        if ($PSCmdlet.ParameterSetName -eq 'Answer') { $cardId = $Answer; $decision = 'answered'; if (-not $text) { throw 'An answer needs text' } }
        $card = @(Get-RelayOwnerCard $roomObject | Where-Object { $_.Id -eq $cardId })
        if ($card.Count -eq 0) { throw "There is no card '$cardId' in room $($roomObject.Id)" }
        if (-not $card[0].IsOpen) { throw "The card '$cardId' is already answered ($($card[0].Decision))" }
        $messageDecision = ''
        if ($decision -ne 'answered') { $messageDecision = $decision }
        $body = $text
        if (-not $body) { $body = "$decision`: $($card[0].Subject)" }
        $id = Send-RelayOwnerMessage -Room $roomObject -Text $body -Re $cardId -Decision $messageDecision
        Complete-RelayOwnerCard -Room $roomObject -CardId $cardId -Decision $decision -Via 'chat' -MessageId $id
        "SENT $id"
    }
}
