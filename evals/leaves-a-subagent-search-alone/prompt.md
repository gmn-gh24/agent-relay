---
description: A subagent of this session is no remote agent; asking for one must not load the skill
tags: [trigger, negative]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

Use a subagent to search this folder for TODO comments and give me the list, so that the file contents stay
out of your own context.
