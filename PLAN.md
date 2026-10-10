# Tunnels — implementation plan

> Status (10 Oct 2026): M0–M6 implemented. See README.md for usage and
> CHECKS.md for what was verified against a local sshd. Open items: the
> sleep/wake and Wi-Fi-off checks on a real machine, and a Developer ID
> signature if the app is shared with teammates.

A macOS menu bar app that manages SSH local port forwards on demand.
Design: variant A from the canvas (grouped by machine, one switch per
forward, a master switch per machine), native look via SwiftUI.

Mockups: https://claude.ai/artifact/5hrPDeqNHC2y8f7PtGhMNu

## 1. Decisions

| Topic | Decision |
|---|---|
| UI | SwiftUI `MenuBarExtra` in `.window` style. `LSUIElement = true`, no Dock icon, no main window. |
| Target | macOS 14 Sonoma or newer. Dev machine is macOS 26 with Xcode 27 and Swift 6.4. |
| SSH | System `/usr/bin/ssh` only. One master connection per machine using ControlMaster; forwards are added and removed on the master with `ssh -O forward` and `ssh -O cancel`. |
| Machines | Host aliases from `~/.ssh/config` (with `Include` resolved). The app never stores hostnames, users, or keys. |
| Auth | Keys must already be loaded in the agent. `BatchMode=yes` so a missing key fails fast and shows as a clear state. No passphrase or password prompts in v1. |
| Favourites | TOML file at `$XDG_CONFIG_HOME/tunnels/favourites.toml`, default `~/.config/tunnels/favourites.toml`. Parsed by a small in-house TOML subset reader (`MiniTOML`), so there is no dependency at all. Watched for changes. |
| Build | Swift Package for everything, built with `swift build`. `scripts/bundle.sh` assembles `Tunnels.app`, writes Info.plist and signs it. No XcodeGen, no Homebrew. The package still opens in Xcode for debugging. |
| Distribution | Users receive `Tunnels.app` only. Runtime dependency is `/usr/bin/ssh`, nothing else. Notarisation is a later step using the same script. |
| Binding | Local listener always binds `127.0.0.1`. Never `0.0.0.0`. |
| Sandbox | No App Sandbox. Ad-hoc code signing for local use. Hardened runtime on. |
| Outside forwards | Detected and can be stopped. Never adopted. |
| Lifecycle | Quitting the app closes every forward it owns. On launch the app restores the forwards that were on when it last quit. |
| Scope | Local forwards only. No remote forwards, no SOCKS, no key management, no other platforms. |

## 2. Project layout

```
Tunnels/
  Package.swift               # targets: Tunnels (executable), TunnelsCore, TunnelsCoreTests
  Sources/Tunnels/            # app target (SwiftUI, menu bar only)
    TunnelsApp.swift          # MenuBarExtra, scene setup, login item
    Views/
      PopoverView.swift       # variant A layout
      MachineSection.swift    # header with master switch + rows
      ForwardRow.swift
      ExternalRow.swift
      QuickOpenField.swift    # host:port / favourite entry with suggestions
      MenuBarLabel.swift      # icon + count + dropped indicator
      SettingsView.swift
    Resources/Info.plist      # LSUIElement, notification usage strings
  Sources/TunnelsCore/        # no AppKit dependency, fully testable
      Models.swift            # Machine, Forward, ForwardState, ExternalForward
      SSHConfig.swift         # enumerate Host aliases, resolve Include
      Favourites.swift        # TOML model + loader + file watcher
      ProcessRunner.swift     # protocol over Process, so tests can fake ssh
      SSHMaster.swift         # one ControlMaster per machine
      ForwardController.swift # desired vs actual state, add/cancel forwards
      Reconnector.swift       # backoff, wake and network triggers
      ExternalScanner.swift   # find ssh -L processes not owned by the app
      PersistedState.swift    # which forwards were on at last quit
  Tests/TunnelsCoreTests/
  scripts/
    bundle.sh                 # swift build -c release, assemble Tunnels.app, codesign
    run.sh                    # bundle then open the app for a manual check
```

The Swift package is the unit of testing; the app target is a thin shell
over it. `scripts/bundle.sh` is the only build entry point and needs just
Xcode's command line tools.

## 3. Core behaviour

### 3.1 Master connection per machine

Started when the first forward on a machine is switched on:

```
ssh -N -M -S <socket> \
    -o ControlPersist=no \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    <alias>
```

Socket path: `~/Library/Application Support/Tunnels/sockets/<sha1(alias) first 12>`.
Unix socket paths are limited to 104 bytes, so the directory is kept short
and the alias is hashed. Stdout and stderr are captured to a per-machine
log for the Settings window.

Machine state machine:

```
disconnected → connecting → connected
connected    → dropped(attempt n) → connecting …
dropped      → failed(reason)     after 5 attempts
any          → disconnected        when master switch is turned off
```

The master is stopped with `ssh -S <socket> -O exit <alias>` when its last
forward is switched off, or immediately when the master switch is turned
off.

### 3.2 Forwards

Add:    `ssh -S <socket> -O forward -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>`
Cancel: `ssh -S <socket> -O cancel  -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>`
Health: `ssh -S <socket> -O check <alias>` every 30 s while any forward is on.

A non-zero exit from `-O forward` marks that forward `error(message)`
without touching the others. Common cases surfaced by text: local port in
use, remote connection refused.

Forward state: `off`, `pending`, `active`, `dropped`, `error(String)`.
The app tracks desired state (what the switches say) separately from
actual state (what ssh reports). Reconnection re-applies desired state.

Before starting a forward the app checks the local port with a bind
attempt and shows "port in use" up front if it fails.

### 3.3 Dropped detection and recovery

Triggers:

- Master process exits (`Process.terminationHandler`).
- `-O check` fails.
- `NSWorkspace.didWakeNotification`.
- `NWPathMonitor` reports a path change to satisfied.

On a trigger every forward on that machine becomes `dropped`, then the
Reconnector restarts the master with backoff 2, 4, 8, 16, 30 seconds. On
success it re-adds all forwards whose desired state is on. After five
failures the machine is `failed` and one user notification is posted
through `UNUserNotificationCenter`. "Retry now" resets the counter.

Wake and network triggers are debounced by 3 seconds so a flapping network
does not stack reconnects.

### 3.4 Forwards started outside the app

Every 10 seconds while the popover is open, and once when it opens:

```
ps -axo pid=,uid=,command=
```

Rows whose command is `ssh` and contains `-L` are parsed into
`ExternalForward(pid, localPort, remoteHost, remotePort, alias)`. The app's
own pids are excluded. Multiple `-L` on one process become several rows
sharing a pid. Stop sends `SIGTERM` to the pid and only for processes
owned by the current user.

Shown under their machine if the alias matches a known Host, otherwise
under a section named by the target as written.

### 3.5 Favourites file

```toml
# ~/.config/tunnels/favourites.toml

[[favourite]]
name   = "postgres"
host   = "prod-db-01"      # Host alias from ~/.ssh/config
port   = 5432              # local port, remote port defaults to the same

[[favourite]]
name        = "postgres"
host        = "staging.internal"
port        = 15432
remote_port = 5432
remote_host = "localhost"  # default

[[favourite]]
name = "mailcatcher"
host = "staging.internal"
port = 1025
```

Validation errors are shown in the popover under a "Favourites file" row
with an "Open in editor" button. The file is watched with
`DispatchSource.makeFileSystemObjectSource` and reloaded on change.

### 3.6 Quick open

Accepted input in the field at the top of the popover:

- `host:port` → forward port to the same port on that host.
- `host:local:remote` → different local and remote ports.
- text matching a favourite name or a Host alias → suggestions list.

Suggestions come from favourites first, then Host aliases. Enter opens the
highlighted suggestion. Ad-hoc forwards appear in their machine section
and are not written to the favourites file; a "Save as favourite" item is
offered on the row.

### 3.7 Menu bar label

SF Symbol `arrow.left.arrow.right` plus the active count. When any
forward is dropped the symbol switches to
`arrow.left.arrow.right.circle` tinted with the system orange and the count
stays. Idle shows the symbol alone, dimmed.

### 3.8 Persistence and startup

`PersistedState` stores the set of forwards that were on at quit in
`~/Library/Application Support/Tunnels/state.json`. On launch the app
restores them. Start at login uses `SMAppService.mainApp`, exposed as a
toggle in Settings.

## 4. Milestones

Each milestone ends with a build that runs and a short check.

**M0 — Scaffold.** Package.swift with the three targets, `bundle.sh`
producing a signed `Tunnels.app` with `LSUIElement`, `MenuBarExtra` showing
a static icon.
Check: app appears in the menu bar with no Dock icon.

**M1 — Core SSH.** `ProcessRunner`, `SSHMaster`, `ForwardController` with
a fake runner in tests. Live check against one real Host alias from the
command line harness: start master, add forward, `curl` through it, cancel,
exit.

**M2 — Popover.** Variant A layout bound to `ForwardController` state.
Switches, master switch, footer menu items, menu bar count.
Check: open and close forwards from the UI.

**M3 — Favourites and quick open.** TOML loader, file watcher, Host alias
enumeration, quick-open parsing and suggestions.
Check: edit the file, popover updates without restart.

**M4 — Resilience.** Exit detection, `-O check`, wake and network triggers,
backoff, failed state, notification, retry.
Check: sleep the Mac, wake, forwards return; kill the master by hand,
forwards return; disable Wi-Fi for two minutes, notification arrives.

**M5 — Outside forwards.** `ps` scanner, external rows, Stop.
Check: run `ssh -N -L 3000:localhost:3000 host` in Terminal, it shows and
can be stopped.

**M6 — Polish.** Login item, Settings window, per-machine logs, persisted
state restore on launch, dark mode pass, VoiceOver labels.

## 5. Tests

Unit tests in `TunnelsCoreTests` with a fake `ProcessRunner`:

- Forward spec formatting and parsing of `host:port` and `host:local:remote`.
- State transitions on master exit, `-O forward` failure, retry exhaustion.
- Backoff sequence and debounce.
- `ps` output parsing including multiple `-L`, spaces in paths, own pid exclusion.
- `~/.ssh/config` Host enumeration with `Include` and wildcard hosts skipped.
- TOML validation errors: missing host, port out of range, duplicate names.

Live checks in section 4 are manual and listed in `CHECKS.md` once M1 lands.

## 6. Risks and how they are handled

- **ControlMaster after sleep.** The master may linger half dead. The
  `-O check` poll plus the wake trigger force a restart rather than trusting
  the old socket. Stale socket files are removed before reconnecting.
- **Key not in agent.** `BatchMode=yes` makes ssh fail immediately. The
  machine shows `failed("no key in agent")` with a hint to run `ssh-add`.
  A helper using `SSH_ASKPASS` is a possible v2.
- **Hosts with ProxyJump or 2FA.** ProxyJump works unchanged. 2FA prompts
  fail under BatchMode and show the same failed state.
- **Socket path length.** Hashed alias under a short directory keeps it well
  under 104 bytes.
- **Notifications from an agent app.** Requires a proper bundle identifier and
  signing. Ad-hoc signing is enough locally.
- **ps parsing fragility.** Only used for display and stop. A row the parser
  cannot read is shown raw rather than hidden.

## 7. Assumptions to confirm

- macOS 14 as the minimum is acceptable.
- Ad-hoc forwards default the remote host to `localhost`.

Resolved: TOML stays (the parser is compiled in, users install nothing).
No Homebrew or XcodeGen; the build is a Swift Package plus `bundle.sh`.
