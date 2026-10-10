#Requires -Version 5.1

<#
.SYNOPSIS
    Writes the byte fixtures of the test suite: message files as other tools and editors might leave them.

.DESCRIPTION
    Every fixture is a message from olivia to emma, named as it must be named in emma's inbox. The suites copy
    them there and check that each engine reads them the same way. Run this again only to change a fixture; the
    files are committed and git does not convert them (see .gitattributes). ASCII only: the non-ASCII
    characters are built from their code points.
#>

[CmdletBinding()]
param([string]$Folder = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bom = [byte[]](0xEF, 0xBB, 0xBF)

function Get-MessageText {
    param([int]$Number, [string]$Type, [string]$Subject, [string]$Body, [string]$Expects = 'none')
    return (@(
            '---'
            ('id: olivia-emma-{0:0000}' -f $Number)
            'from: olivia'
            'to: emma'
            "type: $Type"
            're: '
            "subject: $Subject"
            'sent_utc: 2026-10-10T08:00:00Z'
            "expects: $Expects"
            '---'
            $Body
        ) -join "`n") + "`n"
}

function Save-Fixture {
    param([int]$Number, [string]$Text, [switch]$Crlf, [switch]$WithBom)
    if ($Crlf) { $Text = $Text -replace "`n", "`r`n" }
    $bytes = $utf8.GetBytes($Text)
    if ($WithBom) { $bytes = $bom + $bytes }
    [System.IO.File]::WriteAllBytes((Join-Path $Folder ('olivia-{0:0000}.md' -f $Number)), $bytes)
}

$eAcute = [string][char]0x00E9
$umlaut = [string][char]0x00FC
$enye = [string][char]0x00F1
$kanji = ([string][char]0x65E5) + ([string][char]0x672C)
$emoji = [char]::ConvertFromUtf32(0x1F600)
$euro = [string][char]0x20AC

Save-Fixture 101 (Get-MessageText 101 'note' 'line ends are CRLF' "First line.`nSecond line.`n`nAfter a blank line.") -Crlf
Save-Fixture 102 (Get-MessageText 102 'note' 'file starts with a byte order mark' 'The body after a BOM.') -WithBom
Save-Fixture 103 (Get-MessageText 103 'question' 'BOM and CRLF together' "Does this still parse?`nSecond line." 'reply') -Crlf -WithBom
Save-Fixture 104 (Get-MessageText 104 'note' "non-ASCII: caf$eAcute" "caf$eAcute, M${umlaut}nchen, a${enye}o, $kanji, price 5 $euro, $emoji end")

$special = 'Dollar $HOME and $(sub) and ${brace}; backtick `n `whoami`; pipes a | b || c; quotes "double" and ''single''; percent %PATH%; amp a & b && c; angle <in> >out; bang !history; backslash C:\temp\x; caret ^; tilde ~; star *; hash #; semicolon;'
$builder = New-Object System.Text.StringBuilder
$line = 0
while ($builder.Length -lt 8200) { $line++; $null = $builder.Append(('{0:000} {1}' -f $line, $special)).Append("`n") }
Save-Fixture 105 (Get-MessageText 105 'task' 'eight kilobytes of shell-hostile text' $builder.ToString().TrimEnd() 'reply')

$builder = New-Object System.Text.StringBuilder
$line = 0
while ($builder.Length -lt 8200) { $line++; $null = $builder.Append(('{0:000} second long message, plain filler text to reach the size that makes the tool shorten its output.' -f $line)).Append("`n") }
Save-Fixture 106 (Get-MessageText 106 'note' 'a second eight kilobytes' $builder.ToString().TrimEnd())

Get-ChildItem -LiteralPath $Folder -Filter 'olivia-*.md' | ForEach-Object { '{0}  {1} bytes' -f $_.Name, $_.Length }
