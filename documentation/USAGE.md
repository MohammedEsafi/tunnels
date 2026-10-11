---
name: tunnels-usage
description: How to install and use the Tunnels menu bar app, what every menu item does, the all-ports and offset rules, how reconnection behaves, and which files it writes. Use when answering "how do I…" questions about the app, when changing user-facing behaviour, or when writing release notes.
---

# Using Tunnels

The [README](../README.md) is the short version. [DESIGN.md](DESIGN.md) explains
why things work this way. If you change behaviour described here, change this
file in the same commit.

## When to use this

- You need to know what a menu item, state or notification does.
- You are about to change user-facing behaviour and must keep the docs true.
- You are writing release notes or answering a user's question.

## Install

1. Needs macOS 14 or newer and keys loaded in `ssh-agent`. The app runs ssh in
   batch mode, so a key that still needs a passphrase shows as "No usable key
   in the agent". Run `ssh-add --apple-use-keychain ~/.ssh/<key>` once to keep
   it loaded across reboots.
2. Download `Tunnels.app` from the
   [Releases](https://github.com/MohammedEsafi/tunnels/releases) page and move
   it to `/Applications`.
3. Open it the first time with right-click › Open, or clear the quarantine
   flag. The build is signed ad hoc, not notarised.

   ```bash
   xattr -dr com.apple.quarantine /Applications/Tunnels.app
   ```

4. Keep the app in one place: "Open at login" and the notification permission
   are tied to where the bundle lives.

Machines are anything reachable by `ssh <name>`: Host aliases in
`~/.ssh/config`, or Tailscale MagicDNS names.

## Open a forward

1. Click the + button (or press ⌘N) to show the field.
2. With the field empty, the list shows your machines: Host aliases from
   `~/.ssh/config` plus Tailscale peers when the `tailscale` CLI is installed
   (offline ones are dimmed). Typing part of a machine or forward name shows
   suggestions; arrow keys and Return pick one.
3. Type one of these and press Return:
   - `host:port`, the same port on both ends
   - `host:local:remote`
   - `host:local:remoteHost:remote`, for a service behind the machine
4. Everything you open is remembered in the favourites file.

## Read a row

| You see | It means | Do |
|---|---|---|
| Blue circle | active | nothing |
| Spinner | opening | wait |
| Orange circle with ↻ | the machine dropped | click it to retry now; the tooltip has the reason |
| Red circle with ↻ | this one forward failed while the connection is fine | click it to retry that forward |
| Orange circle, no ↻, tooltip "Nothing listening on host:port" | the forward is open but nothing serves the remote port yet | start the service; the row turns blue within 30 seconds |
| Grey circle | off | switch it on |
| Terminal icon | an `ssh -L` you started outside the app | hover or right-click for Stop; it is never adopted |

There are no words on rows. The full ssh output is under Settings › Connection
Logs. The port column shows the local port, and `28080 → 8080` only when the
remote port differs; click it to copy `localhost:<port>`.

## The switches and menus

- A forward's switch turns it on or off. Clicking its name does the same.
- A machine's switch turns every forward on that machine on or off at once.
- Right-click a forward: Copy `localhost:<port>`, Open in Browser, Rename…,
  Change Ports…, Close and Forget. Change Ports… turns the port column into one
  field in the `local:remote` grammar; a lone number means both. Return
  applies, Escape cancels, and flipping the switch mid-edit applies the edit
  first.
- Right-click a machine: All Ports, Pinned Ports Only, Copy ssh Command (the
  plain `ssh -N -L …` equivalent of its forwards), Show Log, Forget Machine.
- At the bottom: Close All, Settings…, Quit. Settings is a page inside the
  menu with Open at login, Notify about dropped connections, links to the
  favourites file and your SSH config, and Connection Logs. The ‹ chevron or
  ⌘← goes back. Escape or a click outside closes the menu; ⌘Q quits.

## All ports

Turn it on by typing a machine name alone and picking the `all ports` row, or
with All Ports from the machine's menu. Then:

- The app lists the machine's TCP listeners every five seconds over the same
  connection and forwards each one in 1024–32767 to the same local port,
  adding and removing forwards as services come and go.
- The machine shows a small layers glyph; its port rows have no name.
- Close and Forget on such a row means "not this one", kept across reconnects
  and relaunches.
- Switching the machine off stops watching; switching it on resumes with the
  same exclusions. All Ports from the menu is a fresh start and forgets them.
- Pinned Ports Only freezes what the machine had: the open ports, minus the
  ones you closed, become ordinary pinned forwards and watching stops.

### The offset rule, when two machines offer the same port

1. Only one forward can be `localhost:8080`. When a discovered port is already
   taken on this Mac, by another machine's forward or by any local program,
   the machine gets an offset: +10000 for the first such machine, +20000 for
   the next.
2. From then on every discovered port on that machine lands on remote plus
   offset (`18080 → 8080`), so the mapping never depends on which machine
   connected first. One notification explains this the first time.
3. The offset is kept on the machine's `[[host]]` entry (`offset = 10000`)
   across reconnects and relaunches. All Ports from the menu clears it.
4. A pinned forward whose own number is taken moves the same way, and the file
   records `moved = true`.
5. Switching a machine off and on by hand means "start from the best numbers
   available": the offset is dropped and the forwards the app moved try their
   plain numbers again, moving back only what is still taken. Automatic
   reconnects and relaunches keep the numbers as they were.

## Reconnection

- A machine counts as dropped when its ssh master exits, when the 30-second
  health check stops answering, or after the Mac wakes or the network path
  changes.
- The app retries after 2, 4, 8, 16 and 30 seconds, re-adding every forward
  that was on. After five failures the machine shows the retry circle and one
  notification says "<machine> is down".
- A machine that comes back on its own after ten seconds or more posts
  "<machine> is back" with how long it was gone. Both notifications are under
  one switch in Settings.
- A machine whose very first connection fails (unknown host, no key) is not
  retried on its own: fix the cause and click its orange circle. A watched
  machine is treated the same way.
- Quitting closes every forward the app owns. Forwards that were on are
  restored at the next launch; masters left by a crash are closed then too.

## Files the app writes

| Path | What |
|---|---|
| `~/.config/tunnels/favourites.toml` (or `$XDG_CONFIG_HOME/tunnels/…`) | every remembered forward and watched machine; plain TOML, reloaded when it changes |
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
the file, and a write that failed, show at the top of the menu with an Open
button.

To uninstall: quit, delete the app and the paths above, and remove Tunnels
from System Settings › General › Login Items if you enabled it.

## Security notes

- Listeners bind `127.0.0.1` only. Discovered ports are limited to
  1024–32767, and a port that any program on this Mac already serves is never
  bound; the machine moves to an offset instead, so a remote machine cannot
  take over a local service.
- In all-ports mode the remote machine decides which ports exist on
  `localhost`. Anything you open at `http://localhost:<port>` is served by it,
  with whatever `localhost` cookies your browser holds. Use it on machines you
  trust.
- Every ssh call passes `StrictHostKeyChecking=accept-new`: a host you have
  never connected to is accepted on first contact and pinned to `known_hosts`;
  a changed key is still refused.

See [SECURITY.md](SECURITY.md) to report a problem.
