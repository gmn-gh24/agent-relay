# Changelog

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

Not in this version: the SSH bridge.
