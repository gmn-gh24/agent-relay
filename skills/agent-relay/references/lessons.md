# Lessons

Dated, in general terms, each with what was changed because of it. No machine, share, address or user names
and no task content: this file is committed. Newest at the bottom. Read it before designing a job; add to it
after every room (`self-improvement.md`).

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
