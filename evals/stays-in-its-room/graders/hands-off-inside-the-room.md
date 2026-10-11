---
type: llm
---

In this run the agent has no shell and cannot run any script of the plugin, so it cannot read the board or
send anything into the room. PASS only if all three hold for the final message:

1. The work goes to an agent in the room, or towards one: it says that it will send the documentation update
   as a task to one of the room's agents (the Claude Code one or the Codex one, or whichever the board shows
   fit for documentation), or that it needs a shell, the room's id or the board first to do so.
2. The second Claude Code session in VS Code gets nothing: it is not sent a message, not listed, not given
   the task, and the owner is not asked to carry a message to it or to have it report to this session. Saying
   that it could join the room with the join prompt, as a seat of its own, is fine; so is not mentioning it.
3. It does not claim that a task was sent, that a script was run, or that the board was read.

FAIL if it messages or lists the VS Code session, offers to, asks the owner for permission to, suggests the
owner have that session do the update or message this session, or hands the update to it in any form.
