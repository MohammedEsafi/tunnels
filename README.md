# Tunnels

[![CI](https://github.com/MohammedEsafi/tunnels/actions/workflows/ci.yml/badge.svg)](https://github.com/MohammedEsafi/tunnels/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](Package.swift)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-2ECC71)](LICENSE)

A macOS menu bar app that manages SSH local port forwards on demand. Click the
icon, switch a forward on, and the app keeps it up through sleep and network
changes.

- Uses the system `ssh`, your `~/.ssh/config` and your agent. Nothing but Host
  aliases and ports is stored.
- One SSH connection per machine; forwards are added and removed on it without
  reconnecting. Listeners bind `127.0.0.1` only.
- Watch a whole machine and forward every port it serves, with clashes moved to
  an offset automatically.
- Dropped connections reconnect with backoff; one notification if that gives up.
- No dependencies beyond the Xcode command line tools.

## Install

Download `Tunnels.app` from [Releases](https://github.com/MohammedEsafi/tunnels/releases),
move it to `/Applications`, and open it with right-click › Open the first
time (the build is signed ad hoc). Needs macOS 14 and keys in `ssh-agent`.

Or build it yourself:

```bash
scripts/bundle.sh            # release build -> build/Tunnels.app
scripts/run.sh               # debug build, then (re)launch
swift test                   # unit tests
```

## Using it

Type `host:port` in the field and press Return. Each forward and each machine
has a switch. Right-click a forward for Copy, Open in Browser, Rename, Change
Ports and Close and Forget; right-click a machine for All Ports, Pinned Ports
Only, Copy ssh Command, Show Log and Forget Machine. Settings… holds Open at
login, notifications and Connection Logs.

## Skills

The documentation is a set of agent skills in
[`.agents/skills/`](.agents/skills), one `SKILL.md` per task. Open the
repository in an agent that reads that folder (Claude Code does, through the
`.claude/skills` link) and ask; or read the files directly, they are written
for people too.

| Skill | Ask it for |
|---|---|
| [manual](.agents/skills/manual/SKILL.md) | how to use the app: every menu item, all-ports and offsets, reconnection, files |
| [develop](.agents/skills/develop/SKILL.md) | building and running from source, the Docker lab, logging, the snapshot harness |
| [testing](.agents/skills/testing/SKILL.md) | verifying a change: the CI checks, writing a core test, the manual drills |
| [contribute](.agents/skills/contribute/SKILL.md) | making and pushing a change: steps, commit format, house rules |
| [architecture](.agents/skills/architecture/SKILL.md) | the decisions, module boundaries and ssh mechanics |
| [security](.agents/skills/security/SKILL.md) | the trust model, the review checklist, reporting a vulnerability |
| [release](.agents/skills/release/SKILL.md) | what CI does, tagging a version, what the release workflow publishes |

[CHANGELOG.md](CHANGELOG.md) records what changed in each version.

## License

MIT. See [LICENSE](LICENSE).
