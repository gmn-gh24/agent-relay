---
description: Running tests on a remote host over ssh with no second agent is no relay room; the skill must not load
tags: [trigger, negative]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

Our build box is reachable over ssh. Work out the command that runs the unit tests there and shows me only the
failures. There is no other agent involved, I just want the command.
