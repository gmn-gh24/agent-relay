#Requires -Version 5.1

<#
.SYNOPSIS
    The coordinator puts a question to the owner as a card, or records that the owner answered one in the session.

.DESCRIPTION
    A card is what the chat window shows with Approve and Deny. It lives on this PC, not in the room. Use it for
    everything beyond the coordinator's authority in this room; ask the owner in the session as well.

    Without -Resolve: opens a card from the draft file (line 1 is the subject, the rest the question; write it
    so the owner can decide without opening anything else). With -Resolve: closes a card the owner answered in
    the session instead of in the chat window.

.PARAMETER Room
    Room id or room folder.

.PARAMETER Re
    Id of the agent's request this card is about.

.PARAMETER DraftFile
    The text of the card. Default: draft.md of this room on this PC (<local>\rooms\<room id>\draft.md, the file the
    coordinator's launcher names as its draft). A file in the room folder is refused: any agent can write there. So
    is a path that leads into the room through a link. A relative path is taken against the PowerShell location,
    once. The file is removed after use.

.PARAMETER Resolve
    Id of the card the owner answered in the session. A card that is already answered is refused: its decision
    stays.

.PARAMETER Decision
    approved, denied, answered or withdrawn.

.EXAMPLE
    .\Request-RelayOwner.ps1 -Room 2026-10-10-docs -Re emma-olivia-0004

.EXAMPLE
    .\Request-RelayOwner.ps1 -Room 2026-10-10-docs -Resolve olivia-owner-0001 -Decision approved

.NOTES
    Windows PowerShell 5.1 syntax, ASCII only.
#>

[CmdletBinding(DefaultParameterSetName = 'Open')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Room,
    [Parameter(ParameterSetName = 'Open')][string]$Re = '',
    [Parameter(ParameterSetName = 'Open')][string]$DraftFile = '',
    [Parameter(Mandatory, ParameterSetName = 'Resolve')][string]$Resolve,
    [Parameter(Mandatory, ParameterSetName = 'Resolve')][ValidateSet('approved', 'denied', 'answered', 'withdrawn')][string]$Decision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RelayCommon.psm1') -Force

$roomObject = Resolve-RelayRoom $Room
if (Test-Path -LiteralPath (Join-Path $roomObject.Canon 'CLOSED')) { throw "The room $($roomObject.Id) is closed" }

if ($PSCmdlet.ParameterSetName -eq 'Resolve') {
    # A card the owner has answered keeps that answer: a denial in the chat window is not turned into an approval
    $card = @(Get-RelayOwnerCard $roomObject | Where-Object { $_.Id -eq $Resolve })
    if ($card.Count -eq 0) { throw "There is no card '$Resolve' in room $($roomObject.Id)" }
    if (-not $card[0].IsOpen) { throw "The card '$Resolve' is already answered ($($card[0].Decision), in the $($card[0].Via)): its decision stays" }
    Complete-RelayOwnerCard -Room $roomObject -CardId $Resolve -Decision $Decision -Via 'session'
    "RESOLVED $Resolve ($Decision, answered in the session)"
    'NEXT: pass the decision on to the agent that waits for it.'
    return
}

# Where the text of a card comes from: this PC, never the room (any agent can write in the room folder)
$DraftFile = Resolve-RelayDraftPath -Room $roomObject -File $DraftFile -What 'card'
$text = (Read-RelayText $DraftFile).Trim()
if (-not $text) { throw "There is nothing to ask: $DraftFile is missing or empty. Write the question there (line 1 = subject) and run this again." }
$lines = @($text -split "`n")
$subject = ConvertTo-RelayHeaderText (($lines[0]) -replace '^\s*#+\s*', '')
if ($subject.Length -gt 120) { $subject = $subject.Substring(0, 120) }
$body = $subject
if ($lines.Count -gt 1) { $body = (($lines[1..($lines.Count - 1)]) -join "`n").Trim() }
if (-not $body) { $body = $subject }
$id = Add-RelayOwnerCard -Room $roomObject -Subject $subject -Body $body -Re $Re
Remove-Item -LiteralPath $DraftFile -Force -ErrorAction SilentlyContinue
"CARD $id opened for the owner: $subject"
'the text of the card, as recorded:'
foreach ($line in @($body -split "`n")) { "  $line" }
'NEXT: ask the owner in the session as well, then carry on with whatever does not depend on the answer.'
