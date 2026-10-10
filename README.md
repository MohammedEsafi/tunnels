# Tunnels

A macOS menu bar app that manages SSH local port forwards on demand. It lives
only in the menu bar: click the icon to see every forward grouped by machine,
switch forwards on and off, and let the app bring them back after sleep or a
network change.

- Uses the system `ssh` and your existing `~/.ssh/config` and agent. No keys,
  passwords or hosts are stored in the app.
- One SSH connection per machine (ControlMaster); forwards are added and
  removed on that connection without reconnecting.
- Forwards always bind `127.0.0.1`, never the network.
- Forwards opened elsewhere (a stray `ssh -L` in a terminal) are listed too and
  can be stopped.
- Dropped connections reconnect with backoff; you get one notification only if
  that gives up.

## Requirements

- macOS 14 or newer.
- Host aliases in `~/.ssh/config`, with keys loaded in `ssh-agent` (`ssh-add`).
  The app runs ssh in batch mode, so a key that needs a passphrase prompt shows
  as "No usable key in the agent".

## Build

Only Xcode's command line tools are needed. No Homebrew, no Xcode project.

```bash
scripts/bundle.sh            # release build -> build/Tunnels.app
scripts/run.sh               # debug build, then launch
swift test                   # unit tests
```

The bundle is ad-hoc signed. Copy `build/Tunnels.app` to `/Applications` if you
want "Start at login" to keep working after you move the build folder.

## Favourites

Pins in the menu write to `~/.config/tunnels/favourites.toml` (or
`$XDG_CONFIG_HOME/tunnels/favourites.toml`), so you never have to open the file.
It is plain TOML if you want to keep it in your dotfiles, rename entries, or add
them by hand; the app reloads it whenever it changes.

```toml
[[favourite]]
name = "postgres"
host = "prod-db-01"        # Host alias from ~/.ssh/config
port = 5432                # local port on this Mac

[[favourite]]
name = "postgres"
host = "staging"
port = 15432
remote_port = 5432         # defaults to `port`
remote_host = "localhost"  # as seen from the machine, defaults to localhost
```

Problems in the file are shown at the top of the popover with an Open button.

## Using it

- **Switches.** Each forward has a switch. The switch on a machine row turns
  every forward on that machine on or off at once. Clicking a forward's name
  toggles it too.
- **Ports.** The right-hand column shows the local port, and `28080 → 18080`
  only when the remote port differs. Click it to copy `localhost:<port>`.
- **Adding.** The + button (or ⌘N) shows the field. Type `host:port`,
  `host:local:remote`, or `host:local:remoteHost:remote` and press Return.
  Typing part of a favourite name or a Host alias shows suggestions; arrow
  keys and Return pick one. Ad-hoc forwards appear under their machine and
  can be removed with the × that shows on hover.
- **States.** Blue circle: active. Orange circle with ↻: dropped, click it to
  retry the machine now instead of waiting for the next automatic attempt.
  Red circle with ↻: that one forward failed while the connection is fine,
  click to try it again. Grey: not running. Hover a machine row for the
  reason or the retry countdown.
- **Pinning.** Hover a forward and click the pin to keep it for next time
  (it goes into the favourites file); click the filled pin to unpin. The ×
  closes the forward, and unpins it if it was pinned. The file itself is only
  needed for renaming or hand edits; Settings… opens it.
- **First run.** The menu shows just the field. Type `host:port` and press
  Return; pin it if you want it back next time.
- **Started outside Tunnels.** `ssh -L` processes you started in a terminal
  show under their machine with a terminal icon; hover for Stop. They are
  never adopted.
- **Close All** and **Settings…** (start at login, the favourites file,
  per-machine ssh logs) are at the bottom. Escape or a click outside closes
  the menu; ⌘Q quits.

## How reconnection works

A master is considered dropped when its process exits, when a 30-second health
check stops answering, or after the Mac wakes or the network path changes. The
app then retries after 2, 4, 8, 16 and 30 seconds, re-adding every forward that
was on. After five failures the machine shows "Retry now" and one notification
is posted. A machine whose very first connection fails (unknown host, no key)
is not retried automatically: fix the cause and press Retry now.

Quitting the app closes every forward it owns. Forwards that were on are
restored at the next launch.

## Layout

```
Sources/TunnelsCore   ssh master, forward controller, reconnector, favourites,
                      ssh config, quick-open parsing, external scanner — no UI
Sources/Tunnels       AppKit status item + Control Center style panel, SwiftUI content
Sources/tunnelsctl    command-line harness for the core
Tests/TunnelsCoreTests
scripts/bundle.sh     builds and signs Tunnels.app
```

Development environment variables (never needed in normal use):

| Variable | Effect |
|---|---|
| `TUNNELS_SSH_CONFIG` | Use this ssh config file instead of `~/.ssh/config` |
| `TUNNELS_DEBUG` | Log to stderr |
| `TUNNELS_SNAPSHOT` | Show the popover in a window for a few seconds, then quit |
| `TUNNELS_SNAPSHOT_TURN_ON` | With the above, turn every favourite on at launch |
| `TUNNELS_SNAPSHOT_SETTINGS` | Show the Settings window instead |

See `CHECKS.md` for the manual checks run against a local sshd.
