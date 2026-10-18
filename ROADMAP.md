# Roadmap

What is planned, in rough order of value. Nothing here is promised or dated: an item moves to
[CHANGELOG.md](CHANGELOG.md) when it ships, and is removed from this file. To suggest or argue for an item, open an
issue.

## Direction

What stays unique about agent-relay, and so is not up for change: a shared folder as the only transport; agents of
different products on different machines under one coordinator; written assignments with approval tiers and owner
cards; a room that is treated as untrusted.

- The trust boundary and the tamper check of the feed stay.
- The threat model is "a confused or prompt-injected agent", not "a skilled attacker with write access". Attacks that
  need deliberate skill (races, planted links beyond what is covered) are written down as known limits. See
  [SECURITY.md](SECURITY.md).
- Claude Code's own cross-session and team features are not a replacement for a room: they cover Claude-only work
  inside one account. A feature request for distributed agent teams in Claude Code
  (<https://github.com/anthropics/claude-code/issues/79507>) would cover the Claude-only half if it ships.

## Owner request (2026-10-15): clipboard notices only when something was copied

The owner does not want to be told when a prompt was NOT put on the clipboard; only a line saying what WAS copied.

- `scripts/New-RelayRoom.ps1` (the `not on the clipboard` branch near the end) and `scripts/Add-RelayAgent.ps1` (the
  `not on the clipboard` branches of `-Clipboard` and `-CopyJoin`): print nothing when nothing was copied; keep
  `on the clipboard: <which prompt>` when it was. When copying was asked for and failed, say that it failed.
- `tests/Relay.Scripts.Tests.ps1` asserts the old line (the cases that say `not on the clipboard`): change them to
  assert that the line is absent.
- Coordinator behaviour (SKILL.md and `references/startup-interview.md`): mention the clipboard to the owner only
  when a prompt was copied, and say which one.

## Owner's priorities (2026-10-14)

Set by the owner after the plugin-improvements room (eight agents of five products, twelve branches in two and a
half hours). These three come before everything below; the items they point at keep their own sections.

1. **The coordinator's turn count.** It is the real cost of a room: one wake per message, one turn per wake, and
   a restart of `wait` at the end of every turn. Cheap wins first: a wait that batches (D9) and a help verb that
   keeps the first output short (D1). The strong one: a Claude Code Stop hook that holds the turn while no wait
   lease is alive (D3).
2. **The launcher.** Starting an agent from inside a room, headless, with the product's guard and context flags
   set (D2). It turns a thirty-second ritual per seat into one command and makes remote seats routine; the
   per-product facts it needs are in `references/agent-kinds.md`.
3. **Lessons into defaults.** Not a code item: the rules that this room proved go into the coordinator's
   references so the next room avoids the friction without a line of code. Done on the same branch as this entry:
   one test gate at a time per machine; long runs to a loop-waking agent in pieces, one suite or one edition per
   command, output to a file; a local model takes a runner seat (one command per task, a literal report), never
   a coder seat. Where: `references/coordinating.md` ("Owner standing rules seen in real rooms") and
   `references/agent-kinds.md`. The code half of the first rule, test suites on separate machines and never in
   parallel on one, is D11.

## Next: room tool

One release of `relay.ps1` (a room package version bump, tests on both PowerShell editions, a failing test first
for each item).

| Item | What and why |
|---|---|
| Stricter introductions | A second session that introduces itself under the name of a live agent should be refused or marked `ATTENTION`, so it cannot replace that agent's card on the board. Reproduce in a test first |
| Loop guard between agents | Two agents with a direct line can answer each other without end. Refuse an identical repeat to the same receiver, and refuse past N messages on one line within M minutes, with a `NEXT:` line that says to ask the coordinator. To settle: N and M, whether they are room settings |
| Check at `report` | An optional check command per assignment, run by `report`, with its exit code and output attached as evidence, so the coordinator can reject plain failures without reading them. The command comes from the guarded copy of the assignment. To settle: a time limit, what a failing check does, how the output is cut |
| Permission mode in the introduction | Record whether the agent's product guard is off (`codex --yolo`, `claude --dangerously-skip-permissions`), as a hint on the board: risky tasks go only to a machine the owner called disposable |
| Announced model and effort | The board marks a computer-name mismatch but not a model or effort mismatch. Store what the owner announced for a seat and mark the difference |
| Dead coordinator wait | The board cannot tell a dead coordinator wait while the feed keeps the heartbeat alive. Check what the `OVERDUE` wake of 0.7.0 still misses before building anything |
| Notes to all | A note to all also lands in every free seat's inbox, so a late joiner sees notes from before its time. Decide: keep (context) or stop (confusing) |

## Top priority: integrity and small-context agents (from a research room, closed 2026-10-13)

The 0.10.0 release closed the visible half of the integrity gap (a missing feed is now shown and refused; see
CHANGELOG). The rest is design work, and R1 to R3 come first. Each item below says what happened, the
evidence, the direction and what is open, so that a later session can start without the room's files (the
room's archive is in the machine state of the PC that closed it).

### R1. Integrity for agent-written records (top priority)

- **What happened.** The owner edited an agent's `memory` file by hand and nothing reacted: the file has no
  canonical copy, so even a running feed would not have noticed (`Get-RelayMemory` only printed "skipped: 1
  malformed lines"). Room memory is shown to every agent on every wake, so a planted entry is an injection
  path into the whole room. 0.10.0 labels memory UNVERIFIED, flags malformed lines on the board and adds
  `Repair-RelayMemory.ps1`; a well-formed planted or altered entry is still not detected.
- **Direction.** Make the records append-only with a per-entry hash chain (each line carries the hash of the
  line before), or keep a coordinator-side mirror of each file that the feed compares; give every message a
  sender proof; define the reaction to a mismatch (quarantine the entry, a card to the owner, an alarm).
- **Open.** Whether the agents' tool can write a chain without a shared secret an agent could also forge (the
  threat model is a confused or injected agent, not a skilled attacker, per "Direction"); what happens to
  entries already in a room; which files are in scope (memory, journal, inbox, results, progress, card).

### R2. Run the integrity pass from something that outlives the coordinator's session (top priority)

- **What happened.** The feed ran in the coordinator's session; after a PC crash and a resume it was not
  restarted and the check did not run for 83 minutes. 0.10.0 makes that visible and refuses `wait`; it does not
  make the check survive.
- **Direction.** A scheduled watcher started with the room and restarted at logon (a scheduled task running
  `Watch-RelayFeed.ps1 -EndWithParent` is wrong for this; it needs a mode without a parent), registered by
  `New-RelayRoom.ps1` and removed by the close.
- **Open.** Elevation needed for a scheduled task; installed copy versus working copy paths; two feeds at once
  (the pane's and the watcher's: `feed.state` holds only the last writer's pid).

### R3. Compact mode for small-context agents (top priority)

- **What happened.** One full read of what the room puts in front of an agent was about 12k tokens (start
  instructions 2.2k, assignment 1.2k, rules 0.9k, join prompt 0.9k, room memory 3k, a task 0.7k, an attachment
  3.1k), 17k with the protocol reference, before the harness's own prompt and repeated verb output. A light
  local model stopped re-arming its wait after two empty waits.
- **Direction.** A compact mode per agent kind or chosen at join: a short `START-HERE`, no reprint of unchanged
  rules or of memory on every verb, terse `NEXT:` lines, a context budget per agent shown on the board.
- **Open.** What the minimum is that keeps the safety rules (the introduction, "never type text on the command
  line", the exit steps); whether the tool or the template decides; how the coordinator learns an agent's
  window (Q37 below records it per kind).

## Second pass: quick fixes from the same room

Each is minutes of work with a test or a text change. Not done in 0.10.0; the owner chose the first pass only.

### Coordinator guidance (skill and `coordinating.md` text)

- **Q21. Keep agents busy.** On every wake, name what each idle agent could do; never end a turn with an
  available agent idle and work it could take. (0.10.0 added the one-sentence rule to SKILL.md, workflow 2
  step 10, and the rule list; the fuller guidance is open: what counts as work an idle agent could take,
  parallel and cheap tasks, live checks.)
- **Q22. Delivery ladder.** Before the first hand-over and whenever a loop repeats, state what the round must
  prove and the cheapest path (installed product / swapped files / unpacked build / full package). Loop rule:
  after the same expensive step ran twice, ask what makes the third run cost a tenth, and ask the remote agent
  too. Tell the owner the chosen path and its limit. (One sentence is in SKILL.md since 0.10.0.)
- **Q23. Handing files.** Plain files for small sets, `robocopy /E /MT:16 /R:1 /W:1` for folders, a hash
  manifest, a zip only when size or count makes it faster. (One sentence is in SKILL.md since 0.10.0.)
- **Q24. Task template.** Name the shell the commands assume; list the exact files attached and those the agent
  is expected to read; give exact request or wire text for a protocol check or say "skip if unknown"; one task
  at a time to an agent that works one at a time; for a screenshot of a destructive feature say "do not
  trigger it"; ask the agent to say when the delivery method looks heavier than the check needs.
- **Q25. Verification tasks.** Demand an exact quote per row; treat a result that arrives in a small fraction of
  its budget as a flag to spot-check; show elapsed against budget on a result's board line (needs a small
  board change; see R5).
- **Q26. UI testing on a virtual machine.** Say up front that the console must stay unlocked; the agent's first
  step checks for a lock and reports at once.
- **Q27. Match the task to the agent's tools** (full-page fetch, elevation, shell) from the introductions and
  the board before sending.
- **Q28. `-Assign`.** The allowed values of `-Work` and `-MachineCare` are listed in SKILL.md workflow 4 since
  0.10.0. Open: `-Assign` with both `-Roots` and `-May` produced an assignment that calls the work folder
  "read-only for you" while "You may" allows writing there; the label must not be written when `-May` grants
  writes in that root. Reproduce with a test on `ASSIGNMENT.md` first.
- **Q29. START-HERE template.** Say "start ONE wait; exit 4 means yours is already running, do nothing". Three
  agents and the coordinator were confused by exit code 4 from a second `wait`. (The template has a sentence on
  exit 4 under "Stay reachable"; check it is where a small model reads it, and say it in the `NEXT:` line of
  the second wait.)
- **Q30. When an instruction names a group, confirm the set** before sending requests that cannot be taken
  back.
- **Q31. An owner decision about how something is done applies from the next time in the same room**, not
  only to the future plugin.
- **Q32. A coordinator blocked from messaging its own in-process subagents while a room is bound.** The skill
  says subagents are part of the coordinator. Either remove the block for those, or name the exception in the
  refusal text. Look at the pane's refusal in `hooks/register.tsx`.

### Bugs

- **Q34 (remainder).** 0.10.0 makes the tool move to the temporary folder when its working folder is gone, but
  the case was not reproduced: on Linux, on a local disk and on Windows (both engines) it passes without the fix.
  On Windows a shell standing in a folder on a share (also through the loopback admin share) keeps the folder from
  being removed or renamed, and with the shell's location deleted in-process `check` and `help` ran on the old
  tool too. Reproduce with a shell standing in a folder on a share that another machine removes, find the verb
  that failed, and make the test fail first.
- **Q35. The `task` word-match refusal** (`NOT SENT`, "two of that line's telling words") fired on most tasks
  of that room, so `anyway` was needed almost every time. Narrow the match, or the default "Never" lines of a
  tester assignment. Evidence: the room's transcript in the archive. Start with a test on real task texts.

### Agent-kind table (`agent-kinds.json`, `agent-kinds.md`)

- **Q36. Add kinds with measured facts.** `antigravity` (process agy.exe; reported itself as gemini-cli; wake
  loop; fetches full pages); `cursor-agent` (joined on first paste; wake loop; Learn search and fetch);
  `opencode` (process opencode.exe; wake loop; stopped re-arming its wait after two empty waits unless told to
  keep going; effort not visible; reports a model alias, so ask which model it points to); a local model behind
  the Claude Code CLI harness (join refused by the permission check; not usable); the process chain
  `claude.exe < ollama.exe` as the hint for a local model.
- **Q37. Record each kind's usable context and a "give it" line.** A light local model: one file under about 2k
  tokens, no bookkeeping extras, long expected durations, an early `progress`.
- **Q38. Let the introduction carry a product the table lacks, and the underlying model** when the harness
  reports an alias. Two trial tasks done with a hosted strong model under Claude Code took 97 and 44 seconds; a
  27B local model under OpenCode took 4 and 2 minutes and was correct on both.

## Later: larger items from the same room

- **R4. A send-files verb.** Takes a folder, chooses plain copy, robocopy or archive by size and count, hashes
  what it sent and prints the manifest; delivered attachments are moved out or listed as delivered (the
  sender's attach folder cannot be read by the receiver today).
- **R5. Task durations from the room itself.** Show "delivered to result sent" per task on the board, so no
  agent has to time itself (an agent cannot time its host's own file tools).
- **R6. Telling thinking from stalled.** A progress ping per tool call from the harness, or a required early
  `progress` line; the room could not tell for an agent with no wait running.
- **R7. Cost per test round visible.** A per-room "test delivery" note in the plan (how artefacts reach each
  machine, minutes per round), shown on the board.
- **R8. A named draft per verb, or `remember` from a short argument file.** Today every message costs a
  draft-file write plus a command.
- **R9. Join output names seats previously taken from the same machine,** so a new session knows whether one
  is its to resume.
- **R10. A model and harness comparison kit.** The two trial tasks of that room (a grounded release note with
  quotes; an exact-spec PowerShell function with a self-test) as a reusable benchmark with the room's own
  timings. The results are in the room's `model-comparison.md` in its archive.

## From the Ollama room and the plugin-improvements room (2026-10-14)

Items the owner deferred on the day the two rooms ran. Each says what happened, the evidence, the direction
and what is open, so that a later session can start cold. The text and script items of the same day (a shorter
START-HERE, the welcome and reminder in the skill, incremental assignment edits, the owner's model and effort
on a seat) are not listed: they ship, or are in the CHANGELOG.

### D1. A help verb in `relay.ps1`

- **What happened.** After a join the tool printed `START-HERE.md` (about 2,090 tokens) and `ASSIGNMENT.md`
  (about 780). With a client window of 16K tokens that filled the window before the first task arrived. The
  text rewrite of that day brought `START-HERE.md` to about 6,700 characters, which is a cut, not a fix.
- **Direction.** The join prints only the short rules; the details sit behind `help <topic>`. Target: an
  agent's first output is under 2,000 tokens.
- **Open.** Which rules are the short ones (the minimum that keeps the safety rules: the introduction, never
  typing text on the command line, the exit steps); which topics there are; whether the help text is a guarded
  file of the room package. This is the first step of R3 (compact mode).

### D2. Launching an agent from inside a room, with a launcher per product

- **What happened.** Proven by hand: a running agent started a Copilot agent, which joined in 21 seconds.
- **Direction.** One launcher template per product (`Start-Relay<Product>.ps1` for Copilot, Claude Code,
  Codex, OpenCode and aider). A launcher opens a seat first, starts a fresh process (the identity fix is
  done), detects which name the child took, and stops and retires the child. It is visible or headless as the
  product allows, passes the product's approval flag, and writes a prompt that states product, model and
  effort. Optional `-JoinPrompt <text|file>` and `-Configure`; it passes the product's minimal-mode switches
  (Claude Code: `--disable-slash-commands --strict-mcp-config --tools ...`). A custom API key disables the
  claude.ai connectors for that session. The per-product facts are in `references/agent-kinds.md`.
- **Risks.** A window on the owner's desktop; orphan processes; prompt injection through the join prompt file
  for a child started with its guard off; the child inherits tokens from the environment; Copilot cannot
  remember the approval of a UNC path.
- **Open.** Which products first; how the coordinator learns that a child is gone; whether the owner approves
  each launch or once per room.

### D3. Keep-waiting, the strongest layer

- **What happened.** An agent without a running wait cannot be reached from the room: the slowest reply of the
  Ollama room (56 minutes) was from one. Layers 1 to 3 are in work.
- **Direction.** A Claude Code `Stop` hook in the plugin that blocks ending the turn while no wait lease is
  alive; and the launcher adding the rule to the client's system prompt (`--append-system-prompt`) where the
  product has a switch for it.
- **Open.** What the hook reads to know the lease is alive (the room's lease file is room text); products
  without hooks; what the hook does when the room is closed or the agent is retired.

### D4. The tool sends the welcome and the reminder

- **What happened.** The coordinator sends the welcome (name, role, first task) and the keep-waiting reminder
  by hand; the skill text says so (`SKILL.md` workflow 2, `coordinating.md` "Introductions" and "Results").
- **Direction.** The room tool sends the welcome on the first introduction, from a template, and appends the
  keep-waiting reminder to every accepted result.
- **Open.** Where the template lives (a guarded file); how the tool knows a result was accepted (a message
  type, or a verb of the coordinator's); that the text of both stays the coordinator's to change.

### D5. Live check of elevation inheritance

- **What happened.** Documented as not verified: whether an agent started from an elevated agent is elevated,
  and whether the room share opens by UNC from that window.
- **Direction.** Start one elevated agent through UAC, have it run a launcher, and check that the child's
  introduction says `elevated` and that the share opens by UNC from the elevated window.
- **Open.** A machine where the owner can answer the UAC prompt; the result goes into `agent-kinds.md` and the
  elevation lines of `coordinating.md`.

### D6. An un-retire

- **What happened.** A seat was force-retired while its agent was working without running room commands. Only
  a hand edit of the `retired` marker, in canon and in the room, brought it back; it is recorded in
  `exits.log`.
- **Direction.** `Add-RelayAgent.ps1 -Unretire <name>` brings back a seat retired by mistake with its name,
  assignment and worktree, writes the exit record, and tells the agent in a note.
- **Open.** Until when a seat can come back (the generation, the open requests it left); whether the earlier
  rule that a retire asks first makes this rare enough to leave to the hand edit.

### D7. A second wait that joins the first

- **What happened.** A second `wait` is today a calm exit 0 ("a wait is already listening"); some hosts show a
  non-zero exit as a failure, which is why that fix was chosen.
- **Direction.** The second wait joins the first and reports its result when the first ends, so a wait started
  twice still delivers.
- **Open.** The lease holds one owner; what two waiters reading one delivery record do.

### D8. An owner flag for the stated model and effort in the feed and the pane

- **What happened.** The board prints `(owner)` for a model or an effort the owner stated for a seat; the feed
  JSON and the pane carry the effective values and no flag.
- **Direction.** Add the flag to `Watch-RelayFeed.ps1`, the `to*` functions in `hooks/feed.ts`,
  `types/index.d.ts` and `hooks/feed.test.ts`.
- **Open.** How the pane shows it (next to the model, as on the board).

### D9. A wait that batches

- **What happened.** The coordinator's wait ends at the first message: one wake, and one turn, per message.
- **Direction.** Hold for several messages, or for a short quiet period, before ending.
- **Open.** The hold time and the cap, so an urgent message is not held; a limit that stays: a `wait` whose
  output is read and then discarded cannot be told from a legitimate file reader.

### D10. The known-models list offers a fake name

- **What happened.** `models.json` on this PC holds each model name an agent's card gave, after a check of the
  characters. A name an agent made up can appear as a choice offered to the owner.
- **Direction.** Decide whether only names the owner stated are offered, or the card names with a mark.
- **Open.** What the owner needs more: a short list of real models, or all the names that were seen.

### D11. Test suites on separate machines, never in parallel on one (owner, 2026-10-15)

- **What happened.** Eight agents ran Pester suites on one PC at once: every suite two to three times slower,
  child processes timing out (`-999`), conformance checks failing on timing, one gate killed, and the
  coordinator's own suite stopped to free the machine. The same suites passed one after another.
- **Direction.** Two parts. The coordinator advises the owner, at the startup interview and when a job has a
  test gate, to put test runs on separate machines (one runner seat per machine, the kit staged there) and
  says so in every task that runs a suite. The tooling prevents parallel runs on one machine: the gate
  (`tests/Invoke-AllTests.ps1`, `Invoke-Suite.ps1`) refuses or waits when another Pester run of this repository
  is alive on the machine, and the runner seat's task text carries the rule. Standing rule 4 in
  `coordinating.md` is the text half; this item is the code half.
- **Open.** Refuse or queue (wait for the other run to end, with a progress line); how a run is detected (a
  lock file in the repository's temp folder, or the process list); whether the room tool's `wait` should
  print the warning to a runner agent before it starts a command.

## Next: supply chain

A checksum manifest (`MANIFEST.sha256`) for what a room is built from: `assets/room-package/`, `scripts/*.ps1`,
`RelayCommon.psm1`, the `scripts/*.json` tables and `hooks/*.ts*`.

- Generated by script (sorted ordinal paths, SHA-256, LF, ASCII), never by hand; a static-gate check recomputes it
  and fails on drift.
- Checked before a room is built or updated (refuse and name the file on a mismatch) and by the tamper check
  (a damaged canonical copy is reported, not restored from). The manifest is read from this PC's own copy, never from
  the room.
- Enforced for installed copies only; a working copy only reports, or the dev folder fails its own check on every
  edit.
- Published also as an attested release asset (GitHub build provenance), so a copy can be checked against
  something the repository cannot silently rewrite. `release.yml` fails if the two differ. The in-plugin part comes
  first; the attestation is an add-on.

## Next: skill

- **Say when not to open a room.** A single question to one of the owner's own Claude sessions needs no room; a room
  is for a scoped task, an agent of another product, a record, or more than one agent. Add it to `SKILL.md` or
  `references/startup-interview.md`, with an eval case that must not load the skill.

## Next: documentation and references

- Split `references/lessons.md`: keep job-design and coordination lessons; move tool-internals lessons (culture,
  `\d`, `@($list)`, Pester mocks, lock tokens, `$ErrorActionPreference`) to a second file read only by
  `self-improvement.md`. Add a topic line to each entry or an index at the top.
- Remove or condense lessons from the `sh` era and mark superseded ones (parking, closed "still open" lists).
- Trim `references/protocol.md`: move the lease and lock details and most of "Limits" to a `protocol-internals.md`.
- Say each repeated rule once and point to it: the hold, "no ssh, no sh", the exit-0 wait history.
- `agent-kinds.md`: move the wake-mode paragraphs out of "Model and effort", split the long Codex and Claude Code
  notes, and point to the vendor page for the model table instead of copying it.
- `coordinating.md`: add the board status `woken by N overdue task(s)` and split the "Tasks" paragraph into bullets.
- `multi-builder.md`: a ninth rule: before work is handed out, check that the builders can run the gate where they
  are.

## Next: evals

- `closes-with-memory-review` scores 0.60 with the skill: read the answers and decide whether the skill or the
  grader is at fault.
- `asks-about-an-open-room` and `handles-an-overdue-agent` vary between runs because the eval agent reads the real
  room list. Run the cases in a sandbox with an empty local folder, and use five runs per case.
- Cases for the other workflows: pause, hold and stop; the close with memory promotion; a coordinator that tries to
  reach another session with `SendMessage`.

## Next: repository

- `marketplace.json`: take `version`, `category` and the description from `plugin.json`, or add a CI check that
  compares them.
- `CLAUDE.md` at the root makes `claude plugin validate` warn that it is not loaded for plugin users. It is
  contributor guidance and stays.
- Trim the `SKILL.md` description (636 characters; the guideline is about 500) if the evals stay at 1.00 on the
  trigger and negative cases.

## For consideration

- **Developer Certificate of Origin.** A `Signed-off-by:` line on each commit (`git commit -s`), said in
  `CONTRIBUTING.md` and optionally checked in CI. It adds a paper trail for outside contributions at small cost.
  Not needed while the project has one maintainer and an MIT license with no outside work; decide if contributions
  grow. It would apply to new commits only.

- **Enforced file ownership.** Today "one owner per file" (`references/multi-builder.md`) is a plan rule plus the
  self-audit; nothing stops an agent from editing a file it does not own. The coordinator already records each
  agent's files in the plan, so the guard could flag or refuse an edit outside them. A per-file writer lock was
  suggested for the shared folder; the room folder needs none (each agent writes its own message files), and a lock
  on project files would be advisory like the plan rule. Revisit if a real room shows a collision the self-audit
  missed; it overlaps the dropped "file reservations" item below.

## Looked at and dropped

- Task dependencies that unblock by themselves: the plan already has `depends`, a `blocked` status and a cycle
  check.
- File reservations with a pre-commit guard: one owner per file in the plan and the self-audit cover it.
- A2A, mTLS federation, an HTTP server: transports that agent-relay chose not to need.
- A web view: the pane and the feed in a terminal do this.
- Waking an agent through its session's inbox socket: works for Claude Code only, where a background wait already
  wakes the agent.
- Compaction commands from the coordinator: telling a remote agent to compact. A message from the coordinator does
  not make a remote agent compact.
- `sh` and `ssh`: postponed by the owner, with no plan; see "Status and limitations" in [README.md](README.md).
