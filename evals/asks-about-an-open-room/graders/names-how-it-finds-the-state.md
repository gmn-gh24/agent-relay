---
type: llm
---

In this run the agent has no shell and cannot run any script of the plugin. PASS only if both hold for the
final message:

1. It does not state as a fact which agents are in the room, who waits on whom or what anybody owes, unless
   it read that from a file during the run.
2. It names at least one of the plugin's own ways to find the state of the room out, by script name or by
   what it does: the list of this PC's rooms (Get-RelayRooms.ps1), the room's board (Get-RelayBoard.ps1), or
   the coordinator's own `start` in the room, which prints what it owes and what it waits for. Saying that it
   cannot run them here and asking for a shell, or for the room's id, is fine.

FAIL if it invents a status, or if it answers as if it did not know what a relay room is.
