# Agent kinds

`scripts/agent-kinds.json` is the source: per kind, how it waits (`wake`, `wait_minutes`),
where its draft file is, one sentence about waiting that goes into its prompt, and for some kinds a
`coordinator_note`: one line the scripts print once when a seat of that kind is added (how the owner starts
that product: see "Starting an agent without its own guard"). A kind that is not in the file is refused. A
named agent gets its kind
in the answers file. An agent from the join prompt names its product; the room tool maps that to a kind
(`tools/kinds`): an exact kind name first, then any product containing `codex`, `gemini`, `cursor`, `copilot`
or `claude`, otherwise `generic`.

| Kind | Waits | Status |
|---|---|---|
| `claude-code` | `background`: `wait` runs as a background command with no limit; its exit wakes the session; asks its user before commands unless started with `--dangerously-skip-permissions` | worked live rooms on Windows as coordinator and as remote agents on the same PC and on another machine (2026-10-10) |
| `claude-code-headless` | `loop`, 9 minutes; needs a command time limit of 10 minutes | worked a rehearsal room on Windows on a light and a standard model at low effort, given only the start prompt (2026-10-10) |
| `codex` | `loop`, 15 minutes; draft is `relay-draft-<name>.md` in the folder it ran `join` or `start` from; **must be started with `codex --yolo`** | worked live rooms on Windows as remote agents, five in one room on one machine (2026-10-12); stopped waiting after a timed-out wait while that exited 3 (its shell showed 1), fixed by exit 0 and the prompt; a verb run from another folder looked for the draft there, fixed by one full path for every verb |
| `gemini` | `loop`, 1 minute | untested: generic profile |
| `cursor` | `loop`, 1 minute | untested: generic profile |
| `copilot` | `loop`, 1 minute | untested: generic profile |
| `generic` | `loop`, 1 minute | the fallback |

Every kind waits until it is retired or the room is closed: a wait that ends with nothing says that this is
normal and to run it again, however often it happens.

The test suite checks every profile's mechanics (waiting, time-outs, the draft file) on both engines
(`relay.ps1` under PowerShell 7 and Windows PowerShell 5.1). What it cannot check is how a real agent of that
product behaves when it reads the prompts: that is what the status column is about. After a product's first
room, set its numbers from what was seen and change its status line here and in `agent-kinds.json`; that is part
of the retro.

## What the wake mode costs

- `background`: nothing while idle. The agent is woken the moment a message arrives, also while it works:
  a delivery that brings a task tells it to start its wait first, and every other verb reminds it while it
  has a task and no wait running.
- `loop`: one turn of the agent per wait that times out, for as long as the room is open. While it works it
  has no wait: a delivery that brings a task tells it to run `check` after every step.
- `manual`: the agent looks only when its user says so. For agents that cannot run a command for longer than
  a few seconds.

## Model and effort

The three words of an introduction are product, model and effort. Many agents cannot see their own model or
effort setting; their user can. The join prompt tells an agent to write `unknown` for a model or effort it
cannot see, without guessing or asking anyone before joining. The coordinator settles it with the owner
after the agent is in. A named agent's start prompt still tells it to ask the user of its own session before
it runs the command: through its host's question tool when it has one, with the choices its own product
offers (its models, its effort levels) and "other" for typing; as a typed question only when it has no such
tool. The answer is taken as given: a model name of several words, in quotes or as several words, becomes
one word with dashes (`join codex gpt 6 sol medium` gives the model `gpt-6-sol`). For named agents, do not ask
the owner for their model or effort in your own session: when an introduction came with `unknown` and a
task depends on it, tell that agent to ask its
user and to run its `start <product> <model> <effort>` again.

Choose the longest wait the agent's command time limit allows. A wait must return before that limit, or the
agent sees a killed command instead of "nothing arrived".

A wait that timed out exits with code 0 since package 3.3.0, like a wait that delivered, and says "nothing
arrived in N minutes: that is normal, not an error". Until then it exited 3, and a shell that runs the line
through `powershell -Command` hands back 1 for every code that is not 0 (seen with Codex CLI, reproduced by
hand): a product that shows every such code as a failed command had its agents stop waiting after the first
quiet wait, several of them in one room. Only `check` keeps 3 for "nothing new", so a script can test it. The
prompts still tell an agent to go by the text ("nothing arrived") and the `NEXT:` line, never by the number.

Before you seat an agent, give it enough context window: Copilot CLI at least 32,768 (16,384 compacts right
after the first prompt), Claude Code at least 65,536, Codex CLI enough for about 30,000 tokens of its own
start-up context (it keeps answering past the limit). Start-up context seen in rooms: Claude Code about 25,200
tokens untrimmed, about 5,700 with `--disable-slash-commands --strict-mcp-config --tools Bash,Read,Write,Edit`,
about 1,100 with `--bare` (needs an API key); Copilot CLI about 11,700; Codex CLI about 30,000. Keep an
agent's first room output under about 2,000 tokens.

## Starting an agent without its own guard

Each product has a guard of its own: it asks its user before a command, or runs commands in a sandbox. In a
room that guard stops the work: the agent's user is asked on that machine again and again, and a sandbox
blocks the room's commands. The owner starts the agents, so say this when you hand over a prompt:

| Product | Start it with | When |
|---|---|---|
| Codex CLI | `codex --yolo` (headless: `codex exec --yolo`) | always: without it the agent cannot work in a room |
| Claude Code | `claude --dangerously-skip-permissions` | when the owner wants a room without questions and interruptions; without it the room works, and the owner answers the prompts on that machine |

- **The risk, in one line, when the job is risky.** These flags switch the product's own guard off: the agent
  runs every command without asking, with the rights of its account. For a job that installs, removes,
  changes the system or the registry, or runs code that is not trusted, recommend a virtual machine or a
  throwaway computer. For an ordinary job (reading, running tests, editing inside a repository) name the
  flag and leave it there: no lecture.
- **This is said to the owner, never to an agent.** It does not go into a prompt, a task or an assignment. An
  agent that reads about risk asks more and does less; what an agent may do is in its assignment.
- **It changes nothing else.** A machine is still in use unless the owner declared it disposable for this
  job, and the assignment's limits hold whatever the agent was started with.

## Notes per product

**Claude Code.** Started as it is, it asks its user before commands it has no permission for, on its own
machine: the room works, but each such prompt waits for the owner there. For a room without interruptions the
owner starts it with `claude --dangerously-skip-permissions` (see above).
Has a background mode for commands and is woken when one ends. On Windows its shell tool is
Git Bash, and it may also have a PowerShell tool; the prompts carry both spellings. Its file tool can write
anywhere it is allowed to, so the draft stays in its agent folder. It runs each command on a hidden console of
its own, not on the tab's, and it writes the tab's title itself: a generated title, or the session's name once
it has one, with a mark in front that moves while it works. The room tool's tab title (`Jack (researcher) -
<room>`) shows while such an agent waits, which is most of the time; the owner saw it on Windows Terminal in
the first live room. While the agent works on a task Claude Code's own title is back. If the name should stay
then as well, the owner can type `/rename <Name>` in that session (Claude Code shows a session's name on its
tab), or start it with the environment variable `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`.
Its command tool shows every exit code but 0 as an error: `robocopy` returns 1 for "files were copied", and
an agent that copies a kit with it reports a failed copy, or copies again, until it reads the code. A task
that has it copy files says so (`robocopy` codes below 8 are success), or has it copy with `Copy-Item`.
A relay window loads the user's plugins and hooks (a memory plugin wrote files into the temp folder and made a
model call at exit): start relay windows with plugins and hooks off where the client allows it. It reserves
about 33,000 tokens before compacting (window minimum above). Effort is not in an environment variable:
`~/.claude/settings.json` has `modelSettings.<model>.effortLevel` and a top-level `effortLevel`, and a
`--effort` launch flag overrides both and cannot be read from inside. A session started with a custom
Anthropic API key (instead of claude.ai sign-in) has no claude.ai connectors for that session; expected
behaviour, worth knowing before a launcher sets one.

**Claude Code, headless (`claude -p`).** No background wake: the wait runs in the foreground under the
command time limit. It needs its shell and file tools allowed and the room folder added (`--allowedTools`,
`--add-dir <room>`). It names its product as the SDK it is built on or as the CLI, and does not know its
effort setting; for a named seat nothing depends on that. Started with `--setting-sources project` it has
neither the owner's own instructions nor this plugin, which is what a stand-in for a remote agent should be.

**Codex CLI.** It must be started with `codex --yolo` to work in a room (for a headless run
`codex exec --yolo`; the flag's full name is `--dangerously-bypass-approvals-and-sandbox`, and `--help` does
not list the short one). Full access alone (`codex --sandbox danger-full-access`, or Full Access in the
permissions menu) lifts the sandbox but leaves the approvals on: the agent keeps asking its user and some
commands stay blocked. That is the owner's decision for that machine, so say it when you hand over the
prompt; the agent's own start prompt tells it to stop and ask for it. Without it: in its workspace-write
sandbox it cannot reach a
network share, its file tool writes only inside its workspace, and on Windows the sandbox can refuse to start
any command at all, also for a room on the same disk (`helper_unknown_error: setup refresh had errors`, seen
2026-10-10); with approvals switched off, the join command is refused outright. The agent reports the refusal
and does nothing, which is the right thing for it to do. On Windows it runs commands in Windows PowerShell
5.1. Its draft file lives in its working folder, under the agent's name (`relay-draft-<name>.md`), because two
agents may share that folder. That folder is the one it ran `join` or `start` from: its tool prints the full
path, and every verb uses that one file whatever folder it is run from.
A long command returns control to the model after some seconds and has to be polled; the prompt tells it to
keep waiting on the same command and not to start a second wait (a second wait exits 0 with "A wait is already
listening for <name>; nothing to do."). It
showed exit code 1 for a wait that timed out while that exited 3, and its agents took it for a failure (see
above; a timed-out wait exits 0 since package 3.3.0). Its `wait_minutes` is 15, from a measurement
(2026-10-12, codex-cli 0.162.1, Windows, started with `codex --yolo`): foreground commands of 240, 480 and
960 seconds ran to their end and printed their line. The run of 1920 seconds was stopped by the owner before
its end, so no command was seen killed: the product's command time limit is above 16 minutes and still not
known. The number was 4 before, a guess that worked; every wait that ends with nothing costs the agent a turn,
so 15 is about a quarter of the turns in a quiet room. To measure again (another Codex version, or to find
the limit itself): in a Codex session started with `codex --yolo`, run
`powershell -NoProfile -Command "Start-Sleep -Seconds 960; 'alive after 960'"` and double the seconds until
the command is killed instead of printing; the longest one that printed, less a minute, is the limit to put
into `wait_minutes` here and in `agent-kinds.json`, with the date and the Codex version. A session started
without `--yolo` measures nothing: no command starts at all (`helper_unknown_error`, above).
Files to attach go into the agent's `attach`
folder in the room, not next to the draft: the instructions name the folder in full since an agent once made
an `attach` folder in its working folder, which was the root of a share other jobs use.
When the owner says "codex luna medium", that is the three words of an introduction: product, model, effort.
It is never the name of an agent: names come from the room's pool.
Codex CLI cannot be a room agent on an Ollama-served model (web search breaks the Responses stream; no shell
tool without model metadata; tool items rejected). Against its normal provider it works. It needs
`wire_api = "responses"` for a local provider.

Codex models have names that do not say Codex (OpenAI's Codex models page, read 2026-10-11; check it again
when a name here is not what an agent reports, and add a new family word to `scripts/model-tiers.json`):

| Model | Id | What OpenAI says it is for | Tier here |
|---|---|---|---|
| Astra | `gpt-6-astra` | the most capable: complex work from end to end across code, apps and research | strong |
| 6.1 Sol | `gpt-6.1-sol` | close to Astra at lower cost: repeated, long-running work | strong |
| 6 Sol | `gpt-6-sol` | the successor of `gpt-5.5` on the paid plans | strong |
| 6 Luna | `gpt-6-luna` | focused work in high volume: summarize, extract, focused coding | standard |
| 5.6 Sol, Terra, Luna | not given on the page | the family before, still there during the change | by the family word |

An agent that names `gpt-5.5` (last day in Codex: 2026-10-14) or older runs an old client; `gpt-5.4`,
`gpt-5.4-mini`, `gpt-5.3-codex` and `gpt-5.2` are gone already. A model given only as `gpt-6` says nothing about
the family and sorts as strong: ask which one it is before a task depends on it.

Effort goes from low (shown as Light) over medium, high and xhigh (Extra High) to max and ultra. Not every
model or plan has every step: Luna has no ultra, and some plans leave out Extra High. The owner sets it with
`/model` in the session or `model_reasoning_effort` in Codex's configuration.

**Copilot CLI.** An unattended Copilot stops at "Confirm folder trust" when the work folder is not in
`trustedFolders` of its `config.json`, then at an "Allow path access" question for the room folder; `--allow-all`
does not remove the first. A saved `providers.json` makes it ignore `COPILOT_PROVIDER_*` variables and ask for a
GitHub sign-in. Working recipe: a private `COPILOT_HOME` copy without `providers.json`, the work folder added
to `trustedFolders`, and `--add-dir <room folder>`. Copilot cannot remember approval of a UNC path ("UNC/network
paths cannot be approved"): every room command on a share is a new permission event that only the allow-all
flag answers without a human. The host stopped a 20-minute background shell command on its own ("shellId: N was
already stopped via stop_powershell"); no limit was shown. Give a Copilot agent long runs in pieces (one suite or
one edition per command, output to a file, a progress line at start and end), under about 15 minutes each. Window
and start-up sizes are in Model and effort above.

**OpenCode.** Version 2.x (package `@opencode/cli`) gives the model only a JavaScript execute tool and no shell,
so it cannot run the join line; version 1.x (package `opencode-ai`) has a bash tool and can be a room agent.
`--standalone` goes after `run`; `OPENCODE_CONFIG_CONTENT` carries the provider. Name both packages: the two
names were a trap in a real room. Even on 1.x the product has no built-in `wait` or `check` habit: the room
prompt must teach both verbs.
Its host dropped a 20-minute background shell command on its own (no result written), and a foreground
command died at a 10-minute ceiling: give it long runs in pieces of under about 10 minutes, each writing its
result to a file.

**aider.** aider has no shell tool; `--load` runs only `/commands`; use `/ask`. Cannot be a room agent.

**DeepSeek Harness (dsh).** Joins through `dsh headless --patch <overlay>` with
`DSH_PERMISSION_MODE=danger-full-access` and a work folder on the local disk (its sandbox refuses shares and a
Dev Drive). A plain `dsh headless` defaults to a cloud provider and must never be run for a local-model room.

**Everything else.** Starts on the generic profile. Watch the first waits: if the agent's commands are cut
off before a minute, lower `wait_minutes` for its seat (answers field) or switch it to `manual`. For a local
loop agent whose commands finish in seconds, retire or hold other seats before you lower `wait_minutes` to one
or two minutes for the room.

**All products.** Stopping an agent window by force skips its launcher's cleanup (temporary settings folders
stay): retire the seat first so the agent exits by itself, then close the window. Never ask an agent for a
screenshot of another machine (a screen-capture attempt raised a Microsoft Defender alert and produced a blank
image); read the window text instead.

## When an agent has trouble

| Symptom | Likely cause | Fix |
|---|---|---|
| "this tool does not know who you are" | the tool was called directly, not through the wrapper | use the command printed by `start` |
| "you have not introduced yourself" | a verb before `start` | run `start` |
| `wait` prints "A wait is already listening for <name>; nothing to do." and exits 0 | a second wait while the first is alive | keep the first one; do not start another |
| the agent types message text after the verb | habit | the tool refuses anything but single words and says where the draft goes |
| `join` or `start` refuses the agent's three words | a character that is no letter, digit, dot or dash (a slash, a bracket) | the error names the word and prints the command with an example; a name of several words needs no change, its blanks become dashes |
| the agent says its draft is missing although it wrote one | it wrote the draft into another folder than the one the tool printed | the path printed by `start` is the draft, for every verb; the error names it in full |
| the agent's wait is killed by its own time limit | `wait_minutes` too long for that product | shorter wait, or `manual` |
| the agent cannot write its draft | its file tool is confined to its workspace | a draft in its working folder (`draft` in the kind or the answers) |
| the agent keeps asking its user, or a command is blocked | the product's own guard: approvals or a sandbox | the owner starts it again: `codex --yolo`, `claude --dangerously-skip-permissions` |
| "the room is not reachable" | sandbox, rights on the share, or a different path on that machine | see `transports.md` |
