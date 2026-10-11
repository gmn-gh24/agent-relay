# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin (`agent-relay`) that lets one session (the "coordinator") hand out work to any number of other
coding agents through a shared folder (a "room"). There is no build step and no package manager: the product is
PowerShell scripts, one room tool (`relay.ps1`), Markdown instructions, and a TypeScript pane. There is no sh
tool: see "One room tool; no sh" below.
`README.md` is the user-facing document; read its "How it works" and "Security model" sections first.

## Commands

All from the repo root, in `pwsh`. Start tests from a folder on a local disk (Pester 6 fails on network paths).

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1                  # the full gate: static, pane, ps7 and ps5 runs
pwsh -NoProfile -File tests\Invoke-AllTests.ps1 -StaticOnly      # seconds: PSScriptAnalyzer, ASCII/LF, wrapper templates parse, test files listed
pwsh -NoProfile -File tests\Invoke-AllTests.ps1 -Editions ps7    # the gate with one edition's Pester runs (CI runs ps7 and ps5 as two jobs)
pwsh -NoProfile -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines ps7 -Label 'Faults ps7'   # one file, one engine
claude plugin validate .        # manifests and hooks module
claude plugin test .            # the pane's tests (hooks/feed.test.ts)
claude plugin eval . --no-publish   # the skill's cases in evals/; each run is a full headless session on the account
```

- Engines are `ps7` and `ps5`. The four tool test files (`Tool`, `Team`, `Faults`, `Parity`) run once per engine;
  the five script files (`Scripts`, `Plan`, `Guard`, `Owner`, `Gate`) take no `-Engines`. `RELAY_TEST_ENGINES=ps7`
  narrows a run. `ps5` must be started from `powershell.exe`, `ps7` from `pwsh`. The gate runs both (`ps5` on
  Windows only).
- The gate fails without PSScriptAnalyzer or Claude Code unless `-SkipAnalyzer` / `-SkipPane` is given. The
  `ps7` suites also run on Linux and macOS (a few tests expect Windows paths or `cmd.exe` and fail there).
- Pester 6 calls no original command for a call that no `Mock -ParameterFilter` matches: give a filtered mock a
  default mock beside it.
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
   `PROTOCOL.md`, and `*.tmpl` files expanded per room/agent/seat (`Expand-RelayTemplate`).
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
- Nothing follows a link in the room: an agent can put a symbolic link or a junction anywhere in it. The module
  lists with `Get-RelayFileTree`, checks paths with `Test-RelayLinkedPath` and deletes with `Remove-RelayTree`;
  `relay.ps1` refuses a draft, an attach folder or a file of its own that is a link.

### One room tool; no sh (owner decision, final)

`relay.ps1` (PowerShell 7 and Windows PowerShell 5.1) is the only room tool. Agents run on Windows and call it
through their wrapper from PowerShell, cmd or Git Bash (`powershell -File` on the `.ps1` wrapper); an answers
file with `os` other than `windows` or `shell: sh` is refused. `ssh` is refused as a transport.

**There is no sh implementation, and none is planned.** `relay.sh`, the sh wrappers, the sh engine of the tests
and the sh line of the join prompt were removed in 0.2.0. The owner has postponed sh (and ssh) indefinitely: it
will be designed, built and tested if and when the need and the time come, at the owner's word. Until then do not
plan, propose, write or test sh work, do not add sh branches "for later", and do not ask the owner about it again.
Rooms made before 0.2.0 keep the sh files their canonical copy holds; nothing migrates them.

`Relay.Parity.Tests.ps1` pins literal expected lines; `scripts/Test-RelayPackage.ps1` has both PowerShell
engines converse in one room. `RELAY_PAUSE_AT`/`RELAY_PAUSE_DIR` are pause points that `Relay.Faults.Tests.ps1`
uses to force races; renaming one makes the gate fail on purpose.

## Conventions the gate enforces or relies on

- **ASCII only in every file**, Markdown and this file included (the static check fails on any byte over 127), and
  **LF line ends** (CRLF only for `*.cmd`/`*.bat`). `tests/fixtures/*.md` are byte fixtures: never reformat them.
- Scripts must run on **Windows PowerShell 5.1**: no `&&`, `||`, `?:`, `??`, no PS7-only cmdlet parameters.
- Text that is parsed is compared ordinally: `IndexOf([char]':')`, `StartsWith('x', [StringComparison]::Ordinal)`,
  `-c` operators where the other reader is exact. String `IndexOf`/`StartsWith`/`EndsWith` follow the culture,
  and under th-TH `"a: b".IndexOf(':')` is 0. Time stamps go through `Format-RelayUtc` (invariant culture).
  `Set-StrictMode -Version Latest` is on, so initialise every variable. PSScriptAnalyzer must report no
  Error/Warning (only `PSAvoidUsingWriteHost` is excluded); justified exceptions use `SuppressMessageAttribute`.
- Tests are Pester 6 and run real child processes per engine. Every fix comes with a test that fails without it.
- No real machine, share, address or account name in a committed file (`.local/` and `history/` are gitignored for
  that reason).
- A release bumps `version` in `.claude-plugin/plugin.json` **and** the table in `README.md`, bumps
  `room-package/VERSION` only when the package changed, and adds a `CHANGELOG.md` entry. Lessons from real rooms go
  in `references/lessons.md` (`references/self-improvement.md` is the procedure). Push only when the owner says so.
