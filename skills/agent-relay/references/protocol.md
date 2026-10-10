# Protocol 3, coordinator view

`PROTOCOL.md` in every room is the agents' reference. This file adds what only the coordinator's side needs:
which files this PC writes, how the pieces fit, and where state lives.

## The room folder

```
<rooms root>/<room id>/
  ROOM                      key: value: room, protocol, package, job, coordinator, authority, created_utc,
                            stale_minutes, silent_minutes, park_after, proposal_limit
  DECISIONS.md              standing rules and owner decisions (Add-RelayDecision.ps1 only)
  PLAN                      the team plan: parts, owners, status (Set-RelayPlan.ps1 only); see "The team plan"
  PROTOCOL.md               agents' reference
  join.cmd, join            only in rooms with open seats
  PROMPT-JOIN.txt           the join prompt; PROMPT-<name>.txt for each named agent
  tools/relay.ps1           Windows PowerShell 5.1 and PowerShell 7
  tools/relay.sh            POSIX sh
  tools/kinds               how each agent kind waits (from agent-kinds.json)
  tools/VERSION
  agents/<name>/
    seat  gen  control  scope  lines  retired        written by this PC, guarded
    START-HERE.md  ASSIGNMENT.md                      written by this PC, guarded
    g<N>/relay.cmd  g<N>/relay                        written by this PC, guarded
    claim                                             open seat only: who took it (written by the tool)
    card  status  alive  state  journal  delivered    written by the agent's tool
    proposals  progress  wait.lease  baseline/
    wait.lease.lock  proposals.lock  inbox/.claim-*   short-lived: a critical section, a number being taken
    inbox/<from>-<NNNN>.md                            messages to this agent
    draft.md  attach/                                 written by the agent
  files/<message id>/       attachments
  work/                     staged files
  join.log                  one line per join attempt
  TRANSCRIPT.md  CLOSED     at close
```

"Guarded" means: this PC keeps a canonical copy under `<machine state>/rooms/<room id>/canon/` and writes
that copy first. The feed compares the room with it every few seconds, restores a changed or missing file,
moves a file that does not belong out to `quarantine/`, and logs an alarm in `alarms.log`.

## Identity

An agent is its wrapper. `g<N>/relay.cmd` (or `g<N>/relay`) sets `RELAY_NAME`, `RELAY_GEN`, `RELAY_ROOM_ID`
and `RELAY_WRAPPER` and runs the tool. There is no `-Me` argument to get wrong. A replaced session has an old
generation in its wrapper; the tool compares it with `gen` and tells it to stop.

An open seat has `open: yes` and `wake: auto` in its `seat`. `join` creates `claim` exclusively, so two
sessions can never get the same seat, then carries on as that agent's `start`.

The `card` is what the tool read off the machine at `start`, plus the three words the agent gave: `product`,
`model`, `effort`; `agent_process` (the program the agent runs in, from the parent processes); `computer`,
`ipv4`, `os`, `user`; `elevation` (`elevated`, `SYSTEM`, `not elevated, can elevate (UAC prompt)`,
`not elevated, no administrator rights`; on Linux `root`, `not root`, `not root, in group <g> (sudo may
work)`); `shell` (the shell that called, with its version) and `shells` (the others the machine has);
`host_app`, `process_chain`, `cwd`. The `hello` message says the same in sentences first. On Windows the tool
also names the terminal tab after the agent (`tab_titles: no` in `ROOM` or `RELAY_NO_TITLE=1` in the agent's
environment turns that off).

## Messages

- One immutable Markdown file per message, in the receiver's inbox: `<from>-<NNNN>.md`. The id is
  `<from>-<to>-<NNNN>`. The name is an agent name and a number of four to six digits; any other file in an
  inbox is no message. The number is one more than the highest the sender has in that inbox and in the
  receiver's `delivered` list, so an inbox that was lost and made again brings no id back.
- Sending: claim the number (`inbox/.claim-<from>-<NNNN>`, created exclusively; a number is free only when
  the claim could be made and neither the message file nor `files/<id>` exists), move the attachments to
  `files/<id>/`, create the message under its final name exclusively, drop the claim. The message is the last
  thing to appear. A claim older than two minutes was left by a sender that died: whoever meets it removes it
  and skips that number. A send that created no message fails with exit code 2, keeps the draft and puts the
  attachments back.
- Sender, receiver and number are read from where the file is, never from its header. A header that
  disagrees is shown with a warning.
- A message file is read, or it is not there: a file that does not begin with a `---` line, or whose header
  is never closed by one, is no message. `show`, `reply` and `report <id>` say there is none, and it is never
  a request and never closes one.
- Header: `id, from, to, type, re, subject, sent_utc, expects`. Types: `hello, task, question, proposal,
  result, answer, note, bye`. `expects`: `reply`, `none`, or `proceed <minutes>`.
- A request (`task`, `question`, `proposal`) is open until a `result` or `answer` names it in `re`.
- `delivered` is the receiver's append-only list of ids its tool has shown. Delivery and "answered" are
  separate: a message shown to a session that then died is shown again as an open request at the next `start`.
  A delivery records exactly what it showed. A file that cannot be read (held open, still empty, no `type` in
  its header) stays pending and ends no wait; if it is still unreadable after two minutes it is shown once as
  an unreadable message, so that it cannot stay hidden.
- Times in headers are for display. Staleness and a proposal's clock use the file times the room's file
  system gives, read by one machine.

## Verbs and exit codes

`join` (room-level), `start`, `wait [minutes]`, `check`, `show <id>|open|rules`, `reply <id> [approve|deny]`,
`report [<task id>]`, `ask`, `propose <minutes>`, `note`, `who`, `team`, `progress`, `bye`; the coordinator
also has `task <name>`, `ask <name>`, `note <name>|all`. Arguments are single plain words; text comes from the
draft file.

## The team plan

`PLAN` holds how a job is split: one `part:` line per part (`id | owner | status | depends | reviewer |
title`, status one of `todo, doing, review, done, blocked`), `files:` and `note:` lines per part, a revision in
`plan:` that grows with every change, and `end: <revision>` as its last line, by which a reader tells a
complete plan from one caught half written. Only `Set-RelayPlan.ps1` writes it, canonical copy first, one
writer at a time; it also opens the direct lines the plan implies (owner to the owners of what its part depends
on, owner to reviewer).

- `team` prints the plan, every agent's state, its oldest open task, its last `progress` line and its parts,
  and whom the caller may write to. It works without a plan.
- `progress` takes one line from the draft, appends it to the agent's `progress` file (the last 20 are kept)
  and sets its status to `working` with that line. It sends nothing and wakes nobody; the board and `team`
  show it.
- A plan whose revision is higher than the agent's `plan_seen` is shown once, in front of the `NEXT:` line of
  `start` and of the next delivery. A plan change alone does not end a wait.
- Both tools and the board read a plan the same way and never fail on one. A line counts only when it starts
  with a key and its colon, in lower case; of two `plan:`, `goal:`, `updated_utc:` or `end:` lines the first
  counts; a `part:` line with fewer than six fields or an id seen before is ignored; the title is what follows
  the fifth separator; a revision is a number of one to nine digits above 0 (`007` is 7), anything else means
  no plan; a name that is no agent of the room is printed as written, with a capital when it starts with a to z.
  Names and part ids are compared without regard to case: `Emma` as an owner is the agent `emma`, and a part
  `A` after a part `a` is that part again.

| Code | Meaning |
|---|---|
| 0 | done, or something for you |
| 1 | usage or error; the `NEXT:` line says what to do |
| 2 | the room is not reachable |
| 3 | nothing arrived in time: run `wait` again (a shell that wraps the call may report 1: agents go by the `NEXT:` line) |
| 4 | another `wait` already runs for this agent |
| 5 | stop: room closed, or the agent was stopped, replaced or retired |
| 6 | parked: wait for the owner |

## Waiting

`wait` holds a lease (`wait.lease`: token, generation, host, process id; stale after 30 s without renewal or
when the process is gone). On Windows it uses change events on the inbox plus a rescan every few seconds,
and rebuilds the watcher every ten minutes; `relay.sh` polls once a second. It returns on: new messages, a
proposal's time running out, pause or resume, stop, replacement, the coordinator's silence, and its own time
limit. A wait whose inbox folder is not there takes the room for unreachable (a share that is gone looks the
same) and ends with code 2 after thirty minutes of it; a folder that comes back starts the count again.

One wait per agent, also when two start together: judging the lease, taking it, refreshing it and giving it
back each happen inside `wait.lease.lock`, a name created exclusively (a file for `relay.ps1`, a folder for
`relay.sh`, so each refuses while the other holds it), tried for three seconds and taken away when older than
fifteen; one that is gone again when its age is asked for was given back, and nothing is removed. A refresh
writes the first byte of the lease again with the byte it has, so that its time comes from the room's file
system and not from the machine's clock. A wait confirms its lease that way directly before it says anything
its agent acts on. A lease that
belongs to another wait ends it with code 4 and nothing delivered; a lock it cannot get means it says nothing
in that round and asks again in the next.

`proposals` is the agent's own note of what it proposed: id, minutes, when the coordinator received it, and
`open`, `due` or `closed`. The inbox is the authority: an `answer` there closes the proposal whatever the note
says. The note is updated inside `proposals.lock` and a state never goes backwards; a `propose` that cannot
get the lock sends the proposal and leaves the note out, and that proposal never comes due by itself. Nothing
is announced as due while the inbox holds a message the agent has not been shown: it may be the denial. The
receipt time is noted all the same.

Environment switches, for tests and odd machines: `RELAY_NO_EVENTS=1` (rescan only),
`RELAY_POLL_SECONDS`, `RELAY_SETTLE_MS`, `RELAY_DRAFT` (another draft file), `RELAY_MINUTE_SECONDS` (how long a
minute is), `RELAY_PAUSE_AT` with `RELAY_PAUSE_DIR` (the tool stops at a named point, writes
`<point>.reached` there and goes on when `<point>.go` appears: how the tests force a race).

## The owner

- `Send-RelayOwner.ps1` writes the owner's text into the coordinator's inbox as `owner-<NNNN>.md` and its
  id and hash into `owner/log` on this PC. `Test-RelayOwnerMessage` (the board, the feed) checks every file
  that claims to come from the owner against that log.
- Cards (`owner/cards/<NNNN>.md` plus `.answer`) are the coordinator's questions to the owner. They live on
  this PC only.

## Machine state

`Get-RelayRooms.ps1` prints where it is: `.local/` in the plugin's working copy, or
`%LOCALAPPDATA%\agent-relay` for an installed copy (`AGENT_RELAY_LOCAL` overrides both). It holds
`rooms.json` (the room index), `names.json` (which machine and role has which name), `machines.json` (known
shares and machines: facts only), and per room `canon/`, `owner/`, `specs/`, `prompts/`, `quarantine/`,
`alarms.log`, `stats.json`; `archive/` holds one zip per closed room. None of it is in git.

## Limits

- Scope is kept by instruction, self-audit, tamper check and your review. It is not a sandbox.
- An agent that can write to the room can forge a message file. What limits the damage: sender and receiver
  come from the file's place, the "never" lists, the single path of authority through the coordinator, the
  owner's log on this PC, and the tamper check.

## Where the two tools differ

`relay.ps1` and `relay.sh` print the same lines for the same room; the test files run the same cases on each.
These differences are known and stay. An agent uses one tool for the life of its generation.

- The self-audit: each tool keeps its own baseline, and one never compares against the other's. `relay.sh`
  tells a changed file by its time alone, does not follow folder links and leaves hidden files of Windows
  out; `relay.ps1` compares size and time, follows links and lists them.
- A wait of the other tool for the same agent on the same machine is taken over, not refused: each tool can
  only ask its own kind of process whether it is alive. The wait that was taken over ends with code 4.
- A failed move of an attachment names the file in `relay.sh` and gives the system's message in `relay.ps1`.
- The attach folder: `relay.sh` moves everything in it, empty folders too; `relay.ps1` moves the files, with
  their folders, and leaves out what Windows marks as hidden.
- In a draft, `relay.ps1` takes every Unicode blank for a blank; `relay.sh` a space, a tab and a line end.
- An age exactly at its limit (two minutes, fifteen seconds) is already over it in `relay.sh`, which counts
  whole seconds, and not yet in `relay.ps1`.
- The files of `show <id>` are listed in byte order by `relay.sh` and in the order the folder gives them by
  `relay.ps1`; the keys in `state`, `card` and `status` come in another order.
