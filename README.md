# agent-relay

A Claude Code plugin that lets one session coordinate any number of other coding agents: on the same PC, on
other machines through a shared folder, or (planned) over SSH. The other agents can be Claude Code, Codex CLI,
Gemini CLI, Cursor, Copilot or anything else that can run a command and write a file. They do not need the
plugin: each gets one prompt and one command.

Use it to offload development work, run tests or debug on another machine, research, update documentation,
or have work reviewed in parallel, while one session hands out the tasks, answers questions, approves or
denies what goes beyond an assignment, and keeps a record.

## How it works

One job has one shared folder, the **room**. Every agent has a folder in it with its instructions, its
assignment and its inbox. A message is one Markdown file. Two small tools in the room (`relay.ps1` for
Windows PowerShell and PowerShell 7, `relay.sh` for POSIX sh) do everything an agent needs: introduce itself,
wait for messages, send, report.

- **Introductions first.** An agent's first command records where it runs (computer, address, user,
  elevation, shell, host application) and what it is (product, model, effort), and sends that to the
  coordinator. Nobody gets work before that.
- **One prompt for everybody.** A room can have open seats. The same join prompt is pasted into every agent;
  each takes the next free seat and gets a name. Agents can also be named in advance, each with its own prompt.
- **No text on a command line.** A message is written into a draft file; the verbs take single plain words.
- **Every output ends with `NEXT:`**, so an agent with little context still knows what to do.
- **Staying in scope.** Each assignment lists the task, the folders, what may be changed, what must be asked
  first and what is never allowed. Four tiers: just do it, do and tell, announce then proceed, ask first.
  A report carries a self-audit of what changed in the assigned folders.
- **Working as a team.** A job can be split into parts with one owner each. The room then has a plan every
  agent can read (`team`): who owns which part, what it depends on, who reviews it, where everybody stands.
  Owners of parts that depend on each other, and an owner and its reviewer, write to each other directly; a
  one-line `progress` tells the team where an agent stands without waking anybody.
- **A machine is in use unless the owner says otherwise.** No restart, install or system change without
  approval. "Disposable" is declared per machine and per job, and is never remembered.
- **The owner outranks everyone.** The coordinator asks the owner for what is beyond its authority. What the
  owner says in the room is logged on the coordinator's PC and checked against that log.
- **Tamper check.** The coordinator's PC keeps its own copy of the tools, wrappers, instructions and standing
  rules, compares every 15 seconds, restores what changed and raises an alarm.

It is not a sandbox: scope is kept by instruction, evidence and review.

## Requirements

- The coordinator: Claude Code on Windows with PowerShell 7 (`pwsh`) or Windows PowerShell 5.1.
- Other agents on Windows: Windows PowerShell 5.1 (part of Windows). On Linux or macOS: `sh`.
- A folder every agent can reach.

## Install

From a clone of this repository, loaded in place (edits apply after `/reload-plugins`):

```
claude plugin marketplace add <path of the clone>
claude plugin install agent-relay@agent-relay
```

For one session only: `claude --plugin-dir <path of the clone>`.

## Use

Tell Claude Code what you want, for example: "start a relay room for the import tests, two agents will join
from the build machines". The skill asks what it needs, builds the room, and hands you the prompt to paste
into the other agents. In the coordinator's session `/relay <room id>` opens the room as a pane: the agents,
the plan, the conversation and what waits on you. To watch the conversation in any terminal:

```
pwsh -File skills\agent-relay\scripts\Watch-RelayFeed.ps1 -Room <room id> -Follow
```

## Layout

```
.claude-plugin/                     plugin and marketplace manifests
skills/agent-relay/SKILL.md         the coordinator skill
skills/agent-relay/references/      interview, coordinating, protocol, transports, agent kinds, lessons
skills/agent-relay/scripts/         coordinator side (PowerShell): rooms, agents, board, feed, close, statistics
skills/agent-relay/assets/room-package/   what every room gets: tools, templates, protocol reference
hooks/, types/                      the room pane in the coordinator's session
tests/                              Pester suites and byte fixtures; Invoke-AllTests.ps1 is the gate
evals/                              eval cases for the skill (claude plugin eval)
```

State that belongs to one PC (known shares and machines, the room index, canonical copies, the owner's log,
archives) lives in `.local/` and is not in git.

## Tests

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1
```

PSScriptAnalyzer without findings, ASCII only, LF line ends, `relay.sh` syntax, then Pester 6: the room tools
on three engines (PowerShell 7, Windows PowerShell 5.1, dash), one run per test file and engine side by side,
and the coordinator scripts under both PowerShell editions. `relay.sh` starts many processes, which is slow
on Windows: its runs set the length of the gate (about an hour). `-ShellRuns` and `-PowerShellRuns` say how
many runs go side by side; the sh runs default to two, because each takes memory for as long as it runs.

The room pane has its own tests (`claude plugin test .`), and the skill has eval cases:

```
claude plugin eval . --no-publish
```

Three requests that must load the skill without naming it, two that must not (plain work in the session, a
subagent of the session), and one that checks what the coordinator does before it builds anything: it asks how
the other machine may be treated and how far it may decide alone, and claims nothing it did not do. The cases
grant no shell, so no script runs and no room is touched. Each run is a full headless session on your
account; `--no-publish` keeps the report, which holds the transcripts, on this PC (`evals/results/`, not in
git).

## Status

Built and tested: protocol 3, both room tools, rooms with named agents and open seats, the team plan, the
board, the feed, the owner's messages and cards, standing rules, the tamper check, closing with transcript and
statistics. The room pane uses Claude Code's plugin hooks, which are early access: the feed in a terminal
shows the same.

Not built yet: the SSH bridge. Agent kinds other than Claude Code and Codex CLI run on a generic profile until
they have worked a room (`skills/agent-relay/references/agent-kinds.md`).
