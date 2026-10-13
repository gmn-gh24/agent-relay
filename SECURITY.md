# Security policy

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private reporting: the repository's **Security** tab, then
**Report a vulnerability**. Say what you found, how to reproduce it, and what it lets an attacker do.

You will get an answer as soon as the maintainer can give one. Please allow time for a fix before you make the
problem public.

## What counts

agent-relay keeps agents in scope by instruction, evidence and review. **It is not a sandbox**: an agent runs with
the rights of its own account. See the "Security model" section of [README.md](README.md). In scope:

- A way for an agent to change a file the coordinator guards (tools, wrappers, instructions, plan, rules) without
  the tamper check noticing.
- A way for text in a room to pass as the owner or the coordinator.
- A way for a link (symbolic link or junction) in a room to make a tool read or write outside it.
- Secrets that the tools write into a room or a log.

Out of scope: what an agent does with the rights of an account you gave it, and agents started with
`codex --yolo` or `claude --dangerously-skip-permissions` doing what their own guard no longer stops.

## Supported versions

Only the latest release gets fixes.
