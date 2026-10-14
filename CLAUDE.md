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
pwsh -NoProfile -File tests\Invoke-AllTests.ps1 -Editions ps7    # the gate with one edition's Pester runs (CI runs neither; the Pester runs are done on a dev machine)
pwsh -NoProfile -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines ps7 -Label 'Faults ps7'   # one file, one engine
claude plugin validate .        # manifests and hooks module
claude plugin test .            # the pane's tests (hooks/feed.test.ts)
claude plugin eval . --no-publish   # the skill's cases in evals/; each run is a full headless session on the account
```

- Engines are `ps7` and `ps5`. The four tool test files (`Tool`, `Team`, `Faults`, `Parity`) run once per engine;
  the eight script files (`Scripts`, `Plan`, `Guard`, `Owner`, `Gate`, `Memory`, `Reopen`, `Integrity`) take no `-Engines`. `RELAY_TEST_ENGINES=ps7`
  narrows a run. `ps5` must be started from `powershell.exe`, `ps7` from `pwsh`. The gate runs both (`ps5` on
  Windows only).
- The gate fails without PSScriptAnalyzer or Claude Code unless `-SkipAnalyzer` / `-SkipPane` is given. The
  `ps7` suites also run on Linux and macOS (a few tests expect Windows paths or `cmd.exe` and fail there).
- Pester 6 calls no original command for a call that no `Mock -ParameterFilter` matches: give a filtered mock a
  default mock beside it.
- A new test file must also be added to `$toolFiles` or `$scriptFiles` in `tests/Invoke-AllTests.ps1`, or the gate
  never runs it.
- **No Windows jobs in CI (owner decision).** GitHub Actions runs only the Linux static and pane jobs. The Pester
  runs (ps7 and ps5) are done locally on a Windows dev machine before a commit. Do not add a Windows runner or
  a Pester job to `.github/workflows/ci.yml`, and say in the PR's Gate section which edition runs were done locally.
  **A Claude session without Windows (a cloud or Linux session) cannot run the Pester files, so it must ask the
  owner to run them on a Windows machine, and must not push or call a change done before it has the result.** Ask
  with the exact command (`pwsh -NoProfile -File tests\Invoke-AllTests.ps1`, or `-Editions ps7` plus
  `powershell.exe -File ... -Editions ps5` for one edition, or the one affected file through `Invoke-Suite.ps1`),
  say which files changed and what to look at, and put the RESULT lines the owner sends back in the PR's Gate
  section. What a session can run itself, it runs first: `-StaticOnly` (on Linux too, with PSScriptAnalyzer).
- Iterate with `-StaticOnly` plus the one affected file on the one affected engine; run the whole gate before a commit.
- Cloud (Linux) sessions: the proxy blocks the PowerShell Gallery (`Install-Module` fails), nuget.org and
  github.com release assets and git reads are open. Put each module under
  `~/.local/share/powershell/Modules/<Name>/<version>/`:
  - `pwsh`: the `powershell-<v>-linux-x64.tar.gz` of a PowerShell GitHub release, unpacked anywhere, `chmod +x`.
  - Pester: `https://api.nuget.org/v3-flatcontainer/pester/<v>/pester.<v>.nupkg` (a zip; the module files are
    under `tools/`).
  - PSScriptAnalyzer is on neither. The VS Code PowerShell extension bundles it:
    `https://github.com/PowerShell/vscode-powershell/releases/download/v<tag>/powershell-<tag>.vsix` (a zip,
    `git ls-remote --tags https://github.com/PowerShell/vscode-powershell` lists the tags; take a stable one),
    module under `extension/modules/PSScriptAnalyzer/<v>/`.
  A Linux session can run `-StaticOnly` with the analyzer and the `ps7` suites for a first look (a few tests expect
  Windows paths or `cmd.exe` and fail there), and smoke-test a module change directly with `Import-Module`; the
  gate's result is the owner's Windows run, as above.

## Architecture

Three parts that share a protocol (protocol 3, see `PROTOCOL.md`; `skills/agent-relay/assets/room-package/VERSION`
is the package version, a different number):

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
  match this PC's owner log, and the coordinator's own messages only when they match `sent.log`, which its tool
  writes through the launcher. See `Get-RelayRoomObject` / `Resolve-RelayRoom`.
- Files that only the coordinator may write (tools, wrappers, instructions, plan, rules, markers) go through
  `Write-RelayGuardedText` / `Copy-RelayGuardedFile`: canon first, room second. `Test-RelayTamper` (run every
  15 s by the feed) compares them, restores changes, and quarantines strangers. A new guarded file needs no extra
  registration; a new *kind* of stranger to detect does (see its candidate list).
- The feed is the tamper check, and it stops when the coordinator's session stops. Two stamps say whether it runs:
  `feed.state` in `<local>\rooms\<id>\` (what the board's first line, the coordinator's NO FEED block and its
  `wait` decide by; the launcher names it in `RELAY_FEED_STATE`) and `agents\<coordinator>\integrity` in the room
  (only a hint for the agents: anybody can write it). Files agents write for themselves (`memory`, `journal`, `card`,
  inboxes) have no canonical copy and are not covered; `references/protocol.md` ("What the tamper check covers")
  says exactly what is.
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
  A push to `main` whose `plugin.json` version has no tag yet gets the tag `v<version>` and a GitHub Release with
  that version's CHANGELOG section (`.github/workflows/release.yml`); no tag is made by hand, and a version
  without its CHANGELOG section fails that run.
- **No session links in commits, pull requests or comments (owner decision).** Do not add a `Claude-Session:` trailer
  or any `claude.ai/code/session_...` link to a commit message, pull request description or comment, and remove one
  that a tool added before the commit or push. Cloud sessions add it by default: strip it each time
  (`git log --format=%B | grep claude.ai/code/session` must print nothing).
- **Every change reaches `main` through a pull request (owner decision).** In this repository "commit and
  push" means: a branch, a commit, a push of the branch and a pull request; never a commit on `main` pushed
  to `main`, also for a change of one line or of documentation only. The rule for solo repositories in the
  owner's own instructions (commit on `main`, push `main`) does not hold here. Copilot reviews a pull request
  and nothing else: wait for its review, read it (`gh api repos/<owner>/<repo>/pulls/<n>/reviews` and
  `.../pulls/<n>/comments`; the summary can recommend changes with no finding on a line), fix or answer what it
  says, and merge after that, not before. Before the branch is made, and again before the merge, fetch and
  check that `main` has not moved: another session may have released in between, and the version is the next
  free one.

## Time zone

The owner works in Eastern Time: Windows zone id `Eastern Standard Time`, IANA `America/New_York`. That one id
covers both halves of the year: EST (UTC-5) in winter and EDT (UTC-4) in summer, so never assume a fixed offset.

- Times reported to the owner (CI runs, commits, pull requests, releases, room messages) are given in Eastern
  Time with the abbreviation in force on that date, for example `14:32 EDT`. `gh` and the GitHub API answer in
  UTC (`2026-10-11T18:32:00Z`): convert before reporting, and do not pass a UTC time off as local.
- Convert with the zone, not by subtracting hours:
  `[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::Parse($utc).ToUniversalTime(), 'Eastern Standard Time')`
- This is about what the owner reads. Stamps the code writes (messages, logs, the feed) stay UTC through
  `Format-RelayUtc`, and nothing in a script or a test may depend on the PC's zone.
