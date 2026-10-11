---
name: architecture
description: The decisions, module boundaries and ssh mechanics behind Tunnels, and where new code belongs. Use before changing TunnelsCore, the panel, reconnection, all-ports discovery or the build, so a change fits the design instead of working around it.
---

# Tunnels architecture

Read this before touching the engine, the panel or the build. If a change
conflicts with a rule here, raise the conflict before implementing.

## Decisions to keep

| Topic | Decision | Do not |
|---|---|---|
| UI | AppKit `NSStatusItem` with a borderless `NSPanel`, `NSVisualEffectView` and SwiftUI content; `LSUIElement = true` | switch to `MenuBarExtra`: it renders an opaque window |
| Target | macOS 14 or newer | raise it without a changelog reason |
| SSH | `/usr/bin/ssh` only; one ControlMaster per machine; forwards via `-O forward` / `-O cancel` | add an ssh library or reconnect per forward |
| Machines | Host aliases from `~/.ssh/config` (with `Include`) and Tailscale peers; only aliases and ports are stored | store hostnames, users or keys |
| Auth | Keys in the agent; `BatchMode=yes` so a missing key fails fast as a state | add passphrase or password prompts |
| Favourites | TOML at `$XDG_CONFIG_HOME/tunnels/favourites.toml` (default `~/.config/tunnels/`), parsed by the in-house `MiniTOML` subset; edits preserve every other line; watched | add a TOML dependency or rewrite the file wholesale |
| Build | A Swift package; `scripts/bundle.sh` assembles and signs `Tunnels.app` | add XcodeGen, Homebrew or an Xcode project |
| Signing | Ad hoc, hardened runtime; Developer ID and notarisation later, same script | |
| Binding | Listeners bind `127.0.0.1` | ever bind `0.0.0.0` |
| Outside forwards | Detected and stoppable, never adopted | |
| Lifecycle | Quit closes every owned forward; launch restores what was on and sweeps crash leftovers; one instance | |
| Scope | Local forwards only | add remote forwards, SOCKS or key management |

## Module boundaries

```
Tunnels (app)  ──►  TunnelsCore (engine and file formats)  ◄──  tunnelsctl
```

1. The core never reads the environment or picks paths; the app passes
   `SSHOptions` and URLs in once.
2. Views talk only to `AppModel`; they never reach `model.controller`. Add an
   accessor on `AppModel` when a view needs a new read.
3. Core-to-app communication is `@MainActor` closures (`onMasterDropped`,
   `onOffsetAssigned`, `onForwardMoved`, `onGaveUp`, `onReconnected`).
4. `ForwardController` keeps desired state (the switches) apart from actual
   state (what ssh reports). Every mutation of `forwards` goes through the
   id-based `update`; never hold an index across an `await`.
5. New code goes where its neighbours are: `Engine/` for ssh and state,
   `Formats/` for files, `Hosts/` for where machines come from, `System/` for
   the OS; in the app `App/`, `Model/`, `Views/`, `Debug/`.

## The master connection

```
ssh -N -M -S <socket> -o ControlPersist=no -o BatchMode=yes \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new <alias>
```

- Socket: `~/Library/Application Support/Tunnels/sockets/<sha256(alias)[0..<12]>`;
  Unix socket paths are limited to 104 bytes, so the alias is hashed.
- Stopped with `-O exit` when the last forward goes off or the machine's
  switch is turned off.

```
Add:     ssh -S <socket> -O forward -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>
Cancel:  ssh -S <socket> -O cancel  -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>
Health:  ssh -S <socket> -O check <alias>, every 30 s
Listing: ssh -S <socket> <alias> -- "ss -ltnH || netstat -tln || cat /proc/net/tcp /proc/net/tcp6 || netstat -an"
```

Machine states: `disconnected → connecting → connected`,
`connected → dropped(attempt n) → connecting …`, `dropped → failed(reason)`
after the budget, `any → disconnected` when switched off. Forward states:
`off`, `pending`, `active`, `noService`, `dropped`, `error`.

## Who owns a retry

- Triggers: the master exits, `-O check` stops answering, the Mac wakes, the
  network path changes (the last two debounced by three seconds).
- `Reconnector` retries with delays 2, 4, 8, 16, 30 s, re-adding every forward
  whose switch is on; after five failures it marks the machine `failed` and
  fires `onGaveUp`; a machine back after ten seconds or more fires
  `onReconnected`.
- While a machine is `dropped`, `failed` or `connecting`, the all-ports scan
  does nothing; the reconnector alone retries. A scan joining an attempt
  would report the same failure twice and restart the count.
- A failed first connection is left to the user. Watching a machine again
  (`enableAutoHost`) resets a `failed` machine so scans resume.
- Shutdown cancels starts in progress; a master that finishes starting after
  nothing wants it is stopped, not kept.

## All ports and offsets

- A watched machine is listed every five seconds; each listener in
  1024–32767 becomes a forward on the same local port. Exclusions and the
  offset live on the `[[host]]` entry and are keyed by the remote port
  (`excludePort(remotePort:)`), since the local number may carry an offset.
- A local port is taken when one of our forwards holds it or when any local
  program listens on it, on any address: probed by `LocalPorts.isTaken`, a
  wildcard `bind` without `SO_REUSEADDR`. ssh binds with `SO_REUSEADDR`, and
  on macOS that succeeds beside a wildcard listener, which would let a remote
  machine take over a local service. Keep the probe in front of every
  discovered bind.
- The first taken port gives the machine an offset (+10000, +20000, …); from
  then on every discovered port on it uses the offset. A pinned forward whose
  number is taken moves the same way (`moved = true`); a manual switch-on
  drops the offset and lets such forwards try plain numbers again.

## Outside forwards, persistence, lifecycle

- While the panel is open, `ps -axo pid=,uid=,command=` runs every ten
  seconds; the user's ssh processes with `-L` become rows; Stop sends
  `SIGTERM`. At launch, masters from an earlier run (same socket directory,
  not our children) are terminated.
- `state.json` holds the forwards on and the machines watched at the last
  clean quit; launch restores them in parallel.
- Quit asks every master to exit at once under one short cap; SIGTERM,
  SIGINT and SIGHUP take the same path. A second instance exits at launch
  unless `TUNNELS_SOCKET_DIR` isolates it. Open at login uses
  `SMAppService.mainApp`.
