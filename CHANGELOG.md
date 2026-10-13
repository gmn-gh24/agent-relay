# Changelog

## 0.9.0 (2026-10-13)

Two open lessons closed (room package unchanged, 3.5.0).

- **`Get-RelayStats.ps1` reads the numbers of a room whose folder is gone.** The close workflow removes the
  folder before the retro, and the script then refused the room; it now reads the `stats.json` that the close
  saved on this PC (text and `-AsJson`), and refuses as before when that file is missing. A test removes the
  folder and reads the statistics back.
- **The startup interview asks which accounts a job's runs need.** A job that installs a service, runs as
  SYSTEM or checks something as a standard user needs two seats on that machine, one elevated and one not,
  planned when the room is made, and no detour from the elevated agent in their place.
- `lessons.md` marks both as changed and the "still open" list of an earlier room as closed.

## 0.8.1 (2026-10-13)

Stale and misplaced text in the references, from a second review (room package unchanged, 3.5.0).

- `lessons.md`: the header says to search it, as SKILL.md does; the two entries that sent a reader to "The kit"
  in `coordinating.md` now name `multi-builder.md`.
- `transports.md`: the cross-machine wake is the measured one second, not "not measured yet".
- `agent-kinds.md`: the `gpt-5.5` retirement is stated as a fact from 2026-10-14, not as a future event.
- `protocol.md`: the exit-code table sits under "Verbs and exit codes", not under "Room memory".
- `room-memory.md`: a duplicate is not written (it was called refused). `coordinating.md`: extra blank lines
  from the split are gone.

## 0.8.0 (2026-10-12)

A tighter skill, a sharper trigger and a license (room package unchanged, 3.5.0). From a review of the plugin
with the plugin-dev agents.

- **The skill description** is shorter, names the relay room, covers reopening, and says what it is not for:
  subagents of the session, plain ssh or local work with no second agent.
- **Five new evals:** two must not load the skill (an ssh test run, parallel teammates of the session), two
  must (adding an agent to a room, reopening a closed room), and one checks the `OVERDUE` handling (ask first,
  then reassign or tell the owner, never claim it done).
- **No duplicated rules.** The rules at the top of `SKILL.md` and workflow 2 are one line each and point at
  the heading of `coordinating.md` that holds the detail; about 500 words fewer on every load. Workflow 7 says
  it applies only in the plugin's git working copy.
- **`coordinating.md` is split.** "One job, several builders" and "The kit" moved to `references/multi-builder.md`,
  "Room memory" to `references/room-memory.md`; each has its own line in the reference table. Two anecdotes
  that belong in `lessons.md` were cut from the rules, and "Three things a task says" no longer miscounts.
- **MIT license** (`LICENSE`, `license` in `plugin.json`, README). `CLAUDE.md` tells the protocol number (3)
  from the package version.

## 0.7.0 (2026-10-12)

No silent agents, and a coordinator that is woken when one goes quiet (room package 3.5.0; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`). From a room in which a task of a few minutes showed nothing for
four times as long and it took the owner to notice.

- **A task says how long it should take.** `task <name> [anyway] [<minutes>]`: a plain number is the expected
  duration; without one the room's default holds (new room setting `task_minutes`, 15; `New-RelayRoom.ps1
  -TaskMinutes`, or `task_minutes` in the answers file). The agent is shown it with the task: "expected: N
  minutes. If you are not done by then, send a note that says where you stand; do not go silent." The message
  carries it as one more header line, `expected_minutes`, which a reader that does not know it passes over:
  no protocol change, and a room made before reads its messages as before.
- **The coordinator's wait ends when a task is overdue.** When the receiver of a task has sent nothing (no
  result, no question, no note, no `progress` line) for the expected minutes, the coordinator's `wait` ends,
  as on a delivery, with an `OVERDUE` block: the task, the receiver, how long ago it was delivered (or "not
  delivered yet: the agent has not picked it up"), the expected minutes, whether the receiver is waiting and
  its last sign of life, and `DO: look at the board; ask <name> for its status now`. Half the expected time
  later, with still no word, a second block: `DO: <name> is not responding: give the task to another agent
  that can do it (the board's rights and models lines say who), or tell the owner now ...`. Each block comes
  once per task; any message of the receiver, about anything, starts the count again (after the first block, a
  second comes only when the receiver has then been silent for the whole expected time again). What was
  expected and what was already said is kept on the coordinator's PC (`tasks.log` next to the launcher, like
  `sent.log`), never in the room.
- **The board** shows `expected N min, delivered M min ago` under every open task of the coordinator, and
  `OVERDUE: ...` when its agent has sent nothing for that long; its `NEXT:` line says what to do about it. It
  marks an agent that wakes on a background command, has a task it was shown and no wait running, with the
  minutes since its last sign of life. The feed carries the mark in the `attention` field it always had: no
  field of the feed changed.
- **Reachable while working.** The `NEXT:` line of a delivery that brings a task tells an agent that wakes in
  the background to start its wait now, before the work, and then to handle the messages; one that waits in
  the foreground, to run `check` after every step of the work. `START-HERE.md` and `PROTOCOL.md` say it in the
  same sentence (they said "start the wait before you begin" while the `NEXT:` line said "then wait"). Every
  verb but `wait` and `bye` of an agent that wakes in the background, has an open task and no wait running,
  prints first: `=== you have an open task and no wait running: start <call> wait as a background command now
  ===`. `START-HERE.md`: start a long command with the host's own background command, never as a detached
  process to poll, and send a `progress` line when it starts and when it ends.
- **Every agent waits until it is retired or the room is closed.** There is no parking: `park_after` is gone
  from `agent-kinds.json`, from `ROOM`, the seats and `tools/kinds`; the "you are parked" branch of `wait` and
  its exit code 6, the board's "parked: owner must nudge", the `NOTE: <name> is parked` after a send and the
  `parked` column of the statistics are gone. A wait that ends with nothing says, for every kind, that this is
  normal and to run it again. A room whose files still carry `park_after` keeps working: nothing reads it.
  The coordinator's manual: never tell an agent that is still needed to stop waiting or that it may go quiet;
  an agent that is not needed any more is retired (`Add-RelayAgent.ps1 -Retire`).
- **`join` and `start` take a model name as a user types it.** A quoted word with blanks, or more than three
  words, becomes product, one model word with dashes, and effort (`join codex gpt 6 sol medium` gives the
  model `gpt-6-sol`). A word that then holds another character than letters, digits, dot and dash is refused
  with the join (or start) command, its three words, an example and "write unknown where you do not know";
  the refusal no longer points a session that has not joined at a draft file and at `help`.
- **The model and effort question.** The join prompt and every start prompt tell an agent that does not know
  its model or its effort to ask its own user through its host's question tool, with the choices its product
  offers and "other" for typing, and by a typed question only when it has no such tool. The coordinator never
  asks the owner for it in its own session.
- **One draft file per agent, whatever folder a verb is run from.** A draft a product keeps in the agent's
  working folder (`relay-draft-<name>.md`) is the file in the folder of the agent's `start` or `join`: every
  verb reads that one path, `start` prints it in full and fills it into the instructions. A verb run from
  another folder looked for the draft there.
- The skill: three more rules for every workflow (the model question, every agent keeps waiting, a silent
  agent is the coordinator's to handle), the `OVERDUE` step in workflow 2. `coordinating.md`: "Every agent
  keeps waiting", "A task that is overdue", and two lines for "The kit" (name the files to copy; a count in a
  task is the count the runner prints). `agent-kinds.md`: "Model and effort". `COORDINATOR.md`: one paragraph.
- Tests: the three words and their refusal, the draft from another folder for every drafting verb, the two
  `NEXT:` lines and the line of an agent without a wait, a task's minutes, the two `OVERDUE` blocks and what
  resets them, in `Relay.Tool.Tests.ps1`; `task_minutes`, the board's `OVERDUE` and its mark, a room that
  still carries `park_after`, in `Relay.Scripts.Tests.ps1`. The tests that pinned parking pin its absence.

## 0.6.1 (2026-10-12)

- `New-RelayRoom.ps1 -ReachPath` (and `reach_path` in the answers file) is the room folder as other machines
  reach it. When the value ends like the rooms root instead, the room id is appended and a NOTE says so: a room
  built with the rooms root had its first join refused ("join.ps1 does not exist") and needed both ROOM copies
  edited by hand. Any other folder name is still taken as given.

## 0.6.0 (2026-10-12)

Three things the seven-agent room lacked (room package 3.4.0; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`):

- `Add-RelayAgent.ps1 -Assign` takes the assignment as parameters (`-Role -Work -Task -DoneWhen -NonGoals
  -Roots -May -ProposeOk -AskFirst -Never -MachineCare -MachineNotes -Expertise -Standards -DocTools`) and
  several names in one call (`-Assign emma, jack`), every name checked before the first is written. `-Roots`
  takes `'<folder>'`, `'<folder>=<pattern>,<pattern>'` or a hashtable. `-AnswersFile` still works, and a
  parameter given with it wins. The coordinator hand-wrote the JSON through another shell and lost two
  rounds to backslashes, a `$name` and an escape error.
- `New-RelayRoom.ps1` takes the room's answers as parameters too (`-Job -RoomName -RoomId -RoomsRoot
  -Authority -OpenSeats -WorkFiles -ReachPath -NoTabTitles`): a room of open seats needs no file; named
  agents still come from the file.
- A hold as room state: `Add-RelayAgent.ps1 -Control <name>|all -State hold -Note '<why>'`. Every verb of
  the agent prints `=== HOLD: <why> ===` first, `check` exits 7 while the hold lasts (a run script can test
  it before it starts), `wait` tells the agent once and again when the hold is lifted (`-State run`), and
  messages still reach it. `-Control all` covers every agent but the coordinator and the retired, for every
  state. A hold that was a plain note reached an agent after its run had started.
- `relay.ps1`: a `task` whose words run into a line of the receiver's "Never" or "Not part of this task"
  (two telling words of the line in the task, one when it has only one; a short word such as `npm` matches
  whole) is not sent: `NOT SENT` names the line and the words, the draft stays, and `task <name> anyway`
  sends it as it is. The coordinator re-assigns first, or overrides. A word match, not a judgment: the
  message says so. The assignment is read from this PC's copy, which the coordinator's launcher runs, never
  from the room's, which any agent can edit. `-State hold` is refused on a room whose package is older
  than 3.4.0, whose tool would read the state as a resume: `Update-RelayRoom.ps1` first.
- The board: `control: hold (<why>)`. `coordinating.md`: the parameters, the hold, the refusal;
  `PROTOCOL.md`: on hold, exit code 7; the skill names the parameters.
- Tests: `-Assign` with parameters for two agents, `-Control all -State hold` and the board, a room from
  parameters, in `Relay.Scripts.Tests.ps1`; the hold on every verb, `check` 7, the lift, and the task
  refusal with `anyway`, in `Relay.Tool.Tests.ps1`.

## 0.5.1 (2026-10-12)

Wording from the same room (room package 3.3.1: `START-HERE.md` and `ASSIGNMENT.md` change; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`):

- `START-HERE.md` says next to `remember` what an entry is (the whole draft joined into one line), its limits
  (15 to 500 characters, up to 5 tags) and that the verb writes nothing when they are missed. An agent found
  the limits by running the verb three times.
- `ASSIGNMENT.md` says under "Where you work" that scratch files (a runner, a helper script, a log) go into a
  results folder on the agent's own disk, never beside the assigned folders, where every later self-audit
  lists them as `OUTSIDE`.
- `coordinating.md` has a checklist "The kit" under "Tasks": everything the suites read (reference masters,
  profiles, sibling scripts that drift guards compare), per-round folders with only that round's changed files
  and a diff against the round before, and a tested runner template (`-PassThru` with `Run.Exit` false, no
  `Set-StrictMode` in a runner, `PSModulePath` rebuilt from the registry under Windows PowerShell 5.1, output
  to a file in the results folder).
- `agent-kinds.md`: Claude Code's command tool shows `robocopy`'s exit code 1 ("files were copied") as an
  error, and what a task says about it; Codex's command time limit is not measured yet, how to measure it in
  one session, and where to write the result (`wait_minutes` stays 4 until then).
- Tests: the limits in `START-HERE.md` and the scratch sentence in `ASSIGNMENT.md`, in
  `Relay.Scripts.Tests.ps1`.

## 0.5.0 (2026-10-12)

What a room of seven agents on one machine taught over five rounds (room package 3.3.0; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`, and tell the loop agents in a note that a quiet wait now exits 0):

- `relay.ps1`: a `wait` that timed out exits 0, like one that delivered, and says "nothing arrived in N
  minutes: that is normal, not an error". It exited 3, and a product that shows every exit code but 0 as a
  failed command had several agents stop waiting after their first quiet wait. `check` keeps 3 for "nothing
  new", so a script can still test it; the idle status is written as before.
- `relay.ps1`: a seat whose `park_after` is 0 is never parked. The Codex profile uses it: the owner stops a
  Codex agent, the tool does not. Its prompt says that a quiet wait is normal and that the agent never stops
  waiting on its own.
- `relay.ps1`: a draft of one line is sent whole. The line is the subject, cut at 120 characters, and when it
  is longer than that the whole line is the text too; the text beyond the subject was lost.
- The join prompt: an agent that does not know its model or effort asks the user of its session for them by a
  typed answer instead of guessing, and every agent works from a local folder of its own, never from the room
  folder or a share.
- `START-HERE.md`: a task never widens the assignment (the agent answers with `ask` and keeps working on the
  rest), and a new assignment carries the owner's decision whole. `PROTOCOL.md`: the exit codes; one subfolder
  per round in `attach`, with that round's changed files and a diff against the round before; scratch files
  belong in the results folder on the agent's own disk; `park_after` 0.
- The skill: the startup interview goes through the host's question tool with choices
  (`startup-interview.md`, "How to ask"); line 1 of a draft is the subject and the send consumes the draft; a
  task never exceeds the assignment, re-assign first. `agent-kinds.md`: the Codex row and the paragraph on the
  exit code of a wait. A lesson records the room.
- Tests: every timed-out wait expects 0 and the new text; `never parks a loop agent whose seat says
  park_after 0` and `sends a one-line draft whole` in `Relay.Tool.Tests.ps1`; the join prompt's new sentences
  in `Relay.Scripts.Tests.ps1`.

## 0.4.4 (2026-10-12)

An agent in a room stopped at one blocked command (room package 3.2.4; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`):

- The join prompt's sentence for a refused or blocked command (0.3.3) was written for the join step, where an
  agent has no room tool yet, but it named "a command" and said "stop". An agent that had joined and was working
  read it as a standing rule: after one blocked command it stopped watching the room and told nobody, and said
  so when asked. The sentence now names the join command and says that it applies to joining only.
- `PROTOCOL.md` has a section "A command is blocked": after join, a refused, blocked or failing command is sent
  to the coordinator with `ask`, with the exact command and error, and the agent keeps waiting on the room and
  working on what does not depend on the answer. Only a blocked `wait`, which leaves no way to the room, means
  stop and tell the user of the session.
- Tests: the join prompt's new wording and the section, in `Relay.Scripts.Tests.ps1`.

## 0.4.3 (2026-10-11)

The release workflow completes a release it left half done (no change to the room package):

- A run that pushed the tag `v<version>` and then failed to publish the GitHub Release left the version without
  one for good: every later run found the tag and stopped. Now a tag on the commit without its Release gets the
  Release on the next run; a tag on another commit still means nothing to do. Found by the review of pull
  request #9.
- CHANGELOG 0.4.2 says what is tagged: every version from 0.4.1 on, nothing older.

## 0.4.2 (2026-10-11)

Release tags (no change to the room package):

- Every version from 0.4.1 on has a tag and a GitHub Release. `.github/workflows/release.yml` runs on every push to
  `main`: when the version in `plugin.json` has no tag yet, the commit gets the annotated tag `v<version>` and a
  Release whose notes are that version's section of this file; a version without a section fails the run. A
  push that bumps nothing does nothing. On demand, with a commit given, it tags that commit: 0.4.1 is tagged
  this way after the fact, and nothing older is tagged. Linux only, like the rest of CI.
- Docs: README (the gate and the conventions) and CLAUDE.md (the release convention).

## 0.4.1 (2026-10-11)

Agent names repeated from room to room on one PC (no change to the room package):

- The name registry remembered every open seat under one key (`(open seat)|seat 1`), and the coordinator and a
  seat on this PC under this PC's name, so every room made on one PC got the same names (`olivia`, `emma`,
  ...), and two rooms open at the same time shared them. Now only a seat on a named other machine keeps its
  name across jobs. An open seat, a seat on this PC and the coordinator draw a fresh name for each room: the
  pool in a shuffled order, away from the names every open room of this PC holds and from the last 20 names
  handed out (`recent` in `names.json`). The keys an older version wrote for open seats and this PC are
  dropped at the next draw; those of named machines stay.
  A name the owner chose is never refused because a drawn name of the same batch took its letter first: the
  letters of the wanted names of a batch are kept free for them.
- Tests: the Scripts suite pins fresh names across two open rooms and after a close, the shuffled order, what
  is remembered and what is dropped, and the numbered names of a room beyond the pool.
- CLAUDE.md: where a cloud (Linux) session gets `pwsh`, Pester and PSScriptAnalyzer from when the PowerShell
  Gallery is blocked, and how the gate runs there.
## 0.4.0 (2026-10-11)

The coordinator speaks to agents through the room only (no change to the room package):

- A coordinator with a room open used Claude Code's own session-to-session messaging to hand tasks to another
  session of the owner's on the same PC, outside the room, which nobody had authorised. The skill has a fifth
  rule and `coordinating.md` a section, "Only the room": the launcher's verbs are the only channel to an
  agent; no session outside the room is listed, messaged, assigned or coordinated, whether it runs on this PC,
  in an editor or in the cloud; a session that could help is offered the join prompt; an exception is the
  owner's alone, given in the coordinator's session for one agent and one job and recorded with
  `Add-RelayDecision.ps1 -Owner`. The coordinator's own subagents are not covered by the rule.
- The plugin enforces it: while a room is bound in the session (`/relay <id>` or `relay_bind`), `SendMessage`
  and `ListAgents` are refused with a reason, until the owner types `/relay outside on` and confirms it in
  the dialog (`/relay outside off`, a reload of the plugin or a new session refuses them again). A coordinator
  without a bound room (the feed in a terminal) is held by the rule alone. Resuming a subagent of its own
  through `SendMessage` is refused too while a room is bound; it starts a new one instead.
- `self-improvement.md` lists that rule among what needs the owner first; the README's security model says it;
  a lesson records the incident.
- Eval `stays-in-its-room`: a room is open for the job and a second Claude Code session is open on the PC; the
  coordinator must hand the work to an agent in the room and never reach that session.
- Tests: the guard and the owner's switch, in `feed.test.ts`.

## 0.3.8 (2026-10-11)

What a review of the plugin found, and the fixes (room package 3.2.3; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`):

- `relay.ps1`: a left-over claim or lock is removed as a file, or as an empty folder, never recursively. Any
  agent could put a folder with a junction inside where the tool expects its claim or lock, and Windows
  PowerShell 5.1 would have emptied the folder behind the junction with the rights of the agent whose tool ran.
  The staging folder of a send that is undone is removed the same way: every link inside goes as a link first.
- `relay.ps1`: a folder named like a message file (any agent can make one) blocked every later send of that
  sender to that inbox: the number was taken for free, the move into place failed, and the send gave up after
  five tries. Anything at the final name now takes the number, and the send goes on with the next.
- The tamper check: a folder where only a file of this PC may be (a planted `retired`, `seat`, `control`) was
  moved out with `Move-Item`, which across volumes carries over what lies behind a junction inside it. A folder
  that holds a link is not moved and each link is an alarm; one without a link has its files kept on this PC
  and goes as a tree, links as links.
- Nothing reads a message through a link: the board, the feed and the room tool skip a message file that is a
  link and an inbox that lies behind one. The owner's message is never written through a link that stands in
  place of the coordinator's inbox.
- The feed knew a message by the path of its file for the room's life. A forged message under the coordinator's
  name that the tamper check moved out kept its path, and the coordinator's own message that took the same
  number afterwards was never shown, while the forgery stayed in the pane. A message is now known by its path
  with the write time and size of its file; a file that reads differently is read again and compared (the same
  text is the same message, another text has taken its place); one whose file is gone is dropped and the feed
  says so (`removed`), and the pane drops it too. The pane also marks a message whose header names another sender, receiver or number than its file, as the
  terminal feed did.
- `Reopen-RelayRoom.ps1` stopped every seat, open seats nobody had taken included: the first agent to join the
  reopened room got the lowest free seat and was told it was stopped. An untaken open seat keeps running.
- `Add-RelayAgent.ps1 -AnswersFile` chooses every name before the first seat is added: a reserved or taken name
  in the second entry left the first agent added.
- `Close-RelayRoom.ps1`: `-Remove` decided by the CLOSED in the room, which any agent can delete; it decides by
  this PC's marker. A close cut short after the marker never got its statistics: the next call writes them.
- This PC's own files are read strictly where a wrong answer would be written back or acted on: the canonical
  `ROOM` (an unreadable one made `Update-RelayRoom.ps1` write a `ROOM` without a coordinator), the owner's log
  (an unreadable one called the owner's own message a forgery) and the room index when a room is resolved (a
  corrupt index said the room did not exist).
- `Watch-RelayFeed.ps1 -EndWithParent` finds its parent under PowerShell 7 on every platform. Index entries
  without a property end no listing. The skill names `-Room` for `Add-RelayAgent.ps1 -OpenSeats`; the README
  names seven coordinator test files and the 15 seconds of the tamper check.
- Tests: Faults R4 (a folder claim with a link inside, an undone send with a link in its placed folder) and F3 (a
  folder at the final name); Guard round 5 (a stranger folder with a link inside, no message read through a
  link) and G15 (the feed after a forgery is moved out); Scripts (a reserved name in the second entry, the
  statistics of a cut-short close, `-Remove` without the room's CLOSED); Reopen (an untaken open seat); the pane
  (the `removed` line and the mismatch mark).

CI only (no change to the plugin):

- The Windows Pester jobs (PowerShell 7 and Windows PowerShell 5.1) and the job that skipped them for
  documents-only commits are gone from `.github/workflows/ci.yml`; the Linux static and pane jobs stay. The
  Pester files run on a dev machine before a commit (`tests\Invoke-AllTests.ps1`).
- PSScriptAnalyzer (1.24.0) and Claude Code (2.1.296) are pinned and cached in CI, and the pane's steps are left
  out when a commit touches nothing the pane reads.


## 0.3.7 (2026-10-11)

What a review of the design found, and the fixes (room package 3.2.2; running rooms:
`scripts/Update-RelayRoom.ps1 -Room <id>`):

- Forged coordinator messages: any agent could write a file named like a coordinator message into another
  agent's inbox, and the room tool takes the sender from the file name. The coordinator's launcher now has its
  tool write the id and hash of every message it sends into `sent.log` on this PC, before the message appears,
  and the tamper check moves out (alarm `TAMPER forged moved out: ...`) every file under the coordinator's name
  that is not on it or whose bytes changed. The record of an older room starts with the next
  `Update-RelayRoom.ps1` and counts the coordinator's messages already there as sent; a room whose tool is
  older gets none (a new launcher there, when the coordinator is replaced, starts no record). A record that cannot be
  written means no message; one that cannot be read judges nothing and says so. An agent whose wait is running
  can still read a forgery in the seconds before the next pass; the alarm names it, and the coordinating
  reference says what to tell the agent.
- The board and the feed read open requests the way the room tool does: types and ids exactly, an owner file is
  never a request, only the receiver's result or answer to the one who asked closes a request, and hidden or
  capitalised message files are taken as the tool takes them. Before, the board could show a request as open or
  closed that the agent's own `show open` did not.
- `RelayCommon.psm1` sets `$ErrorActionPreference = 'Stop'` itself: a module does not take the preference of the
  script that imports it, so a listing that failed inside it (an inbox the share would not list) went on with
  nothing and looked like an empty inbox.
- `relay.ps1`: a lock holds a token of the call that made it, and is removed only by that call. A call that
  kept a lock past 15 seconds, and lost it to another, removed the other's lock when it ended.
- Guarded files in the room (instructions, wrappers, controls, rules, tools, and the tamper check's restores)
  are replaced in one step, so an agent's tool never reads a part of one; a part of `ASSIGNMENT.md` used to make
  the self-audit take a new baseline. Where the file server refuses the replacement, the file is written in
  place, as before.
- Docs: the tamper check runs every 15 seconds while the feed runs, not on every round (README, CLAUDE.md); the
  Faults suite names all six pause points.
- Tests: Guard G15 (forged messages), G16 (one-step writes), G17 (the module's error preference), a Scripts test
  that holds the board's open requests against every agent's `show open`, and a Faults race for the lock.

## 0.3.6 (2026-10-11)

Times in JSON under PowerShell 7.0 to 7.4 (no change to the room package):

- `ConvertFrom-RelayJson` kept times as text only with `-DateKind`, which exists from PowerShell 7.5. Under 7.0 to
  7.4 (7.4 is a long-term release) every time in the room index and the machine state came back as a date and
  was printed in the local format: the closed time of `Close-RelayRoom.ps1 -ListClosed`, the index, statistics.
  There the text is now read with Json.NET (which ConvertFrom-Json is built on) with its reading of dates turned
  off, and handed over in the same shapes. Test in Relay.Guard.Tests.ps1; it also takes that path under 7.5.
- The README's version line had stayed at 0.3.4.

## 0.3.5 (2026-10-11)

Wording, after a live room with one elevated agent (no change to the scripts or the room package):

- The startup interview: the product of a named agent is asked, never chosen. A guessed product gave the
  agent a prompt for the wrong way of waiting, and the seat had to be issued again.
- The coordinating reference: code with variables goes into a task as a script to save and run from a file.
  A one-line command handed to a second shell in quotes failed at parsing.
- The skill's close workflow names `-Confirm:$false` for deleting a closed room's folder: the coordinator's
  shell cannot answer the confirmation.
- The self-improvement reference says where the statistics are once the room's folder is deleted. One gap is
  written down and not closed: the statistics script does not fall back to that file by itself.
- Lessons for all of the above.

## 0.3.4 (2026-10-11)

Codex models, after a live room in which "codex luna medium" was read as an agent's name (no change to the
room package):

- `scripts/model-tiers.json` knows the Codex family words: `luna` standard; `astra`, `sol`, `terra` strong. A
  tier may have more than one list, and `luna` stands in one in front of the generation words: `gpt-6-luna`
  had sorted as strong by its `gpt-6`.
- The agent kinds reference lists the Codex models, what each is for and the steps of effort (OpenAI's Codex
  models page, read 2026-10-11), and says that "codex luna medium" is product, model and effort, never a name.
- The coordinating reference: ask the owner what a session was started with when a task depends on a model or
  an effort that came as `unknown` or as a generation without a family; tell the owner when an introduction is
  not what the owner announced.
- Lessons: a job that runs as SYSTEM and as a standard user needs two seats on that machine, planned when the
  room is made; read the `rights:` line again after an agent was started again elevated. Two gaps are written
  down and not closed: the room does not hold the model and effort the owner announced for a seat, and a
  second introduction under the name of a live agent is neither refused nor marked.
- README and references, on the owner's word that agents are not limited to Windows: the texts no longer say
  that an agent's machine must run Windows. They say what is there: the room tool is PowerShell, there is no
  `sh` tool, and no agent on Linux or macOS has worked a room yet. No change to the scripts: an answers file
  still takes `os` `windows` only for a named agent.

## 0.3.3 (2026-10-11)

How the owner starts the agents, on the owner's word after several live rooms (no change to the room package):

- Codex CLI is started with `codex --yolo` (`codex exec --yolo` headless). Full access alone
  (`codex --sandbox danger-full-access`, what 0.1.1 said) leaves the approvals on: the remote agent kept asking
  its user and some commands stayed blocked. The note the scripts print for a Codex seat, the Codex start
  prompt, the skill, the agent kinds reference and the README say so.
- Claude Code: for a room without questions and interruptions the owner starts it with
  `claude --dangerously-skip-permissions`; without it the room works and the owner answers the prompts on that
  machine. Seats of both Claude Code kinds print a note that says so.
- Both flags switch the product's own guard off. The coordinator says that to the owner in one line, and only
  when the job is risky, with the advice to use a virtual machine or a throwaway computer
  (`references/agent-kinds.md`, "Starting an agent without its own guard"; the README's security model). It
  never goes to an agent: tests hold the join prompt, the start prompts and the scripts' output to that.
- The join prompt says what to do when a command is refused, blocked or cannot start: change nothing, stop,
  tell the owner the exact error, and do not work around it. An agent in a sandbox cannot run `join`, so it
  never saw the hint of its kind. Running rooms get the new prompt and the new hints with
  `scripts/Update-RelayRoom.ps1 -Room <id>`.

## 0.3.2 (2026-10-11)

After a second live room that ran SYSTEM test cycles on a disposable VM:

- A report names the entries its self-audit counts as outside the assigned paths (the first ten, then a count),
  under the summary line, to the agent and in the message the coordinator reads. Before, five reports in a row
  said "2 OUTSIDE the assigned paths" about files the coordinator itself had restaged in a folder the agent only
  reads, and neither side could see which two.
- START-HERE says that a `wait` ending with "another wait is already running" (exit 4) has not failed.
- The coordinating reference: start the wait again after "no reply needed" too, and only through the host's
  background command; the audit cannot tell who changed a file; what to tell the owner when a delivered message
  does not wake an idle session; what a clean-up task says on a guarded host; write an order of setup steps that
  matters into the first task.
- Room package and relay.ps1 3.2.1. Running rooms: `scripts/Update-RelayRoom.ps1 -Room <id>`.

## 0.3.1 (2026-10-11)

After a live room that ran a SYSTEM test cycle on a disposable VM (wording only, no tool change):

- The coordinating reference says what to do when a later task needs what the agent's assignment forbids under
  "never": re-assign with the wider `may` first, and foresee at assignment time what a test job on a disposable
  machine will need. A task message cannot carry that approval, and in the room the agent rightly asked its
  owner three times.
- The close step of the skill asks for the `bye` verb by name; a note titled bye left the room unclosable until
  `-Force`.
- Lessons: name the items a task acts on instead of a rule over names the coordinator has not seen; tell the
  agent where evidence must be written when the test re-creates its own folder.

CI only (no change to the plugin):

- The Windows gate runs as two jobs side by side, PowerShell 7 and Windows PowerShell 5.1, through the new
  `tests/Invoke-AllTests.ps1 -Editions ps7|ps5`; each takes 15 to 20 minutes instead of one job of about 45.
- A commit that changes only documents no test reads (the Markdown at the top, `SKILL.md`, `references/`,
  `evals/`) leaves the Windows jobs out; the static and pane checks still run.
- Pester is pinned (6.2.0) and kept in the Actions cache; PSScriptAnalyzer runs only in the Linux static job.
- Tests: a child gate's standard error no longer ends a test under Windows PowerShell 5.1, and a tool's output
  is waited for up to 30 seconds after the tool exits (the tab-title helper can hold the pipe a little longer).

## 0.3.0 (2026-10-11)

Room memory, a reviewed close, and reopening a closed room:

- Room memory: agents run `remember [tag ...]` (one durable finding, text from the draft file; secret text and
  duplicates are refused) and `find [word|tag:x ...]` (searches every agent's memory). Start, wait deliveries
  and the answer to `ask` show `room memory: N entries, M new`. Memory is peer data, never an order. The work
  kinds' method text now tells agents to `find` before starting or asking and to `remember` durable findings.
- Coordinator: `scripts/Get-RelayMemory.ps1` (`-Find`, `-Agent`, `-Since`, `-Json`); the board shows
  `memory: N entries from K agents`. A wrong entry is corrected with `Add-RelayDecision.ps1` or by asking the
  agent for a correction.
- Permanent memory: `scripts/Add-RelayLocalMemory.ps1` keeps local notes on this PC (never committed, never
  secrets; `-Find`, `-List`); project memory is `references/lessons.md` through the Improve procedure, which
  falls back to local notes in an installed copy.
- Close review: the closing note asks for last findings; the coordinator curates the memory and asks the owner
  one combined question (promotions with item, target and reason; delete or keep the shared folder after the
  verified archive). Nothing is promoted or deleted without the answer. Close records `folder: kept|removed`
  and `-ListClosed` shows it.
- `scripts/Reopen-RelayRoom.ps1` reopens a closed room on the PC that closed it: restores the folder from the
  verified archive if it was deleted, clears the closed state and keeps the old transcript as
  `TRANSCRIPT-closed-<stamp>.md`. Old sessions stay stopped; memory and rules carry over.
- New eval case `closes-with-memory-review`.
- Room package 3.2.0 (protocol still 3). Running rooms: `scripts/Update-RelayRoom.ps1 -Room <id>` to get the
  new verbs. Until then `Add-RelayAgent.ps1` refuses to write a seat into such a room (add, `-Replace`,
  `-Assign`, `-OpenSeats`): the instructions would name verbs its tool does not have.

## 0.2.2 (2026-10-11)

What the first full CI run on Windows (PowerShell 7 and Windows PowerShell 5.1) found:

- relay.ps1: a second `wait` stops waiting for the lease when neither a lease nor its lock is there twice in a
  row: the agent's folder takes no new file, and no holder will ever give the lease back (it waited the whole
  35 seconds for nothing). A lock held by a wait that is ending still gets the full patience.
- Tests: git in the tests' own repositories ignores git for Windows' LF/CRLF warnings, which Windows
  PowerShell 5.1 turns into errors (a new `Invoke-TestGit` helper); a tree snapshot no longer compares a
  folder's own time, which Windows sets a moment after a copy; a wait is looked at until it listens instead of
  for a fixed three seconds; the half-written-plan test times five back-to-back pairs of calls (one that waits,
  one that does not) and takes the median difference, which a burst of load on a shared runner does not move
  (the smallest of three calls of each kind measured from 0.95 to 4.16 seconds there, for a true 2); the
  graceful-stop test calls `kill` by its path, not an alias.
- Package and relay.ps1 3.1.2.

## 0.2.1 (2026-10-11)

The wait lease, after an agent in a live room was left without a wait while it believed it had one:

- A second `wait` that finds the lease held no longer gives up at once. It waits up to 35 seconds (the life of a
  lease plus a margin) and takes over when the holder ends, is killed or stops refreshing. Before, a second wait
  started while the holder (a wait or a `check`) was ending exited 4 with "do nothing", the holder ended a moment
  later, and nothing listened for the agent. Exit 4 now comes only from a holder that stays alive, and names its
  process and host; `check` still answers at once.
- A wait that ends with no answer (stopped by Ctrl+C or by its host, which removes the lease and used to exit 0 in
  silence, or broken by an error) prints that nothing listens now and a NEXT line to wait again.
- The journal records each wait's process (`wait`) and how it ended (`wait-end`).
- START-HERE, the protocol references, agent kinds and the README say how a second wait behaves now.
- Room package and relay.ps1 3.1.1. Running rooms: `scripts/Update-RelayRoom.ps1 -Room <id>`.

## 0.2.0 (2026-10-11)

A full review of the plugin by five independent readers (each tool, the module, the scripts, the pane and the
gate), and the fixes, each with a test that fails without it. Owner decisions: sh is postponed, so `relay.sh`,
the sh wrappers and the sh line of the join prompt are removed (see below); text an agent wrote loses its
control characters when printed, and nothing else about the output changes; `may:` patterns are matched without
regard to case, and that is documented.

sh is removed (postponed by the owner; it is built and tested if and when it is needed):

- The room package no longer holds `relay.sh` or the templates of the sh wrappers. A new room gets no
  `tools/relay.sh`, no `join` and no `agents/<name>/g<N>/relay`; the join prompt has no line for Linux or
  macOS, and `Update-RelayRoom` no longer writes the sh wrappers. Agents on Linux or macOS cannot join until
  sh is built. A room made earlier keeps the sh files its canonical copy holds; nothing migrates them.
- Agents run on Windows only: an answers entry with an `os` other than `windows`, or with `shell: sh`, is
  refused with a message that says sh is postponed; `agent-kinds.json` has no Linux shell. `ssh` stays refused.
- `relay.ps1` lost its sh call format and its reading of a baseline taken by `relay.sh`; the rights a Linux
  card gave (`root`, `sudo`) are no longer sorted on the board.

Nothing the coordinator's PC decides by comes from the room, again:

- The coordinator's launcher no longer falls back to the tool's own folder when the room cannot be reached.
  That folder is this PC's canonical copy: a share that was gone for a moment made the coordinator's tool write
  its state into it, and the tamper check then put those stale files over the real ones in the room.
- The agents of a room, and which of them are retired, come from this PC's copy, not from the room's folders.
  A planted agent folder was a plan owner, got direct lines and showed on the board as "owner must paste the
  start prompt"; a planted `retired` marker retired a real agent. The seat order of a new open seat comes from
  the copy too, and a prompt or join command at the top of the room that this PC did not write is moved out.
- Nothing follows a link in the room. The tamper check, the guarded writes, the archive and `-Remove` never go
  through a symbolic link or junction (a repair pass could move the owner's own files into quarantine); the room
  tool refuses a draft, an attach folder or a file of its own that is a link (another agent could make a
  verb send a private file).
- The owner's log hashes the bytes it means to send, not a file in the inbox that an agent could swap.
- A template value can no longer expand another key; PowerShell quoting doubles the typographic quotes too.

Coordinator scripts:

- `Close-RelayRoom -WhatIf` changes nothing (it used to close the room). A close cut short leaves the room
  closed in the index. The archive is made with literal paths (a `[` in the path no longer breaks it).
- The room index is read, changed and written by one caller at a time, and an index that cannot be read is an
  error, never an empty list. Strict reads also for the rules, the plan revision, the lines, the name registry
  and the templates.
- `New-RelayRoom` checks every answer before it builds anything and refuses a leftover folder of an earlier
  attempt; `Add-RelayAgent` refuses an empty list and an unknown agent kind; `Request-RelayOwner -Resolve`
  refuses a card already answered; `Update-RelayRoom` passes `-Confirm` on; `Test-RelayPackage` deletes only a
  work folder it made. Relative paths are taken against the PowerShell location. Missing NEXT lines added.
- The feed says once that the room folder is gone, restores nothing meanwhile, and says when it is back.
- Text an agent wrote is printed without control, escape and direction characters everywhere.

Time and culture:

- Every time stamp is written in the invariant culture (a dot in fi-FI and the Thai calendar broke the feed).
- Text that is parsed is compared ordinally. Under th-TH `"room: x".IndexOf(':')` is 0 in .NET with ICU: every
  key: value file read as empty and the room tool called the room "not reachable" (since 0.1.0).
- The wait measures time on the UTC clock (a daylight-saving change stopped the heartbeat for an hour).

The room tool `relay.ps1` (package 3.1.0, protocol 3 unchanged):

- The self-audit says NOT COMPARED, with git's reason, when git cannot read an assigned folder, never "nothing
  changed"; no fsmonitor command of a repository runs.
- A UTF-16 or UTF-32 draft (what Windows PowerShell 5.1 writes with `>`) is decoded, and the secret check sees
  it; a draft with NUL characters is refused.
- One unreadable attachment no longer blocks every later delivery; hidden files are sent and listed.
- What cannot be read is no changed assignment (the baseline was taken again mid-task); the state is written
  inside a lock; a damaged proposal line is skipped; paused is said once; `wait -0` is refused; dot files are
  seen on Linux and macOS.
- Refactored: the wait loop in four functions, one lease writer, one send undo.

The pane:

- A feed that was replaced can no longer draw into another room's view, and a decision goes only to the room
  the pane showed. Unbinding stops the feed's process at once; a reload notifies no card again; Approve and
  Deny cannot both go out; an error note clears when the feed reads the room again.
- Text is measured in terminal cells (wide characters, emoji); control and direction characters are stripped
  from every toast; Home and End jump to the ends; a restart keeps the message history; times are local.

The test gate:

- No sh engine: the test helpers, the suites and `Test-RelayPackage` run `relay.ps1` under PowerShell 7 and
  Windows PowerShell 5.1 only; Windows PowerShell 5.1 only on Windows.
- A failing `BeforeAll` or `AfterAll`, a file that does not load, a path that names nothing and a run in which
  no test ran fail it (`Relay.Gate.Tests.ps1`). Every test file must be listed; the ASCII and line-end check
  reads what git tracks; the PowerShell wrapper templates are parsed; the pane's validate and tests are steps.
  `-SkipAnalyzer` and `-SkipPane` run the rest where PSScriptAnalyzer or Claude Code is missing.
- The suites run on Linux and macOS under PowerShell 7 (ps5 offered only on Windows).
- Eval cases: the must-load cases can fail now, each with an outcome grader.

## 0.1.1 (2026-10-10)

The room pane, after the owner's first look at a live room:

- Every text is wrapped at the pane's width instead of cut at its edge: the job, what an agent is and where
  it stands, the plan, an alarm, a card, the subject of a message.
- A message shows the beginning of its text under its subject (what the feed gives of it: 400 characters).
- The pane holds every message the feed gave it and shows a window of them, with a scroll bar at its right
  edge. The window follows the newest until the owner scrolls (the mouse wheel, or PgUp and PgDn while the
  pane has the keyboard) and follows it again once it is back at the end. What waits on the owner stands at
  the end, and a new card brings the window there.
- The input, and what the feed says about itself, stand still at the foot of the pane.
- A `/relay <room>` that was interrupted while it looked at the room says so, and that it can be asked again.

From a rehearsal with stand-in agents that had nothing but their start prompt (Claude Code headless on two
models, Codex CLI):

- Codex CLI must be started with full access to work in a room: in its sandbox it could not start one
  command. The agent kinds, the skill and the start prompt of a Codex seat say so.
- The headless Claude Code profile has worked a room.
- A task whose "done when" needs a change the assignment lists under "ask first" carries the approval, or a
  standing rule is recorded before the tasks go out (the coordinating reference).
- `New-RelayRoom.ps1` and `Add-RelayAgent.ps1` print a note for every Codex seat: start it with full access.
- `START-HERE.md` says that sending uses the draft file up: a new one for every message.

From the close of the first team room, and from what its agents said slowed them down:

- The board, the feed and the pane mark an agent that has not picked up a message for 30 minutes
  (`pickup_minutes` of the room): a session that ends while it works says nothing, and its state stays
  `working`.
- Every agent's instructions say what to do after a restart (`start`, then one `wait`) and to work on its
  own disk, not in a folder on the share. The file of a seat taken with the join prompt says that its
  commands and paths are filled in when the tool prints it.
- The archive of a closed room is made beside its place, tried three times and moved there whole. An empty or
  cut file at its name is no archive: `Close-RelayRoom.ps1` makes it again, lists the room as not archived
  and does not remove the room's folder on its word.
- The tamper check no longer moves out a file this PC wrote while the check was running (the transcript of a
  room that was closing).
- The coordinating reference: what an agent passes on as the owner's word is confirmed with the owner before
  it is acted on; checks go to an agent whose machine has the engine; long runs are asked for in pieces, with
  their output in a file; a large part is confirmed with the owner before a team starts it.
- `tests/Invoke-AllTests.ps1` says in its help how to run one test file on one engine.
- The README is rewritten: installation, a quick start, the pane, a reference of scripts, verbs and settings,
  the security model and troubleshooting.

Small fixes:

- A retired agent owes nothing, and no request is open with it on the board. Whether an agent is retired is
  read from this PC's copy of the room, not from the room folder.
- The plan table has an id column as wide as the longest id, wherever it is printed: by `Set-RelayPlan.ps1`,
  on the board and in the readable feed.
- The static checks of the test gate leave what an eval run writes into the repository folder alone.

## 0.1.0 (2026-10-10)

First version.

- Protocol 3: rooms, one inbox per agent, ids without a lock file, a delivery record kept by the tool,
  messages written through a draft file, a wrapper per agent and session generation, introductions before
  work, four approval tiers, self-audit with every report, pause, stop, replace and retire.
- Room tools `relay.ps1` (Windows PowerShell 5.1 and PowerShell 7) and `relay.sh` (POSIX sh) with the same
  verbs and behaviour.
- Open seats and `join`: one prompt for every agent; the agent that takes a seat says what it is, and gets its
  assignment afterwards (`Add-RelayAgent.ps1 -Assign`).
- Coordinator scripts: `New-RelayRoom`, `Add-RelayAgent`, `Get-RelayRooms`, `Get-RelayBoard`,
  `Watch-RelayFeed` (live view, tamper check, heartbeat), `Send-RelayOwner`, `Request-RelayOwner`,
  `Add-RelayDecision`, `Get-RelayStats`, `Close-RelayRoom`, `Update-RelayRoom`, `Test-RelayPackage`.
- The skill with seven workflows and its reference files.
- Test gate `tests/Invoke-AllTests.ps1`.

From the first live room (three agents, two products, one remote machine, a share):

- Introductions open with what work is handed out by: the kind of agent (product, model, effort, the program
  it runs in), its rights (`elevated`, `not elevated, can elevate (UAC prompt)`, `not elevated, no
  administrator rights`), its shell with version, and the other shells on the machine.
- The board has a `rights:` line; the skill has a rule that work goes to an agent that can do it alone.
- Work is handed out by model strength: a `models:` line on the board, a `FIT:` line at `-Assign`, a work
  kind `run` for plain command runs, `scripts/model-tiers.json`.
- Rooms are named after the project, script or task (`room_name`); a date only tells two of a name apart.
- On Windows a helper of the tool names the terminal tab after the agent while it waits (`tab_titles`,
  `RELAY_NO_TITLE`).
- `Update-RelayRoom.ps1` also brings the join prompt and each seat's instructions up to date.
- Addresses written for other machines carry the server's IPv4 address.
- `.ps1` wrappers started with `powershell -File`, so a working folder on a share survives.
- A session that joins twice is recognised by its session id where the product gives one.
- A changed assignment is shown with the next delivery (`Add-RelayAgent.ps1 -Assign`).
- Self-audit: a work folder created during the task is counted; an uncompared folder is named as such.
- The attach folder is named by its full path; a draft in the working folder carries the agent's name.
- Waiting goes by the text and the NEXT line, not by exit code 3.

From the first team room (six agents, two products, one job split into parts with one owner each):

- The team plan: a `PLAN` file per room (parts with owner, status, what each depends on, reviewer, files and
  notes), written by `Set-RelayPlan.ps1`, which also opens the direct lines the plan implies. The room tools
  have `team` (the plan and where everybody stands) and `progress` (one line for the team; wakes nobody). A
  changed plan is shown once, with the next message. Board and feed show plan, parts and progress.
- The chat window: a pane in the coordinator's session (`/relay <room>`) with the agents, the plan, the
  conversation and what waits on the owner.
- An independent review of the room tools as they stood found seventeen faults. They are fixed in both tools,
  each with a test that fails without the fix:
  - a delivery records only what it showed; a message that cannot be read stays pending and is shown as
    unreadable after two minutes;
  - a send that created no message fails, keeps the draft and puts the attachments back;
  - a message number belongs to one sender from before anything is placed (a claim in the inbox);
  - one wait per agent also when two start together: the lease is judged, refreshed and released inside a
    lock, and a wait confirms it before it says anything its agent acts on;
  - a denied proposal stays denied: the inbox is the authority, and the note of open proposals is updated
    inside a lock and never goes backwards;
  - the self-audit says `NOT COMPARED` for a folder it cannot compare (grown too large, baseline taken by the
    other tool, a git repository that is gone) and lists a plain folder that is gone as deleted;
  - a replaced session sends nothing, `bye` included; a new assignment counts as seen only once it was shown;
  - both tools print the same order, numbers and wording; `help` names the real attach folder; a parked
    agent is told to stop and nothing else; the tab helper checks whose console it names before every attach.
- The owner of each tool read the other tool line by line, and a third reader of the plan (the board) was run
  next to `team`. Where they differed, one rule now holds for all: names and part ids in a plan are compared
  without regard to case; a card file without one `key: value` line is no card in every verb; a file that does
  not begin with a header, or never closes it, is no message; a wait whose inbox folder is gone takes the room
  for unreachable and ends after thirty minutes; a proposal is noted inside its lock or not at all, and its
  receipt is noted also while a message waits to be shown; an entry of `lines` is trimmed at both ends.
- `relay.sh`: a lock or a number claim that is gone again by the time its age is asked for is no longer taken
  for one that was left behind, and a file time is always a number (twelve sends at once could stop one of
  them with a shell error). Its lease is refreshed with the room's clock, not the machine's. Only a file
  named like a message is one; documents and rules are printed without blanks at their end.
- A sender numbers past what the receiver has been shown: an inbox folder that was lost and made again
  brings no id back that counts as delivered. The differences between the two tools that stay are listed in
  the protocol reference.
- The board and the feed print no control character from a room file and no line that ends in a blank; a
  `PLAN`, `CLOSED` or `TRANSCRIPT.md` that this PC did not write is moved out with an alarm, and the board
  marks a plan that differs from this PC's copy.
- Words the room tool reads as part of a command (`approve`, `deny`, `open`, `rules`, `new`, `off`, `all`,
  `owner`) are refused as agent names.
- A send to a parked agent says so (`NOTE: <name> is parked ...`): it reads nothing until its own user tells
  it to continue.
- The self-audit of `relay.ps1` gives the same paths for an assigned folder written in 8.3 short form.
- `relay.sh` starts fewer processes per call. The test gate runs one process per test file and engine, the
  PowerShell engines first and the sh runs after them.

From two more independent reviews, one of the coordinator's side and one of both room tools for races and
failures. What they have in common: any agent can write any file in the room folder, so nothing the
coordinator's PC decides by may come from there, and "could not read" is never "empty".

- A room is what the room index and the canonical copy on this PC say it is: its id, folder, settings and
  closed state no longer come from the room's own `ROOM` and `CLOSED` files. A folder that is no entry of the
  index is refused, an id is lower-case letters, digits and dashes, and what is put into a command line for
  somebody to paste is quoted for the shell it is for.
- The coordinator runs its tool from this PC: a launcher in the machine state starts the canonical copy and
  names the room (`RELAY_ROOM`) and a draft next to itself. Cards for the owner and standing rules take their
  text from that draft, never from a file in the room.
- The tamper check never stops at one file: each is compared and restored by itself, and one that cannot be
  restored raises its own alarm. It runs before the feed looks at anything else; a `CLOSED` planted in the
  room is moved out and closes nothing. The prompts handed out are guarded files.
- The owner's log covers the whole message file, header included, and is written before the file. A message
  from `owner` is never acted on by its header: both tools tell the coordinator to look at the board first.
- A message number that would need more than six digits is a failed send, not a message nobody reads; the
  owner's messages are numbered from the owner's log.
- The feed counts a message as known only after it has printed it. A failed archive can be made again by
  closing the closed room once more. The statistics do not fail on a number an agent wrote.
- `ssh` is refused as a transport until the bridge exists, and the descriptions no longer offer it.
- The room pane: `/relay <room>` and `relay_bind` say "bound" only when the room resolved on this PC, and
  say why not otherwise; a feed that ends by itself is started again (three times, after 5, 30 and 120
  seconds) and the owner is told when that is used up, because the tamper check and the coordinator's
  heartbeat end with it; a card is shown whole, and one the feed cut says that there is more.
- Both room tools: a lock that cannot be had is given up after three seconds whatever the reason; the line a
  placeholder leaves in `delivered` ends in `unreadable` and is no receipt for a proposal; a proposal is not
  announced as due while any file in the inbox cannot be read, or when the inbox holds an answer to it; a
  `control` file caught empty says nothing in that round; an age is never taken from the machine's own clock,
  and without the room's time nothing is judged old; a lease that cannot be read is "nothing known", only
  another wait's token is a lost lease, and a missing one, or one left without a token for 30 seconds, is
  written again by the wait that holds it; a `state` or `delivered` file
  that reads as nothing though it has bytes is neither rewritten nor believed; a file whose time cannot be
  read is young; `wait 08` is eight minutes; `report` works without an attach folder.
- `relay.sh` checks every write of a send (the message, each attachment, the self-audit) and never writes
  over an existing name where no hard link can be made; it reads the inbox file by file, so one that cannot
  be opened hides no other; of two lines with one key the last counts, as everywhere else.

Also new: eval cases for the skill (`evals/`, run with `claude plugin eval . --no-publish`): when it loads,
when it must not, and that it interviews the owner before it builds a room.

Not in this version: the SSH bridge.
