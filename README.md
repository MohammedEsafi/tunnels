# Tunnels

[![CI](https://github.com/MohammedEsafi/tunnels/actions/workflows/ci.yml/badge.svg)](https://github.com/MohammedEsafi/tunnels/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](Package.swift)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-2ECC71)](LICENSE)

A macOS menu bar app that manages SSH local port forwards on demand. It lives
only in the menu bar: click the icon to see every forward grouped by machine,
switch forwards on and off, and let the app bring them back after sleep or a
network change.

- Uses the system `ssh` and your existing `~/.ssh/config` and agent. No
  hostnames, users, keys or passwords are stored; only Host aliases and ports.
- One SSH connection per machine (ControlMaster); forwards are added and
  removed on that connection without reconnecting.
- Forwards always bind `127.0.0.1`, never the network.
- Forwards opened elsewhere (a stray `ssh -L` in a terminal) are listed too and
  can be stopped.
- Dropped connections reconnect with backoff; you get a notification only if
  that gives up, and one when the machine comes back after a long drop.
- No third-party dependencies: a Swift package, the command line tools, and
  `/usr/bin/ssh`.

## Requirements

- macOS 14 or newer.
- Machines reachable by `ssh <name>`: Host aliases in `~/.ssh/config`, or
  Tailscale MagicDNS names. Keys loaded in `ssh-agent` (`ssh-add`); the app
  runs ssh in batch mode, so a key that still needs a passphrase prompt shows as
  "No usable key in the agent". `ssh-add --apple-use-keychain ~/.ssh/<key>`
  keeps it loaded across reboots.

## Install

Download `Tunnels.app` from the [Releases](https://github.com/MohammedEsafi/tunnels/releases)
page and move it to `/Applications`. The build is signed ad hoc, not
notarised, so Gatekeeper refuses it the first time: right-click the app and
choose Open, or run

```bash
xattr -dr com.apple.quarantine /Applications/Tunnels.app
```

Or build it yourself (below). Keep the app in one place: "Open at login" and
the notification permission are tied to where the bundle lives.

## Build

Only Xcode's command line tools are needed. No Homebrew, no Xcode project.

```bash
scripts/bundle.sh            # release build -> build/Tunnels.app
scripts/run.sh               # debug build, then (re)launch
swift test                   # unit tests
```

## Using it

- **Switches.** Each forward has a switch. The switch on a machine row turns
  every forward on that machine on or off at once. Clicking a forward's name
  toggles it too.
- **Ports.** The right-hand column shows the local port, and `28080 → 8080`
  only when the remote port differs. Click it to copy `localhost:<port>`.
- **Adding.** The + button (or ⌘N) shows the field. With the field empty it
  lists your machines: Host aliases from `~/.ssh/config` plus Tailscale peers
  when the `tailscale` CLI is installed (offline ones are dimmed). Type
  `host:port`, `host:local:remote` or `host:local:remoteHost:remote` and press
  Return. Typing part of a machine or forward name shows suggestions; arrow
  keys and Return pick one. Everything you open is remembered in the
  favourites file.
- **Row menu.** Right-click a forward for Copy `localhost:<port>`, Open in
  Browser, Rename…, Change Ports… and Close and Forget. Change Ports… turns the
  port column into one field in the same `local:remote` grammar; a lone number
  means both. Return applies, Escape cancels, and flipping the switch mid-edit
  applies the edit first.
- **Machine menu.** Right-click a machine for All Ports, Pinned Ports Only,
  Copy ssh Command (the plain `ssh -N -L …` equivalent of its forwards), Show
  Log and Forget Machine.
- **All ports.** Type a machine name alone and pick the `all ports` row, or
  choose All Ports from the machine's menu. The app then watches that machine
  over the same connection, every five seconds, and forwards every TCP
  listener it finds (1024 up to 32767, below the ephemeral range) to the same
  local port, adding and removing forwards as services come and go. The
  machine shows a small layers glyph after its name; its port rows have no
  name. Close and Forget on such a row means "not this one", kept across
  reconnects and relaunches. Switching the machine off stops watching;
  switching it on resumes with the same exclusions. All Ports from the menu
  is a fresh start and forgets them. Pinned Ports Only freezes what the
  machine had: the ports that were open, minus the ones you closed, become
  ordinary pinned forwards, and watching stops.
- **When two machines offer the same port.** Only one can be `localhost:8080`.
  When a discovered port is already taken on this Mac, by another machine's
  forward or by any local program, the machine gets an offset: +10000 for the
  first such machine, +20000 for the next. From then on every discovered port
  on it lands on remote plus offset, `18080 → 8080`, so the mapping never
  depends on which machine connected first. One notification tells you the
  rule when it first happens. The offset is kept on the machine's entry in the
  favourites file (`offset = 10000`) across reconnects and relaunches; All
  Ports from the menu clears it. A pinned forward whose own number is taken
  moves the same way, and the file records `moved = true` so it stays there.
  Switching a machine off and on by hand means "start from the best numbers
  available": the offset is dropped and the forwards the app moved try their
  plain numbers again, moving back only what is still taken. Automatic
  reconnects and relaunches keep the numbers as they were.
- **A forward with nothing behind it.** A pinned forward whose remote port has
  no listener shows an orange circle with the tooltip "Nothing listening on
  host:port". It is open and works the moment something starts there; checked
  when it opens and every 30 seconds.
- **States.** Blue circle: active. Spinner: opening. Orange circle with ↻:
  dropped, click it to retry the machine now. Red circle with ↻: that one
  forward failed while the connection is fine, click to try again. Grey: off.
  No words on the rows: the reason is the tooltip on the circle, and the full
  ssh output is under Settings › Connection Logs.
- **Started outside Tunnels.** `ssh -L` processes you started in a terminal
  show under their machine with a terminal icon; hover or right-click for
  Stop. They are never adopted.
- **Close All**, **Settings…** and **Quit** are at the bottom. Settings is a
  page inside the menu: Open at login, Notify about dropped connections, links
  to the favourites file and your SSH config, and Connection Logs. The ‹
  chevron or ⌘← goes back. Escape or a click outside closes the menu; ⌘Q quits.

## How reconnection works

A machine is considered dropped when its ssh master exits, when a 30-second
health check stops answering, or after the Mac wakes or the network path
changes. The app retries after 2, 4, 8, 16 and 30 seconds, re-adding every
forward that was on. After five failures the machine shows the retry circle
and one notification says "<machine> is down". If it comes back on its own
after being down for ten seconds or more, a second one says "<machine> is
back" with how long it was gone. Both are under one switch in Settings.

A machine whose very first connection fails (unknown host, no key) is not
retried on its own: fix the cause and click its orange circle. A machine in
all-ports mode is treated the same way.

Quitting the app closes every forward it owns. Forwards that were on are
restored at the next launch. Masters left behind by a crash are closed at the
next launch too.

## Files

| Path | What |
|---|---|
| `~/.config/tunnels/favourites.toml` (or `$XDG_CONFIG_HOME/tunnels/…`) | every remembered forward and all-ports machine; plain TOML, reloaded when it changes |
| `~/Library/Application Support/Tunnels/state.json` | which forwards were on at the last quit |
| `~/Library/Application Support/Tunnels/sockets/` | the ssh control sockets, created `0700` |

```toml
[[favourite]]
name = "postgres"
host = "prod-db-01"        # Host alias from ~/.ssh/config
port = 5432                # local port on this Mac; remote_port defaults to it

[[favourite]]
name = "postgres"
host = "staging"
port = 15432
remote_port = 5432
remote_host = "localhost"  # as seen from the machine, defaults to localhost

[[host]]                   # a machine in all-ports mode
name = "gpu-box"
all_ports = true
exclude = [5432]
offset = 10000
```

The parser is a small TOML subset: strings, integers, booleans, arrays of
those, `[table]` and `[[array of tables]]` headers, `#` comments. Problems in
the file are shown at the top of the menu with an Open button.

To uninstall: quit, delete the app and the paths above, and remove Tunnels
from System Settings › General › Login Items if you enabled it.

## Security notes

- Local listeners bind `127.0.0.1` only. Discovered ports are limited to
  1024–32767, and a port that any program on this Mac already serves is never
  bound (the machine moves to an offset instead), so a remote machine cannot
  take over a local service.
- In all-ports mode the remote machine decides which ports exist on
  `localhost`. Anything you open at `http://localhost:<port>` is served by it,
  with whatever `localhost` cookies your browser holds. Use it on machines you
  trust.
- Every ssh call passes `StrictHostKeyChecking=accept-new`: a host you have
  never connected to is accepted on first contact and pinned to `known_hosts`;
  a changed key is still refused.

See [SECURITY.md](SECURITY.md) for how to report a problem.

## Development

```
Sources/TunnelsCore         the engine and the file formats, no UI
  Engine/                   ProcessRunner, SSHMaster, SSHOptions, ForwardController (+Discovery), Reconnector
  Formats/                  MiniTOML, Favourites (+Editing), FileWatcher, PersistedState
  Hosts/                    SSHConfig, Hosts (Tailscale), QuickOpen
  System/                   ExternalScanner, PortDiscovery, LocalPorts
Sources/Tunnels             the app
  App/                      entry point, status item, panel, system events
  Model/                    AppModel and its extensions: the one thing views talk to
  Views/                    SwiftUI content of the panel
  Debug/                    stderr logging and the snapshot harness
Sources/tunnelsctl          command-line harness for the core
Tests/TunnelsCoreTests      XCTest, with a scripted stand-in for ssh
scripts/                    bundle.sh, run.sh, makeicon.swift, testenv.sh
testenv/                    a Docker lab with two ssh machines
docs/                       DESIGN.md, TESTING.md
```

`swift build -Xswiftc -warnings-as-errors`, `swift test` and
`xcrun swift-format lint --strict --recursive Sources Tests` must pass; CI runs
them. [docs/TESTING.md](docs/TESTING.md) describes the Docker lab, the manual
drills and the debug environment variables. [docs/DESIGN.md](docs/DESIGN.md)
records the decisions. [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## License

MIT. See [LICENSE](LICENSE).
