# Contributing

Thanks for helping. Issues and pull requests are welcome at <https://github.com/gmn-gh24/agent-relay>. Read the
[Code of Conduct](CODE_OF_CONDUCT.md) first. [README.md](README.md) explains what the project is and how it works;
[CLAUDE.md](CLAUDE.md) holds the full list of conventions.

## Before you start

- For a bug, open an issue with what you did, what happened and what you expected. Say which PowerShell edition
  (7 or Windows PowerShell 5.1) and which agent product you used.
- For a larger change, open an issue first so the direction can be agreed before you write code.
- A security problem is not an issue: see [SECURITY.md](SECURITY.md).

## Setup

No build step, no package manager. You need PowerShell 7 and Windows PowerShell 5.1, Pester 6, PSScriptAnalyzer
and Claude Code. Work from a folder on a local disk: Pester fails on network paths.

## Rules a change must follow

- **ASCII only** in every file, Markdown included, and **LF line ends** (CRLF only for `*.cmd` and `*.bat`).
- Scripts must run on **Windows PowerShell 5.1**: no `&&`, `||`, `?:`, `??`, no PowerShell 7-only parameters.
- **Every fix comes with a test that fails without it.** A new test file must also be listed in
  `tests/Invoke-AllTests.ps1`.
- No real machine, share, address or account name in a committed file.
- Add a line to [CHANGELOG.md](CHANGELOG.md). A release also bumps `version` in `.claude-plugin/plugin.json` and
  the table in the README; the maintainer does that.

## The test gate

```
pwsh -NoProfile -File tests\Invoke-AllTests.ps1
```

It runs the static checks, the pane checks and the Pester suites on both PowerShell editions, and must pass
before a pull request. For a quick loop use `-StaticOnly` plus the one affected file through
`tests\Invoke-Suite.ps1`. If you have no Windows machine, run `-StaticOnly` and say in the pull request that the
Pester runs are not done; the maintainer will run them.

## Pull requests

1. Branch from an up-to-date `main`.
2. Keep the change to one subject.
3. Say in the description what changed, why, and which gate runs you did.
4. Answer review comments, then wait for the maintainer to merge.

## Licence

By contributing you agree that your work is released under the [MIT License](LICENSE).
