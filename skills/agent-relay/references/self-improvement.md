# Self-improvement

The plugin changes itself after every room and after every failure. The rule that keeps this safe: a change
is committed only when the test gate passes, and the owner is told what changed.

## Where it runs

Only in the plugin's working copy (a git repository). `scripts/Get-RelayRooms.ps1` says which copy this is.
An installed copy cannot improve itself: tell the owner that the lesson is waiting, and write it into the
room's retro notes on this PC instead. The same holds for a promotion to project lessons: without a git
working copy it falls back to local memory (`scripts/Add-RelayLocalMemory.ps1`).

## The room's improvements file

Closing a room includes writing its dated section into `PLUGIN-IMPROVEMENTS.md`, in the job's project folder
(SKILL.md, "6. Close", a mandatory step before `Close-RelayRoom.ps1`). The coordinator writes the section into
its draft on this PC and runs `scripts/Add-RelayImprovement.ps1 -Room <id>` (with `-ProjectFolder <folder>`
when the room's answers name none): it appends the section and records it on this PC, and
`Close-RelayRoom.ps1` refuses to close without that record. The Improve procedure reads that file first,
before the retro below: every item in it is a finding with its evidence and a proposed change. After the
owner's choice, mark each item **done**, **roadmap** or **discarded**, and what was done points at the commit.

## The retro

1. `scripts/Get-RelayStats.ps1 -Room <id>`: reply times, requests never answered, questions asked twice,
   changes outside assigned paths, alarms, time lost to dead waits and to agents that went silent on a task,
   and each agent's `bye` with what slowed it down. For a room whose folder was deleted at close the script reads
   `stats.json` on this PC, which the close saved.
2. Read the transcript where a number looks bad. Look for: a prompt or instruction an agent misread; a
   `NEXT:` line that did not say enough; a question the assignment should have answered; an approval that had
   to go to the owner and could have been a rule; a wait that cost turns; an introduction that surprised.
3. For each finding decide: is it the package (tools, templates, protocol reference), the skill text, a
   reference file, an agent-kind profile, or the scripts? One finding, one cause, one change.

## Triage with the owner

Do not implement every finding. Sort them, then let the owner choose per group.

1. Give every finding a class: **quick fix** (minutes each, safe right after a close: skill or reference text, a
   template line, a small script change with a test), **roadmap** (needs design or a session of its own),
   **lesson only** (a line in `references/lessons.md`, no code).
2. Put them into groups the owner can judge in one go (integrity, paths and prompts, exits, asking the owner,
   coordinator guidance, bugs, agent kinds), each with its findings, the evidence and what you propose.
3. Ask the owner through the question tool, one question per group, with the choices **implement now**, **to the
   roadmap**, **defer or discard** (and the reasons in the description). Never as numbered prose to answer by
   typing.
4. Implement only what the owner chose, behind the gate (below). What goes to the roadmap is written into
   `ROADMAP.md` with enough context to start cold in a later session: what happened, the evidence, the proposed
   direction and the open questions. What the owner discards is dropped, and the lesson says so.
5. If an item chosen for "now" turns out to need design, stop on that item, move it to the roadmap with what
   you found, and say so. One item must not hold the pass.
6. End with a table of every finding: done, on the roadmap, in lessons, or discarded.

## Lessons

Add each finding to `references/lessons.md`: date, what happened in general terms, what was changed. No
machine names, no share names, no addresses, no user names, no task content: the file is committed. A lesson
that only says "be careful" is not a lesson; it names the change that makes care unnecessary, or says plainly
that none was found.

## Promotions from room memory

At close the coordinator curates the room's memory and the owner approves what is promoted
(`references/room-memory.md`). An item approved for project lessons becomes a lesson like any
other: rewritten in the coordinator's own words, dated, with the same anonymisation (no machine, share,
address, user or task content), and it names what changed or says plainly that nothing could. An item approved
for local notes goes in with `scripts/Add-RelayLocalMemory.ps1` and is never committed. Nothing is promoted
that the owner did not approve in that session.

## What may change

| May change freely | Needs the owner first |
|---|---|
| Wording of prompts, templates, `NEXT:` lines, references, this skill | The four approval tiers and what "ask first" covers |
| Agent-kind profiles and their status lines | Anything that lets an agent do more without asking |
| Bug fixes in tools and scripts, with a test that fails before and passes after | The protocol number, or a change old rooms cannot read |
| New tests, new byte fixtures | Removing the tamper check, the secret block or the introduction rule |
| Lessons | Pushing, publishing, or installing anything |
| Eval cases and their graders | The rule that the room is the coordinator's only channel to an agent, the guard that holds it, and what counts as an exception |

## The gate

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1
```

Static checks (PSScriptAnalyzer without findings, ASCII only, LF line ends, the wrapper templates parse, every
test file listed), the pane's checks (`claude plugin validate`, `claude plugin test`), then Pester 6: the room
tool and the coordinator scripts under PowerShell 7 and Windows PowerShell 5.1. A tool change also runs
`scripts/Test-RelayPackage.ps1` (the engines talk to each other in one room). There is no `sh` tool and no
`sh` test: the owner has postponed sh (and ssh). A lesson that would need one is recorded with "Not changed:
sh is postponed", and nothing is built for it.

## Commit

1. Bump `version` in `.claude-plugin/plugin.json`, and `assets/room-package/VERSION` when the package
   changed (patch for fixes and wording, minor for new behaviour).
2. Add a `CHANGELOG.md` entry: date, version, what changed and why, in the reader's terms.
3. Commit in the working copy. One retro, one commit. Push only when the owner has said so.
4. Tell the owner: what was learned, what changed, what the gate said.

When the gate fails: revert the change, keep the lesson, and write into it that the fix did not hold and why.

## Rooms in flight

A room keeps the package it was created with. `scripts/Update-RelayRoom.ps1 -Room <id>` brings a running
room's tools up to date when a fix cannot wait for the next room; tell its agents in a note what changed for
them.
