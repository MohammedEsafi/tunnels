---
name: usage
description: Answer questions about using the Tunnels menu bar app: installing it, opening forwards, what the rows and circles mean, the right-click menus, all-ports mode and the offset rule, reconnection, notifications, and which files it writes. Use whenever someone asks how to do something in the app, why it behaves a certain way, or where its data lives.
---

# Tunnels usage

You are answering for the app as it is in this repository. If a question is
about a behaviour you cannot find below, read the code under
`Sources/Tunnels/Views` and `Sources/Tunnels/Model` before answering, and say
that you did.

## How to answer

1. Find the matching section below and answer from it, in the user's words.
2. Give the exact menu label, key or file path; never invent one.
3. If the answer depends on the state of the user's machine (a key in the
   agent, a port in use), say what to check and how.

## Install

- Needs macOS 14 or newer and keys loaded in `ssh-agent`. The app runs ssh in
  batch mode, so a key that still needs a passphrase shows as "No usable key
  in the agent". `ssh-add --apple-use-keychain ~/.ssh/<key>` keeps it loaded
  across reboots.
- Download `Tunnels.app` from the repository's Releases page, move it to
  `/Applications`, and open it the first time with right-click › Open or
  `xattr -dr com.apple.quarantine /Applications/Tunnels.app`. The build is
  signed ad hoc, not notarised.
- Keep the app in one place: "Open at login" and the notification permission
  are tied to where the bundle lives.
- Machines are anything reachable by `ssh <name>`: Host aliases in
  `~/.ssh/config`, or Tailscale MagicDNS names.

## Open a forward

1. Click the + button (or press ⌘N) to show the field.
2. With the field empty, the list shows the machines: Host aliases from
   `~/.ssh/config` plus Tailscale peers when the `tailscale` CLI is installed
   (offline ones dimmed). Typing part of a machine or forward name shows
   suggestions; arrow keys and Return pick one.
3. Type `host:port`, `host:local:remote` or `host:local:remoteHost:remote`
   and press Return.
4. Everything opened is remembered in the favourites file.

## What a row shows

| Seen | Meaning | Do |
|---|---|---|
| Blue circle | active | nothing |
| Spinner | opening | wait |
| Orange circle with ↻ | the machine dropped | click to retry now; the tooltip has the reason |
| Red circle with ↻ | this forward failed while the connection is fine | click to retry it |
| Orange circle, tooltip "Nothing listening on host:port" | open, but nothing serves the remote port yet | start the service; the row turns blue within 30 s |
| Grey circle | off | switch it on |
| Terminal icon | an `ssh -L` started outside the app | hover or right-click for Stop; never adopted |

No words on rows. The full ssh output is under Settings › Connection Logs.
The port column shows the local port, and `28080 → 8080` only when the remote
differs; clicking it copies `localhost:<port>`.

## Switches and menus

- A forward's switch, or clicking its name, turns it on or off. A machine's
  switch does every forward on it at once.
- Right-click a forward: Copy `localhost:<port>`, Open in Browser, Rename…,
  Change Ports…, Close and Forget. Change Ports… turns the port column into one
  field in the `local:remote` grammar; a lone number means both. Return
  applies, Escape cancels, flipping the switch mid-edit applies the edit first.
- Right-click a machine: All Ports, Pinned Ports Only, Copy ssh Command (the
  plain `ssh -N -L …` equivalent), Show Log, Forget Machine.
- Bottom: Close All, Settings…, Quit. Settings is a page in the menu: Open at
  login, Notify about dropped connections, links to the favourites file and
  the SSH config, Connection Logs. ‹ or ⌘← goes back; Escape or a click
  outside closes the menu; ⌘Q quits.

## All ports

Turn it on by typing a machine name alone and picking the `all ports` row, or
with All Ports from the machine's menu. Then the app lists the machine's TCP
listeners every five seconds over the same connection and forwards each one in
1024–32767 to the same local port, adding and removing as services come and
go. The machine shows a small layers glyph; its rows have no name.

- Close and Forget on such a row means "not this one", kept across reconnects
  and relaunches.
- Switching the machine off stops watching; on again resumes with the same
  exclusions. All Ports from the menu is a fresh start and forgets them.
- Pinned Ports Only freezes what the machine had: the open ports, minus the
  closed ones, become ordinary pinned forwards and watching stops.

### The offset rule

1. Only one forward can be `localhost:8080`. When a discovered port is already
   taken on this Mac, by another machine's forward or by any local program,
   the machine gets an offset: +10000 for the first such machine, +20000 for
   the next.
2. From then on every discovered port on that machine lands on remote plus
   offset (`18080 → 8080`), so the mapping never depends on connection order.
   One notification explains this the first time.
3. The offset is kept on the machine's `[[host]]` entry (`offset = 10000`).
   All Ports from the menu clears it.
4. A pinned forward whose number is taken moves the same way; the file
   records `moved = true`.
5. Switching a machine off and on by hand drops the offset and lets the moved
   forwards try their plain numbers again, moving back only what is still
   taken. Automatic reconnects and relaunches keep the numbers.

## Reconnection and notifications

- A machine counts as dropped when its ssh master exits, the 30-second health
  check stops answering, or the Mac wakes or the network path changes.
- Retries after 2, 4, 8, 16 and 30 seconds, re-adding every forward that was
  on. After five failures the machine shows the retry circle and one
  notification says "<machine> is down". A machine back on its own after ten
  seconds or more posts "<machine> is back". Both are under one Settings
  switch; a hint appears there if notifications are off in System Settings.
- A machine whose very first connection fails (unknown host, no key) is not
  retried on its own: fix the cause and click the orange circle. A watched
  machine is treated the same way.
- Quitting closes every owned forward; forwards that were on are restored at
  the next launch; masters left by a crash are closed then too. Opening the
  app twice makes the second copy exit.

## Files

| Path | What |
|---|---|
| `~/.config/tunnels/favourites.toml` (or `$XDG_CONFIG_HOME/tunnels/…`) | every remembered forward and watched machine; plain TOML, reloaded when it changes |
| `~/Library/Application Support/Tunnels/state.json` | which forwards were on at the last quit |
| `~/Library/Application Support/Tunnels/sockets/` | the ssh control sockets, created `0700` |

```toml
[[favourite]]
name = "postgres"
host = "prod-db-01"        # Host alias from ~/.ssh/config
port = 5432                # local port; remote_port defaults to it

[[favourite]]
name = "postgres"
host = "staging"
port = 15432
remote_port = 5432
remote_host = "localhost"  # as seen from the machine

[[host]]                   # a watched machine
name = "gpu-box"
all_ports = true
exclude = [5432]
offset = 10000
```

The parser is a small TOML subset: strings, integers, booleans, arrays of
those, `[table]`, `[[array of tables]]`, `#` comments. Problems in the file,
and a write that failed, show at the top of the menu with an Open button.

Uninstall: quit, delete the app and the paths above, and remove Tunnels from
System Settings › General › Login Items if it was enabled.

## Security facts to state when asked

- Listeners bind `127.0.0.1` only. Discovered ports are limited to
  1024–32767, and a port that any local program already serves is never
  bound; the machine moves to an offset instead.
- In all-ports mode the remote machine decides which ports exist on
  `localhost`, cookies included. Use it on trusted machines.
- Every ssh call passes `StrictHostKeyChecking=accept-new`: first contact is
  accepted and pinned; a changed key is refused.
