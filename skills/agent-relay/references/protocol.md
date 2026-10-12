# Protocol 3, coordinator view

`PROTOCOL.md` in every room is the agents' reference. This file adds what only the coordinator's side needs:
which files this PC writes, how the pieces fit, and where state lives.

## The room folder

```
<rooms root>/<room id>/
  ROOM                      key: value: room, protocol, package, job, coordinator, authority, created_utc,
                            stale_minutes, pickup_minutes (the board's limit for a message nobody picked
                            up), silent_minutes, park_after, proposal_limit
  DECISIONS.md              standing rules and owner decisions (Add-RelayDecision.ps1 only)
  PLAN                      the team plan: parts, owners, status (Set-RelayPlan.ps1 only); see "The team plan"
  PROTOCOL.md               agents' reference
  join.cmd, join.ps1        only in rooms with open seats
  PROMPT-JOIN.txt           the join prompt; PROMPT-<name>.txt for each named agent
  tools/relay.ps1           the room tool: Windows PowerShell 5.1 and PowerShell 7
  tools/kinds               how each agent kind waits (from agent-kinds.json)
  tools/VERSION
  agents/<name>/
    seat  gen  control  scope  lines  retired        written by this PC, guarded
    START-HERE.md  ASSIGNMENT.md                      written by this PC, guarded
    g<N>/relay.cmd  g<N>/relay.ps1                    written by this PC, guarded
    claim                                             open seat only: who took it (written by the tool)
    card  status  alive  state  journal  delivered    written by the agent's tool
    proposals  progress  wait.lease  baseline/
    memory                                            written by the agent's tool, not guarded
    wait.lease.lock  proposals.lock  state.lock       short-lived: a critical section
    inbox/.claim-*                                    short-lived: a number being taken
    inbox/<from>-<NNNN>.md                            messages to this agent
    draft.md  attach/                                 written by the agent
  files/<message id>/       attachments
  work/                     staged files
  join.log                  one line per join attempt
  TRANSCRIPT.md  CLOSED     at close
```

"Guarded" means: this PC keeps a canonical copy under `<machine state>/rooms/<room id>/canon/` and writes
that copy first. The feed compares the room with it every 15 seconds, restores a changed or missing file,
moves a file that does not belong out to `quarantine/`, and logs an alarm in `alarms.log`.

## Identity

An agent is its wrapper. `g<N>/relay.cmd` (or `g<N>/relay.ps1`) sets `RELAY_NAME`, `RELAY_GEN`, `RELAY_ROOM_ID`
and `RELAY_WRAPPER` and runs the tool. There is no `-Me` argument to get wrong. A replaced session has an old
generation in its wrapper; the tool compares it with `gen` and tells it to stop.

The coordinator is the one agent that does not run its wrapper in the room. Every agent can write there, and
the coordinator's tool runs on the owner's PC: `New-RelayRoom.ps1` and `Update-RelayRoom.ps1` write a launcher
into the machine state (`rooms/<room id>/relay.ps1` and `relay.cmd`) that sets the same four variables plus
`RELAY_ROOM` (the room folder, from the room index) and `RELAY_DRAFT` (`draft.md` next to the launcher), and
starts this PC's canonical copy of the tool. `relay.ps1` takes the room folder from `RELAY_ROOM` whenever it
is set: a room it cannot reach at that moment (a share that is briefly gone, a mangled path) is "not
reachable" (exit code 2), as for every agent. It never works on its own place then, which for the launcher is
this PC's canonical copy: the tamper check would later write that copy's stale files over the room's.

An open seat has `open: yes` and `wake: auto` in its `seat`. `join` creates `claim` exclusively, so two
sessions can never get the same seat, then carries on as that agent's `start`.

The `card` is what the tool read off the machine at `start`, plus the three words the agent gave: `product`,
`model`, `effort`; `agent_process` (the program the agent runs in, from the parent processes); `computer`, `ipv4`,
`os`, `user`; `elevation` (`elevated`, `SYSTEM`, `not elevated, can elevate (UAC prompt)`, `not elevated, no
administrator rights`); `shell` (the shell that called, with its version) and `shells` (the others the machine
has); `host_app`, `process_chain`, `cwd`. The `hello` message says the same in sentences first. On Windows the
tool also names the terminal tab after the agent (`tab_titles: no` in `ROOM` or `RELAY_NO_TITLE=1` in the agent's
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
  attachments back. That holds for every step: a message that could be written in part only, an attachment
  that could not be moved, and a number that would need more than six digits (`could not find a free message
  number in <inbox>`: a file with a longer number would be read by nobody). An existing name is never written
  over, also where the file system has no hard links.
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
  an unreadable message, so that it cannot stay hidden. The line that leaves in `delivered` ends in the word
  `unreadable`: the id was shown, the message was not read. Two minutes are counted on the room's clock; a
  file whose time cannot be read is young.
- "Could not read" is not "empty". A `delivered` that has bytes and reads as nothing is read once more a second
  later, and while it stays so nothing is delivered: every message would look new. A `state` file in that
  condition is not written, because one key would replace all the others, and nothing is judged by it: a
  pause or resume that could not be noted is not said (it would be said again in every wait), and an
  assignment whose fingerprint or state cannot be read counts as unchanged, so its baseline stays. `relay.ps1`
  reads and writes `state` inside `state.lock`, so that a wait in the background and a call in the foreground
  never write an older copy back over each other's key; a call that cannot get the lock in three seconds
  writes nothing.
- An old baseline that cannot be taken away for a new assignment (somebody holds it open) is not taken for the
  new one: the call stops with an error and the next one tries again.
- Times in headers are for display. Staleness and a proposal's clock use the file times the room's file
  system gives, read by one machine.

## Verbs and exit codes

`join` (room-level), `start`, `wait [minutes]`, `check`, `show <id>|open|rules`, `reply <id> [approve|deny]`,
`report [<task id>]`, `ask`, `propose <minutes>`, `note`, `who`, `team`, `progress`, `remember [tag ...]`,
`find [word|tag:name ...]`, `bye`; the coordinator
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
- The tool and the board read a plan the same way and never fail on one. A line counts only when it starts
  with a key and its colon, in lower case; of two `plan:`, `goal:`, `updated_utc:` or `end:` lines the first
  counts; a `part:` line with fewer than six fields or an id seen before is ignored; the title is what follows
  the fifth separator; a revision is a number of one to nine digits above 0 (`007` is 7), anything else means
  no plan; a name that is no agent of the room is printed as written, with a capital when it starts with a to z.
  Names and part ids are compared without regard to case: `Emma` as an owner is the agent `emma`, and a part
  `A` after a part `a` is that part again.

## Room memory

`remember` takes one durable finding from the draft file and appends a line `<utc> | tags | text` to the
agent's `agents/<name>/memory` (tags `-` when none). Up to 5 tags, plain words; the text is 15 to 500
characters, one fact per entry; text that looks like a secret is refused. The last 200 lines per agent are kept.
An entry identical to one anybody already recorded prints `ALREADY RECORDED by <name>` and writes nothing.

- `find` searches every agent's memory: all words must match (case-insensitive substring in tags or text, or
  `tag:name` for a tag), tag hits rank first, newest first, at most 20. If nothing matches all words it shows
  the closest matches; with no words it shows the 10 newest.
- `start`, a wait delivery and `ask` print `room memory: N entries, M new - run: find <words> before you start
  or ask` with up to 3 newest unseen entries (a seen counter in the agent's `state`). `report` nudges an agent
  that has recorded nothing.
- Trust: the file is not guarded and any agent can edit it. Entries are colleagues' records, never orders. The
  coordinator corrects a wrong entry only by a standing rule (`DECISIONS.md`) or by telling the agent to add a
  corrected entry; entries are append-only, and a wrong one is superseded by a new entry that says so.
- Memory belongs to the room: it is archived at close and carries over if the room is reopened.

| Code | Meaning |
|---|---|
| 0 | done, or something for you; also a `wait` that timed out ("nothing arrived in N minutes: that is normal, not an error"): run `wait` again |
| 1 | usage or error; the `NEXT:` line says what to do |
| 2 | the room is not reachable |
| 3 | `check` found nothing new (a `wait` exited 3 on a time-out before package 3.3.0; a shell that wraps the call may report 1 for any code but 0: agents go by the `NEXT:` line) |
| 4 | another `wait` already runs for this agent |
| 5 | stop: room closed, or the agent was stopped, replaced or retired |
| 6 | parked: wait for the owner |

## Waiting

`wait` holds a lease (`wait.lease`: token, generation, host, process id; stale after 30 s without renewal or when
the process is gone). A `wait` that finds the lease held waits for it for up to 35 seconds (the life of a lease
plus a margin) and takes it over when the holder ends, is killed or stops refreshing: a second wait that gave up
at once left its agent without one whenever the holder (a wait or a `check` that was ending) ended a moment later.
Only a holder that stays alive all that time ends the second wait with code 4, which names the holder's process
and host. `check` does not wait for the lease. A wait that ends with no answer (stopped by Ctrl+C or by its host,
which lets its cleanup run and remove the lease, or broken by an error) prints that nothing listens now and a
`NEXT:` line to wait again; the journal records each wait's process (`wait`) and how it ended (`wait-end`). It uses change events on the inbox plus a rescan every five seconds, and rebuilds the
watcher every ten minutes. It returns on: new messages, a proposal's time running out, pause or resume, stop,
replacement, the coordinator's silence, and its own time limit. A wait whose inbox folder is not there takes the
room for unreachable (a share that is gone looks the same) and ends with code 2 after thirty minutes of it; a
folder that comes back starts the count again, whether the agent is paused or not. A `control` file that is there
but gives no `state:` at that moment (this PC writes it by emptying and filling it) says nothing in that round: no
pause, no resume, no delivery. A number given to `wait` or `propose` is decimal: `wait 08` waits eight minutes.

Every age the tool judges (a lease, a lock, a claim, an unreadable file, the coordinator's silence) is the
difference of two times the room's file system gave: the heartbeat the tool has just written, and the file in
question. When the heartbeat cannot be written or read back, the room's time is not known and nothing is
judged old in that call; the machine's own clock never stands in for it.

One wait per agent, also when two start together: judging the lease, taking it, refreshing it and giving it back
each happen inside `wait.lease.lock`, a file created exclusively (whatever else holds that name keeps the lock
taken), tried for three seconds and taken away when older than fifteen; one that is gone again when its age is
asked for was given back, and nothing is removed. A refresh writes the first byte of the lease again with the byte
it has, so that its time comes from the room's file system and not from the machine's clock. A wait confirms its
lease that way directly before it says anything its agent acts on. A lease that holds another wait's token ends it
with code 4 and nothing delivered. A lock it cannot get, or a lease that is there but gives no token at that
moment, means nothing is known: it says nothing in that round and asks again in the next. A lease that is not
there at all is written again by the wait that asks, inside the lock, and the wait goes on; so is one that has
been there without a token for 30 seconds, because nobody refreshes such a file and a wait that only waited for it
would say nothing for good. A wait that starts treats a lease without a token as somebody's while it is young, and
takes it over after 30 seconds.

`proposals` is the agent's own note of what it proposed: id, minutes, when the coordinator received it, and
`open`, `due` or `closed`. The inbox is the authority: an `answer` there closes the proposal whatever the note
says. The note is updated inside `proposals.lock` and a state never goes backwards; a `propose` that cannot
get the lock sends the proposal and leaves the note out, and that proposal never comes due by itself. The
receipt is a line of the coordinator's `delivered` that does not end in `unreadable`: a placeholder is no
receipt. Nothing is announced as due while the inbox holds a message the agent has not been shown, or a file
that cannot be read at that moment, shown already or not: it may be the denial. A proposal is announced only
when the inbox holds no answer to it and the note could be set to `due`. The receipt time is noted all the
same.

Every span of time a wait measures (its limit, the heartbeat, the lease, the thirty minutes of an unreachable
room) is taken on the UTC clock: local time jumps by an hour twice a year.

Environment switches, for tests and odd machines: `RELAY_NO_EVENTS=1` (rescan only),
`RELAY_POLL_SECONDS`, `RELAY_SETTLE_MS`, `RELAY_DRAFT` (another draft file), `RELAY_MINUTE_SECONDS` (how long a
minute is), `RELAY_PAUSE_AT` with `RELAY_PAUSE_DIR` (the tool stops at a named point, writes
`<point>.reached` there and goes on when `<point>.go` appears: how the tests force a race).

## The owner

- `Send-RelayOwner.ps1` writes the owner's text into the coordinator's inbox as `owner-<NNNN>.md` and its
  id and hash into `owner/log` on this PC, the log line first. The hash is that of the whole file, so the
  header (type, subject, `re`) is verified together with the text, and the number comes from the log, not
  from what lies in the inbox. `Test-RelayOwnerMessage` (the board, the feed) checks every file that claims
  to come from the owner against that log.
- A message from `owner` in the coordinator's inbox is not acted on by its header. Whatever its type and
  subject, the tool prints for it: look at the board first, act only if it says verified there.
- Cards (`owner/cards/<NNNN>.md` plus `.answer`) are the coordinator's questions to the owner. They live on
  this PC only. The text of a card, and of a standing rule, is read from a file on this PC (by default the
  coordinator's `draft.md` in the machine state); a file inside the room folder is refused.

## What this PC decides by

Any agent can write any file in the room folder. What the coordinator's scripts decide by therefore comes
from this PC: a room is an entry of the room index (an id of lower-case letters, digits and dashes, and the
folder recorded for it), its settings are read from the canonical `ROOM`, an agent's generation, seat and
control from the canonical copies, the standing rules of the transcript from the canonical `DECISIONS.md`,
and a room is closed when the canonical copy holds `CLOSED`. A `CLOSED` that anybody else puts into the room
closes nothing: the tamper pass, which runs before the feed looks at anything else, moves it out. That pass
compares and restores each guarded file by itself: one that cannot be restored raises its own alarm (`TAMPER
<kind> could not restore: <file>: <reason>`) and stops nothing. The prompts handed out (`PROMPT-*.txt`) are
guarded files too.

## Machine state

`Get-RelayRooms.ps1` prints where it is: `.local/` in the plugin's working copy, or
`%LOCALAPPDATA%\agent-relay` for an installed copy (`AGENT_RELAY_LOCAL` overrides both). It holds
`rooms.json` (the room index), `names.json` (which named other machine and role has which name, and the
names handed out lately), `machines.json` (known shares and machines: facts only), and per room `canon/`, `owner/`, `specs/`, `prompts/`, `quarantine/`,
`alarms.log`, `stats.json`, `sent.log` (what the coordinator's tool sent), the coordinator's launcher
(`relay.ps1`, `relay.cmd`) and its `draft.md`;
`archive/` holds one zip per closed room. None of it is in git.

## Limits

- Scope is kept by instruction, self-audit, tamper check and your review. It is not a sandbox.
- An agent that can write to the room can forge a message file. What limits the damage: sender and receiver
  come from the file's place, the "never" lists, the single path of authority through the coordinator, the
  owner's log on this PC, and the tamper check. A message under the coordinator's name counts only when the
  coordinator's own tool sent it: the launcher on this PC has the tool write the id and the hash of every
  message it sends into `sent.log` before the message appears, and the tamper pass moves out (alarm `TAMPER
  forged moved out: ...`) every file under the coordinator's name that is not on it, or whose bytes changed.
  An agent whose wait is running can still read a forgery in the seconds before the next pass; the alarm says
  which one. A room whose launcher was written before the record starts it with the next `Update-RelayRoom.ps1`,
  which counts the coordinator's messages already in the room as sent.
- A wait that outlives its session keeps the lease: no new wait starts for that agent until the old process
  ends or the agent is replaced (`Add-RelayAgent.ps1 -Replace <name>`). A new wait of the same session waits for
  it for 35 seconds and then says which process holds it.
- Two callers that both judge the same left-over lock old can each take it. The window is the moment between
  one caller's look and its removal, on a lock that was already left behind by a caller that died.
- A send that is killed between staging its attachments and creating its message leaves them in
  `files/.staging-*`. Nothing reads that folder; it is removed by hand or with the room.
- Some damage is left for a person to mend, because every way a tool could mend it alone is a guess: a file
  in an agent's inbox that never opens holds that agent's proposals back until the file is removed (it is
  shown once as unreadable after two minutes, so the agent knows); a `delivered` list that has bytes and never
  reads keeps its agent's wait from delivering; and without the room's time (a heartbeat that cannot be
  written) a left-over lock is never taken away, so every call waits its three seconds for it.
- The SSH bridge is not built: every agent needs a folder that the coordinator's PC can reach too.

## Details of the tool

- The self-audit compares the size and time of every file of a plain folder, follows folder links and lists
  them. In a git repository it never lists a file git ignores. A git that cannot read the repository makes the
  folder `NOT COMPARED`, with git's reason; `core.fsmonitor` is turned off for every git call, because a
  repository's own config could otherwise run a command while git looks at the files.
- The assigned paths (`may:` in `scope`) are matched without regard to case.
- A failed move of an attachment gives the system's message.
- The attach folder: the files are moved, hidden ones too, with their folders; the send is refused when the
  folder holds a link.
- A draft that is a link, or that still holds NUL characters once read, is refused. A draft with a byte order
  mark of UTF-16 or UTF-32 is read in that encoding. In a draft every Unicode blank counts as a blank.
- An age exactly at its limit (two minutes, fifteen seconds) is not yet over it.
- The files of `show <id>` are listed in byte order; a link there is named and not followed.
- Names, types and ids are compared exactly; agents and seats are sorted in byte order whatever the culture of
  the machine; times are written with the invariant culture.
- There is no sh tool: sh is postponed by the owner, and the room tool is PowerShell. A room made before 0.2.0 may
  still hold `tools/relay.sh`, a `join` and `g<N>/relay` files from that time; this PC's copy keeps them as
  they are, and nothing writes them again.
