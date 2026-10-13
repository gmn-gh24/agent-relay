# Ideas from the research on alternatives (2026-10-12)

Not started. Four changes taken from what other tools do, in the order they should be done, and what was
looked at and dropped. Each idea was checked against the code with a quick search, not a full read: confirm
that it is still missing before building it.

## Background

The research compared agent-relay with Claude Code's own features (agent teams, cross-session messaging,
Remote Control) and with third-party tools (MCP Agent Mail, a2abridge, worktree orchestrators). Nothing found
does the whole of what agent-relay does. What stays unique: a shared folder as the only transport, agents of
different products on different machines under one coordinator, written assignments with approval tiers and
owner cards, and a room that is treated as untrusted.

Decisions taken in the same session:

- The trust boundary stays, and so does the tamper check of the feed.
- The threat model is fixed at "a confused or prompt-injected agent", not "a skilled attacker with write
  access". No new adversarial review rounds unless a real room shows a problem; attacks that need deliberate
  skill (races, planted links beyond what is covered) are written down as known limits, not fixed.
- Open risk: the feature request for distributed agent teams in Claude Code
  (<https://github.com/anthropics/claude-code/issues/79507>) would cover the Claude-only half if it ships.

## To do

### 1. Say when not to open a room

From: cross-session messaging exists (`SendMessage`, `ListAgents`).

The references mention the built-in session tools only to refuse them. Add a short section to `SKILL.md` or
`references/startup-interview.md`: a single question to one of the owner's own Claude sessions needs no room;
a room is for a scoped task, an agent of another product, a record, or more than one agent.

- Touches: `skills/agent-relay/SKILL.md` or `references/startup-interview.md`, and one case in `evals/` for
  "must not load".
- No change to the room package.

### 2. A loop guard on the lines between agents

From: cross-session messaging rate-limits repeated messages per sender and drops identical repeats.

No agent parks since 0.7.0, and the plan opens direct lines between owners, so two agents can answer each
other without end and burn turns until the coordinator notices. Nothing in `relay.ps1` was found that stops
it. In the send verbs: refuse an identical repeat to the same receiver, and refuse past N messages on one
line within M minutes, with a `NEXT:` line that says to ask the coordinator.

- Touches: `assets/room-package/tools/relay.ps1`, `Relay.Tool.Tests.ps1` or `Relay.Team.Tests.ps1`, and
  `Relay.Parity.Tests.ps1` for the literal lines.
- Room package version bump; tests on both PowerShell editions.
- To settle: N and M, whether they are room settings, and whether messages to the coordinator count.

### 3. A check that the tool runs at `report`

From: the `TaskCompleted` hook of agent teams, which can refuse a completion.

`-DoneWhen` is prose and the report carries a self-audit, so verifying is all on the coordinator, the most
expensive model in the room. An optional check command per assignment, run by `report`, with its exit code
and output attached as evidence, lets the coordinator reject plain failures without reading them.

- The command comes from the canonical copy of the assignment (a guarded file), never from a file an agent
  can edit.
- Touches: `Add-RelayAgent.ps1 -Assign` (a new field), `ASSIGNMENT.md.tmpl`, `relay.ps1` (`report`),
  `references/coordinating.md`, tests.
- Room package version bump; tests on both PowerShell editions.
- To settle: a time limit for the check, what a failing check does (refuse the report, or send it marked
  failed), and how the output is cut.

### 4. The agent's permission mode in its introduction

From: cross-session messaging holds messages to a session that bypasses permission prompts.

An introduction records whether the agent runs elevated; it was not seen to record whether the product's own
guard is off (`codex --yolo`, `claude --dangerously-skip-permissions`). With it, the coordinator sends risky
tasks only to an agent on a machine the owner called disposable, and the board shows it.

- The agent reports this itself: it is a hint, never something the coordinator's PC decides by.
- Touches: `relay.ps1` (`start`), the board, the feed and the pane if it is shown there
  (`Watch-RelayFeed.ps1`, `hooks/feed.ts`, `types/index.d.ts`, `hooks/feed.test.ts`),
  `references/agent-kinds.md`.
- Room package version bump.

## Looked at and dropped

- Task dependencies that unblock by themselves: the plan already has `depends`, a `blocked` status and a
  check for cycles.
- File reservations with a pre-commit guard (MCP Agent Mail): one owner per file in the plan and the
  self-audit cover it, and a git hook helps only for git work.
- A2A, mTLS federation, an HTTP server: transports that agent-relay chose not to need.
- A web view: the pane and the feed in a terminal do this.
- Waking an agent through its session's inbox socket: works for Claude Code only, where a background wait
  already wakes the agent. Codex, where a wait is expensive, has nothing like it.

## Sources

- <https://code.claude.com/docs/en/agent-teams>
- <https://code.claude.com/docs/en/cross-session-messaging>
- <https://github.com/anthropics/claude-code/issues/79507>
- <https://github.com/Dicklesworthstone/mcp_agent_mail_rust>
- <https://pkg.go.dev/github.com/vbcherepanov/a2abridge>
