# Security policy

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private reporting: the repository's **Security** tab, then
**Report a vulnerability**. Say what you found, how to reproduce it, and what it lets an attacker do.

Targets (a policy, not a contract):

| Step | Target |
|---|---|
| Acknowledge the report | 3 business days |
| Fix or mitigation for a confirmed critical issue | 30 days |

Please allow time for a fix before you make the problem public.

## Supported versions

Only the latest release gets fixes.

## What counts

agent-relay keeps agents in scope by instruction, evidence and review. **It is not a sandbox**: an agent runs with
the rights of its own account. See the "Security model" section of [README.md](README.md).

| In scope | Out of scope |
|---|---|
| An agent changing a file the coordinator guards (tools, wrappers, instructions, plan, rules) without the tamper check noticing | What an agent does with the rights of the account you gave it |
| Text in a room passing as the owner or the coordinator | Agents started with `codex --yolo` or `claude --dangerously-skip-permissions` doing what their own guard no longer stops |
| A symbolic link or junction in a room making a tool read or write outside it | A room on a share that other people can write to for reasons unrelated to agent-relay |
| Secrets that the tools write into a room or a log | |

## Where data goes

- **No network calls.** The scripts and the room tool make none. Nothing is sent to the maintainer, and there is no
  telemetry. A room is a folder; if it is on a file share, the share's own network traffic applies.
- **Agent products.** What an agent reads and writes is handled by its own product (Claude Code, Codex CLI, and
  so on) under that product's terms. agent-relay does not control it.
- **Messages are plain files.** Every message in a room is a Markdown file that every agent in it can read. The
  send verbs stop on text that looks like a key or token, but that is a safety net, not a guarantee. Keep secrets
  out of messages.
- **This PC's local folder** (`.local/` in a clone, `%LOCALAPPDATA%\agent-relay` for an installed copy) holds the
  canonical copy of each room, the owner's log, alarms and archives. Archives hold the full transcript of a room.
  Treat the folder as sensitive. Uninstalling the plugin does not delete it; delete it by hand when you no longer
  need it.

## Installing and updating

The plugin installs from this repository through Claude Code's plugin commands. To inspect before you install,
clone a tagged release (`v<version>`) and add the clone as the marketplace.
