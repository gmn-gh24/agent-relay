# Agent kinds

`scripts/agent-kinds.json` is the source: per kind, how it waits (`wake`, `wait_minutes`, `park_after`),
where its draft file is, one sentence about waiting that goes into its prompt, and for some kinds a
`coordinator_note`: one line the scripts print once when a seat of that kind is added (Codex: start it with
full access). A kind that is not in the file is refused. A named agent gets its kind
in the answers file. An agent from the join prompt names its product; the room tool maps that to a kind
(`tools/kinds`): an exact kind name first, then any product containing `codex`, `gemini`, `cursor`, `copilot`
or `claude`, otherwise `generic`.

| Kind | Waits | Status |
|---|---|---|
| `claude-code` | `background`: `wait` runs as a background command with no limit; its exit wakes the session | worked live rooms on Windows as coordinator and as remote agents on the same PC and on another machine (2026-10-10) |
| `claude-code-headless` | `loop`, 9 minutes, parks after 3 idle waits; needs a command time limit of 10 minutes | worked a rehearsal room on Windows on a light and a standard model at low effort, given only the start prompt (2026-10-10) |
| `codex` | `loop`, 4 minutes, parks after 4; draft is `relay-draft-<name>.md` in its working folder; **must be started with full access** | worked a live room on Windows as one remote agent (2026-10-10) |
| `gemini` | `loop`, 1 minute, parks after 10 | untested: generic profile |
| `cursor` | `loop`, 1 minute, parks after 10 | untested: generic profile |
| `copilot` | `loop`, 1 minute, parks after 10 | untested: generic profile |
| `generic` | `loop`, 1 minute, parks after 10 | the fallback |

The test suite checks every profile's mechanics (waiting, time-outs, parking, the draft file) on both engines
(`relay.ps1` under PowerShell 7 and Windows PowerShell 5.1). What it cannot check is how a real agent of that
product behaves when it reads the prompts: that is what the status column is about. After a product's first
room, set its numbers from what was seen and change its status line here and in `agent-kinds.json`; that is part
of the retro.

## What the wake mode costs

- `background`: nothing while idle. The agent is woken the moment a message arrives.
- `loop`: one turn of the agent per wait that times out. That is why loop agents park: after `park_after`
  idle waits in a row the tool tells the agent to stop asking and tell its user. The board then shows
  "parked: owner must nudge".
- `manual`: the agent looks only when its user says so. For agents that cannot run a command for longer than
  a few seconds.

Choose the longest wait the agent's command time limit allows. A wait must return before that limit, or the
agent sees a killed command instead of "nothing arrived".

A wait that timed out exits with code 3, but do not build on the number: a shell that runs the line through
`powershell -Command` hands back 1 for every code that is not 0 (seen with Codex CLI, reproduced by hand).
The prompts therefore tell an agent to go by the text ("nothing arrived") and the `NEXT:` line.

## Notes per product

**Claude Code.** Has a background mode for commands and is woken when one ends. On Windows its shell tool is
Git Bash, and it may also have a PowerShell tool; the prompts carry both spellings. Its file tool can write
anywhere it is allowed to, so the draft stays in its agent folder. It runs each command on a hidden console of
its own, not on the tab's, and it writes the tab's title itself: a generated title, or the session's name once
it has one, with a mark in front that moves while it works. The room tool's tab title (`Jack (researcher) -
<room>`) shows while such an agent waits, which is most of the time; the owner saw it on Windows Terminal in
the first live room. While the agent works on a task Claude Code's own title is back. If the name should stay
then as well, the owner can type `/rename <Name>` in that session (Claude Code shows a session's name on its
tab), or start it with the environment variable `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`.

**Claude Code, headless (`claude -p`).** No background wake: the wait runs in the foreground under the
command time limit. It needs its shell and file tools allowed and the room folder added (`--allowedTools`,
`--add-dir <room>`). It names its product as the SDK it is built on or as the CLI, and does not know its
effort setting; for a named seat nothing depends on that. Started with `--setting-sources project` it has
neither the owner's own instructions nor this plugin, which is what a stand-in for a remote agent should be.

**Codex CLI.** It must be started with full access to work in a room: `codex --sandbox danger-full-access`
(for a headless run `codex exec --sandbox danger-full-access`), or Full Access in the permissions menu of a
running session. That is the owner's decision for that machine, so say it when you hand over the prompt, and
it is in the agent's own start prompt as well. Without it: in its workspace-write sandbox it cannot reach a
network share, its file tool writes only inside its workspace, and on Windows the sandbox can refuse to start
any command at all, also for a room on the same disk (`helper_unknown_error: setup refresh had errors`, seen
2026-10-10); with approvals switched off, the join command is refused outright. The agent reports the refusal
and does nothing, which is the right thing for it to do. On Windows it runs commands in Windows PowerShell
5.1. Its draft file lives in its working folder, under the agent's name (`relay-draft-<name>.md`), because two
agents may share that folder.
A long command returns control to the model after some seconds and has to be polled; the prompt tells it to
keep waiting on the same command and not to start a second wait (a second one exits at once with code 4). It
reports exit code 1 for a wait that timed out (see above). Files to attach go into the agent's `attach`
folder in the room, not next to the draft: the instructions name the folder in full since an agent once made
an `attach` folder in its working folder, which was the root of a share other jobs use.

**Everything else.** Starts on the generic profile. Watch the first waits: if the agent's commands are cut
off before a minute, lower `wait_minutes` for its seat (answers field) or switch it to `manual`.

## When an agent has trouble

| Symptom | Likely cause | Fix |
|---|---|---|
| "this tool does not know who you are" | the tool was called directly, not through the wrapper | use the command printed by `start` |
| "you have not introduced yourself" | a verb before `start` | run `start` |
| wait exits at once with code 4 | a second wait for the same agent | keep the first one; do not start another |
| the agent types message text after the verb | habit | the tool refuses anything but single words and says where the draft goes |
| the agent's wait is killed by its own time limit | `wait_minutes` too long for that product | shorter wait, or `manual` |
| the agent cannot write its draft | its file tool is confined to its workspace | a draft in its working folder (`draft` in the kind or the answers) |
| "the room is not reachable" | sandbox, rights on the share, or a different path on that machine | see `transports.md` |
