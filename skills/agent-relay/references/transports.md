# Transports: how an agent reaches the room

| Transport | The room is | Tested |
|---|---|---|
| `same-pc` | a local folder on the coordinator's PC | yes |
| `share` | a folder on a file share every machine can reach | yes (Windows, SMB) |
| `ssh` | a local folder on the remote machine, kept in step by a bridge on the coordinator's PC | not built: the scripts refuse it |

## Same PC

`rooms_root` is a local folder (default `C:\temp\agent-relay`). Every agent uses the same path. Use it for
rehearsals and for stand-in agents.

## Share

`rooms_root` is a folder on a share, given by the owner for this job or taken from the known shares in the
machine state. Never assume a share: other jobs and other people's agents may use the same one. A room
touches only its own folder under `rooms_root`.

**Other machines get the server's address, never its name.** A machine on another subnet often cannot resolve
the name this PC uses, so every share path written for another machine (the join prompt, a named agent's
start prompt and instructions) carries the server's IPv4 address, resolved when the room is built and recorded
as `reach` in the `ROOM` file. `reach_path` in the answers overrides it, and `room_path` per agent overrides it
for that agent. This PC keeps using the path the owner gave: it may reach the share by name only (credentials
are stored per server name), so do not replace the room's own path with the address. The same holds for an
ssh target: `user@name` becomes `user@address`.

What was measured and what follows from it:

- With writer and reader on the same PC, a Windows reader got a change event for a new file on the share in
  tens of milliseconds, against seconds with polling alone. Across two machines this has not been measured
  yet; the 2026-10-09 job saw wakes of 10 to 20 s there with polling alone. `relay.ps1` uses events plus a
  rescan, so a lost event costs seconds, not a message.
- Creating a file exclusively works on SMB. The loser of a race gets "already exists" or, now and then,
  "access denied"; the tools treat both as "taken, try the next".
- Every agent has two Windows wrappers. PowerShell and Git Bash use `relay.ps1`:
  `powershell -NoProfile -ExecutionPolicy Bypass -File '//address/share/.../relay.ps1' <verb>` (forward
  slashes work in both). cmd uses `relay.cmd`: `"\\address\share\...\relay.cmd" <verb>`. The tool prints the
  spelling for the wrapper and shell it was called with.
- Why two: an agent's working folder is often the share itself, and `cmd.exe` cannot stand in a network
  folder. Through `relay.cmd` every command then prints "UNC paths are not supported", runs in the Windows
  folder, records that as the agent's working folder, and looks for a working-folder draft in the wrong
  place. `relay.ps1` has no `cmd.exe` in between and keeps the folder.
- Windows PowerShell runs the tool with `-ExecutionPolicy Bypass`. A machine whose policy is set by Group
  Policy can still refuse scripts from a share; the error says so. Then the room has to live somewhere that
  machine trusts.
- A sandboxed agent may not reach a share at all (Codex CLI in its workspace-write mode does not, whatever
  extra folder is added). Such an agent needs full-access mode, or a room on its own disk.
- A machine that reaches the share under another path (a mapped drive) uses that path. The wrappers find the
  tool relative to themselves, so any path to the same folder works.
- An agent running as SYSTEM, or as a user without rights on the share, cannot reach it. Its `join` or
  `start` fails with "the room is not reachable"; the fix is on that machine, by its owner.

## SSH

Not built. The owner has postponed an SSH bridge, like sh, until it is needed: it is not planned for any
version. The scripts refuse `ssh` as a transport (`the SSH bridge is not built yet: use share or same-pc`).
There is no `sh` tool either: the room tool is PowerShell on every machine.

## Traps seen so far

| Trap | What happens | What the tools do about it |
|---|---|---|
| Windows PowerShell started below PowerShell 7 through `cmd.exe` inherits a module path it cannot use | built-in cmdlets go missing | `relay.ps1` sets the standard module path before it needs a cmdlet; `relay.cmd` clears the variable |
| An agent's working folder is on a share and it calls a `.cmd` | `cmd.exe` prints a banner on every command and falls back to the Windows folder | PowerShell and Git Bash callers get the `.ps1` wrapper |
| A share's server is named by its host name in a prompt | a machine on another subnet cannot resolve it and cannot join | prompts carry the address |
| This PC reaches the share by name but not by address | a room path rewritten to the address stops working here | only what is written for other machines carries the address |
| Windows PowerShell writes a byte order mark into a child's standard input | the first line of piped text is damaged | the scripts read bytes and strip it |
| Text on a command line | quoting breaks on `$`, backticks, pipes, quotes | text only ever travels in the draft file |
| JSON read by PowerShell 7 | text that looks like a time becomes a date | `ConvertFrom-RelayJson` keeps it as text |
| An agent works in a folder on the share | it is slow, and some tools do not run there: Pester 6 fails when its working folder is a network path | every agent's instructions say to copy what it needs and work on its own disk |
| A typed list handed on as `@($list)` in a PowerShell script | "Argument types do not match", and the script ends | the scripts hand on `$list.ToArray()` |
