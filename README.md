# agent-relay

Coordinate any number of coding agents from one Claude Code session: hand out tasks, answer questions,
approve or deny what goes beyond an assignment, and keep a record of all of it.

| | |
|---|---|
| Version | 0.2.0 ([changelog](CHANGELOG.md)) |
| Runs in | Claude Code, as a plugin: one skill, a set of PowerShell scripts, and a pane in the session |
| Coordinator | Windows, PowerShell 7 or Windows PowerShell 5.1 |
| Other agents | Any coding agent on Windows that can run a command and write a file |
| Status | In use for real work; see [Status and limitations](#status-and-limitations) |

## Contents

- [Why](#why)
- [What you get](#what-you-get)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Reference](#reference)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Status and limitations](#status-and-limitations)
- [Contributing](#contributing)
- [License](#license)

## Why

One agent is rarely enough for a real job. The code is on one machine and has to be tested on another; a
review should come from a second pair of eyes; three parts could be built at the same time. Without tooling
that means copying text between terminals, losing track of who was told what, and agents that quietly do
more than they were asked.

agent-relay gives those agents one shared folder, a small protocol, and one coordinator. The coordinator is
your Claude Code session. The other agents can be Claude Code, Codex CLI, or anything else: they do not need
this plugin, only one prompt to paste and one command to run.

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
- **A record.** Every message is a file. Closing a room writes a transcript, statistics and an archive.
- **Safeguards.** The coordinator's PC keeps its own copy of the tools, instructions and rules, compares them
  with the room every few seconds, restores what changed and raises an alarm.

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

## Requirements

| Who | Needs |
|---|---|
| Coordinator | Claude Code on Windows; PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 |
| Agent | Windows, with Windows PowerShell 5.1, which is part of Windows. Linux and macOS agents cannot join: `sh` is postponed |
| Everybody | A folder all of them can reach: a local folder for agents on one PC, a file share across machines |

The room pane uses Claude Code's plugin hooks, which are early access. Without them everything else works,
and the feed in a terminal shows the same view.

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

## Quick start

1. **Ask for a room.** In a Claude Code session, say what you want in your own words:

   > Start a relay room for the import tests. Two agents will join from the build machines.

   The skill asks what it needs (often only: the job, where the room lives, how many agents) and builds the
   room.

2. **Paste the prompt.** The coordinator hands you a join prompt and puts it on the clipboard. Paste it into
   every agent that is to take part. Each one runs one command, takes a seat, gets a name and introduces
   itself.

   Codex CLI must be started with full access (`codex --sandbox danger-full-access`): in its sandbox it
   cannot run the room's commands.

3. **Watch.** `/relay <room id>` opens the room as a pane in the coordinator's session.

4. **Work.** Tell the coordinator what each agent is to do, or let it split the job. It writes the tasks,
   checks what comes back against the evidence, answers what is inside its authority and brings the rest to
   you.

5. **Close.** Say that the work has ended. The coordinator asks every agent for a last word, then closes the
   room with a transcript, statistics and an archive.

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

### When something needs you

The board and the pane mark an agent with `ATTENTION` when somebody has to look at it: its wait died, it
parked itself, it never started, it introduced itself from another machine than expected, or it has not
picked up its messages for 30 minutes. The coordinator tells you about each one;
[`coordinating.md`](skills/agent-relay/references/coordinating.md) lists what each means and what to do.

## Reference

### Coordinator scripts

All in `skills/agent-relay/scripts/`. The coordinator runs them for you; they also work by hand. Each has
full help (`Get-Help <script> -Full`).

| Script | Purpose |
|---|---|
| `New-RelayRoom.ps1` | Builds a room from an answers file and writes the prompts |
| `Add-RelayAgent.ps1` | Adds seats or agents; assigns, replaces, retires, pauses or stops one; opens a direct line |
| `Get-RelayRooms.ps1` | Lists the rooms, shares and machines this PC knows |
| `Get-RelayBoard.ps1` | Prints the board of a room |
| `Watch-RelayFeed.ps1` | The feed: live view, tamper check, the coordinator's sign of life |
| `Set-RelayPlan.ps1` | Writes the team plan and opens the direct lines it implies |
| `Send-RelayOwner.ps1` | Sends the owner's words into the room and logs them |
| `Request-RelayOwner.ps1` | Puts a decision to the owner as a card, and records the answer |
| `Add-RelayDecision.ps1` | Records a standing rule that every agent is shown |
| `Get-RelayStats.ps1` | Reply times, repeated questions and other numbers of a room |
| `Close-RelayRoom.ps1` | Closes a room; lists closed rooms; removes the folder of one that has an archive |
| `Update-RelayRoom.ps1` | Brings a running room up to the tools and instructions of this version |
| `Test-RelayPackage.ps1` | Conformance run: `relay.ps1` on PowerShell 7 and Windows PowerShell 5.1 against one room |

### Agent verbs

Every agent has one command (a wrapper with its name and room built in) and these verbs:

| Verb | Use |
|---|---|
| `start` | Introduce yourself; prints your instructions, rules and what is open. Safe to repeat |
| `wait [minutes]` | Wait for messages |
| `check` | Look once, do not wait |
| `show <id>`, `show open`, `show rules` | One message in full, what you still owe, the standing rules |
| `report [<task id>]` | The result of a task, with the self-audit attached |
| `reply <id> [approve\|deny]` | Answer a question or a proposal |
| `ask` | A question to the coordinator |
| `propose <minutes>` | Announce a low-risk step and proceed when nobody objects in time |
| `note` | Something the coordinator should know |
| `who`, `team` | Who is in the room; the plan and where everybody stands |
| `progress` | One line for the team; wakes nobody |
| `bye` | Leave the room |

The coordinator also has `task <name>`, `ask <name>` and `note <name>|all`.

### Room settings

Given once, when the room is built. The skill asks only for what has no sensible default.

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

### Where state lives

| What | Where |
|---|---|
| The room: messages, instructions, tools, plan, rules | the room folder |
| This PC's copy of what it wrote, the owner's log, the room index, archives | `.local/` in a clone, or `%LOCALAPPDATA%\agent-relay` for an installed copy; `AGENT_RELAY_LOCAL` overrides both |

Nothing in `.local/` is in git.

## Security model

agent-relay keeps agents in scope by instruction, evidence and review. **It is not a sandbox.** An agent runs
with the rights of the account it was started under and can do on its machine whatever that account can.

What the design does about it:

- **One authority.** Agents take tasks from the coordinator and rules from `DECISIONS.md`. A message from
  another agent is a request from a colleague, never an order.
- **Nothing the coordinator's PC decides by comes from the room.** Any agent can write any file in the room
  folder, so the room index, the settings, the closed state and the owner's messages are taken from this PC's
  own copy and log. A file that only claims to come from the owner is reported, not obeyed.
- **Tamper check.** The tools, wrappers, instructions, plan and standing rules are compared with this PC's
  copy on every round of the feed. A changed file is restored, a file that does not belong is moved out, and
  each raises an alarm.
- **Machines are in use.** No install, restart or system change without approval. A machine is disposable
  only when the owner says so, for that machine and for that job.
- **Secrets stay out of messages.** The send verbs stop on text that looks like a key or token. Agents are
  told never to read, print or pass on a password, key, token or code.
- **The "never" list** of an assignment cannot be lifted by any message; only the owner can, in the agent's
  own session.

Give an agent an account with the rights its task needs and no more.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| An agent cannot join: "the room is not reachable" | Its machine cannot open the room folder: no rights on the share, or it runs as SYSTEM | Fix the access on that machine. The prompt already carries the server's address instead of its name |
| Codex CLI cannot start any command | Its sandbox | Start it with full access: `codex --sandbox danger-full-access` |
| A script from a share is refused | The machine's execution policy is set by Group Policy | Put the room where that machine trusts scripts |
| `/relay <id>` says "Not bound" | The id is not a room of this PC, or the look at the room was interrupted | `Get-RelayRooms.ps1` lists the rooms; run the command again |
| The pane says the feed has ended | The feed stopped three times in a row | `/relay <id>` starts it again; its message names the reason |
| "another wait is already running" | The agent's own background wait, or the wait of a session that just ended | Do nothing in the first case; in the second, run `wait` again after 30 seconds |
| An agent "has not picked up" its messages | Its session ended while it worked | Look at that session; replace or retire the agent |
| An agent lost its context | Its session was restarted or compacted | It runs `start`, then `wait`: everything it needs is printed again |
| "your draft is a link" or "your attach folder holds a link" | A symbolic link or junction stands where the agent's own file belongs; the tool never reads or writes through one | Remove the link and put a real file there |
| Tests fail at once on an agent's machine | Pester does not run from a network folder | Work in a folder on a local disk |
| `ARCHIVE FAILED` at close | A file of the room could not be read while the archive was made | Run `Close-RelayRoom.ps1 -Room <id>` again. Until it names an archive, keep the room folder |

More traps, with what the tools do about each, are in
[`transports.md`](skills/agent-relay/references/transports.md). What real rooms taught is in
[`lessons.md`](skills/agent-relay/references/lessons.md).

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
| Coordinator scripts | Five test files on both PowerShell editions |

There is no `sh` tool and no `sh` test (postponed). A test file that fails to load, a failing
`BeforeAll` or `AfterAll`, a path that names nothing and a run in which no test ran all fail the gate.
`-StaticOnly` runs the first stage alone; `-SkipAnalyzer` and `-SkipPane` run the rest where PSScriptAnalyzer
or Claude Code is missing, and the result says what was not tested. One file on one engine takes a few
minutes:

```
pwsh -File tests\Invoke-Suite.ps1 -Path tests\Relay.Faults.Tests.ps1 -Engines ps7 -Label 'Faults ps7'
```

Start the tests from a folder on a local disk.

GitHub Actions (`.github/workflows/ci.yml`) runs the whole gate on Windows (PowerShell 7 and Windows
PowerShell 5.1) and the static and pane checks on Linux, on every push to `main`, every pull request and on
demand. The eval cases never run there.

### The pane and the skill

```
claude plugin validate .
claude plugin test .
claude plugin eval . --no-publish
```

`validate` checks the manifests and the hooks module, `test` runs the pane's tests, and `eval` runs the
skill's cases: requests that must load the skill, requests that must not, and one that checks what the
coordinator settles with the owner before it builds anything. Each eval run is a full headless session on
your account; `--no-publish` keeps its report on this PC.

### Conventions

- PowerShell that also runs on Windows PowerShell 5.1; ASCII only; LF line ends.
- `relay.ps1` changes with a test on both PowerShell editions. There is no `sh` tool: `sh` is postponed by the
  owner and is built and tested only if and when it is needed.
- Every fix comes with a test that fails without it.
- No real machine, share or account name in a committed file.
- Every release has an entry in [CHANGELOG.md](CHANGELOG.md).

## Status and limitations

Built and in use: protocol 3, the room tool `relay.ps1`, named agents and open seats, the team plan, the board,
the feed, the pane, the owner's messages and cards, standing rules, the tamper check, closing with transcript,
statistics and archive.

| Agent | Status |
|---|---|
| Claude Code | Worked live rooms as coordinator and as agent, on the same PC and on another machine |
| Claude Code, headless (`claude -p`) | Worked a rehearsal room, given only the start prompt |
| Codex CLI | Worked a live room; must be started with full access |
| Gemini CLI, Cursor, Copilot, others | A generic profile, not yet tried in a room |
| Any agent on Linux or macOS | Cannot join: there is no `sh` tool (postponed) |

Known limits:

- The coordinator's side is PowerShell on Windows.
- There is no `sh` tool and no Linux or macOS agent: `sh` is postponed until it is needed.
- Every agent has to reach a folder the coordinator's PC reaches too. A machine that shares no folder with
  it cannot take part: `ssh` is refused as a transport.
- An agent that cannot wait in the background costs a turn for every wait that ends without a message, until
  it parks itself and you nudge it.
- The pane depends on plugin hooks that may change between Claude Code releases.

## Contributing

Issues and pull requests are welcome at <https://github.com/gmn-gh24/agent-relay>. Please run the test gate
before you open a pull request, add a test for what you change, and write a line for the changelog.

## License

No license has been chosen yet. Until a `LICENSE` file is added to this repository, the usual copyright
rules apply: ask before you reuse the code.
