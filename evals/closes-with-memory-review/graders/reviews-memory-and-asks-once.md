---
type: llm
weight: 2
---

In this run the agent has no shell and cannot run any script of the plugin. PASS only if all hold for the
final message:

1. It says the room's memory is read or reviewed before the room is closed (for example with
   Get-RelayMemory.ps1), and that each candidate is checked and rewritten in the coordinator's own words
   rather than copied.
2. It proposes concrete promotion items, or says it will propose numbered ones, each with a target (local
   notes or project lessons) and a reason it is reusable.
3. It asks the owner in one question both about the promotions (all, some or none) and about the shared
   folder: delete it after the verified archive or keep it. It recommends deleting after the archive, and
   says the archive stays on this PC.
4. It does not delete the folder or promote anything before the owner has answered; it waits for the answer.

FAIL if it closes, deletes or promotes first, asks the two things in separate rounds, or leaves out the
review of the memory.
