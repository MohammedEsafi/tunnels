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
- Machines reachable by `ssh <name>`: Host aliases in `~/.ssh/config`, or
  Tailscale MagicDNS names. Keys loaded in `ssh-agent` (`ssh-add`); the app
  runs ssh in batch mode, so a key that needs a passphrase prompt shows as
  "No usable key in the agent".

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

Opening a forward writes to `~/.config/tunnels/favourites.toml` (or
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

A machine in all-ports mode is a `[[host]]` entry:

```toml
[[host]]
name = "gpu-box"
all_ports = true
exclude = [5432]
```

Problems in the file are shown at the top of the popover with an Open button.

## Using it

- **Switches.** Each forward has a switch. The switch on a machine row turns
  every forward on that machine on or off at once. Clicking a forward's name
  toggles it too.
- **Ports.** The right-hand column shows the local port, and `28080 → 18080`
  only when the remote port differs. Click it to copy `localhost:<port>`.
- **Adding.** The + button (or ⌘N) shows the field. With the field empty it
  lists your favourites and machines: Host aliases from `~/.ssh/config` plus
  Tailscale peers when the `tailscale` CLI is installed (offline ones are dimmed).
  Type `host:port`,
  `host:local:remote`, or `host:local:remoteHost:remote` and press Return.
  Typing part of a favourite name or a Host alias shows suggestions; arrow
  keys and Return pick one. Ad-hoc forwards appear under their machine and
  can be removed with the × that shows on hover.
- **All ports.** Type a machine name alone and pick the `all ports` row.
  The app then watches that machine over the same connection, every five
  seconds, and forwards every TCP listener it finds (1024 up to 32767, below
  the ephemeral range) to the same local port, adding and removing forwards
  as services come and go. The host shows a small layers glyph after its name; its port rows
  have no name. Switch a port off (or ×) to say "not this one"; that is kept
  across reconnects and relaunches. Switching the host off stops watching;
  switching it on again asks whether you want all ports or only the pinned
  ones. Answering "All ports" forgets the "not this one" choices.
  Answering "Pinned only" freezes what the host had: the ports that were
  open when you switched it off, minus the ones you closed, become ordinary
  pinned forwards, and watching stops for good.
- **When two machines offer the same port.** Only one can be `localhost:8080`.
  The first keeps the plain number. When a discovered port on another
  machine is taken locally, that machine gets an offset, +10000 for the
  first such machine, +20000 for the next, and from then on every discovered
  port on it lands on remote plus offset: `18080 → 8080`, whether or not that
  particular port clashes, so the rule never depends on which machine
  connected first. One notification tells you the rule when it first
  happens. The offset is kept on the host's entry (`offset = 10000`) across
  reconnects and relaunches; answering "All ports" again is a fresh start and
  clears it. A pinned forward whose own number is taken moves the same way,
  and the favourites file is rewritten (with `moved = true`) so it stays
  there; a forward you gave a different local number yourself is left alone.
  Switching a machine off and on by hand means "start from the best numbers
  available": its offset is dropped and the forwards the app moved try their
  plain number again, moving back only what is still taken. Automatic
  reconnects and relaunches keep the numbers as they were.
- **A forward with nothing behind it.** A pinned forward whose remote port has
  no listener shows an orange circle with the tooltip "Nothing listening on
  host:port". It is open and will work the moment something starts there;
  checked when it opens and every 30 seconds. Stored in the
  favourites file as a `[[host]]` entry with `all_ports = true` and an
  optional `exclude = [...]`.
- **States.** Blue circle: active. Spinner: opening. Orange circle with ↻:
  dropped, click it to retry the machine now. Red circle with ↻: that one
  forward failed while the connection is fine, click to try again. Grey: not
  running. No words on the rows: the reason is the tooltip on the retry
  circle, and the full ssh output is in Connection Logs.
- **Pinning.** Hover a forward and click the pin to keep it for next time
  (it goes into the favourites file); click the filled pin to unpin. The ×
  closes the forward, and unpins it if it was pinned. The file itself is only
  only needed for hand edits; renaming is done on the Pinned Forwards page.
- **First run.** The menu shows just the field. Type `host:port` and press
  Return. It is remembered until you × it.
- **Started outside Tunnels.** `ssh -L` processes you started in a terminal
  show under their machine with a terminal icon; hover for Stop. They are
  never adopted.
- **Close All** and **Settings…** are at the bottom. Settings is a page
  inside the menu, like Control Center's sub-pages: open at login, the
  give-up notification, a Forwards page where you rename or forget in
  place, links to the favourites file and SSH config, and Connection Logs,
  a list of machines where clicking one shows its timestamped ssh lines. The ‹ chevron or ⌘← goes back. Escape or a click outside
  closes the menu; ⌘Q quits.

## How reconnection works

A master is considered dropped when its process exits, when a 30-second health
check stops answering, or after the Mac wakes or the network path changes. The
app then retries after 2, 4, 8, 16 and 30 seconds, re-adding every forward that
was on. After five failures the machine shows the retry circle and one
notification is posted, "<machine> is down". If it comes back on its own after
being down for ten seconds or more, a second one says "<machine> is back" with
how long it was gone. Both are under one switch in Settings. A machine whose very first connection fails (unknown host, no key)
is not retried automatically: fix the cause and click its orange circle.

Quitting the app closes every forward it owns. Forwards that were on are
restored at the next launch.

## Layout

```
Sources/TunnelsCore   ssh master, forward controller, reconnector, favourites,
                      ssh config, quick-open parsing, external scanner — no UI
Sources/Tunnels       AppKit status item + Control Center style panel, SwiftUI content
Sources/tunnelsctl    command-line harness for the core
Tests/TunnelsCoreTests
scripts/bundle.sh     builds and signs Tunnels.app (renders the icon first)
Resources/AppIcon.svg the app icon; scripts/makeicon.swift turns it into .icns
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
