# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin (`agent-relay`) that lets one session (the "coordinator") hand out work to any number of other
coding agents through a shared folder (a "room"). There is no build step and no package manager: the product is
PowerShell scripts, two room tools (`relay.ps1` / `relay.sh`), Markdown instructions, and a TypeScript pane.
`README.md` is the user-facing document; read its "How it works" and "Security model" sections first.

## Commands

All from the repo root, in `pwsh`. Start tests from a folder on a local disk (Pester 6 fails on network paths).

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1                  # the full gate; takes the better part of an hour
pwsh -NoProfile -File tests\Invoke-AllTests.ps1 -StaticOnly      # seconds: PSScriptAnalyzer, ASCII/LF check, dash -n on relay.sh
pwsh -NoProfile -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines sh -Label 'Faults sh'   # one file, one engine
claude plugin validate .        # manifests and hooks module
claude plugin test .            # the pane's tests (hooks/feed.test.ts)
claude plugin eval . --no-publish   # the skill's cases in evals/; each run is a full headless session on the account
```

- Engines are `ps7`, `ps5`, `sh`. The four tool test files (`Tool`, `Team`, `Faults`, `Parity`) run once per engine;
  the four script files (`Scripts`, `Plan`, `Guard`, `Owner`) take no `-Engines`. `RELAY_TEST_ENGINES=sh` narrows a
  run. `ps5` must be started from `powershell.exe`, the other two from `pwsh`.
- A new test file must also be added to `$toolFiles` or `$scriptFiles` in `tests/Invoke-AllTests.ps1`, or the gate
  never runs it.
- Iterate with `-StaticOnly` plus the one affected file on the one affected engine; run the whole gate before a commit.

## Architecture

Three parts that share a protocol (currently 3, `skills/agent-relay/assets/room-package/VERSION`):

1. **Coordinator side** - `skills/agent-relay/SKILL.md` + `references/*.md` + `scripts/*.ps1`. The SKILL is the
   coordinator's operating manual (seven workflows); the scripts do the work and all import
   `scripts/RelayCommon.psm1` (room index, guarded files, tamper check, message parsing, board, name pool, seat
   and prompt generation). Small data tables live in `scripts/*.json` (agent kinds, model tiers, work kinds, names).
   Editing SKILL.md or a reference changes how the coordinator behaves; `evals/` holds cases (prompt + graders)
   for when it must or must not load.
2. **Room package** - `skills/agent-relay/assets/room-package/` is what every new room gets: `tools/relay.ps1`,
   `tools/relay.sh`, `PROTOCOL.md`, and `*.tmpl` files expanded per room/agent/seat (`Expand-RelayTemplate`).
   Agents never see the SKILL or the scripts, only this package and one start prompt. A room keeps the package it
   was created with; `Update-RelayRoom.ps1` upgrades a running room.
3. **Pane** - `hooks/register.tsx` (command `/relay`, tool `relay_bind`, engine integration), `hooks/feed.ts` (pure
   transform: feed JSON lines in, view out), `types/index.d.ts` (shared types and `PluginState`). The pane spawns
   `Watch-RelayFeed.ps1 -Json -EndWithParent`; that JSON is the contract. A field added to the feed means touching
   `Watch-RelayFeed.ps1`, the `to*` functions in `feed.ts`, `types/index.d.ts`, and `feed.test.ts`. `feed.ts`
   strips control characters from everything an agent wrote.

### The trust boundary (the thing most likely to be broken by accident)

Every agent can write every file in a room folder, so **nothing the coordinator's PC decides by comes from the room**.
Per-room state lives in `<local>\rooms\<id>\` (`canon\`, `owner\`, alarms, quarantine), where `<local>` is `.local/`
in a working copy, `%LOCALAPPDATA%\agent-relay` for an installed copy, or `AGENT_RELAY_LOCAL` (the tests set it).

- Which rooms exist: `rooms.json` in `<local>`, never a folder scan. What a room is (`ROOM`, `CLOSED`, settings,
  retired state, generation): the **canon** copy, never the file in the room. Owner messages count only when they
  match this PC's owner log. See `Get-RelayRoomObject` / `Resolve-RelayRoom`.
- Files that only the coordinator may write (tools, wrappers, instructions, plan, rules, markers) go through
  `Write-RelayGuardedText` / `Copy-RelayGuardedFile`: canon first, room second. `Test-RelayTamper` (run on every
  feed round) compares them, restores changes, and quarantines strangers. A new guarded file needs no extra
  registration; a new *kind* of stranger to detect does (see its candidate list).
- Message text never travels on a command line: it is written to a draft file and the verb takes plain words.

### Two tools, one behaviour

`relay.ps1` (PowerShell 7 and Windows PowerShell 5.1) and `relay.sh` (POSIX sh, run under dash on Windows) must
behave identically, including printed lines and the closing `NEXT:` line. A change to one is a change to the
other, with a test on every engine. `Relay.Parity.Tests.ps1` pins literal expected lines;
`scripts/Test-RelayPackage.ps1` has all three engines converse in one room. `RELAY_PAUSE_AT`/`RELAY_PAUSE_DIR` are
pause points that `Relay.Faults.Tests.ps1` uses to force races; renaming one makes the gate fail on purpose.

## Conventions the gate enforces or relies on

- **ASCII only in every file**, Markdown and this file included (the static check fails on any byte over 127), and
  **LF line ends** (CRLF only for `*.cmd`/`*.bat`). `tests/fixtures/*.md` are byte fixtures: never reformat them.
- Scripts must run on **Windows PowerShell 5.1**: no `&&`, `||`, `?:`, `??`, no PS7-only cmdlet parameters.
  `Set-StrictMode -Version Latest` is on, so initialise every variable. PSScriptAnalyzer must report no
  Error/Warning (only `PSAvoidUsingWriteHost` is excluded); justified exceptions use `SuppressMessageAttribute`.
- Tests are Pester 6 and run real child processes per engine. Every fix comes with a test that fails without it.
- No real machine, share, address or account name in a committed file (`.local/` and `history/` are gitignored for
  that reason).
- A release bumps `version` in `.claude-plugin/plugin.json` **and** the table in `README.md`, bumps
  `room-package/VERSION` only when the package changed, and adds a `CHANGELOG.md` entry. Lessons from real rooms go
  in `references/lessons.md` (`references/self-improvement.md` is the procedure). Push only when the owner says so.
