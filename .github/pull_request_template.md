## What changed and why

<!-- One or two lines per change: what was wrong or missing, and what the change does about it. -->

-

## Tests

<!-- The test that comes with each change (file and name). CLAUDE.md: every fix comes with a test that fails
without it. -->

-
- [ ] Each new test was seen to fail without its change

## Gate

<!-- Paste the RESULT lines. Say what did not run and why (no Windows, no Claude Code, ...). A session without Windows asks the owner to
run the Pester files and pastes the owner's RESULT lines here. -->

- [ ] `tests\Invoke-AllTests.ps1 -StaticOnly` (PSScriptAnalyzer, ASCII and LF, wrapper templates, test files listed)
- [ ] Pester under PowerShell 7 (`-Editions ps7`)
- [ ] Pester under Windows PowerShell 5.1 (`-Editions ps5`, Windows only)
- [ ] Pane: `claude plugin validate .` and `claude plugin test .`

## Release

- [ ] `version` in `.claude-plugin/plugin.json` and the table in `README.md`
- [ ] `skills/agent-relay/assets/room-package/VERSION` (and `$script:ToolVersion` in `tools/relay.ps1`), only if
      the room package changed
- [ ] `CHANGELOG.md` entry
- [ ] `references/lessons.md` entry, if a room or a review taught something
- [ ] No real machine, share, address or account name in a committed file

## Running rooms

<!-- Does a room in flight need scripts\Update-RelayRoom.ps1 -Room <id> to get this? Anything that changes for
an agent already in a room? -->
