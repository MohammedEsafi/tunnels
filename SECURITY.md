# Security

## Reporting

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/MohammedEsafi/tunnels/security/advisories/new)
rather than in a public issue. You will get an answer within a week. Fixes
ship as a new release with a note in the changelog; credit is given unless you
prefer otherwise.

## What the app does, in security terms

- Runs `/usr/bin/ssh` as the current user, with the user's own `~/.ssh/config`
  and agent. It never handles keys, passphrases or passwords.
- Binds listeners on `127.0.0.1` only. Discovered ports are limited to
  1024–32767 and are never bound when any local program already listens on
  that port, on any address.
- Passes `StrictHostKeyChecking=accept-new` to every ssh call: a host seen for
  the first time is accepted and pinned to `known_hosts`; a changed key is
  refused. If your config says `ask` or `yes`, the app's setting wins for its
  own connections.
- In all-ports mode the remote machine chooses which ports appear on
  `localhost`. Treat that as trusting the machine with your `localhost`
  origin, including cookies a browser holds for it.
- Reads `~/.ssh/config` (Host aliases only), `tailscale status --json` (peer
  names and online state) and `ps` (to list the user's own `ssh -L`
  processes). Sends `SIGTERM` only to processes owned by the current user that
  it recognises as its own stale masters or that the user chose to stop.
- Writes `~/.config/tunnels/favourites.toml` and
  `~/Library/Application Support/Tunnels/`; control sockets live there in a
  `0700` directory.
- Has no network code of its own and makes no connections except through ssh.
