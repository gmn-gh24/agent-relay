<div align="center">

<h1>agent-relay</h1>

<p><strong>Many agents. One room. You decide.</strong></p>

<p>Coordinate any number of coding agents from one Claude Code session: hand out tasks, answer questions,<br>
approve or deny what goes beyond an assignment, and keep a record of all of it.</p>

<p>
<a href="CHANGELOG.md"><img alt="Version 0.10.0" src="https://img.shields.io/badge/version-0.10.0-blue"></a>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green"></a>
<a href="https://github.com/gmn-gh24/agent-relay/actions/workflows/ci.yml"><img alt="CI status" src="https://github.com/gmn-gh24/agent-relay/actions/workflows/ci.yml/badge.svg"></a>
<img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-orange">
<img alt="PowerShell 5.1 and 7" src="https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE">
</p>

**[Why](#why)** | **[How it works](#how-it-works)** | **[Install](#installation)** | **[Quick start](#quick-start)** | **[Usage](#usage)** | **[Reference](#reference)**<br>
**[Security](#security-model)** | **[FAQ](#faq)** | **[Troubleshooting](#troubleshooting)** | **[Development](#development)** | **[Status](#status-and-limitations)** | **[Roadmap](ROADMAP.md)**

</div>

---

<table align="center">
<tr>
<td align="center"><h3>Any number of agents</h3>1 prompt to paste</td>
<td align="center"><h3>4 approval tiers</h3>just do it to ask first</td>
<td align="center"><h3>15 s tamper check</h3>changes restored, alarm raised</td>
</tr>
</table>

Runs in Claude Code as a plugin: one skill, a set of PowerShell scripts, and a pane in the session. The
coordinator needs Windows with PowerShell 7 or Windows PowerShell 5.1; the other agents can be any coding agent
that can run a command and write a file. In use for real work: see
[Status and limitations](#status-and-limitations).

**In 60 seconds:** install the plugin, ask for a room, paste one prompt into each agent. See
[Quick start](#quick-start).

```
claude plugin marketplace add gmn-gh24/agent-relay
claude plugin install agent-relay@agent-relay
```

> [!WARNING]
> agent-relay is **not a sandbox**. An agent runs with the rights of the account it was started under. Give
> each agent an account with the rights its task needs and no more. See [Security model](#security-model).

---

## Why

One agent is rarely enough for a real job. The code is on one machine and has to be tested on another; a
review should come from a second pair of eyes; three parts could be built at the same time. Without tooling
that means copying text between terminals, losing track of who was told what, and agents that quietly do
more than they were asked.

agent-relay gives those agents one shared folder, a small protocol, and one coordinator. The coordinator is
your Claude Code session. The other agents can be Claude Code, Codex CLI, or anything else: they do not need
this plugin, only one prompt to paste and one command to run.

| Without agent-relay | With agent-relay |
|---|---|
| Copy text between terminals | One shared folder, one protocol |
| Lose track of who was told what | Every message is a file; closing a room writes a transcript, statistics and an archive |
| Agents quietly do more than they were asked | Every assignment lists the task, the folders, what to ask first and what is never allowed |
| You have to notice a silent agent | A task says how long it should take; the coordinator is woken, asks the agent, then hands the task on or tells you |

---

## What you get

- **One prompt for every agent.** A room has seats. Paste the same join prompt into as many agents as you
  like; each takes the next free seat and gets a name. Agents can also be named in advance, each with its own
  assignment.
- **Introductions before work.** An agent's first command records where it runs (computer, address, user,
  rights, shells) and what it is (product, model, effort). Work is handed out by those facts.
- **Scope that is written down.** Every assignment lists the task, the folders, what may be changed, what must
  be asked first and what is never allowed. Every report carries a self-audit of what changed.
- **Approvals without nagging.** Four tiers: just do it, do and tell, announce then proceed, ask first. What
  is beyond the coordinator's authority comes to you as a card with Approve and Deny.
- **Teams.** A job can be split into parts with one owner each. Every agent can read the plan, see who is
  busy, and write to the colleagues its part depends on.
- **A live view.** A pane in the coordinator's session shows the agents, the plan, the conversation and what
  waits on you, with an input to speak as the owner. The same view runs in any terminal.
- **No silent agents.** A task says how long it should take. When its agent has sent nothing for that long,
  the coordinator is woken, asks the agent, and then hands the task on or tells you: you are not the one who
  has to notice.
- **A record.** Every message is a file. Closing a room writes a transcript, statistics and an archive.
- **Safeguards.** The coordinator's PC keeps its own copy of the tools, instructions and rules, compares them
  with the room every 15 seconds while the feed runs, restores what changed and raises an alarm.

---

## How it works

```
  Coordinator's PC                     The room (a shared folder)              Other agents
+---------------------------+      +--------------------------------+      +--------------------------+
| Claude Code + agent-relay |      | agents/<name>/  inbox, status, |      | Claude Code, Codex CLI,  |
|                           | <--> |                 instructions   | <--> | or any other agent       |
| skill      what to do     |      | tools/          relay.ps1      |      |                          |
| scripts    rooms, board   |      | join.cmd/.ps1   join a seat    |      | one prompt to paste      |
| pane       live view      |      | DECISIONS.md    standing rules |      | one command to run       |
| .local/    canonical copy |      | PLAN            who builds what|      | no plugin needed         |
+---------------------------+      +--------------------------------+      +--------------------------+
```

| Term | Meaning |
|---|---|
| Room | The shared folder of one job. Everything about the job lives in it. |
| Coordinator | Your Claude Code session with this plugin. It hands out work and answers within its authority. |
| Owner | You. The owner outranks every agent, the coordinator included. |
| Seat | A place for one agent: named in advance, or open for whoever is given the join prompt. |
| Message | One Markdown file in an inbox: `task`, `question`, `proposal`, `result`, `answer`, `note`, `hello`, `bye`. |
| Board | One printed view of the room: agents, plan, open requests, what waits on whom. |
| Feed | The live stream of the room. It drives the pane, runs the tamper check and shows the coordinator alive. |

One tool in the room does everything an agent needs: `relay.ps1` (Windows PowerShell 5.1 and PowerShell 7),
called from PowerShell, cmd or Git Bash through the agent's own wrapper. There is no `sh` tool: `sh` is
postponed (see [Status and limitations](#status-and-limitations)). Every output ends with a `NEXT:` line that
says what to do, so an agent with little context still knows its next step. Message text is never typed on a
command line: it is written into a draft file, and the verbs take single plain words.

The full protocol is in [`skills/agent-relay/references/protocol.md`](skills/agent-relay/references/protocol.md).

---

## Requirements

| Who | Needs |
|---|---|
| Coordinator | Claude Code on Windows; PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 |
| Agent | PowerShell for the room tool, `relay.ps1`: Windows PowerShell 5.1, which is part of Windows, or PowerShell 7 (`pwsh`) |
| Everybody | A folder all of them can reach: a local folder for agents on one PC, a file share across machines |

The room pane uses Claude Code's plugin hooks, which are early access. Without them everything else works,
and the feed in a terminal shows the same view.

---

## Installation

**From GitHub**

```
claude plugin marketplace add gmn-gh24/agent-relay
claude plugin install agent-relay@agent-relay
```

**From a clone** (for development: the plugin is read from the folder, and edits apply after
`/reload-plugins`)

```
git clone https://github.com/gmn-gh24/agent-relay.git
claude plugin marketplace add <path of the clone>
claude plugin install agent-relay@agent-relay
```

**For one session only**

```
claude --plugin-dir <path of the clone>
```

**Check it**

```
claude plugin list
```

`agent-relay@agent-relay` should be listed as enabled. In a session, `/relay` should answer
`No room is bound. Type /relay <room id>.`

**Update and remove**

```
claude plugin marketplace update agent-relay
claude plugin update agent-relay@agent-relay
claude plugin uninstall agent-relay@agent-relay
```

---

## Quick start

1. **Ask for a room.** In a Claude Code session, say what you want in your own words:

   > Start a relay room for the import tests. Two agents will join from the build machines.

   The skill asks what it needs (often only: the job, where the room lives, how many agents) and builds the
   room.

2. **Paste the prompt.** The coordinator hands you a join prompt and puts it on the clipboard. Paste it into
   every agent that is to take part. Each one runs one command, takes a seat, gets a name and introduces
   itself.

   Codex CLI must be started with `codex --yolo`: without it the agent keeps asking its user and its sandbox
   blocks the room's commands. Claude Code works as it is; start it with
   `claude --dangerously-skip-permissions` when you want a room without questions and interruptions. Both
   switch the product's own guard off (see "Security model").

3. **Watch.** `/relay <room id>` opens the room as a pane in the coordinator's session.

4. **Work.** Tell the coordinator what each agent is to do, or let it split the job. It writes the tasks,
   checks what comes back against the evidence, answers what is inside its authority and brings the rest to
   you.

5. **Close.** Say that the work has ended. The coordinator asks every agent for a last word, then closes the
   room with a transcript, statistics and an archive.

---

## Example: one job, start to finish

An illustration of the flow, not a recording. The job: run the import tests on two build machines.

| Step | Who | What happens |
|---|---|---|
| 1 | You | "Start a relay room for the import tests. Two agents will join from the build machines." |
| 2 | Coordinator | Asks only what it lacks: where the room lives, and whether the agents are named in advance or take open seats. Builds the room, puts the join prompt on the clipboard |
| 3 | You | Paste the join prompt into a Codex CLI session on one machine and a Claude Code session on the other, and run `/relay <room id>` to watch |
| 4 | Agents | Each runs one command, takes a seat, gets a name and introduces itself: computer, user, rights, product, model |
| 5 | Coordinator | Hands out work by those facts: a task with its folders, what may be changed, what must be asked first, what is never allowed, and how many minutes it should take |
| 6 | Agent | Works, then sends a `report` with a self-audit of what changed |
| 7 | Coordinator | Checks the report against the evidence. An agent asks to install a tool, which is beyond its assignment: you get a card with **Approve** and **Deny** |
| 8 | Coordinator | One agent stays silent past its time: the board marks the task `OVERDUE`, the coordinator asks the agent, then hands the task on or tells you |
| 9 | You | "The work has ended." Every agent gives a last word; the room closes with a transcript, statistics and an archive |

Each step is a message file in the room, so the whole job can be read afterwards.

---

## Usage

### Rooms and seats

| | Named agent | Open seat |
|---|---|---|
| Decided in advance | role, machine, kind of agent, task, folders | nothing |
| Prompt | its own start prompt | the join prompt, the same for every agent |
| Task and limits | in its assignment from the start | given after its introduction |
| Use it when | you have a plan for each agent | you want to paste one prompt into whatever is running |

Both can be mixed in one room, and seats can be added while the room runs.

A room is named after what it is for (`backup-agent-rollout`), not after a date. Where it lives is asked
for every job: a share that other jobs use too is never assumed.

### The pane

| Command | Does |
|---|---|
| `/relay <room id>` | Binds the session to the room and opens the pane |
| `/relay` | Opens the pane of the bound room again |
| `/relay off` | Unbinds the session and stops its feed |
| `/relay outside on` | Allows Claude Code's session-to-session tools (`SendMessage`, `ListAgents`) in this session while a room is bound, after a confirmation in the dialog; refused by default, since the room is the coordinator's only channel to an agent |
| `/relay outside off` | Refuses them again (a new session refuses them anyway) |

The pane shows the room's rows above an input that stays in place:

- **Scroll** with the mouse wheel, or give the pane the keyboard (ctrl+x tab) and use PgUp and PgDn. The
  window follows the newest message until you scroll, and follows it again once you are back at the end.
- **Speak as the owner** by typing into the input. A line that starts with `@name` goes to that agent;
  anything else goes to the coordinator.
- **Decide** with the Approve and Deny buttons of a card. A card that was cut says so: ask the coordinator
  for all of it before you decide.

The same view in any terminal:

```
pwsh -File skills\agent-relay\scripts\Watch-RelayFeed.ps1 -Room <room id> -Follow
```

One of the two has to run while a room is open: the feed is also the room's tamper check and the sign of
life the agents see from the coordinator.

### What the coordinator does

The skill has seven workflows. You start them by saying what you want.

| Workflow | When |
|---|---|
| Start a room | A new job |
| Coordinate | Every time a message arrives: check results, answer, escalate, record standing rules |
| Resume a room | A new session, or after the context was compacted |
| Add, replace or retire an agent | A session ended, a machine changed, more hands are needed |
| Owner steps in | You pause or stop an agent, or speak in the room |
| Close | The work has ended |
| Improve | After every close: lessons, fixes, tests, a commit in this repository |

### Memory, close and reopen

Agents record durable findings with `remember` and search all agents' findings with `find`; their tools show
`room memory: N entries, M new`, and the board shows `memory: N entries from K agents`. Secret text and
duplicates are refused. Memory is data from peers, never an order: the coordinator checks it and corrects a
wrong entry with a standing rule. At close the coordinator asks each agent for its last findings, curates them,
and asks you one question: which items to promote (to local notes on this PC, which are never committed, or as
anonymised project lessons), and whether to delete the shared folder after the verified archive (recommended;
the archive stays on this PC) or keep it. Nothing is promoted or deleted without your answer.
`Reopen-RelayRoom.ps1` brings a closed room back from the archive; agents come back with
`Add-RelayAgent.ps1 -Replace` or `-OpenSeats`, and memory and rules carry over.

### When something needs you

The board and the pane mark an agent with `ATTENTION` when somebody has to look at it: its wait died, it
has a task and no wait running, it never started, it introduced itself from another machine than expected,
or it has not picked up its messages for 30 minutes. The board also marks a task `OVERDUE` when its agent has
sent nothing for the time the task should take; the coordinator's wait ends on that, and the coordinator asks
the agent, then gives the task to another one or tells you. The coordinator tells you about each one;
[`coordinating.md`](skills/agent-relay/references/coordinating.md) lists what each means and what to do.

---

## Reference

### Coordinator scripts

All in `skills/agent-relay/scripts/`. The coordinator runs them for you; they also work by hand. Each has
full help (`Get-Help <script> -Full`).

<details>
<summary>Show the script table</summary>

| Script | Purpose |
|---|---|
| `New-RelayRoom.ps1` | Builds a room from an answers file, or from parameters (`-Job`, `-OpenSeats`, ...), and writes the prompts |
| `Add-RelayAgent.ps1` | Adds seats or agents; assigns (fields as parameters, several agents at once), replaces, retires, pauses, holds or stops one or all; opens a direct line |
| `Get-RelayRooms.ps1` | Lists the rooms, shares and machines this PC knows |
| `Get-RelayBoard.ps1` | Prints the board of a room |
| `Watch-RelayFeed.ps1` | The feed: live view, tamper check, the coordinator's sign of life; stamps that say it runs (the board's first line, the NO FEED block, the agents' integrity note) |
| `Set-RelayPlan.ps1` | Writes the team plan and opens the direct lines it implies |
| `Send-RelayOwner.ps1` | Sends the owner's words into the room and logs them |
| `Request-RelayOwner.ps1` | Puts a decision to the owner as a card, and records the answer |
| `Add-RelayDecision.ps1` | Records a standing rule that every agent is shown |
| `Get-RelayStats.ps1` | Reply times, repeated questions and other numbers of a room |
| `Close-RelayRoom.ps1` | Closes a room (records whether the folder was kept or removed); lists closed rooms; removes the folder of one that has an archive |
| `Get-RelayMemory.ps1` | Reads a room's memory: `-Find`, `-Agent`, `-Since`, `-Json` |
| `Repair-RelayMemory.ps1` | Lists an agent's memory file by line and removes lines after an evidence copy (memory is not covered by the tamper check) |
| `Add-RelayLocalMemory.ps1` | Writes or searches this PC's permanent local notes (`-Find`, `-List`) |
| `Reopen-RelayRoom.ps1` | Reopens a closed room on the PC that closed it |
| `Update-RelayRoom.ps1` | Brings a running room up to the tools and instructions of this version |
| `Test-RelayPackage.ps1` | Conformance run: `relay.ps1` on PowerShell 7 and Windows PowerShell 5.1 against one room |

</details>

### Agent verbs

Every agent has one command (a wrapper with its name and room built in) and these verbs:

| Verb | Use |
|---|---|
| `start` | Introduce yourself; prints your instructions, rules and what is open. Safe to repeat |
| `wait [minutes]` | Wait for messages. An agent waits until it is retired or the room is closed |
| `check` | Look once, do not wait |
| `show <id>`, `show open`, `show rules` | One message in full, what you still owe, the standing rules |
| `report [<task id>]` | The result of a task, with the self-audit attached |
| `reply <id> [approve\|deny]` | Answer a question or a proposal |
| `ask` | A question to the coordinator |
| `propose <minutes>` | Announce a low-risk step and proceed when nobody objects in time |
| `note` | Something the coordinator should know |
| `remember [tag ...]` | Record one durable finding from your draft file in the room memory |
| `find [word\|tag:x ...]` | Search the memory of all agents |
| `who`, `team` | Who is in the room; the plan and where everybody stands |
| `progress` | One line for the team; wakes nobody |
| `bye` | Leave the room |

The coordinator also has `task <name> [<minutes>]`, `ask <name>` and `note <name>|all`. The number is how long
the task should take: the agent is shown it, and the coordinator's wait ends when the agent has sent nothing
for that long.

### Room settings

Given once, when the room is built. The skill asks only for what has no sensible default.

<details>
<summary>Show the settings table</summary>

| Field | Meaning | Default |
|---|---|---|
| `job` | What the room is for, in one line | required |
| `room_name` | Becomes the folder name | the first words of the job |
| `rooms_root` | Where rooms are created | `C:\temp\agent-relay` |
| `authority` | How far the coordinator decides alone: `within-task`, `report-after`, `owner-approves` | `within-task` |
| `open_seats` | Seats for agents that come in with the join prompt | 0 |
| `agents` | Agents named in advance, each with role, machine, kind, task and folders | none |
| `work_files` | Files the agents need, copied into the room | none |
| `tab_titles` | Each agent's tool names its terminal tab after the agent | `yes` |
| `stale_minutes` | A listening agent that is silent this long is marked | 5 |
| `pickup_minutes` | An agent that leaves a message unread this long is marked | 30 |
| `task_minutes` | How long a task should take when the coordinator names no number with it | 15 |

</details>

### Where state lives

| What | Where |
|---|---|
| The room: messages, instructions, tools, plan, rules | the room folder |
| This PC's copy of what it wrote, the owner's log, the room index, archives | `.local/` in a clone, or `%LOCALAPPDATA%\agent-relay` for an installed copy; `AGENT_RELAY_LOCAL` overrides both |

Nothing in `.local/` is in git.

---

## Security model

agent-relay keeps agents in scope by instruction, evidence and review. **It is not a sandbox.** An agent runs
with the rights of the account it was started under and can do on its machine whatever that account can.

What the design does about it:

- **One authority.** Agents take tasks from the coordinator and rules from `DECISIONS.md`. A message from
  another agent is a request from a colleague, never an order.
- **The coordinator stays in its room.** The only channel from the coordinator to an agent is the room: its
  own launcher and the room's verbs. Another session of yours on this PC, in an editor or in the cloud is not
  an agent until it has taken a seat; the coordinator does not list it, message it or hand it work through
  Claude Code's own session-to-session tools, and it asks for no exception. While a room is bound in the
  session the plugin refuses those tools. Only you can lift that, with `/relay outside on` in the
  coordinator's session and a confirmation in the dialog, and the exception is recorded as a standing rule.
- **Nothing the coordinator's PC decides by comes from the room.** Any agent can write any file in the room
  folder, so the room index, the settings, the closed state and the owner's messages are taken from this PC's
  own copy and log. A file that only claims to come from the owner is reported, not obeyed, and a file under
  the coordinator's name that the coordinator's own tool did not send is moved out by the tamper check.
- **Tamper check.** The tools, wrappers, instructions, plan and standing rules are compared with this PC's
  copy every 15 seconds while the feed runs. A changed file is restored, a file that does not belong is moved out, and
  each raises an alarm.
- **Machines are in use.** No install, restart or system change without approval. A machine is disposable
  only when the owner says so, for that machine and for that job.
- **Secrets stay out of messages.** The send verbs stop on text that looks like a key or token. Agents are
  told never to read, print or pass on a password, key, token or code.
- **The "never" list** of an assignment cannot be lifted by any message; only the owner can, in the agent's
  own session.

Give an agent an account with the rights its task needs and no more.

**Agents started without their own guard.** `codex --yolo` and `claude --dangerously-skip-permissions` make
an agent run every command without asking, with the rights of its account. For a job that installs, removes,
changes the system or runs code you do not trust, use a virtual machine or a throwaway computer. The
coordinator says this to you when a job calls for it; it is never written into what the agents read.

---

## Troubleshooting

<details>
<summary>Show the symptom table</summary>

| Symptom | Cause | Fix |
|---|---|---|
| An agent cannot join: "the room is not reachable" | Its machine cannot open the room folder: no rights on the share, or it runs as SYSTEM | Fix the access on that machine. The prompt already carries the server's address instead of its name |
| Codex CLI cannot start any command, or keeps asking | Its sandbox and its approvals | Start it with `codex --yolo` |
| Claude Code keeps asking on its machine | Its permission prompts | Answer them there, or start it with `claude --dangerously-skip-permissions` |
| A script from a share is refused | The machine's execution policy is set by Group Policy | Put the room where that machine trusts scripts |
| `/relay <id>` says "Not bound" | The id is not a room of this PC, or the look at the room was interrupted | `Get-RelayRooms.ps1` lists the rooms; run the command again |
| The pane says the feed has ended | The feed stopped three times in a row | `/relay <id>` starts it again; its message names the reason |
| "another wait is already running" (after about half a minute) | The agent's own background wait is alive: the line names its process | Do nothing; if that wait ends without printing anything, run `wait` again. A wait of a session that ended is taken over by itself |
| "your wait was stopped before anything arrived" | Its host or a Ctrl+C stopped the wait; nothing listens for that agent | Run `wait` again, as the line says |
| An agent "has not picked up" its messages | Its session ended while it worked | Look at that session; replace or retire the agent |
| An agent lost its context | Its session was restarted or compacted | It runs `start`, then `wait`: everything it needs is printed again |
| "your draft is a link" or "your attach folder holds a link" | A symbolic link or junction stands where the agent's own file belongs; the tool never reads or writes through one | Remove the link and put a real file there |
| Tests fail at once on an agent's machine | Pester does not run from a network folder | Work in a folder on a local disk |
| `ARCHIVE FAILED` at close | A file of the room could not be read while the archive was made | Run `Close-RelayRoom.ps1 -Room <id>` again. Until it names an archive, keep the room folder |

</details>

More traps, with what the tools do about each, are in
[`transports.md`](skills/agent-relay/references/transports.md). What real rooms taught is in
[`lessons.md`](skills/agent-relay/references/lessons.md).

---

## FAQ

<details>
<summary><strong>Do the other agents need this plugin?</strong></summary>

No. They need one prompt to paste and one command to run. The room tool, `relay.ps1`, is inside the room folder.
Only the coordinator, your Claude Code session, has the plugin.
</details>

<details>
<summary><strong>How is this different from Claude Code's own agent teams and session messaging?</strong></summary>

Those connect Claude Code sessions. agent-relay uses a shared folder, so agents of different products on
different machines can work under one coordinator, each with a written assignment, approval tiers, owner cards and
a record. While a room is bound, the plugin refuses Claude Code's session-to-session tools by default, because the
room is the coordinator's only channel to an agent (`/relay outside on` lifts that).
</details>

<details>
<summary><strong>Is it a sandbox?</strong></summary>

No. It keeps agents in scope by instruction, evidence and review. An agent can do on its machine whatever its
account can. See [Security model](#security-model).
</details>

<details>
<summary><strong>Does it send my data anywhere?</strong></summary>

The scripts and the room tool make no network calls and have no telemetry. A room is a folder; on a file share, the
share's own network traffic applies. What an agent reads and writes is handled by its own product. See
[`SECURITY.md`](SECURITY.md).
</details>

<details>
<summary><strong>Can the coordinator be something other than Claude Code on Windows?</strong></summary>

Not today. The coordinator is a Claude Code session on Windows with PowerShell 7 or Windows PowerShell 5.1. The
other agents can be any coding agent that can run a command and write a file.
</details>

<details>
<summary><strong>Does it work with agents on Linux or macOS?</strong></summary>

Not tried yet. The room tool is PowerShell, and there is no `sh` tool. See
[Status and limitations](#status-and-limitations).
</details>

<details>
<summary><strong>What if an agent goes silent?</strong></summary>

A task says how long it should take. When its agent has sent nothing for that long, the board marks the task
`OVERDUE`, the coordinator's wait ends, and the coordinator asks the agent, then gives the task to another one or
tells you.
</details>

<details>
<summary><strong>Where is the record, and can I reopen a room?</strong></summary>

Every message is a file. Closing a room writes a transcript, statistics and an archive, which stay on the
coordinator's PC. `Reopen-RelayRoom.ps1` brings a closed room back on that PC. See
[Memory, close and reopen](#memory-close-and-reopen).
</details>

---

## Development

### Repository layout

```
.claude-plugin/                          plugin and marketplace manifests
skills/agent-relay/SKILL.md              the coordinator skill
skills/agent-relay/references/           interview, coordinating, protocol, transports, agent kinds, lessons
skills/agent-relay/scripts/              coordinator side (PowerShell)
skills/agent-relay/assets/room-package/  what every room gets: tools, wrappers, templates, protocol reference
hooks/, types/                           the room pane
tests/                                   Pester suites and byte fixtures
evals/                                   eval cases for the skill
CHANGELOG.md
```

### Prerequisites

PowerShell 7 and Windows PowerShell 5.1, Pester 6, PSScriptAnalyzer, and Claude Code (the gate runs the
pane's checks). The PowerShell 7 suites also run on Linux and macOS; Windows PowerShell 5.1 only on Windows.

### The test gate

Nothing is committed while it fails.

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1
```

| Stage | Checks |
|---|---|
| Static | PSScriptAnalyzer without findings, ASCII only and LF line ends in every file git tracks, the PowerShell wrapper templates parse, every test file is listed in the gate |
| Pane | `claude plugin validate` and `claude plugin test` |
| Room tools | Four test files, each on PowerShell 7 and Windows PowerShell 5.1 |
| Coordinator scripts | Seven test files on both PowerShell editions |

There is no `sh` tool and no `sh` test (postponed). A test file that fails to load, a failing
`BeforeAll` or `AfterAll`, a path that names nothing and a run in which no test ran all fail the gate.
`-StaticOnly` runs the first stage alone; `-SkipAnalyzer` and `-SkipPane` run the rest where PSScriptAnalyzer
or Claude Code is missing, and the result says what was not tested. One file on one engine takes a few
minutes:

```
pwsh -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines ps7 -Label 'Faults ps7'
```

Start the tests from a folder on a local disk.

GitHub Actions (`.github/workflows/ci.yml`) runs the static and pane checks on Linux, on every push to `main`,
every pull request and on demand. The Pester files (PowerShell 7 and Windows PowerShell 5.1) do not run there:
run them on a Windows dev machine before a commit (`tests\Invoke-AllTests.ps1`). A Claude session that
cannot run them (no Windows) asks the owner to run them and to report the RESULT lines. The eval cases never run
in CI. A push to `main` whose version in `plugin.json` has no tag yet gets the tag `v<version>` and a GitHub
Release with that version's changelog section (`.github/workflows/release.yml`); no tag is made by hand.

### The pane and the skill

```
claude plugin validate .
claude plugin test .
claude plugin eval . --no-publish
```

`validate` checks the manifests and the hooks module, `test` runs the pane's tests, and `eval` runs the
skill's cases: requests that must load the skill, requests that must not, and cases that check how the
coordinator behaves: what it settles with you before it builds, how it closes a room, and that it reaches an
agent through the room only. Each eval run is a full headless session on your account; `--no-publish` keeps
its report on this PC.

### Conventions

- PowerShell that also runs on Windows PowerShell 5.1; ASCII only; LF line ends.
- `relay.ps1` changes with a test on both PowerShell editions. There is no `sh` tool: `sh` is postponed by the
  owner and is built and tested only if and when it is needed.
- Every fix comes with a test that fails without it.
- No real machine, share or account name in a committed file.
- Every release has an entry in [CHANGELOG.md](CHANGELOG.md) and a tag `v<version>`, which CI makes from that
  entry.

---

## Status and limitations

Built and in use: protocol 3, the room tool `relay.ps1`, named agents and open seats, the team plan, the board,
the feed, the pane, the owner's messages and cards, standing rules, the tamper check, closing with transcript,
statistics and archive.

| Agent | Status |
|---|---|
| Claude Code | Worked live rooms as coordinator and as agent, on the same PC and on another machine |
| Claude Code, headless (`claude -p`) | Worked a rehearsal room, given only the start prompt |
| Codex CLI | Worked a live room; must be started with `codex --yolo` |
| Gemini CLI, Cursor, Copilot, others | A generic profile, not yet tried in a room |
| Any agent on Linux or macOS | Not yet tried in a room; the room tool is PowerShell (there is no `sh` tool) |

Known limits:

- A closed room can be reopened only on the PC that closed it, because that needs its local canonical copy.
- The coordinator's side is PowerShell on Windows.
- There is no `sh` tool: the room tool is PowerShell. No agent on Linux or macOS has worked a room yet.
- Every agent has to reach a folder the coordinator's PC reaches too. A machine that shares no folder with
  it cannot take part: `ssh` is refused as a transport.
- An agent that cannot wait in the background costs a turn for every wait that ends without a message, for
  as long as the room is open, and while it works it sees a message only between two steps.
- The pane depends on plugin hooks that may change between Claude Code releases.

---

## Roadmap

What is planned, and what was looked at and dropped, is in [ROADMAP.md](ROADMAP.md). Changes by release are in
[CHANGELOG.md](CHANGELOG.md).

---

## Contributing

Issues and pull requests are welcome at <https://github.com/gmn-gh24/agent-relay>. Please run the test gate
before you open a pull request, add a test for what you change, and write a line for the changelog. See
[CONTRIBUTING.md](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md) and the
[security policy](SECURITY.md). What is planned: [ROADMAP.md](ROADMAP.md). Names and trademarks: [TRADEMARKS.md](TRADEMARKS.md) and [NOTICE](NOTICE).

---

## Support

- **A question or a bug:** [open an issue](https://github.com/gmn-gh24/agent-relay/issues) with the PowerShell
  edition, the agent product and the exact error line.
- **A security problem:** report it privately, see [SECURITY.md](SECURITY.md).
- **Behavior in the project's spaces:** see the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## License

MIT, see the `LICENSE` file.

---

<div align="center">

Many agents. One room. You decide.

</div>
