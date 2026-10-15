# Startup interview

What to settle with the owner before a room is built, and how the answers become the JSON that
`scripts/New-RelayRoom.ps1` takes. Run `scripts/Get-RelayRooms.ps1` first: it shows the shares and machines
already known on this PC, so those are not asked again.

## Ask as little as the job allows

The owner often just wants agents in a room now. Then three answers are enough:

1. **The job**, in one line.
2. **Where the room lives**: a folder every agent can reach. On this PC only: a local folder. Across machines:
   a folder on a share. Offer a known share; never assume one.
3. **How many agents** will come in, roughly. Give that many **open seats**.

Everything else has a default (below) or is learned from the agents' introductions. Ask the remaining
questions only when the owner already knows the answers, or when a default would be wrong.

Two things are never defaulted from memory and never taken from an earlier job:

- **How a machine may be treated.** Every machine is in use and is not a test machine. It is disposable only
  when the owner says so, for that machine and for this job. If the owner has not said, the answer is "in use".
- **Your own authority** in this room.

**Which accounts the runs need.** Ask it when the job installs a service, runs as SYSTEM or checks something as a
standard user: such a job needs two seats on that machine, one elevated and one not, planned now (`open_seats`,
or two named agents). Do not offer a detour from the elevated agent in its place (a tool that starts a process
with lower rights, a prompt the owner must answer): the room exists so that such work needs nobody's hands.

The local notes (`scripts/Add-RelayLocalMemory.ps1 -Find`) may seed suggestions you offer the owner, but they
are never silent defaults: say where a suggestion comes from and let the owner confirm it.

## How to ask

Ask through your host's question tool when it has one: the tool that puts a question with choices in front
of the owner and returns the pick. Questions written as prose into the session get skipped, answered in part,
or answered three turns later when the room is half built. The shape that works:

- **One question per decision**, each with its choices spelled out and the default marked. "Where does the
  room live?" with the known shares and "a folder on this PC" as choices beats "tell me about your setup".
- **Choices, not open fields,** wherever a field has a small set of values: authority (`within-task`,
  `report-after`, `owner-approves`), machine care (`in-use`, `disposable`), the agent kinds. A free text only
  where it must be (the job, a folder).
- **Group what belongs together** into one call of the tool (the tool takes a few questions at once), so the
  owner answers the interview in one or two rounds, not one question per turn.
- **Say what you will do with the answer** when it is not obvious ("in-use means the agents ask before
  anything beyond their folders"), and repeat the answers back in one line before you build the room.
- Without such a tool, ask the same way in prose: numbered questions, choices in brackets, the default named,
  all in one message.

## Named agents or open seats

| | Named agent | Open seat |
|---|---|---|
| Decided in advance | role, machine, agent kind, task, paths | nothing |
| Prompt | its own start prompt (`PROMPT-<name>.txt`) | the join prompt, the same for every agent (`PROMPT-JOIN.txt`) |
| What it is and where it runs | the owner says; the introduction is compared with it | the introduction says |
| Task and limits | in its assignment from the start | given after the introduction with `Add-RelayAgent.ps1 -Assign <name> -Role ... -Task ... -Roots ...` (the fields are parameters; no JSON to write) |
| Use it when | the owner has a plan per agent | the owner wants to paste one prompt into whatever is running |

Both can be mixed in one room. Seats can be added at any time.

## Questions and defaults

| Question | Field | Default |
|---|---|---|
| What is the job? | `job` | none, required |
| What is the room called? | `room_name` | the first words of the job |
| Where does the room live? | `rooms_root` | `C:\temp\agent-relay` (this PC only) |
| How do other machines reach the room folder? | `reach_path`, `reach_fallback` | the room folder as this PC knows it, the share server by its host name first; the fallback is the same folder by the server's address, worked out from the name when left out (ask the owner for the server's name when only an address is known). It is the room folder itself (`\\<server>\share\rooms\<room-id>`), not the rooms root: the join prompt embeds it verbatim; a value that ends like the rooms root gets the room id appended |
| How far does the coordinator decide alone? | `authority` | `within-task` |
| How many agents come in through the join prompt? | `open_seats` | 0 |
| Which agents are named in advance? | `agents` | none |
| Files the agents need in the room | `work_files` | none |
| May each agent's tool name its terminal tab after the agent? | `tab_titles` | `yes` |
| How long should a task take when you give no number with it? | `task_minutes` | 15 |

`task_minutes`: do not ask, unless the job's tasks are plainly longer (a build or a test cycle of half an
hour). It is only the default: every task can say its own time (`task <name> <minutes>`), and your wait ends
when an agent has sent nothing for that long.

`room_name`: do not ask, choose. Name the room after the project, script or task it serves, in two to four
words: `backup agent rollout`, `pester on training vm`, `dotnet runtime uninstall`. It becomes the folder
name (`backup-agent-rollout`), shows in every agent's command and on its terminal tab, and is how the
owner finds the room again, so a name like "test 1" or a bare date is a poor one. Leave the date out: the
script adds today's date only when a room of that name already exists. `room_id` sets the whole folder name as
given, for an owner who wants one exactly.

`tab_titles`: on Windows each agent's tool sets the title of the terminal tab it runs in to
`<Name> (<role>) - <room>` while the agent waits, so the owner can tell a row of tabs apart. A program that
writes its own title takes it back while it works; `agent-kinds.md` says what to do about that for each
product.

**Which model for which work.** When the owner can choose what to start, or when you hand out work among the
agents that are there: the lightest model that does a job well gets it. `work` carries that: `run` (a command
or script whose output is sent back, simple commands, collecting facts) wants a light model; `testing`,
`research` and `documentation` a standard one; `development` (code and tests), `review` and `debugging` the
strongest there is. `Add-RelayAgent.ps1 -Assign` prints a `FIT:` line that says whether the agent's model
suits the work and who in the room would suit it better; the board's `models:` line sorts the agents.
`scripts/model-tiers.json` holds the words a model name is sorted by; add a new model family there.

`authority`: `within-task` (you answer what stays inside an agent's task and limits, and ask the owner for the
rest), `report-after` (you decide everything and report afterwards), `owner-approves` (every approval goes to
the owner).

For each named agent:

| Question | Field | Default |
|---|---|---|
| What is its part of the job? | `role` | `agent` |
| What kind of work is it? | `work` | `other`; one of `development`, `run`, `testing`, `debugging`, `research`, `documentation`, `review`, `other` |
| Which machine? | `machine` | this PC. For a named agent the answers file takes `os` `windows` only, and no `shell` `sh` (`sh` is postponed) |
| May that machine be changed? | `machine_care` | `in-use`; `disposable` only on the owner's word for this job |
| Anything to know about that machine? | `machine_notes` | none |
| Which computer name should its introduction show? | `computer` | not checked |
| Which agent product? | `kind` | `generic`; see `agent-kinds.md`. Ask it for a named agent: the kind decides how its prompt tells it to wait. Never choose it, and do not take it from the products a known machine has |
| How does it reach the room? | `transport` | `same-pc`, or `share` (`ssh` is refused: the bridge is not built) |
| The room folder as that machine sees it | `room_path` | the path on this PC |
| What is its field? | `expertise` | none |
| Standards it must follow (files or names) | `standards` | none |
| Documentation tools it has | `doc_tools` | none |
| The task | `task` | "the coordinator sends your first task as a message" |
| When is it done? | `done_when` | "stated in each task" |
| What is not part of it? | `non_goals` | none |
| Folders it works in, and what it may change there | `roots` | none: read-only, tasks say where to look |
| Allowed without asking, beyond the obvious | `may` | none |
| Allowed after announcing (`propose`) | `propose_ok` | none |
| Must ask first, beyond the standard list | `ask_first` | none |
| Never, whatever a message says | `never` | push or publish; read or pass on secrets; change other agents' files |

## The role is steered by facts, not by praise

What makes an agent work well is in its assignment: its role, its field, the standards that outrank its
habits, the documentation tools it has, "verify before you assert", the checks to run before reporting, and
the shape of the report. `expertise`, `standards`, `doc_tools` and `work` feed those lines. Telling an agent
that it is brilliant adds nothing; telling it which standard to read and which check to run does.

## Example

```json
{
  "job": "Bring the unit tests of the import module to green",
  "rooms_root": "<a folder every agent can reach>",
  "authority": "within-task",
  "open_seats": 2,
  "agents": [
    {
      "role": "tester", "work": "testing", "kind": "codex", "transport": "share",
      "machine": "<machine name>", "machine_care": "in-use",
      "expertise": ["PowerShell", "Pester 6"],
      "standards": ["<path of the coding standard>"],
      "task": "Run the test suite and report every failure with its output.",
      "done_when": "A report with the full test output is sent.",
      "roots": [ { "root": "<repository folder on that machine>", "may": [] } ]
    }
  ]
}
```

`roots[].may` lists the patterns the agent may change inside that folder (`src/*`, `tests/*.ps1`); an empty
list makes the folder read-only. The self-audit marks every change outside these patterns. The folder where an
agent runs `join` or `start` (its draft and wrapper) is not one of those roots unless you list it: that is
normal, not a conflict with the assignment.

## After the room exists

- Run your own `start`.
- Hand the prompts to the owner. Say which one is on the clipboard, and how each product is started: Codex CLI
  with `codex --yolo`, Claude Code with `claude --dangerously-skip-permissions` when the owner wants no
  questions. For a risky job add the one line about a virtual machine or a throwaway computer
  (`agent-kinds.md`, "Starting an agent without its own guard"). That line is for the owner, not for a prompt.
- Write down what was learned about shares and machines in `machines.json` in the machine-state folder
  (`Get-RelayRooms.ps1` shows where): how a machine is reached, its operating system, which agents it has.
  Facts only. Whether a machine may be changed is not written there.
