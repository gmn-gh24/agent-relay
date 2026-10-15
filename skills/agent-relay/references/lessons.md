# Lessons

Dated, in general terms, each with what was changed because of it. No machine, share, address or user names
and no task content: this file is committed. Newest at the bottom. Search it by keyword before designing a job (never read it
whole); add to it after every room (`self-improvement.md`).

## 2026-10-09: the hand-built channel (three agents, three machines, one share)

What worked and was kept: one immutable Markdown file per message with a small header; files first and the
message last; short messages that point at files; a heartbeat with a stale threshold; a table of owner
decisions; a closing message from every agent.

| What happened | What protocol 3 does instead |
|---|---|
| Agent names were written into the tools; a second job meant copying and editing the whole folder | The roster is the list of agent folders; a room is built by a script from a package |
| Sending took a lock file; a killed sender left the lock behind | No lock: a temporary file, then the final name is created exclusively; a taken number means the next number |
| Each agent recorded by hand what it had read, forgot, and was woken again by the same message | `wait` records delivery itself; a request stays open until a result or answer names it |
| `wait` printed paths, and reading the messages was a second step | `wait` prints the messages and ends with one `NEXT:` line |
| Message text went on the command line; real texts ran to several KB with `$`, backticks, pipes and quotes, and every shell broke them differently | Text travels only in a draft file; verbs take single plain words |
| Every call carried the agent's own name as an argument, and a typo made an agent speak as another | A wrapper per agent and session generation holds the name; a replaced session is told to stop |
| Polling every 10 s plus the file-share client's cache made a wake take 10 to 20 s | Change events plus a short rescan on Windows; one-second polling in `sh` |
| Status files were JSON, some with a byte order mark; a plain shell could not read them | `key: value` text without byte order mark; carriage returns stripped on read |
| Protocol, task and roster shared one README; every agent read everything | `START-HERE`, `ASSIGNMENT`, `DECISIONS`, `PROTOCOL`: each agent reads its own part |
| A machine was called disposable in one conversation, and that could have been read as true for every machine | A machine is in use unless the owner declares it disposable for that machine and that job; the default is written into every assignment and never remembered |

## 2026-10-10: measurements before the build

- On a file share, with writer and reader on the same PC: a change event reached the reader in tens of
  milliseconds; polling the same folder every 5 s took about 3 s on average, every 1 s about 0.3 s. Events can
  be lost, so the tools use both. Not measured yet: writer and reader on different machines.
- Exclusive creation on a file share works by rename, by hard link and by creating a folder. The loser of a
  race sees "already exists" or sometimes "access denied". Both mean "taken".
- Windows PowerShell 5.1 writes a byte order mark into a child process's standard input when the console
  input encoding is UTF-8. Scripts that read piped text read bytes and strip it; code that starts a child sets
  a BOM-less encoding around the start.
- The PowerShell pipeline is not safe for binary data in either edition. Bytes go through streams.
- A sandboxed agent may not see a network share at all. That is a property of the agent's mode, not of the
  share; the fix is the agent's mode or a room on its own disk.
- An agent whose file tool is confined to its workspace cannot write a draft in the room. Its draft lives in
  its working folder, and the self-audit leaves that file out.
- An agent without a command time-out setting hands control back after some seconds and polls. It needs a
  foreground wait of a few minutes and the instruction not to start a second one.

## 2026-10-10: the build

- **One prompt for every agent.** The first design needed the owner to say in advance which agent runs on
  which machine, and gave each its own prompt. The owner wanted to paste one prompt into whatever was running
  and learn from the introductions what had arrived. Changed: open seats and `join`; the tool derives how an
  agent waits from the product it names; the assignment follows the introduction (`-Assign`).
- **Nothing about a place belongs in the plugin.** A share is today's share on today's PC. Changed: the
  default room root is a local folder; shares and machines are remembered only in the machine state, as
  facts, and are offered, never assumed.
- **A room has no upper limit of agents.** The name pool ran out at its length. Changed: after the pool, the
  same names with a number.
- **Every room on one PC got the same names.** The registry that keeps a machine and role's name across jobs
  keyed every open seat as `(open seat)|seat 1` and the coordinator and this PC's seats under this PC's name,
  so two rooms open side by side both had `olivia` and `emma`. Changed: only a named other machine is
  remembered; the rest draw from a shuffled pool, away from the names of this PC's open rooms and the last 20
  handed out.
- **Status claims drift ahead of tests.** Agent kinds were marked "tested" from measurements of what a product
  can do, before any had worked a room. Changed: the status says what was actually done.
- **PowerShell 7 reads JSON times as dates.** A time stored as text came back as a date and printed in the
  local format. Changed: one JSON reader for all scripts that keeps such text as text.
- **`return , @(...)` and `@()` at the call site nest.** A list came back as one element holding a list.
  Changed: functions return `@(...)` and callers wrap once.
- **A `.cmd` started from PowerShell 7 poisons Windows PowerShell's module path.** Built-in cmdlets
  disappeared in the child. Changed: the wrappers clear the variable.
- **A Windows absolute path is not absolute to `sh`.** `C:\...` was joined to the working folder. Changed:
  drive paths and share paths are recognised.
- **A counter set in a Pester `BeforeEach` does not survive into the next test.** Folders collided. Changed:
  unique ids from a helper.

## 2026-10-10: first live room (two agents of one product on one remote machine, a share)

- **A host name in a prompt stops an agent on another subnet.** The first agent could not resolve the share's
  server, stopped as told, and needed the owner to supply the address. Changed: everything written for
  another machine carries the server's IPv4 address (`reach` in `ROOM`, `Resolve-RelayRemotePath`); the
  coordinator's PC keeps the path it was given, because it may reach the share by name only.
- **An agent's working folder can be the share itself.** `cmd.exe` cannot stand there: every command through
  the `.cmd` wrapper printed a three-line banner, ran in the Windows folder, and the introduction showed that
  as the working folder. Changed: a `.ps1` wrapper started with `powershell -File` for PowerShell and Git Bash
  callers; `.cmd` only for callers in `cmd`.
- **The introduction named the tool's shell, not the agent's.** It said Windows PowerShell 5.1 for an agent
  working in PowerShell 7. Changed: the shell line names the calling program first and says what the tool
  runs in.
- **Two sessions of one product on one machine look the same to `join`.** The second was refused as "already
  joined", read the NEXT line, and joined with `new` four seconds later, but said it had to guess. Changed:
  the refusal tells the agent to decide by what its own conversation holds.
- **"The room folder" is not obvious when the agent's working folder contains it.** Changed: START-HERE says
  that the folder or share around the room is not the agent's either.
- **A cross-machine wake takes about a second.** Coordinator and agent on different machines, the room on a
  share: from the agent's send time to the coordinator's tool printing the message, zero to two seconds on
  four messages. Two machines' clocks are compared, so it is no finer than that. The other direction has not
  been measured.

## 2026-10-10: first live room, second half (three agents, two products, a real task from the owner)

- **A task for "an elevated agent" went to one that was not, and the owner had to answer a prompt.** No agent
  in the room was elevated. The coordinator said so in one status line and routed the work through an
  elevation prompt instead of stopping. The owner had expected an elevated session to do it untouched: "one of
  the main goals, and it failed". Changed: a fourth standing rule in the skill (work goes to an agent that can
  do it alone; when the kind of agent the owner named is not in the room, say so and hand over the join
  prompt), a `rights:` line on the board that says `elevated: NOBODY` in capitals, and introductions that put
  the rights first.
- **"standard" did not say whether an account can elevate.** One agent reported "not an administrator at
  all", another "deny-only", for the same account. The list of groups of a token leaves deny-only groups out;
  its claims do not. Changed: the tool reads the claims and reports one of `elevated`, `not elevated, can
  elevate (UAC prompt)`, `not elevated, no administrator rights`. Asking sudo on Linux was dropped (it is
  logged as a failed attempt where the user may not use it); the groups are read instead.
- **The owner had to ask what the agents are.** Product, model, effort, rights and shell were on the card but
  the coordinator never said them, and the `hello` was a bare table. Changed: the `hello` opens with them in
  sentences, the join prompt asks for the exact product and for the effort "if your session shows one", and
  the skill tells the coordinator to pass each arrival on in one line.
- **A review before an elevated run paid for itself twice.** The coordinator found that the install script
  ran on after a failed step and would have removed the old module after a failed install. A second agent,
  reading the same script, found that it assumed a 64-bit process. Two minutes each. Kept as practice in
  `coordinating.md`.
- **An independent before-and-after check is cheap when it is asked for before the work starts.** A read-only
  agent took a snapshot as a file, the worker changed the machine, the first agent ran the same probes again
  and reported the rows that differ. It also corrected the worker's report on one point.
- **A self-audit that could not compare said "0 changed".** The work folder did not exist when the baseline
  was taken. Changed: every file of such a folder counts as added, and a folder that cannot be compared is
  named "NOT COMPARED" in the summary line.
- **"The folder `attach` next to your draft" sent attachments to the root of a share.** For a product whose
  draft lies in its working folder, that folder was the share. The files never arrived and a stray folder had
  to be removed. Changed: the instructions name the attach folder by its full path; a working-folder draft
  carries the agent's name.
- **Exit code 3 arrives as 1.** A shell that runs the line through `powershell -Command` flattens every code
  that is not 0. Changed: the instructions go by the text and the NEXT line.
- **A room named after a date and "live-1" tells nobody what it is for.** Changed: rooms are named after the
  project, script or task (`room_name`); the date is added only to tell two of the same name apart.
- **Naming the tab swallowed the tool's output, and the tests did not see it.** An agent runs its commands
  with the output caught, on a hidden console; the tab is the console of the highest parent process that has
  one, and a process can attach to it and set its title. Done inside the room tool, that made Windows replace
  the tool's own standard output whenever the tool had inherited it from a shell: `start` printed nothing, and
  a wait would have printed a message into nowhere. Three agents met it within minutes of the update. The
  suite had passed, because it hands the tool its output explicitly, the one case Windows leaves alone.
  Changed: the tab is named by a helper process of its own (`tools/tab-title.ps1`); the tool never touches a
  console. The suite calls the tool through a shell, the way agents do, in a test that delivers a message to
  a waiting agent with the naming on. Kept as a rule: what the tool prints is the protocol; nothing in the
  tool may put it at risk for a convenience, and a test that does not call the tool the way agents call it
  proves little about what agents will see.
- **The owner liked the named tabs at once** (`Jack (researcher) - <room>` on a row of terminal tabs). The
  feature was nearly dropped over the fault above; the owner's word kept it. A fault in a feature is a reason
  to fix its design, not to drop what the owner finds useful.
- **Pester 6 under Windows PowerShell 5.1 fails when the working folder is a network path** ("the given
  path's format is not supported", found by the agent that installed it). Noted here because agents whose
  session starts on the share will meet it: set the location to a local folder before running tests.

## 2026-10-10: the first team room (seven agents, two products, one job built in parts)

The team view of this plugin (`PLAN`, `team`, `progress`, `Set-RelayPlan.ps1`) was built by the kind of team it
is for: four agents of a standard model each built one part, two of a strong model reviewed, the coordinator
wrote the contract, built the part only its own PC could run, and put the parts together. From the first task
to the last part: about forty minutes.

- **The coordinator is the bottleneck, so take it out of every path it does not have to be in.** Every
  question, finding and file went through one session at first, and the builders were faster than the answers.
  What helped, in the order it was found: direct lines between the builder of a file and the agent testing it,
  then between each reviewer and the owner of what it reviews; findings sent as a note at once instead of with
  the report; a contract that is frozen at some point, with later wishes on a list.
- **A review of the contract while the builders start is the best-spent turn of the whole job.** The strongest
  model in the room had three faults within two minutes and fourteen within ten, each checked against the
  code: a length limit that a helper would have cut shorter, two rules that refused the contract's own
  defaults, a file that a reader could catch half written. None of them would have shown in a test, because
  the tests are written from the same words.
- **Builders ask the right questions when the task tells them not to settle things between themselves.** One
  listed ten places where the contract was silent, with the choice made at each; another three. Every one was
  a place where two implementations would have printed different lines.
- **An agent at work does not read messages.** Five revisions of the contract went out in twenty minutes; the
  builders saw them when they next waited, some after reporting. Changed: the instructions tell an agent to
  keep its wait running in the background while it works, or to `check` between steps. Kept as practice: one
  revision that collects what a review found, not one per finding.
- **Tests written from the contract by somebody who has not seen the code find what the builder cannot.** The
  test writer planted 24 faults in the finished tool, one per rule, to see each test fail; the tests had
  already found two real departures from the contract. A reviewer of the tests then found three that passed
  for the wrong reason (a setup that never produced the case, an assertion that a script doing nothing would
  also meet).
- **Two implementations are compared by running them against one room, block by block.** A scratch room, the
  same commands on both engines, the outputs compared as text: three differences in the first run, none in
  the second, and the conformance run with all three engines passed the first time it included the third.
- **Before building on a tool, have the strongest model read it, and ask for proof.** The code reviewer was
  given the tool as it stood, not only the new code. It found six faults no test had shown, three of them
  races, each proved with a forced schedule in a throw-away room: a message that could not be read at that
  moment was recorded as delivered, a send could report success without a message, an attachment folder could
  land on another message, two waits could both take a dead lease, a report failed when an assigned folder
  was gone, and a denied proposal could be announced as "no objection". A finding with a schedule that forces
  it is a test half written.
- **An engine the builders cannot run stays with whoever can.** The machine of the six agents had no POSIX
  shell, so the sh half of every change stayed with the coordinator. Before a job that touches an engine,
  check that it can be run where the builders are, and ask the owner for it first if it cannot.
- **PowerShell compares without regard to case unless told otherwise** (`-eq`, `-match`, `-contains`, `-in`
  and their negations). A builder's own test found an upper-case id accepted. Where a file is read by a second
  tool that is exact about case, the reader in PowerShell uses the `-c` forms. Decide it per field and write it
  down: here keys are exact, and names and ids are compared without regard to case, which the exact tool then
  has to do on purpose.
- **A test run against a file that is being edited tests neither version.** It happened to a builder and to
  the coordinator in the same hour. Run from a copy of the tree, edit the original.
- **A wait that was started with a faulty tool swallows the next message.** After a fix is pushed, send each
  such agent a note it can afford to lose, let it start a fresh wait, and only then send its task.
- **The one who found a fault reads its fix.** The reviewer read the written fixes before any code existed and
  showed where four still leaked: a lease refreshed outside its lock, a file read again and written back
  without one, a fallback that answered "mine" when the lock was busy, attachments left in a staging folder by
  a failure nobody had rolled back. Each came with a probe that forces it, and each became a rule.
- **A lock that cannot be had means "nothing known", never "go on".** Every fallback that carried on without
  the lock reopened the race the lock was for. The tool says nothing in that round and asks again in the next.
- **Tests written on a fast engine carry its timing.** Under dash on Windows one call of `relay.sh` takes 4 to
  10 seconds; tests with a "minute" of two seconds failed there on time alone. Margins depend on the engine,
  and hand-made locks and claims get a time in the future, so that they stay fresh however slow the call is.
- **`\d` is not `[0-9]`.** In .NET it matches every Unicode digit, and the conversion to a number then throws.
  Wherever a number is read from a file or a file name, the pattern names the ten digits.
- **A parked agent reads nothing, and the send said `SENT`.** The two reviewers (agents that wait in a loop)
  parked themselves after ten and sixteen idle minutes, a few minutes before each was sent its review. Both
  tasks lay unread for three quarters of an hour; the board said "parked: owner must nudge" the whole time,
  and the coordinator was looking at its own wait, not at the board. Changed: a send to a parked agent prints
  a `NOTE:` line directly after `SENT`. Kept as practice: the board after every task to a loop agent, the
  next piece of work to a reviewer before it runs dry, and work that can move without the parked agent is
  handed to those who are awake (the author of one tool read the other, the test writers read each other's
  tests).
- **Too many test runs at once measure the machine, not the tool.** Twelve test processes side by side made
  every call four times slower, and every test with a margin of seconds failed on all three engines. The gate
  runs the PowerShell engines first and the sh runs after them; a room copied from a template starts with every
  heartbeat at the present; margins are the same wide ones on every engine.
- **A baseline has to do the same work as what it is compared with.** A test measured two seconds of waiting
  against a call that printed more and wrote a file; where file access is slow the difference came out as
  1.2 to 1.6 seconds, steadily. The baseline became a call that does the same work and does not wait.
- **Two readers of one file agree only on what was written down as a rule.** A read of the second reader by
  the reviewer, side by side with the first, found five inputs they took differently (a blank before a key, a
  revision with leading zeros, a capital for a letter outside a to z, a title with blanks around a separator,
  what counts as a blank). None had a test, because both readers passed every test there was.
- **The author of one implementation reads the other, line by line.** With both reviewers parked, the author of
  `relay.ps1` read `relay.sh` next to her own file, and the author of the plan script ran the third reader of
  the plan (the board) next to `team`. An hour, fourteen findings, in tools that passed the same four hundred
  tests and the conformance run: a name in another case was three different things in three readers, a file
  with a header that is never closed was a task in one tool and no message in the other, and a wait on a share
  that is gone ended after half an hour in one and never in the other. Nobody knows a contract's silent places
  better than somebody who had to fill them.
- **A reviewer's finding is run before it becomes a decision.** One of the fourteen was a misread index. A probe
  that does the same thing as the same seat on each engine, in one room, showed which were real in ten
  minutes, and showed the fix by printing the same lines on both.
- **"Missing" is not "old".** A lock or a claim that is gone again by the time its age is asked for was given
  back by somebody alive. `relay.sh` read that as age "since 1970", took the name away from whoever held it
  next, and once, where the file came back between two calls of `stat`, got a block of text where it expected a
  number and stopped with a shell error. Twelve senders at once showed it in four runs of six; the same test
  had passed in every gate before, on a machine busy enough to keep the senders apart. A race test runs its
  race several times, and an age is taken only from a file that is there.
- **A test gate has a memory bill, and the coordinator's own wait pays it.** Four sh runs side by side, next
  to a desktop in use, took a 32 GB machine to its limit; the session's host stopped its background commands
  to save itself: the gate, and with it the coordinator's wait and the feed. For two hours the room had no
  coordinator, and every agent was told so. The gate runs two sh runs at a time now. Kept as practice: nothing
  heavy on the coordinator's PC while a room is live, or the heavy work goes to an agent.
- **"The folder is not there" and "the server is gone" look the same to a tool.** `Test-Path` answers false for
  a path on a share that is gone, and a missing folder lists as empty: a wait that reads "missing" as "empty"
  never notices that its room is gone. The wait counts a missing inbox as an unreachable room.

## 2026-10-10: two more reviewers, each with one question (the coordinator's side; races and failures)

- **A reviewer gets one question, and reviewers who have seen nothing find what the builders cannot.** After
  the cross-read, two more reviews, each by somebody who had seen none of the work and was given one thing to
  look for: "what can an agent that writes into the room make the coordinator's PC do" and "what happens when
  a read fails or two callers meet". Thirty-three findings in files that had passed every test, among them
  three that had to be fixed before anything was committed. The builders had tested what the tools do; nobody
  had asked what they believe.
- **What the coordinator decides by comes from its own PC.** The room's `ROOM` file said which room it was,
  who coordinates it and whether it was closed, and every agent can write that file. One line in it moved the
  machine state out of its folder, and another made one room's canonical files land in another room. An empty
  file named `CLOSED` closed the room for everybody. The index and the canonical copy on the PC decide now,
  and the room is only where the work is.
- **The coordinator must not run what an agent can write.** Its tool and wrapper lay in the room and were
  started with the execution policy bypassed, on the owner's PC, at the coordinator's next verb. The tamper
  check would have restored a changed tool within fifteen seconds; a verb takes less. A launcher outside the
  room starts the PC's own copy.
- **A check that stops at its first failure protects nothing after it.** One guarded file replaced by a
  folder of the same name made the tamper check throw, and every later file stayed as the attacker left it,
  without an alarm. Each file is compared and restored by itself now, and the one that cannot be restored
  raises its own alarm.
- **"Could not read" is not "empty".** An empty read of `delivered` made every old message new, of `state`
  made the next write drop every other key, of the lease made a live wait look gone, of `control` made a
  paused agent run. Each of these is a file that this PC or another process was writing at that moment. A
  reader that gets nothing where there are bytes knows nothing, says nothing and asks again.
- **An age needs two times from the same clock.** Where the heartbeat could not be written, the tool fell
  back to the machine's own clock and compared it with file times of the share: a machine that is minutes
  off takes live locks and leases for dead ones. Without the room's time nothing is old.
- **A dead feed must be loud.** The pane kept showing the room after its feed had ended, and with the feed
  the tamper check and the coordinator's heartbeat had stopped. Whatever also carries a safety job restarts
  itself and tells the owner when it cannot.

## 2026-10-10: a rehearsal with stand-in agents (three headless sessions, two products, only the start prompt)

A room on the coordinator's PC, a toy script in three copies, one task each: two failing checks in the
assigned folder, a third failing check with a one-letter fix in a folder that was not theirs, and a setting
the task could not be finished without, in a file the assignment listed under "ask first". The agents had
no plugin, no instructions of the owner and nothing but the prompt: Claude Code headless on a light and on a
standard model at low effort, and Codex CLI. 21 messages in under seven minutes.

- **The prompt and the tool's NEXT lines are enough.** All three introduced themselves with the right facts,
  waited, took the task, asked before touching the setting (two with `ask`, one in its report), left the
  one-letter fix alone and reported it under findings, sent the output of the check as evidence, and said
  bye when told. Nobody was asked twice, nothing was delivered twice, no tamper alarm.
- **Codex CLI must be started with full access.** In its workspace-write sandbox on Windows it could not
  start one command, for a room on the same disk too (`helper_unknown_error: setup refresh had errors`). It
  did the right thing: reported the refusal and changed nothing. Started with full access it worked the room
  like the others. The owner decides that for the machine; the skill says it when a prompt is handed over,
  and the start prompt of a Codex seat says what the agent is to do when its commands are refused.
- **A seat can change its product.** The Codex seat that could not start was given a new generation as a
  headless Claude Code seat (`Add-RelayAgent.ps1 -Replace <name> -Kind ...`) and a third seat was added for
  Codex with full access: both without touching the others.
- **What three agents ask for, a rule answers once.** The same approval was given three times before it was
  recorded as a standing rule; the third agent was shown the rule with its answer. Better: a task whose
  "done when" needs an ask-first change carries the approval, or the rule is recorded before the tasks go
  out. It is in the coordinating reference now.
- **The self-audit reads harsher than it is.** "1 OUTSIDE the assigned paths" was the approved change in all
  three reports, and one agent said it reads like a violation. The audit cannot know what was approved: the
  coordinator reads it against its own approvals.
- **Sending uses the draft up.** One agent looked for its draft after `ask` to write its report into it and
  found it gone. The instructions said where the draft is, not that each message needs a new one.
- **A headless session does not know what it is called.** Asked for its product "as exactly as you know it",
  one wrote the SDK it is built on, the other the CLI; neither knew its effort setting and both wrote
  `unknown`, as the prompt allows. For a named seat the kind comes from the answers, so nothing depends on it.

## 2026-10-10: the close of the first team room (three byes, and what the close itself showed)

The owner ended the work with one line typed into the chat window. The three agents that were still there
said bye within a minute; the room closed with 404 messages. What they said slowed them down, and what the
last hour showed:

- **A session that ends while it works says nothing.** One agent's session had ended an hour and a half
  before anybody knew: its state stayed `working`, four messages lay in its inbox, and its part was waited for. The
  owner saw it first, on the machine. The board now marks an agent that has not picked up a message for 30
  minutes (`pickup_minutes`), and the coordinating reference says what to do then.
- **An agent passed on the owner's word.** "The owner says: retire the others" came from an agent, in a note.
  It was true, and it was still only what an agent said: the coordinator asked the owner in its own session
  before it retired anybody. The agent had done the right thing by not acting itself. Both are in the
  coordinating reference now.
- **Two of three agents lost a session and did not know what to do next.** `start` prints everything again,
  and the instructions said so in a table row nobody read. They have a paragraph of their own now: after a
  restart, `start`, then one `wait`; a wait that is refused as the second one is the old session's.
- **Pester does not run from a network folder.** Two agents found it out by themselves, each at the cost of a
  round. The instructions now tell every agent to work on its own disk, and the tasks say where to copy from.
- **An agent that cannot run an engine cannot check its work on it.** Tests written for three engines went to
  an agent whose machine had two. Every result for the third came from the coordinator, one round trip each.
  Hand out the checks with the work, or say in the task who runs them.
- **A long run is lost with the session.** The analyzer and four suites on two editions in one command: the
  session ended, and nobody knew how it had come out. Ask for runs in pieces, each with its output in a file.
  `tests/Invoke-AllTests.ps1` says in its help how to run one file on one engine.
- **A part the owner had not asked for by name cost three rounds.** It was in the plan from the first day,
  was built by two agents and read four times, and was stopped by the owner when it was to be tried. Ask
  before a team starts a large part whether it is wanted now.
- **The file of a seat is not what its agent is shown.** An agent opened `START-HERE.md` in its folder and
  found `{{DRAFT}}` where a path should be: for a seat taken with the join prompt the tool fills these in
  when it prints the text. The file of such a seat now says so.
- **The close raced with the room's own writers.** The zip of the room failed because a wait removed its
  lease while the zip was made, and a feed moved the transcript out as a stranger because its list of this
  PC's files was a moment older than the transcript. The archive is now made beside its place, tried three
  times and moved there whole; an empty or cut file at its name is no archive (the folder of a room is
  removed on that word); and the tamper check asks this PC's copy again before it calls a file a stranger.
- **A test found a fault its author had just made.** Handing the feed's list of messages on as `@($list)`
  ended the feed with "Argument types do not match", in a test that had been written for something else:
  the pane would have shown a dead feed. Run the suite that covers a script after every change to it, also
  a change of one line.
- **A note to all also lies in every free seat's inbox.** Whoever takes that seat later is shown notes from
  before its time. Not changed yet: it may be what a late joiner needs, or it may confuse it.
- **Names in tests.** Pester expands `<name>` in the title of a test, and two agents whose names begin with
  the same letter are easy to take for each other in a test's output: both cost one agent reruns.

## 2026-10-11: a full review by five readers, and the fixes (no room)

- **Readers who each own one part find what the gates do not.** One reader per tool, one for the module, one
  for the scripts, one for the pane and the gate: over seventy findings in code that had passed every test,
  among them a fallback that let a share outage write the coordinator's state into this PC's canonical copy,
  an agent list read from the room's folders, and a tamper check that followed a planted link and moved the
  owner's own files into quarantine. The trust boundary breaks where nobody asks "where does this value come
  from" for the one function that everybody calls. Changed: the roster, the seat order and the launcher's room
  come from this PC; nothing follows a link in the room.
- **The culture decides what a string search finds.** `String.IndexOf(string)` compares by the culture: under
  th-TH on .NET with ICU, `"room: x".IndexOf(':')` is 0, so every key: value file was empty and the room tool
  called the room unreachable. Nobody had run it under Thai; a test written for time stamps found it. Changed:
  parsers search for a char or compare ordinally, time stamps use the invariant culture, sorting is by byte.
- **A test that cannot fail proves nothing, and nor does a gate that counts only what it was told to count.**
  A failing `AfterAll` passed the gate, a wrong path reported "failed=0", and three eval cases could not fail.
  Changed: the gate counts block and container failures, refuses a run in which no test ran and every unlisted
  test file, and each eval case has a grader that can fail.
- **Pester 6 runs no original command for a call that no filtered mock matches.** A test with only a filtered
  mock made every other call throw, and the code under test took the throws for findings. A filtered mock gets
  a default mock beside it.
- **Builders who cannot run their code hand over untested code.** The parallel builders' isolated sessions
  could not start PowerShell; four of five branches came back unrun and one test of each kind above failed on
  the first run. Before handing out work, check that the builders can run the gate where they are; otherwise
  plan the runs, and the round trips, with whoever can.
- **sh is removed and postponed.** The owner first took the sh implementation out of the gate, then removed it:
  `relay.sh`, the sh wrappers, the sh engine of the tests and the sh line of the join prompt are gone, and an
  agent on Linux or macOS cannot join. sh (and ssh) is built and tested if and when the need and the time come,
  from `relay.ps1` as it is then; nothing is kept in step with it meanwhile.

## 2026-10-11: an agent without a wait that believed it had one (a live room, one agent of Claude Code)

- **A second wait gave up at once, and the one it gave way to ended a moment later.** The agent kept a wait running
  in the background while it worked, as its instructions say, and started another when its report's NEXT line
  told it to. The second exited 4 ("another wait is already running, its lease refreshed 2 s ago: do nothing").
  Shortly after, the first ended without a word and without its lease, and nothing listened for the agent: a
  message from the coordinator lay unread until the owner restarted the wait by hand.
- **The lease of two seconds was not the wait that had just woken the agent.** A wait gives its lease back when
  it ends (reproduced: no lease right after it exits on a message). A lease refreshed two seconds earlier belongs
  to a wait that was still alive: the one the agent had started for the work, which refreshes every ten seconds.
- **A stopped wait ended in silence.** Ctrl+C, or a host that stops a command gracefully, lets PowerShell run the
  wait's cleanup: the lease goes, the exit code is 0, and nothing is printed (reproduced). A plain kill leaves the
  lease, and the next wait on that machine frees it at once by the process id. From the outside the silent stop
  looks exactly like what the owner saw.
- **Changed:** a second `wait` waits up to 35 seconds for the lease (the life of a lease plus a margin) and takes
  over when the holder ends; exit 4 now comes only from a holder that stays alive, and names its process. A wait
  that ends with no answer says that nothing listens and tells the agent to wait again. The journal records each
  wait's process and how it ended, so the next such case can be read off the room. The NEXT line after a report
  still says to run `wait`: a second wait is harmless now.
- **Not changed yet:** the board cannot tell a dead coordinator wait while the feed keeps the coordinator's
  heartbeat alive. Kept for the review of how the coordinator recovers its wait.

## 2026-10-11: a SYSTEM test cycle on a disposable VM (a live room, one agent of Claude Code)

- **A task cannot lift an assignment's never-list, and the agent knows it.** The job's later tasks needed an
  msiexec removal and registry writes on the disposable machine; the assignment given after the introduction
  had forbidden both. "Approved for this task" in the task message was read correctly as no approval at all, and
  the agent asked its owner three times. Changed: the coordinating reference says to re-assign (`-Assign` with
  the wider `may` or `propose_ok`) before such a task goes out, and to foresee at assignment time what a test
  job on a disposable machine will need (uninstalls, registry, files outside the work folder).
- **Name the thing, not a rule the agent must apply to things it has not seen.** A task said "the registry keys
  whose name contains the product version"; no key name did (they carried another version scheme), and the
  agent had to guess and ask. When the selection criterion is unverified, make the listing its own task and
  name the items in the next one.
- **The closing note must name the verb.** "Send your bye" was answered with a `note` titled bye; the close
  refused, and the room was closed with `-Force` after the owner had ended the agent. Changed: the close step of
  the skill says to ask for the `bye` verb by name, and the closing note is expected to say so.
- **Second waits exited 4 twice and nothing was lost.** With the 0.2.1 lease behaviour a second wait beside a
  live one is the expected outcome; the agent found it alarming in its bye. Not changed: the exit text already
  names the holder; a calmer wording can wait for the next case.
- **A harness that re-stages its folder deletes what the agent put there.** Two logs an agent had written into
  the harness's folder were gone after the run, and a bundle log of a fixed name from an earlier run looked like
  this run's. Not a plugin matter; written here because the pattern (evidence written into a folder the test
  re-creates) will recur: tell the agent in the task where to write what must survive.

## 2026-10-11: a second SYSTEM test room on a disposable VM, twelve hours and a rewrite long (a live room, one agent of Claude Code)

- **The self-audit blamed the agent for the coordinator's files.** The coordinator put new copies of two files
  into a folder that was one of the agent's read-only roots. Five reports in a row said "2 OUTSIDE the assigned
  paths", and neither side could tell from the report which two; the agent said so in its bye. Changed: a report
  names the entries outside the assigned paths under its summary line (the first ten, then a count), to the
  agent and in the message the coordinator reads; the coordinating reference says that the audit cannot tell who
  changed a file and that the coordinator names its own. Not changed: the baseline is not taken again when the
  coordinator changes a root; the coordinator has no way to tell the tool yet.
- **A second wait that exits 4 still read as a failure, a second time.** Four times for the agent, once for the
  coordinator, harmless each time. Changed: START-HERE says in one sentence that this outcome is no failure and
  that the first wait still listens. Not changed: the exit code stays 4, since `check` and the hosts' loop
  wrappers read it.
- **A delivered message did not wake an agent whose session sat idle.** The first task was delivered and the
  agent's wait had ended, the board said "working, woken by 1 message", and nothing followed until the owner
  spoke to that session; the owner asked whether the message was lost. Changed: the coordinating reference has
  that board line in its table with what to tell the owner. Not changed: the board does not mark it ATTENTION by
  itself; "has not picked up" only covers undelivered messages.
- **The coordinator ended turns without a wait, and once started one that could wake nobody.** After a result
  that needed no reply the wait was not started again, and a note lay unread until the owner asked. Earlier a
  wait was started as a detached hidden process: it held the lease and had to be found and stopped. Changed: the
  loop in the coordinating reference says the wait is started again after "no reply needed" too, and only
  through the host's background command.
- **A guarded host cost the clean-up several rounds.** The agent's host refused deletes whose command line held
  several statements or a path with a space, and a helper process started as another user from a foreground
  call held that call until it ended. Not a plugin matter. Changed: the coordinating reference lists both under
  what a task says (one delete per command and the allowed other way; long-lived helpers from a background
  command), and that an order of setup steps that matters is written into the first task that needs it.
- **What held:** stop at the first unexpected result with a precise question, a short pass or fail table per
  report, one folder with the files under test and their hashes for the agent to confirm, fixes returned between
  rounds. Seven requests, all answered, none asked twice, no owner card.

## 2026-10-11: how the owner starts the agents (the owner's word, after several live rooms)

- **Full access was not enough for Codex CLI.** The lesson of 2026-10-10 said to start it with
  `codex --sandbox danger-full-access`. That lifts the sandbox and leaves the approvals on: the remote agent
  kept asking its user, and some commands stayed blocked. Changed: Codex CLI is started with `codex --yolo`
  (`codex exec --yolo` headless); the note the scripts print, the Codex start prompt, the skill, the agent
  kinds reference and the README say so.
- **Claude Code asks too, and nobody had written what to do about it.** For a room without questions and
  interruptions the owner starts it with `claude --dangerously-skip-permissions`. Without it the room works,
  and the owner answers the prompts on that machine. Changed: a note for seats of both Claude Code kinds, and
  the same places as above.
- **The risk is the owner's, and so is the sentence about it.** Both flags switch the product's own guard off.
  The coordinator says so to the owner in one line, and only when the job is risky, with the advice to use a
  virtual machine or a throwaway computer. Nothing about it goes to an agent: not in the join prompt, a start
  prompt, a task or an assignment (a test holds the prompts to that).
- **An agent in a sandbox never got as far as its instructions.** The hint for a blocked command was in the
  kind's text, which a joining agent sees only after `join` has run. Changed: the join prompt itself says what
  to do when a command is refused, blocked or cannot start: change nothing, stop, tell the owner the exact
  error, and do not work around it.

## 2026-10-11: a room for a job with SYSTEM and standard-user runs (a live room, as its coordinator reported it)

- **"codex luna medium" was read as an agent called Luna.** The owner named what would join: product, model,
  effort. The coordinator made a seat named Luna, which had to be retired and replaced. `luna` is a Codex
  model, and the table of model names did not know it. Changed: the Codex family words are in
  `scripts/model-tiers.json` (`luna` standard; `astra`, `sol`, `terra` strong), in a list of their own where
  one must win over the generation in front of it: `gpt-6-luna` had sorted as strong by its `gpt-6`. The agent
  kinds reference lists the Codex models and says that these three words are an introduction, never a name.
- **The agent that took the seat said `gpt-6 xhigh`; it had been started as Luna at medium.** A generation
  without a family, and an effort nobody set. Changed: the coordinating reference says to ask the owner what
  the session was started with when a task depends on it, and to tell the owner when an introduction is not
  what the owner announced. Not changed yet: the room does not hold what the owner announced for a seat's
  model and effort, so the board cannot mark the mismatch as it does for the computer name.
- **An agent started again elevated keeps its name.** Read the board's `rights:` line again before you trust
  an earlier "not elevated". Reported from the same room and not reproduced here: a second session that
  introduced itself under the name of a live agent replaced its card, and the board showed the wrong rights
  for the real one. Not changed yet: such an introduction is neither refused nor marked ATTENTION.
- **A job that runs as SYSTEM and as a standard user needs two seats on that machine.** One elevated agent
  and one that is not, planned when the room is made. The coordinator offered a detour from the elevated agent
  instead (a tool that starts a process with lower rights, or a UAC prompt for the owner). That is wrong for
  the same reason as before: the room is there so that such work needs nobody's hands. Ask the owner for a
  second agent. Changed (0.9.0): the startup interview asks which accounts a job's runs need.

## 2026-10-11: a room with one elevated agent for one system setting (a live room, as its coordinator reported it)

- **The coordinator guessed the product of a named agent, and guessed wrong.** The owner gave a name, a
  machine and the rights, not the product. The machine was known to have two products; the coordinator chose
  one, and the session that arrived was the other, with a prompt that told it to wait the wrong way. The seat
  had to be issued again. Changed: the startup interview says that the product of a named agent is asked,
  never chosen, and that the list of products a known machine has is not an answer.
- **The first session came in not elevated, although the owner had asked for an elevated agent.** The board
  said so, no work went out, and the owner started a second session as administrator. That worked as meant.
  Not changed: the start prompt cannot make a terminal elevated; the line to the owner says "Run as
  administrator" as its own step.
- **A one-line command with variables failed at parsing, before it did anything.** The agent passed the code
  to a second shell in double quotes, and its own shell emptied every variable first. A task that names the
  commands in prose leaves the way to run them open. Changed: the coordinating reference says that code with
  variables goes into a task as a script to save and run from a file, with the exact command line.
- **Deleting the folder of a closed room stopped at a confirmation nobody could answer.** The coordinator's
  shell is not interactive. Changed: the skill's close workflow names `-Confirm:$false` for that step, after
  the owner chose delete in the session.
- **The statistics script refused the room once its folder was deleted.** The close workflow removes the
  folder before the retro, and the retro starts with that script. The numbers were still there, in the file
  the close saved on this PC. Changed: the self-improvement reference names that file for a room whose folder
  is gone. Changed (0.9.0): the script reads that file by itself when the folder is gone.

## 2026-10-11: a review of the design (no room)

- **A guard that covers one sender and not the other protects the wrong one.** The owner's messages were
  checked against a log on this PC; the coordinator's own, which carry the tasks, were not, and any agent could
  write one into another agent's inbox. Changed: the coordinator's tool keeps a record on this PC and the tamper
  check moves out what is not on it. When a check is added for one kind of file, ask which other kind an agent
  can write that is believed for the same reason.
- **Two readers of one file drift, also when both are tested.** The room tool and the module each read messages
  and open requests; they disagreed on case, hidden files, owner files and what closes a request, and no test
  held one against the other. Changed: a test that builds one room and compares the board with every agent's
  `show open`. Where a format has two readers, test them against each other, not each against itself.
- **A module does not inherit the caller's `$ErrorActionPreference`.** Every script set `Stop`; the module's
  functions still ran under `Continue`, so a failed listing went on with nothing. Set it in the module.
- **A lock that anybody may remove is no lock.** A holder that ran long lost its lock to another caller and then
  removed that caller's lock. A lock carries the token of its holder, and only that holder removes it.

## 2026-10-11: a coordinator reached a session outside its room (a live room, as the owner reported it)

- **A second session of the owner's was treated as a spare agent.** The coordinator had a room open for the
  job. The owner also had another session of the same product open on the same PC, on unrelated work. The
  coordinator used its host's own session-to-session messaging to hand that session documentation tasks,
  outside the room, without a seat, an introduction, an assignment or the owner's word. Nothing of it
  reached the board, the transcript or the record of sent messages. Changed: the skill has a fifth rule and
  the coordinating reference a section, "Only the room": the launcher's verbs are the coordinator's only
  channel to an agent, no session outside the room is listed, messaged, assigned or coordinated, a session
  that could help is offered the join prompt, and an exception comes from the owner alone, in the session,
  for one agent and one job, recorded with `Add-RelayDecision.ps1 -Owner`. The plugin refuses the host's
  session tools while a room is bound, until the owner types `/relay outside on` and confirms it in the
  dialog. An eval case holds the coordinator to it. Not changed: the room package; agents never had such a
  channel.

## 2026-10-12: an agent went silent after one blocked command (a live room, as the owner reported it)

- **A sentence written for the join step became a standing rule.** The join prompt said, since 0.3.3: "if a
  command is refused, blocked or cannot start ... change nothing, stop and tell your owner the exact error".
  It was meant for an agent whose sandbox blocks `join` itself, which then has no room tool and no coordinator
  to reach. An agent that had joined and was working had a command of its task blocked by its product's
  permission guard, and did what the sentence said: it stopped, stopped running `wait`, and told nobody in the
  room. Asked why, it quoted the sentence. Nothing in `PROTOCOL.md` said what to do with a blocked command
  after join, so the join prompt's sentence was the only text on the subject. Changed: the sentence names the
  join command and says it applies to joining only; `PROTOCOL.md` has a section "A command is blocked": `ask`
  the coordinator with the exact command and error, keep waiting on the room, keep working on what does not
  depend on the answer; only a blocked `wait` means stop and tell the session's user. Lesson for the next
  prompt rule: a rule promoted from a lesson into a prompt needs its own "when this applies", or the agent
  keeps it for the whole room.

## 2026-10-12: seven agents, one machine, five rounds (a live room, from its statistics and byes)

Seven agents of two products on one machine reviewed and reworked a script through five rounds; the room ran a
day. What cost rounds, and what was changed:

- **A timed-out wait looked like a failure.** The wait exited 3 when nothing arrived, and the agents' product
  showed every exit code but 0 as a failed command. Several agents of that product took the first quiet wait
  for an error, stopped waiting and told nobody; the owner had to nudge each session by hand, and the ones
  that kept waiting were parked after four quiet waits and had to be nudged too. Changed: a wait that timed
  out exits 0 and says "nothing arrived in N minutes: that is normal, not an error" (`check` keeps 3, so a
  script can test it); that product's profile never parks (`park_after` 0 means never) and its prompt says
  that a quiet wait is normal and that the agent never stops waiting on its own.
- **A one-line draft lost its text.** An agent wrote a whole result as one line; the tool took the first 120
  characters as the subject and sent the subject as the text, and the rest was gone. Changed: a one-line draft
  is sent whole, the line as the subject (cut at 120) and the whole line as the text.
- **Agents guessed their model and effort at join.** The join prompt said "write unknown where you do not
  know; do not guess", and agents guessed anyway, or wrote unknown where their user could have told them.
  Changed: the join prompt says to ask the user of the session for the two words by a typed answer, and to take
  them as typed.
- **Agents worked inside the room folder and on the share.** Test runs and scratch files landed in the room,
  one agent's runner started from a share and failed, and every such file showed as outside the assignment
  in the next self-audit. Changed: the join prompt and `PROTOCOL.md` say to work from a local folder of one's
  own, one subfolder per round in `attach` with that round's changed files and a diff against the round
  before, and scratch files in the results folder, never beside the assigned folders.
- **A task asked for more than the assignment allowed, twice.** The agent stopped at the line of its
  assignment and asked, which was right, and the round was lost. A replaced assignment was then read as
  needing a further approval. Changed: `START-HERE.md` says that a task never widens the assignment (answer
  with `ask`, keep working on the rest) and that a new assignment carries the owner's decision whole; the skill
  has a rule "a task never exceeds the assignment: re-assign first".
- **The coordinator asked the owner in prose and lost the answers.** Interview questions written into the
  session were skipped or answered in part; the host's question tool, which shows choices, got answers at once.
  Changed: the skill says to interview through that tool; `startup-interview.md` has a section "How to ask".
- **The coordinator expected its draft to survive a send.** A second verb ran on a draft the first had consumed
  and sent nothing. Changed: the skill's rule on drafts says that line 1 is the subject and the send consumes
  the draft.
- Open after this room (closed in the two entries below, 0.5.1 and 0.6.0, except the Codex time limit, which
  `agent-kinds.md` tracks): the assignment JSON that the coordinator
  hand-writes (a heredoc lost backslashes and a variable, then a JSON escape error: two failed rounds), the
  `remember` limits that an agent found only when the verb failed, a hold that was a plain note and reached
  an agent after its run had started, a kit that lacked what the suites read, the product's command time
  limit against `wait_minutes`, a task that contradicts the receiver's assignment, and scratch files next to
  the working folder in the self-audit.

## 2026-10-12: the open items of that room, wording (0.5.1)

- **The limits of `remember` were learned from its refusals.** An agent found the 15 to 500 character limit
  of an entry by running the verb three times; the limit stood in `PROTOCOL.md`, which agents rarely read, and
  in the error text. Changed: `START-HERE.md` says next to the verb what counts (the whole draft joined into
  one line), the limits, and that the verb writes nothing when they are missed.
- **A kit that lacked what the suites read cost a round each time.** Reference masters, profiles and the
  sibling scripts a drift guard compares were not in the kit; the agents reported failures that were missing
  files, and a runner written by hand set strict mode into the test scope and lost its cmdlets under Windows
  PowerShell started from PowerShell 7. Changed: a checklist "The kit" (now in `multi-builder.md`):
  everything the suites read, per-round folders with only that round's changes and a diff against the round
  before, and a tested runner template (`-PassThru` with `Run.Exit` false, no `Set-StrictMode`, `PSModulePath`
  rebuilt from the registry under Windows PowerShell 5.1, output to a file in the results folder).
- **Scratch files beside the working folder showed as outside the assignment in every audit.** The runner
  and its logs lay next to the kit, and every report after the first listed them as `OUTSIDE`, which the
  coordinator had to read past each time. Changed: `ASSIGNMENT.md` says under "Where you work" that scratch
  files go into a results folder on the agent's own disk, and why; `PROTOCOL.md` said it since 0.5.0.
- **A copy that worked was reported as failed.** The agent's command tool shows every exit code but 0 as an
  error, and `robocopy` returns 1 for "files were copied". Changed: a note in `agent-kinds.md` under Claude
  Code: say in the task that `robocopy` codes below 8 are success, or have it copy with `Copy-Item`.
- **Codex's command time limit is still a guess.** `wait_minutes` 4 worked, but nobody measured when the
  product kills a foreground command. Not changed: the number stays; `agent-kinds.md` says how to measure it
  in one Codex session and where to write the result. A cloud session without Codex cannot do it.
  (Measured later that day: see "Codex's wait, measured (0.9.1)".)

## 2026-10-12: the open items of that room, behaviour (0.6.0)

- **Hand-written JSON cost two rounds.** The coordinator wrote an agent's assignment as JSON through a
  heredoc of another shell: the first lost its backslashes and a `$name`, the second failed on a JSON escape,
  and the agent sat without an assignment both times. Changed: `Add-RelayAgent.ps1 -Assign` takes every field
  of the assignment as a parameter and several agents in one call, and `New-RelayRoom.ps1` takes the room's
  answers as parameters; a room of open seats needs no JSON at all. The file still works for named agents.
- **A hold was a note, and a note is read when the agent next looks.** The coordinator asked everybody in a
  note not to start the next round while the kit was restaged; one agent had already started its run when
  it read the note, and the run went against the old kit. Changed: a hold is a control state
  (`-Control <name>|all -State hold`): every verb of the agent prints it first, `check` exits 7 while it
  lasts so a run script can test it before it starts, `wait` says it once and says when it is lifted, and
  messages still arrive. A state that must stop something from starting belongs where the tool reads before
  every command, not in the inbox.
- **A task asked for what the assignment forbade, and the agent was right to stop.** Twice a task needed a
  change under the agent's "Never" or outside its non-goals; the agent asked, the coordinator re-assigned,
  and a round was gone each time. Changed: the coordinator's `task` compares the draft with the receiver's
  "Never" and "Not part of this task" lines and refuses with `NOT SENT` when two telling words of a line are
  in the task; the draft stays, and `anyway` sends it. It is a word match: it says so, and the coordinator
  reads the line before deciding.

## 2026-10-12: a five-agent room across two machines (0.6.1)

- **The join prompt named the rooms root, and the first join was refused.** The coordinator passed the share's
  rooms folder as `reach_path`; the prompt embeds that path verbatim, so the agent looked for `join.ps1` one
  level too high, reported it exactly as its prompt says, and a round was lost to a hand edit of both ROOM
  copies and a regenerated prompt. Changed: `New-RelayRoom.ps1` appends the room id when `reach_path` ends like
  the rooms root (any other folder name is still taken as given, a share may show the room under another name)
  and prints a NOTE; a test covers both cases. The skill's startup interview says `reach_path` is the room
  folder itself.
- **The wait whose "another wait is already running" was mine.** A second `wait` started while the first still
  held the lease exited at once with code 4 and a text that says the running one listens; the host showed the
  exit as a failure. Not changed: the text and the exit code are right, and the host's colour is the host's.
- **What slowed the agents down, in their own words.** One lost ten minutes to a wrapper under test that waited
  for its own shell (a project lesson of the owner's repo, not of the relay); one found a vendor switch by trial
  because nothing documented it. Not changed here: both are the job's, not the room's.

## 2026-10-12: a silent agent, and a coordinator that did not notice (a live room, two agents on one machine, 0.7.0)

- **A model name with blanks was refused, and the refusal pointed at a draft.** An agent asked its user for
  its model, got a name of three words, passed it in quotes and was told that arguments are single plain
  words; the next line named "your draft file" and `help`, though a session that has not joined has neither a
  draft nor a command of its own. It took the owner to find the form with dashes. Changed: `join` and `start`
  take the three words as a user types them (a quoted word with blanks, or more than three words, becomes
  product, one model word with dashes, and effort); what is then still no plain word is refused with the join
  (or start) command, its three words, an example and "write unknown where you do not know", and with nothing
  about a draft or `help`. Every other verb keeps its refusal.
- **An agent that must ask for its model was told to ask for a typed answer.** The owner wants choices to pick
  from. Changed: the join prompt and every start prompt say to ask through the host's question tool when there
  is one, with the models and effort levels of the agent's own product and "other" for typing, and to fall back
  to a typed question only without such a tool. The skill and `agent-kinds.md` ("Model and effort") say that
  the coordinator never asks the owner for it in its own session: it has the agent ask its user.
- **The coordinator told an idle agent that its wait could run out.** It had no work for a loop agent yet, and
  wrote that the owner would nudge it later; the manual's own words about loop agents that "park themselves"
  led there. The owner's rule, final: an agent never stops monitoring the room until it is retired or the room
  is closed, and the coordinator never tells an agent that is still needed to stop waiting. Changed: there is
  no parking. The numbers, the branch of `wait`, the board state and the note after a send are gone; a wait
  that ends with nothing says, for every kind, that this is normal and to run it again; the instructions say
  once that the agent keeps waiting until it is retired or the room is closed; `coordinating.md` has "Every
  agent keeps waiting" (an agent that is not needed any more is retired, not told to idle). A room made before
  still carries the number in its files: nothing reads it.
- **A verb looked for the draft in the folder it was run from.** A product keeps its draft in the agent's
  working folder under a file name; the tool joined that name to the current folder on every call, so a verb
  run from the work folder did not find the draft the join had printed in full for the home folder. Changed:
  one path per agent, the file in the folder of its `start` or `join` (the card holds that folder), used by
  every verb and filled into the printed instructions; a named seat's `START-HERE.md` keeps the place of the
  path instead of a bare file name. A test runs every drafting verb from another folder than the one of join.
- **An agent was unreachable for the whole of its task, and nobody but the owner noticed.** A task expected to
  take some minutes produced nothing for four times as long. The agent had followed the `NEXT:` line of the
  delivery (handle the messages, then wait) and not its instructions (start the wait first), so no wait ran
  while it worked and the coordinator's question lay unread; it had started its long command as a detached
  process and watched for a signal file that was never written, so it never learned that the run had ended;
  and the coordinator waited, because nothing woke it. Changed, on the agent's side: the `NEXT:` line of a
  delivery that brings a task tells an agent that wakes in the background to start its wait now, before the
  work, and one that waits in the foreground to run `check` after every step; `START-HERE.md` and `PROTOCOL.md`
  say it in the same sentence, and a test holds the three together. Every verb but `wait` and `bye` of such an
  agent prints first that it has an open task and no wait running. The instructions say to start a long command
  with the host's own background command, never as a detached process to poll, and to send a `progress` line
  when it starts and when it ends. Changed, on the coordinator's side: a task carries the minutes it should
  take (`task <name> <minutes>`, or the room's `task_minutes`, 15), the agent is shown them, and the
  coordinator's wait ends with an `OVERDUE` block when the agent has sent nothing for that long, and once more
  half that time later when it has still sent nothing; what was expected and what was already said is kept on
  the coordinator's PC, never in the room. The board marks the task `OVERDUE` and the agent that has a task and
  no wait. The skill's loop and `coordinating.md` ("A task that is overdue") say what to do at each of the two:
  ask the agent, then hand the task on or tell the owner. A loop agent gets no "no wait running" line and no
  such mark on the board: it has no wait while it works, by its nature.
- **A kit that said five and held seven.** The task said to copy five files from a folder of seven, and the
  agent copied all of them with a wildcard; a count of steps in the task differed from the runner's, and the
  agent stopped to ask. Changed: "The kit" in `multi-builder.md` says to name the files to copy, or to stage a
  folder that holds exactly them, and that a count in a task is the count the runner prints.

## 2026-10-12: Codex's wait, measured (0.9.1)

- **The guess of 4 minutes cost fifteen turns an hour in a quiet room.** A Codex agent cannot be woken by a
  command that ends, so every wait that ends with nothing is a turn of its model, and since 0.7.0 no agent
  parks. The owner measured it in one Codex session (codex-cli 0.162.1, Windows): commands of 240, 480 and 960
  seconds ran to their end; the one of 1920 seconds was stopped by the owner, so the product's limit is above
  16 minutes and still not known. Changed: `wait_minutes` of `codex` is 15 (the longest that ran, less a
  minute), in `agent-kinds.json`, its prompt line and `agent-kinds.md`. A room made before keeps the 4 its
  seats and `tools/kinds` hold; `Update-RelayRoom.ps1` writes `tools/kinds` again, a named seat keeps its
  number.
- **The first two measurements measured nothing.** The session was started without `codex --yolo`, and no
  command started at all (`helper_unknown_error: setup refresh had errors`), the test command and
  `codex --version` alike. Changed: `agent-kinds.md` says under the measurement that it needs a session started
  with `codex --yolo`, and what the refusal looks like.

## 2026-10-14: a research room across three machines and several agent kinds (0.10.0)

Thirteen lessons from one closed room, approved by the owner in groups: the first six are what the room measured
and the owner approved from room memory (L1 to L7); the rest are the coordinator's own mistakes (L8 to L13). The
changes the same room caused in the tools and the skill follow in the next section.

- **L1. A share can be reachable by host name on one machine and only by address on another.** The same share
  was refused by address on one machine ("user name or password is incorrect"), not resolvable by name on a
  second, and reachable both ways on a third. Changed: prompts and wrappers give the host name first and name
  the address as the fallback ("Fallback, the same folder by the server's address"); see the next section.
- **L2. For a grounded writing task, ask for an exact quote per claim and have the agent check its quotes by
  script.** A release note written from sources was only as good as its quotes; an agent that must quote cannot
  invent, and a script that looks each quote up in the source finds the ones it tidied up. Changed: nothing in
  the tools; the task template on the roadmap asks for a quote per row.
- **L3. UI testing on a virtual machine: a locked console gives blank screenshots while the automation tree
  still answers.** The agent reported success with empty images. Changed: say up front that the console must
  stay unlocked, and have the agent's first step check for a lock and report at once (roadmap, task template).
- **L4. A UI Automation button press blocks when the button opens a modal dialog.** The call never returns
  because the dialog waits for the click the call is making. Use a real mouse click for such a button. Nothing
  to change in the tools.
- **L5. An agent's tool shell may be PowerShell 7 while the task assumes Windows PowerShell 5.1.** Commands
  that differ between the two failed in one and not the other. Changed: the task template on the roadmap names
  the shell the commands assume; the introduction already says which shell the agent has.
- **L6. Deliver test builds as plain files with a hash manifest, swapped into the installed product; build the
  installer once.** A full installer per test round cost minutes per round for nothing the round had to prove.
  Changed: the skill states the rule in one sentence ("Proportionate effort"), and plain files for small sets,
  `robocopy /E /MT:16 /R:1 /W:1` for folders, a zip only when size or count makes it faster; the fuller delivery
  ladder is on the roadmap.
- **L7. Installer verbose logs are UTF-16.** Read as text they look empty or garbled; read them as Unicode.
  Nothing to change in the tools.
- **L8. Never stop a running agent on an answer the owner may still revise, and tell every long agent to commit
  as soon as its build is green.** An agent was stopped on a provisional answer and its uncommitted work was
  lost with it. Changed: the lesson only; "How an agent leaves" now has every graceful exit ask for
  `remember` and `bye` first.
- **L9. Copying files between git worktrees: leave the `.git` pointer file out (`robocopy /XF .git`).** Copied
  along, it made the next commit land on the other worktree's branch. Nothing to change in the tools.
- **L10. Before declaring a subagent lost, list the recent commits on all branches.** A subagent that looked
  silent had committed. Nothing to change in the tools.
- **L11. A fast light model can return confident, partly invented detail on a verify-row-by-row task.** The
  result came back in a small fraction of its time budget and read fine; quotes per row and a spot-check found
  the invented rows. Changed: the lesson only; showing elapsed time against budget on the board is on the
  roadmap.
- **L12. The same local model can be usable under one harness and unusable under another.** Under one product's
  harness it joined by itself and produced correct work; under another the permission check refused the join
  command and no work followed. Trial the harness, not only the model. Changed: the join prompt now says that a
  guarded host may refuse the join (a correct default) and names the two ways through.
- **L13. Look at a UI before calling it reviewed.** A review was written from the code of a window nobody had
  seen. Get a screenshot beside an existing window before the first review. Nothing to change in the tools.

## 2026-10-14: the same room, what the tools changed (0.10.0)

- **The feed was not running for 83 minutes and nothing showed it.** The coordinator's PC crashed and its
  session resumed; it restarted `start` and `wait` but not the bind that runs the feed, which is the tamper
  check and the coordinator's heartbeat. The owner found out by editing an agent's memory file by hand, and
  that file has no canonical copy, so even a running feed would not have reacted. Earlier the same day the same
  missing bind made the board show the coordinator stale for 12 hours while it worked, and the owner had a
  tester shut a machine down on that. Changed: the feed writes two stamps (this PC's `feed.state`, and
  `agents/<coordinator>/integrity` in the room); the board's first line says whether the feed runs; the
  coordinator's tool prints a NO FEED block on every sending verb and its `wait` refuses to start without a
  feed; every agent's tool tells its agent when the integrity stamp is old; the resume workflow starts with the
  feed, in bold. The tamper check's limits are written down (`protocol.md`, "What the tamper check covers").
  Not changed: running the check from something that outlives the coordinator's session, and integrity for
  agent-written files (roadmap).
- **Memory printed "skipped: 1 malformed lines" and nobody read it.** The count was in the last line of a long
  listing. Changed: the board flags the lines per agent as an attention item and labels memory UNVERIFIED;
  `Get-RelayMemory.ps1` warns; `Repair-RelayMemory.ps1` lists a file by line and removes lines after an
  evidence copy; `room-memory.md` has the procedure for a planted or altered entry.
- **Retired agents left without a goodbye.** `-Retire` sent no exit request and three agents were retired with
  no `bye`, so their last findings and what slowed them were lost; after `bye` an agent's own `start` still
  resumed its seat, which looked like a second life. Asked for the exit steps, agents did them in about 40
  seconds. Changed: `-Retire` and `-Replace` ask a living agent to `remember` and say `bye` and wait for it; a
  lost session is not waited for and is recorded as lost; `-Force -Reason` goes on regardless and records why;
  the close lists who cannot be reached before the closing note; a seat that comes back after `bye` shows
  `returned after bye` on the board. `-Reinstate` was not built: asking first removes the need.
- **Four self-audits listed the agents' own deliverables and the room's bookkeeping as outside the assigned
  paths.** Roots had been assigned in one spelling of the share while the tool ran in the other, and other
  agents' heartbeat files counted as changes. Changed: the room's own folders (`agents`, `files`, `tools`, and
  the files at the top) are found by the room folder's name and left out of the count, in either spelling; the
  report says how many were left out.
- **A verb failed when the shell's working folder on the share had gone.** Setting a local working folder
  fixed it. Changed: the tool moves to the temporary folder for the call when its working folder is gone. Not
  reproduced on Linux or on a local disk, where the guard test passes without the fix too: the case needs a
  folder on a share that another machine removes. Kept on the roadmap as "reproduce on Windows".
- **A guarded host refused the join command, and the agent then misquoted the room's instructions.** The command
  was a script it had never seen, on a share, reading machine identity. The owner ran the join line and it worked. Changed: the join prompt says that a refusal is a correct default, that the agent tries once, and
  names the two ways through; the skill tells the coordinator to warn the owner and to have a sentence of the
  owner's own typed in front of a pasted prompt; the prompts say never to run a script from the room except
  the agent's own command and one a task tells it to write in its own work folder.
- **The asks of the owner were prose.** Questions went to the owner as numbered prose to answer by typing; one
  `-Replace` for several agents left the owner not knowing which prompt was on the clipboard. Changed: the
  skill and `coordinating.md` say every question is asked through the question tool with options, and the
  Improve step triages per group the same way (`self-improvement.md`); `-Replace` names the prompt to paste and
  `Add-RelayAgent.ps1 -Clipboard <name>` puts a named one on the clipboard.
- **The join prompt spent a small agent's context before work began.** An agent with a 16K-token window
  compacted after reading a 4,160-character join prompt. Changed: the prompt holds only the pre-join steps
  and opens with the owner's request to join. The join prints the after-join rules in `START-HERE.md`;
  the blocked-command rule remains in `PROTOCOL.md`, with its after-join summary belonging in `START-HERE.md`.
  An unknown model or effort no longer delays joining: the agent writes `unknown`, and the coordinator
  settles it with the owner after the agent is in.

## 2026-10-14: the Ollama room, by the numbers (115 messages in 281 minutes)

A research room of several agents on several machines; its statistics and its owner-requested notes gave
these numbers and the changes they led to:

- **32 requests, 3 never answered; median reply 3 minutes, slowest 56.** The slowest was an agent with no wait
  running: nothing could reach it, and the status request to it took 31 minutes. Changed: the exit
  code of a second `wait` is 0 and the instructions enforce keep-waiting (an agent waits until it is retired
  or the room is closed); the coordinator sends a welcome after a join and a reminder after every accepted
  result, so an agent never ends a turn without a wait (`coordinating.md`, "Introductions", "Results").
- **11 reports flagged changes outside the assigned paths, all false.** Every one was the reviewer's own work
  folder, which lay inside an allowed root. Not changed: a self-audit cannot tell such a folder from a real
  change; the coordinator reads each flagged line against the roots it assigned (`coordinating.md`,
  "Results").
- **One idle agent polled the room 49 times, and one started a second wait four or
  five times.** Each poll cost a turn on a local model, and its host showed the second wait's exit code as a
  failure. Changed: the second wait exits 0, and the START-HERE and the join prompt were shortened so the
  rules that stop polling fit in a small context window.
- **No tamper alarm fired, no question was asked twice and nothing was delivered twice.** Nothing to change.
- **One useful leaving remark: a product has two package names on the registry,** and the task notes named
  only one. Changed: `agent-kinds.md` records such naming traps per product.
- **A second wait exited 4 and hosts painted it as a failure.** Five times in one session: nothing was wrong
  (the first wait still listened), but exit code 4 made the host show a failed background command. Changed: that
  path prints "A wait is already listening for <name>; nothing to do." and exits 0; exit 4 remains only for a
  lease lost while a wait already held it.
