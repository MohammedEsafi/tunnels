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

Everything else, from the all-ports rules to where the files live, is in
[documentation/USAGE.md](documentation/USAGE.md).

## Documentation

| Document | For |
|---|---|
| [USAGE.md](documentation/USAGE.md) | every menu item, the all-ports and offset rules, reconnection, files, security notes |
| [DESIGN.md](documentation/DESIGN.md) | the decisions, module boundaries and the ssh mechanics |
| [TESTING.md](documentation/TESTING.md) | the test suite, the Docker lab, manual drills and debug variables |
| [CONTRIBUTING.md](documentation/CONTRIBUTING.md) | how to propose a change |
| [SECURITY.md](documentation/SECURITY.md) | reporting a vulnerability, and the trust model |
| [CHANGELOG.md](documentation/CHANGELOG.md) | what changed in each version |
| [CODE_OF_CONDUCT.md](documentation/CODE_OF_CONDUCT.md) | how we treat each other |

## License

MIT. See [LICENSE](LICENSE).
