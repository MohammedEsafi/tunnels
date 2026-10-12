# Changelog

Add a line under Unreleased with every user-visible change, under Security,
Fixed, Added or Changed. On release, the lines move under the version and
date. Versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Changed
- In all-ports mode only the ports whose local number is taken move to the
  offset; the rest keep their own numbers. Moved ports are remembered on the
  machine's entry (`moved = [...]`) so reconnects and relaunches keep them,
  and the notification names the ports that moved. Before, one taken port
  moved every port on the machine.

## [0.1.1] — 2026-10-12

### Fixed
- All-ports mode on a macOS machine found no ports: the listing stopped at
  `netstat -tln`, which a Mac accepts but answers with established
  connections only. The listing now goes straight to `netstat -an` where
  `ss` and `/proc/net/tcp` are absent. This also fixes the "nothing listening"
  check for pinned forwards on Mac machines.

## [0.1.0] — 2026-10-12

First release.

### Added
- Menu bar panel with forwards grouped by machine, switches per forward and
  per machine, inline rename and port editing, right-click menus.
- Favourites in `~/.config/tunnels/favourites.toml`, reloaded on change.
- One ssh ControlMaster per machine; reconnection with backoff after drops,
  wake and network changes; notifications when a machine gives up or comes back.
- All-ports mode with exclusions and per-machine offsets for clashing ports.
  A port that any local program already serves is never bound, so a remote
  machine cannot take over a local service.
- Detection of `ssh -L` forwards started outside the app.
- Open at login, connection logs, and two ssh machines in Docker for trying
  it out (`simulation/machines`).
- Documentation as agent skills under `.agents/skills/`, so a person or an
  agent can ask for usage help, run the tests, or follow the contribution and
  release steps from the repository itself.
