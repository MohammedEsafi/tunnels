# Design

The decisions behind Tunnels and the mechanics that are not obvious from the
code. User-facing behaviour is in the [README](../README.md).

## Decisions

| Topic | Decision |
|---|---|
| UI | An AppKit `NSStatusItem` with a custom borderless `NSPanel` holding a `NSVisualEffectView` and SwiftUI content. SwiftUI's `MenuBarExtra` gives an opaque window that does not look like Control Center. `LSUIElement = true`: no Dock icon, no main window. |
| Target | macOS 14 or newer. |
| SSH | The system `/usr/bin/ssh` only. One ControlMaster connection per machine; forwards are added and removed on it with `ssh -O forward` and `ssh -O cancel`. |
| Machines | Host aliases from `~/.ssh/config` (with `Include`) and Tailscale peers from `tailscale status --json`. Nothing but aliases and ports is stored. |
| Auth | Keys must be in the agent. `BatchMode=yes`, so a missing key fails fast and shows as a state instead of a prompt. |
| Favourites | TOML at `$XDG_CONFIG_HOME/tunnels/favourites.toml`, default `~/.config/tunnels/favourites.toml`, parsed by a small in-house subset reader (`MiniTOML`) so there is no dependency. Edits preserve every other line. Watched for changes. |
| Build | A Swift package built with `swift build`; `scripts/bundle.sh` assembles `Tunnels.app`, writes `Info.plist` and signs it. No XcodeGen, no Homebrew. |
| Signing | Ad hoc, hardened runtime. A Developer ID signature and notarisation are a later step using the same script. |
| Binding | Local listeners bind `127.0.0.1`, never the network. |
| Outside forwards | Detected and can be stopped, never adopted. |
| Lifecycle | Quitting closes every forward the app owns; launch restores the ones that were on and closes masters left by a crash. One instance at a time. |
| Scope | Local forwards only. No remote forwards, no SOCKS, no key management. |

## Module boundaries

```
Tunnels (app)  ──►  TunnelsCore (engine and file formats)  ◄──  tunnelsctl
```

The core knows nothing about AppKit, the environment or where files live:
the app resolves paths and settings once and passes them in as `SSHOptions`
and URLs. Views talk only to `AppModel`; the engine's callbacks run on the
main actor. `ForwardController` keeps the desired state (what the switches
say) apart from the actual state (what ssh reports), and every mutation of
its forward list goes through an id-based update, never a stored index.

## The master connection

Started when the first forward on a machine is switched on, or when the
machine is watched in all-ports mode:

```
ssh -N -M -S <socket> -o ControlPersist=no -o BatchMode=yes \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new <alias>
```

Socket path: `~/Library/Application Support/Tunnels/sockets/<sha256(alias)[0..<12]>`.
Unix socket paths are limited to 104 bytes, so the directory is kept short and
the alias is hashed. The master is stopped with `-O exit` when its last forward
is switched off, or when the machine's switch is turned off.

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

## Reconnection

Triggers: the master process exits, `-O check` stops answering, the Mac wakes,
the network path changes (the last two debounced by three seconds). The
reconnector then retries with delays 2, 4, 8, 16, 30 seconds, re-adding every
forward whose switch is on. After five failures the machine is `failed` and one
notification is posted; a machine that comes back on its own after at least
ten seconds posts "is back". While a machine is dropped or failed the
reconnector owns every retry: the all-ports loop does not reconnect on its own,
so the backoff and the notification stay true. A failed first connection is
left to the user.

## All-ports mode and offsets

A watched machine is listed every five seconds; each listener in 1024–32767
becomes a forward on the same local port. Exclusions and the offset are kept on
the machine's `[[host]]` entry. A local port is taken when one of our own
forwards holds it or when any program on this Mac listens on it, on any
address: the latter is probed with a wildcard `bind` without `SO_REUSEADDR`,
because ssh binds its listeners with `SO_REUSEADDR` and on macOS that bind
succeeds beside a wildcard listener, which would let a remote machine take
over a local service. The first taken port gives the machine an offset
(+10000, +20000, …) and from then on every discovered port on it uses the
offset, so the mapping never depends on connection order. A pinned forward
whose own number is taken moves the same way and is recorded as
`moved = true`; a manual switch-on drops the offset and lets such forwards try
their plain numbers again.

## Forwards started outside the app

While the panel is open, `ps -axo pid=,uid=,command=` is read every ten
seconds. ssh processes of the current user with `-L` become rows under their
machine. Stop sends `SIGTERM`. At launch, masters from an earlier run of the
app (same socket directory, not our children) are terminated so their ports
are free.

## Persistence

`state.json` holds the forwards that were on and the machines watched at the
last clean quit; launch restores them in parallel so one unreachable machine
does not delay the rest. Open at login uses `SMAppService.mainApp`.
