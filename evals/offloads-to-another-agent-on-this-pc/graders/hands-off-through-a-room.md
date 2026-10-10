---
type: llm
---

In this run the agent has no shell and cannot run any script of the plugin. PASS only if both hold for the
final message:

1. It sets the hand-off up through a relay room: it says that it will create a room (a shared folder through
   which Codex and this session exchange messages) and give the owner a prompt to paste into Codex, or it asks
   the owner what it needs to know before it creates one (for example what the documentation update covers,
   which files Codex may change, or how far it may decide alone).
2. It does not claim that a room was created, that a prompt was written or put on the clipboard, that Codex
   was started or has joined, or that a script was run.

FAIL if it says that it cannot work with another agent at all, if all it offers is to pass messages by hand
through the owner, or if it reports any such action as done.
