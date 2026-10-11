# Changelog

Add a line under Unreleased with every user-visible change, under Security,
Fixed, Added or Changed. On release, the lines move under the version and
date. Versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Security
- A discovered port that any local program already serves is never bound; the
  machine moves to an offset instead, so a remote machine in all-ports mode
  cannot take over a local service.

### Fixed
- Running the app twice no longer kills the first copy's ssh connections; the
  second copy exits.
- Close and Forget on a discovered port of an offset machine records the right
  port and the port stays gone.
- Escape, a click elsewhere or another app taking focus now reset the panel
  like the status item click does; Escape inside an inline edit cancels the
  edit instead of closing the panel.
- Switching a watched machine off during a scan keeps it off; a connection
  that finishes starting after everything was switched off is closed; a
  forward switched off while it is being added, or while nothing listens
  behind it, is cancelled.
- After a drop the reconnector alone retries a watched machine, so "is down"
  is true and discovered rows recover with the connection; a scan no longer
  joins an attempt in progress and restarts the backoff, and All Ports from
  the menu revives a machine the reconnector had given up on.
- A plain-port retry switched off while ssh was adding it comes down instead
  of ending active with its switch off.
- A favourites file that cannot be written says so in the menu's problems row.
- A remote that refuses a forward is reported as such instead of "Local port
  in use"; UDP sockets on a macOS remote are no longer forwarded.
- Quit asks every ssh connection to close at once and also handles SIGINT and
  SIGHUP; the panel stays on its screen; the settings page says when the login
  item awaits approval or notifications are off; the inline editor is readable
  in light mode; Stop on an outside forward is reachable from the keyboard.

### Changed
- The code is split into Engine, Formats, Hosts and System in the core and
  App, Model, Views and Debug in the app; views read through `AppModel`; the
  core takes its ssh settings as `SSHOptions` instead of reading the
  environment.
- The documentation is a set of agent skills under `.agents/skills/` (`.claude/skills` links to it),
  so a person or an agent can ask for usage help, run the tests, or follow
  the contribution and release steps from the repository itself.

## [0.1.0] — 2026-10-11

### Added
- Menu bar panel with forwards grouped by machine, switches per forward and
  per machine, inline rename and port editing, right-click menus.
- Favourites in `~/.config/tunnels/favourites.toml`, reloaded on change.
- One ssh ControlMaster per machine; reconnection with backoff after drops,
  wake and network changes; notifications when a machine gives up or comes back.
- All-ports mode with exclusions and per-machine offsets for clashing ports.
- Detection of `ssh -L` forwards started outside the app.
- Open at login, connection logs, a Docker lab for testing.
