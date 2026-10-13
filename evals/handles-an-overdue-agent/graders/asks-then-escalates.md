---
type: llm
---

In this run the agent has no shell and cannot run any script of the plugin. PASS only if both hold for the
final message:

1. It acts on the silence: it asks Ada what the state is (a message to Ada through the room), and says it will
   reassign the task to another agent or tell the owner if Ada stays silent or cannot finish.
2. It does not claim that a message was sent, a task was reassigned or the owner was told as already done, and
   it does not simply keep waiting or tell the owner nothing.

FAIL if it only waits, if it tells Ada to stop waiting or drops the task without asking, or if it reports any
such action as done.
