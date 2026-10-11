---
name: tunnels-design
description: The decisions, module boundaries and ssh mechanics behind Tunnels. Use before changing TunnelsCore, the panel, the reconnection or all-ports logic, or the build, so a change fits the design instead of working around it.
---

# Design

Read this before touching the engine, the panel or the build. User-facing
behaviour is in [USAGE.md](USAGE.md).

## When to use this

- You are changing anything under `Sources/TunnelsCore` or `Sources/Tunnels/App`.
- You are deciding where new code belongs.
- A proposed change conflicts with a rule below; bring the conflict up before
  implementing.

## Decisions to keep

| Topic | Decision | Do not |
|---|---|---|
| UI | An AppKit `NSStatusItem` with a borderless `NSPanel`, `NSVisualEffectView` and SwiftUI content. `LSUIElement = true`. | switch to `MenuBarExtra`; it renders an opaque window |
| Target | macOS 14 or newer | raise it without a reason in the changelog |
| SSH | The system `/usr/bin/ssh` only; one ControlMaster per machine; forwards via `ssh -O forward` / `-O cancel` | add an ssh library or reconnect per forward |
| Machines | Host aliases from `~/.ssh/config` (with `Include`) and Tailscale peers; only aliases and ports are stored | store hostnames, users or keys |
| Auth | Keys in the agent; `BatchMode=yes` so a missing key fails fast and shows as a state | add passphrase or password prompts |
| Favourites | TOML at `$XDG_CONFIG_HOME/tunnels/favourites.toml` (default `~/.config/tunnels/`), parsed by the in-house `MiniTOML` subset; edits preserve every other line; watched for changes | add a TOML dependency or rewrite the file wholesale |
| Build | A Swift package; `scripts/bundle.sh` assembles and signs `Tunnels.app` | add XcodeGen, Homebrew or an Xcode project |
| Signing | Ad hoc, hardened runtime; Developer ID and notarisation are a later step in the same script | |
| Binding | Listeners bind `127.0.0.1` | ever bind `0.0.0.0` |
| Outside forwards | Detected and stoppable, never adopted | |
| Lifecycle | Quit closes every owned forward; launch restores what was on and sweeps masters left by a crash; one instance at a time | |
| Scope | Local forwards only | add remote forwards, SOCKS or key management |

## Module boundaries

```
Tunnels (app)  ──►  TunnelsCore (engine and file formats)  ◄──  tunnelsctl
```

Rules, checked in review:

1. The core never reads the environment or picks paths. The app resolves them
   once and passes `SSHOptions` and URLs in.
2. Views talk only to `AppModel`; they never reach `model.controller`. Add an
   accessor on `AppModel` when a view needs a new read.
3. Core-to-app communication is `@MainActor` closures (`onMasterDropped`,
   `onOffsetAssigned`, `onForwardMoved`, `onGaveUp`, `onReconnected`), not
   observation of the core from the app.
4. `ForwardController` keeps desired state (the switches) apart from actual
   state (what ssh reports). Every mutation of `forwards` goes through the
   id-based `update`; never hold an index across an `await`.
5. New code goes where its neighbours are: `Engine/` for ssh and state,
   `Formats/` for files, `Hosts/` for where machines come from, `System/` for
   the OS, and in the app `App/`, `Model/`, `Views/`, `Debug/`.

## The master connection

Started when the first forward on a machine is switched on, or when the
machine is watched:

```
ssh -N -M -S <socket> -o ControlPersist=no -o BatchMode=yes \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new <alias>
```

- Socket path: `~/Library/Application Support/Tunnels/sockets/<sha256(alias)[0..<12]>`.
  Unix socket paths are limited to 104 bytes, so the alias is hashed.
- The master is stopped with `-O exit` when its last forward is switched off,
  or when the machine's switch is turned off.

```
Add:     ssh -S <socket> -O forward -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>
Cancel:  ssh -S <socket> -O cancel  -L 127.0.0.1:<local>:<remoteHost>:<remotePort> <alias>
Health:  ssh -S <socket> -O check <alias>, every 30 s
Listing: ssh -S <socket> <alias> -- "ss -ltnH || netstat -tln || cat /proc/net/tcp /proc/net/tcp6 || netstat -an"
```

Machine states: `disconnected → connecting → connected`,
`connected → dropped(attempt n) → connecting …`, `dropped → failed(reason)`
after the budget, `any → disconnected` when switched off.
Forward states: `off`, `pending`, `active`, `noService`, `dropped`, `error`.

## Reconnection, who owns the retry

- Triggers: the master exits, `-O check` stops answering, the Mac wakes, the
  network path changes (the last two debounced by three seconds).
- The `Reconnector` retries with delays 2, 4, 8, 16, 30 seconds, re-adding
  every forward whose switch is on; after five failures it marks the machine
  `failed` and fires `onGaveUp`; a machine back after ten seconds or more
  fires `onReconnected`.
- While a machine is `dropped`, `failed` or `connecting`, the all-ports scan
  does nothing; the reconnector alone retries. This keeps the backoff real and
  the "is down" notification true. A scan joining an attempt would report the
  same failure twice and restart the count.
- A failed first connection is left to the user (the orange circle). Watching
  a machine again (`enableAutoHost`) resets a `failed` machine so scans resume.
- Shutdown cancels starts in progress; a master that finishes starting after
  nothing wants it is stopped, not kept.

## All ports and offsets

- A watched machine is listed every five seconds; each listener in 1024–32767
  becomes a forward on the same local port. Exclusions and the offset live on
  the `[[host]]` entry.
- A local port is "taken" when one of our forwards holds it or when any
  program on this Mac listens on it, on any address. The latter is probed
  with a wildcard `bind` without `SO_REUSEADDR` (`LocalPorts.isTaken`),
  because ssh binds with `SO_REUSEADDR` and on macOS that bind succeeds
  beside a wildcard listener, which would let a remote machine take over a
  local service. Keep this probe in front of every discovered bind.
- The first taken port gives the machine an offset (+10000, +20000, …); from
  then on every discovered port on it uses the offset. A pinned forward whose
  number is taken moves the same way and is recorded `moved = true`; a manual
  switch-on drops the offset and lets such forwards try plain numbers again.
- Exclusions are keyed by the remote port, which is what discovery reports;
  the local number may carry an offset. The API says `excludePort(remotePort:)`
  for that reason.

## Forwards started outside the app

While the panel is open, `ps -axo pid=,uid=,command=` runs every ten seconds.
The current user's ssh processes with `-L` become rows under their machine;
Stop sends `SIGTERM`. At launch, masters from an earlier run of the app (same
socket directory, not our children) are terminated so their ports are free.

## Persistence and lifecycle

- `state.json` holds the forwards that were on and the machines watched at the
  last clean quit; launch restores them in parallel so one unreachable machine
  does not delay the rest.
- Quit asks every master to exit at once under one short cap, because logout
  gives the process only seconds. SIGTERM, SIGINT and SIGHUP take the same path.
- A second instance exits at launch unless `TUNNELS_SOCKET_DIR` isolates it.
- Open at login uses `SMAppService.mainApp`.
