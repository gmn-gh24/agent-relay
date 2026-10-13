# Several builders and the kit

Read this when a job is split across several agents, or when agents run a test suite, a build or a review on a
copy of a project you stage. The rest of coordinating a room is in `coordinating.md`.

## One job, several builders

When a job is bigger than one agent's task, split it and let the agents build side by side. You stay the one
who decides and the one who puts the parts together. What made this work in a real room, in this order:

1. **Write the contract first.** One file in the room's `work` folder that every part is built against: the
   file formats, the exact output, the names, who owns which file. Whatever it leaves open, two builders
   decide differently. Number its revisions and list what changed at the top, so a builder who started on an
   earlier one sees in a minute what moved.
2. **One owner per file.** Split along files, not along features: two agents never edit the same file, and a
   new file is better than a shared one. A part that needs a change in somebody else's file asks for it.
3. **Have the contract reviewed while the builders start.** Give the strongest model in the room the contract
   and the code it builds on. Ask for the three worst faults as a note at once and the full list after: the
   early ones arrive before anybody has built around them.
4. **Tests come from the contract, not from the code.** One agent builds, another writes the tests from the
   words alone. The tests are the referee between two implementations, and both learn where the words fail.
5. **Put the plan into the room:** `scripts/Set-RelayPlan.ps1 -Room <id> -PlanFile <json>` (parts, owners,
   status, what depends on what, a reviewer and the files of each part). Every agent sees it with `team`, is
   shown a changed plan with its next message, and gets a direct line to the owners of the parts its own part
   depends on and to its reviewer. Move a part as it moves: `-Part <id> -Status review`. The board shows the
   plan, what each part still waits for, and each agent's last `progress` line; a plan in the room that is not
   the one this PC wrote is marked `DIFFERS FROM THE COPY ON THIS PC` there, and the feed puts it back.
6. **Let them talk where their parts meet.** A builder hands its file to the agent that tests it; a reviewer
   sends findings to the owner of the file; the owner decides how to fix. What the contract does not decide
   still comes to you: two agents settling it between them make a third version of the contract.
7. **Decide fast, in writing, once.** An answer to one builder that touches another's part goes into the
   contract, not only into the reply. Collect what a review finds into one revision instead of five notes.
8. **You integrate.** Check each result against its evidence: the hash, the difference to what the agent
   started from, the self-audit. Put the parts together in the working copy, run them against each other,
   run the whole gate, and have the strongest model read the whole before you call it done.
9. **Where one thing is built twice, each author reads the other's.** Two tools with the same verbs, a second
   reader of the same file: the author of one reads the other line by line next to its own and lists every
   place they differ. Run each finding on both before you decide which side moves, and write the decision
   into the contract.

An agent at work does not read messages: it sees a changed contract when it next waits or checks. Its
instructions tell it to keep a wait running in the background, or to `check` between steps; not every agent
does. Expect one round of rework after a late revision, and send one revision, not five.

## The kit

When agents run a test suite, a build or a review on a copy of a project (a "kit" you stage in `work`),
what is not in the kit costs a round: an agent reports a failure that is only a missing file, you restage,
the agent runs again. Before the first task goes out, check the kit against this list, and again after every
change to it:

- **The task names the files, and its numbers are the kit's.** "Copy these five files" from a folder that
  holds seven gets seven copied with a wildcard: list the files to copy by name, or stage a folder that holds
  exactly what is to be copied and say "the whole folder". A count the task gives (steps, files, tests) is
  the count the runner prints: read both once more before you send, since an agent that finds two numbers
  stops to ask which one is right.

- **Everything the suites read** is in it: the reference masters a test compares its output with, the
  profiles or settings files a run loads, the sibling scripts a drift guard compares (a guard that reads
  `..\other.ps1` fails on a kit that holds only the file under test), the fixtures, the data tables. Run the
  suite once yourself from a copy of the kit on another path before you stage it: what fails there fails for
  the agent too.
- **Per round, only what changed.** For round N stage a folder `round-N` with the files that changed since
  round N-1 and a diff of those files against round N-1, not against the checkout: a reader who reviewed round
  N-1 sees what moved, and nothing else. Say in the task which folder is the round's. Ask the agents for the
  same shape back (`PROTOCOL.md`, "Files first, message last").
- **A tested runner template.** When agents run tests from a script you hand them, test the script yourself
  first, with these in it:
  - `Invoke-Pester -PassThru` with `Run.Exit` false: the runner reads the result object and sets its own exit
    code from it; with `Run.Exit` true Pester ends the host process from inside the runner.
  - No `Set-StrictMode` in the runner: it leaks into the test scope, and a test that was fine alone then
    fails on an unset variable.
  - Under Windows PowerShell 5.1, rebuild `PSModulePath` from the registry values of the Machine and User
    scope before the first `Import-Module`: a `powershell.exe` started from `pwsh` inherits the PowerShell 7
    module folders, and `Set-Acl`, `Get-FileHash` and other cmdlets of its own then go missing.
  - The runner writes its output to a file in the agent's results folder and names that file in the report:
    a run whose output lived only in the agent's session is gone with the session.
- **The runner and its scratch files live in the results folder** on the agent's own disk, never beside the
  kit's folders: the self-audit lists every new file next to an assigned folder as `OUTSIDE`.
