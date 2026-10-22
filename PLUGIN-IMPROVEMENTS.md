# Plugin improvements

One dated section per closed room, appended by `skills/agent-relay/scripts/Add-RelayImprovement.ps1` at the close: what the owner asked for, every finding from the agents, the statistics and the coordinator's own mistakes, each with its evidence and a proposed change. The Improve procedure (`skills/agent-relay/references/self-improvement.md`) works this list; a worked item points at its commit. Earlier rooms wrote their sections into the job's repository; they were moved here on 2026-10-22.

## Room atera-agent-install (closed 2026-10-22)

## Room atera-agent-install (2026-10-21/22): InstallAteraAgent 1.0 live tests as SYSTEM on a disposable VM

Job: live-test a new Intune install wrapper for the Atera RMM agent MSI on the test VM (one elevated Claude Code agent, Opus 5.5 medium), the coordinator writing all code and fixes, the agent running the rounds and reporting evidence. Four test rounds plus a baseline survey; about 3.5 hours; 16 coordinator messages, 16 agent messages, 2 standing rules, 0 owner cards; 4 real script defects found by the agent's evidence; the agent's session was lost once (VM restart in task 2) and replaced by generation 2.

### What the owner asked for, in the owner's words
- "you write code, the other agent just runs all the tests and provides feedback"
- "this script should not use the action modules, standalone logging only, to new secure path, check coding standards"
- "continue iteration until its done and works perfectly in all scenarios, test in depth, if you need to restart the vm do it last"
- "give me a prompt to rejoin the agent from scratch or retire him and add a new agent" (after the VM restart ended the agent's session)

### Findings from the agent's reports and memory
1. **A task that restarts the machine ends the agent's session; plan the replacement.** Task 2 asked the agent to restart the VM and continue; the session died with the restart and the owner asked for a rejoin prompt. Evidence: owen-daniel-0004 (generation 2 introduction), the owner's request. Proposal: the coordinating reference says a restart task is the last step of a task, and that the coordinator prepares `Add-RelayAgent.ps1 -Replace <name> -Force` with `-Clipboard` the moment the restart progress line arrives, instead of waiting for the owner to ask.
2. **The task word filter refused every task of this room (false positives on "test", "stop", "commit", "remove", "msi", "json", "hashes").** All eleven tasks went out with `task <name> anyway`, which drops the minutes given on the command line (each task then carried the room default of 20 minutes instead of its own 30 or 45). Evidence: every NOT SENT block, "expected: 20 minutes" on tasks sent with 30/45. Proposal: `anyway` keeps the minutes argument; the filter ignores words inside the assignment's own "Never" sentence when they are generic verbs (stop, remove, commit as "host background command"), or matches whole phrases only.
3. **A second wait printed "already listening" and exited 0; the first wait kept working.** Harmless, but the coordinator could not tell which background command was the live one. Evidence: the wait output after task 1. Proposal: the message names the process id or the start time of the live wait.
4. **The kit's hashes were the agent's only way to confirm a restage; it worked every time** (five restages). Keep: a task names every changed file with size and SHA256, and the agent confirms before running. No change.
5. **The agent's probes proved two platform behaviours the coordinator could not see from the dev PC** (empty $PSScriptRoot in param defaults under 5.1 -File; RelatedProducts after a lost registration). Keep: "stop at the first deviation, probe the cause read-only, report with the probe scripts attached" in the tester assignment. Proposal for the assignment templates: a `testing` role gets "write small read-only probes to prove a cause before reporting" in its standards line.
6. **The owner spoke to the agent in its own session (allowed reading identity files; allowed small VM fixes) and the agent reported it.** The coordinator could only take it as a claim. Evidence: owen-daniel-0009, -0010 section 5. Proposal: when the owner changes an agent's limits in that agent's session, the board should show it as an owner message (the owner types it in the chat window) or the coordinator re-assigns with `-AddMay`; the skill could say so in "Messages from the owner".
7. **"You are not it" after a lost session:** the generation-2 agent reported its start verb saying "Owen's session is still alive and you are not it" after the VM restart although no relay process ran on the VM. Not verified by the coordinator. Proposal: the liveness check tolerates a machine that rebooted (process ids restart from low numbers) or the start verb offers "take over" when the recorded process is gone.

### Coordinator mistakes and workarounds
- The first expectation for identity preservation (backup-file hash unchanged) was wrong; the agent's reading of the MSI log corrected it. Lesson: name the evidence the agent can read (a log line), not a hash of a file the product rewrites.
- A help line starting with ".NET" silently broke the comment-based help; found by the Pester suite, not by the analyzer. Worth a validator check ("a help line must not start with a dot followed by a word that is not a help keyword").
- The coordinator silenced WhatIf alias noise with Import-Module first, which a fleet test refuses for standalone scripts; the Get-Command autoload form passed. Lesson: run the suite before restaging a cosmetic change.
- The packager crashed on a registry "Exists" rule without Value (fixed as IntuneAppPackager 6.7); packaging should be dry-run earlier in a script job, not after the live tests.

### What slowed the agent down (its bye, in its words, each with a proposal)
- "Session handover across the VM restart: the restart ends the agent's own terminal, the new terminal came up unelevated, and start kept refusing ('Owen's session is still alive') although no wait process was left." Proposal: a documented restart procedure in the agent instructions (handoff file, restart elevated) and a seat lease that ends at reboot (see finding 7).
- "Git Bash rewriting '/c' into a path, and the tool's safety check blocking Remove-Item on args it misread as '/c' or 'C:\', cost two retries." Proposal: the Claude Code agent kind says to start PsExec and cmd from the PowerShell tool, never from Git Bash, and tasks with `/c` arguments say so.
- "Test commands that did not match how Intune runs them (64-bit cmd vs SysNative) needed a docs check first. Stating the process bitness with each test command would save that." Proposal: the multi-builder "kit" checklist adds the bitness of the process a command is written for.
- "A send uses up the attach folder, so a note sent mid-task would have emptied the staged evidence for the report." Proposal: a note or progress line sends without the attach folder unless `-Attach` is given, or the attach folder is per message id.
- "Leak-pattern false positives from the script's own WARN text ('creates a new AgentId:')." Proposal: the leak check the agent runs matches `name: value` with a value, not the bare field name.

### Statistics
Rounds: baseline survey, round 1 (4 runs), round 2 (6 breaks), round 2b (3), round 3 (12 steps), round 4 (8 steps incl. restart). Restages: 6. Defects fixed from VM evidence: 4 (plus 3 from the unit-test agent). Owner cards: 0. Standing rules: 2. Agent bye received: Owen (generation 2); generation 1 lost to the VM restart.

## Room atera-agent-detection (closed 2026-10-22)

## Room atera-agent-detection (2026-10-21/22): Intune detection of InstallAteraAgent proven on the VM and through the real Intune Management Extension

Job: after the owner found the first package's detection version-agnostic, prove the corrected version-tracked detection on the disposable test VM (one elevated Claude Code agent, Opus 5.5 low effort) and then the real Intune run. One task, one note round, about an hour; 3 coordinator messages, 7 agent messages; 0 owner cards; no defect in the script, one package-notes correction (rule 3 is required).

### What the owner asked for, in the owner's words
- "the deployment is incorrectly done, all deployments track the version of the app being deployed ... version tracking in app detection rules is generally required for app detection to trigger an update when it changes"
- "either we create a yupix audit key with the version or better if we track the apps own msi version key, right? implement the best way"
- "improve whats needed where needed so this doesn't happen again"
- "you must open a room and test thorougly on the remote vm"
- "improve the packagin skill as needed, if needed"
- "I need a final pacakge for intune when all is green"

### Findings from the agent's reports and memory
1. **The owner drove the Intune run from the agent's own session** ("proceed as directed by the coordinator", "dont ask, do as told", "monitor the deployment", "reboot after the job"): the agent reported each instruction as a claim, which is right, and the coordinator could only take them as such. The owner also uninstalled the agent by hand on the VM to trigger Intune. Evidence: noah-ryan-0002, -0003, -0005, -0007. Proposal: the skill says that an owner who works in the agent's session should type the same lines in the chat window, so the board marks them verified; and a `-Control` or assignment flag "owner steers this agent directly" that tells the coordinator to expect notes instead of results.
2. **A manual uninstall leaves the YUPIX marker; only the ANDed file rule caught it** (AppWorkload.log 22:52:54). Not a plugin matter, kept in the package notes and the DecisionLog. Keep: the test plan included the real IME run, which is where this showed.
3. **The VM introduced itself under a new computer name (YPX-MIA-VM01, was EXP-63593989334) at the same address.** The board could not say it was the same machine; the coordinator inferred it from the address and user. Proposal: `machines.json` keeps the address and the previous names of a machine, and the board says "same address as <known machine>" on an introduction with an unknown name.
4. **The guard blocked Remove-Item on the agent's own attach folder again** (also in the previous room), so old attachments travelled with the next report. Proposal: the send verb clears the attach folder itself after a successful send, or the agent kind text names the allowed way to empty it.
5. **The remember limit (500 characters) forced a rewrite.** Proposal: the limit is printed before the agent writes, or raised to 600 like the local notes.
6. **The agent's first terminal was elevated this time** (the join prompt plus the owner's "run as administrator"); no replacement needed. Keep.

### Coordinator mistakes and workarounds
- The task word filter refused the task again (false positives on "stop", "commit", "remove", "msi", "json", "hashes"); sent with `anyway` and the minutes were dropped (20 instead of 30). Same as the previous room's finding 2.
- The Intune end-to-end task was never sent as a task: the owner started the deployment and told the agent directly, so the agent reported it as a note. Harmless here; the plan should have had the task ready before the owner's upload.

### Statistics
Tasks: 1 (six steps, all pass). Notes from the agent: 5 (two owner-instruction claims, one live-monitoring note, one result note, one bye). Restages: 0. Owner cards: 0. Agent bye received: Noah (generation 1).

## Room nvidia-app-agent-toggle-2026-10-22 (closed 2026-10-22)

Job: find where a desktop app stores an "allow AI agents" toggle, then build and live-test a one-shot SYSTEM script that turns it off. One coordinator, one elevated Claude Code agent on the owner's in-use PC, 5 tasks, all accepted, about 70 minutes.

What the owner asked for, in the owner's words
- "forget about that path, this is our default rooms folder moving forward" (a new share given after the room was created). Proposed change: New-RelayRoom.ps1 or machines.json should support a marked default rooms root that the interview offers first, and Get-RelayRooms.ps1 should show which share is the default.
- "ask him to start over and monitor for very quick progress dialog window that showed up, should be fully silent install". The owner saw a progress dialog flash on an in-use PC. It was the agent's Procmon CSV export (/OpenLog /SaveAs shows "Applying Event Filter" and "Exporting event data" dialogs; /Quiet /Minimized only cover the capture instance). Proposed change: the in-use machine wording in an assignment should say "anything that shows a window on the owner's screen is announced first", and agent-kinds or lessons should name Procmon exports as a known flash.

Findings from the room
1. Moving a room to another share means close plus create. The first room had nobody in it and was closed with -Force. Close-RelayRoom.ps1 -Remove of its folder was refused by the host's permission classifier. Evidence: the denial in the coordinator session. Proposed: a documented "abandon an empty room" path (close, archive and remove in one step for a room with no joins), or Update-RelayRoom.ps1 -RoomsRoot to move a room that has no agents yet.
2. The new room got a date suffix (-2026-10-22) because a closed room with the same name existed in the local index, although it lived on another share. Proposed: the name clash check could ignore a closed, empty room, or the interview could offer to reuse the name.
3. The coordinator's first start in the new room did not register. The next task send failed with "you have not introduced yourself in this room yet", and a second start fixed it. The first start's output had been piped through Select-Object -Last 3, which hid any error. Not verified why it failed; possibly a race with the feed starting at the same moment. Proposed: start should exit non-zero when the introduction is not recorded, and the skill should say not to trim start's output.
4. The task guard matched false positives twice: the non-goal "Changing any other NVIDIA App setting" matched the UI path "Settings > Features", and the never-line "push or publish" matched the word "public" in "NVIDIA's public connection reference". Both needed "task <name> anyway". Proposed: match whole words only ("public" is not "publish"), and skip menu paths (text with ">" separators).
5. Add-RelayAgent.ps1 -Never 'a; b; c' stores ONE line, not three, so -RemoveNever needs that exact joined text, and there is no -AddNever. Removing one rule meant removing the whole line and setting -Never again. Proposed: split -Never, -May and -NonGoals on ";" into list items, or add -AddNever; and say in the error message which lines exist (it already does).
6. An agent passed on owner words typed in its own session ("proceed with this instructions, access any file, app, reg key needed"). The coordinator treated them as the agent's claim; the assignment already covered the work. This worked as designed.
7. Owner decision "leave the machine in the state the tested script leaves it" had to be recorded with Add-RelayDecision.ps1 -Owner, plus a removed never-line and new machine notes. Proposed: a template line for "final state after a live test" in the in-use machine assignment, since live script tests on in-use machines will often end changed on purpose.

Statistics
1 agent (Claude Code, strong model, elevated), 1 open seat used, 12 coordinator messages, 9 agent messages, 1 question (a registry write beyond the assignment, approved within the coordinator's authority), 0 overdue tasks, 0 tamper alarms.

Coordinator mistakes and workarounds
- Ran start with its output trimmed, so a failed introduction went unnoticed until the first task send (finding 3).
- Asked the owner deployment-style questions (uninstall, detection marker) for a plain configuration script. The owner rejected them. That is a project lesson, not a plugin one, and is recorded in the coordinator's project memory.

## Room 7zip-download-wrapper (closed 2026-10-22)

## Room 7zip-download-wrapper (2026-10-22): Deploy-7Zip 3.0 / Uninstall-7Zip 3.0 live tests as SYSTEM on a disposable VM, file-association investigation, Intune policy and real Intune run

Job: live-test a download-based Intune wrapper for 7-Zip (pinned 26.05, nothing bundled) on the disposable test VM with one elevated Claude Code agent (Opus 5.5 medium), the coordinator writing every fix, the agent running the rounds and reporting evidence; then a read-only investigation of file associations, the registration the scripts write, the Intune DefaultAssociationsConfiguration policy and the real Intune Management Extension run; the restart as the last step of a task with a planned replacement. Ten tasks in 84 minutes (28 messages: 10 tasks, 9 results, 2 questions, 2 answers, 3 notes, 2 hellos); 3 generations of the agent (restart, then a session that never introduced itself); 0 owner cards; 6 room memory entries; 3 script gaps found by the agent's evidence, 2 kit defects and 2 wrong test premises of the coordinator's.

### What the owner asked for, in the owner's words
- "we don't bundle the msi, we download and deploy straight from 7z, keep todays lessons in mind to update and deploy the latest stable version of 7z, open a room for testing when needed"
- "when ready, open a room for testing on the vm, full circle, all scenarios"
- "uninstall must uninstall any/all instances of 7z, safely and cleanly ... when updating/upgrading we must uninstall first and then install new ... test this case, make sure its flawless"
- "I wonder if uninstalling 7z removes its windows explorer file associations ... investigate this in depth live on the VM, we want 7z files to always open with 7zip"
- "since this will be deployed to newer windows 11 the old association wont work, lets skip that, just create a separate md file with simple step by step to get that setup in intune configuration policies"
- "the intune policy has been created and should be synced to the remote vm any minute now, check"
- "or give me the prompt for karen gen 3"

### Findings from the agent's reports and memory
1. **The agent stopped on an expectation the coordinator wrote wrongly, twice, and once on a script gap; all three stops were right.** Round 1: no WHATIF line for the uninstall preview (a real script gap, fixed). Round 2 step 12: the per-user install setup used the same ProductCode as the machine install, which Windows Installer only reconfigures (the agent proved it with MsiInstaller events 1033/1035). Round 2b step 17: the EXE uninstaller removes its Start-menu folder itself, so the cleanup branch never ran; the agent continued and proposed a break mode that plants the folder, which was added and proved the branch. Proposal: the tester assignment's standards line keeps "stop at the first deviation, probe the cause read-only, report with the probe attached" (it paid off every time); the coordinator's task template should mark each expectation as "must" or "expected, report if different", so a wrong premise does not stop a round.
2. **Two kit defects of the coordinator cost a round each.** The break helper returned two objects (Write-Output plus return) so the installer path was mangled; the runner swallowed its snapshot lines into a variable and read a console that PsExec's redirected stdout never carried. Both found by the agent's probes. Proposal: a kit checklist line in the multi-builder reference: "run every helper once on the dev PC in a dry mode before staging; a function that prints and returns must print with Write-Host".
3. **Elevated pwsh 7.6 on the VM refused New-Item -Force and Remove-Item on an HKLM key that Windows PowerShell 5.1 accepted** ("Requested registry access is not allowed"); the agent switched the helper to powershell.exe and said so. Not reproduced on the dev PC. Proposal: the agent-kinds reference notes that registry helpers for a VM are run under Windows PowerShell 5.1 unless pwsh is the product under test.
4. **A task that restarts the machine: the replacement was prepared the moment the "restarting now" line arrived (the lesson of the previous room), but the first replacement session never introduced itself; the owner asked for "the prompt for karen gen 3" and the second one joined.** The board kept showing the stale "restarting now" progress line under generation 2. Proposal: `-Replace` clears the previous generation's progress line, and the board says "no introduction yet" for a replaced seat.
5. **The owner worked in the agent's session again** (asked it to watch an Intune reinstall after a manual uninstall, before the generation-3 join); the agent reported it as a claim with the evidence, which the coordinator accepted as the step-30 result. Same as the Atera rooms' finding. Proposal unchanged: an owner who steers an agent directly types the same line in the chat window, so the board marks it verified.
6. **The task word filter refused every task again** ("test", "remove", "commit", "installer", "stop"), all sent with `anyway`, which dropped the minutes (30 instead of 40-60). Same as the previous rooms. Proposal unchanged: `anyway` keeps the minutes; the filter ignores the assignment's own "Never" sentence words that are generic verbs.
7. **The agent has no mouse or GUI control; a step that needed a Settings click was answered with a scripted baseline** (removing the agent's own per-user choice, no hash written) after the agent asked instead of guessing. Keep: "ask first" worked. Proposal: the tester assignment template says whether the agent has desktop control, so the coordinator writes no click steps.
8. **Agent facts worth keeping** (verified against its evidence): the 7-Zip MSI registers no associations; HKLM .7z stays ArchiveFolder on Windows 11; a per-user UserChoice survives an uninstall as a dead link; an elevated per-user MSI install still writes the HKLM ARP key and the files; `AssocQueryString` with `$null` as the verb fails because PowerShell passes `""` for a P/Invoke string (use `[NullString]::Value`); the dmmap WMI class shows the policy value to SYSTEM only; the DefaultAssociationsConfiguration policy lands in `PolicyManager\current\device\ApplicationDefaults` with event 814 and is applied by the logon task "DefaultAssociations" at sign-in, rewriting the UserChoice of every listed type with a new hash at each sign-in. Promoted to the project memory and the DecisionLog, not to the plugin.

### Coordinator mistakes and workarounds
- Expectation "Removed the empty Start menu folder" written without checking what the EXE uninstaller itself does; the "UninstallEntries none" precondition for the per-user step written without knowing that an elevated per-user MSI install writes the HKLM key; fixed by reading the agent's probes and adjusting the step instead of the script.
- The first kit was never dry-run on the dev PC (finding 2).
- The `-Clipboard` parameter of `Add-RelayAgent.ps1` takes the agent's name and cannot be combined with `-Replace` in one call; two calls were needed. Proposal: the skill text names the two-call form next to the restart lesson.
- Step 30 was written as "uninstall with the kit, sync, watch", while the owner had already uninstalled by hand and assigned the package; the manual uninstall turned out to be the stronger case (detection fails on the file rule only). Lesson: for the real Intune run, ask the owner which trigger they will use before writing the step.
- The coordinator's own host blocked two commands whose text held a copy switch beside a delete verb (the same guard the agent hit); the close-out text went through a file write instead.

### The agent's bye (in its words, each with a proposal)
- "The room host name does not resolve on the VM; every command had to switch to the address." Proposal: machines.json already records it; New-RelayRoom could put the address first in the prompt for a machine whose note says the name does not resolve.
- "The kit had defects I hit first ... A dry run of each break mode before a round would have caught them." Proposal: finding 2.
- "The elevated pwsh 7.6 refused New-Item/Remove-Item on an HKLM key while 5.1 worked." Proposal: finding 3.
- "The Claude Code safety check blocked combined commands containing a copy switch or a reg switch next to Remove-Item (it read the switch as a path), so commands had to be split." Proposal: the Claude Code agent kind says: one delete per command, no copy or registry tool switches in a command that also deletes.
- "No mouse control: Settings and the Open-with checks needed deep links, screenshots and API probes." Proposal: finding 7.
- "The pre-existing per-user association on the test account masked machine-level behaviour in every user-side check." Proposal: the baseline survey of a job lists the test account's per-user state for the product (a fresh local account would be cleaner; ask the owner).
- "The 1-minute wait cycles meant many idle wake-ups between tasks." Proposal: wait_minutes 1 was chosen for responsiveness; a longer wait for a tester between rounds (5) with the coordinator's task delivery waking it would cost nothing.

### Statistics
Tasks: 10 (round 1 stopped at step 01; round 1 again 8/8; round 2 stopped at the setup; round 2 again 7 of 8 with one not tested; round 2b stopped at a precondition; round 2b continued 4/4; round 2c 5/5 plus one partial display check; investigation; round 3 2/2 then the restart; round 3b 2/2). Questions from the agent: 2, answered within the authority, median reply 0 min. Restages: 6. Defects fixed from VM evidence: 3 script gaps (WhatIf uninstall line, signed CDN URL in the log, empty Start-menu folder), 2 kit defects. Owner cards: 0. Standing rules: 0. Generations: 3 (bye received from generation 3; generation 1 ended by the planned restart; generation 2 never introduced itself). Changes outside assigned paths: 0. Tamper alarms: 0.
