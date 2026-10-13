# Contributing

Thanks for helping. Issues and pull requests are welcome at <https://github.com/gmn-gh24/agent-relay>. Read the
[Code of Conduct](CODE_OF_CONDUCT.md) first. [README.md](README.md) explains what the project is and how it works;
[CLAUDE.md](CLAUDE.md) holds the full list of conventions.

## What to contribute

- **Bug reports** with a way to reproduce them.
- **Fixes**, each with a test that fails without it.
- **Agent profiles**: how to run another coding agent in a room (see `skills/agent-relay/references/agent-kinds.md`).
  A profile based on a real room is worth more than one written from the product's manual.
- **Lessons from real rooms**, anonymised (see `skills/agent-relay/references/lessons.md`).
- **Documentation**: wrong, missing or unclear text.
- **Larger features**: open an issue first so the direction is agreed before you write code.

A security problem is not an issue: see [SECURITY.md](SECURITY.md).

## Reporting a bug

Say what you did, what happened and what you expected. Include the PowerShell edition (7 or Windows PowerShell
5.1), the agent product and its version, and the exact error line. Do not paste secrets, real machine names or
shares.

## Setup

No build step, no package manager. You need PowerShell 7 and Windows PowerShell 5.1, Pester 6, PSScriptAnalyzer
and Claude Code. Work from a folder on a local disk: Pester fails on network paths.

## Rules a change must follow

| Rule | Why |
|---|---|
| ASCII only in every file, Markdown included; LF line ends (CRLF only for `*.cmd` and `*.bat`) | The static check fails on any other byte |
| Scripts run on Windows PowerShell 5.1: no `&&`, `\|\|`, `?:`, `??`, no PowerShell 7-only parameters | Deployed machines run 5.1 |
| Every fix comes with a test that fails without it | The gate relies on it |
| A new test file is listed in `tests/Invoke-AllTests.ps1` | Otherwise the gate never runs it |
| No real machine, share, address or account name in a committed file | Nothing private reaches the public repository |
| A line in [CHANGELOG.md](CHANGELOG.md) | Every change is recorded. The maintainer bumps the version |

The files under `tests/fixtures/` are byte fixtures: never reformat them.

## The test gate

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1
```

It runs the static checks, the pane checks and the Pester suites on both PowerShell editions. For a quick loop use
`-StaticOnly` plus the one affected file through `tests\Invoke-Suite.ps1`. If you have no Windows machine, run
`-StaticOnly` and say in the pull request that the Pester runs are not done; the maintainer will run them.

## Pull requests

1. Branch from an up-to-date `main`.
2. Keep the change small and to one subject; match the style of the code around it.
3. Fill in the pull request template: what changed and why, the tests, and which gate runs you did.
4. Answer review comments, then wait for the maintainer to merge.

## Questions

Open an issue at <https://github.com/gmn-gh24/agent-relay>.

## License

By contributing you agree that your work is released under the [MIT License](LICENSE).
