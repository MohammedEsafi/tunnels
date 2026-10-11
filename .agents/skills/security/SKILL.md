---
name: security
description: "The trust model of Tunnels and the checks to run on a change that touches ssh arguments, local ports, the favourites file, process listing or signals, plus how to report a vulnerability. Use when reviewing such a change, assessing a security report, or answering \"is this safe\" questions."
---

# Tunnels security

## Trust model

A change that weakens a line here needs a stated reason in the pull request.

- Runs `/usr/bin/ssh` as the current user with the user's own `~/.ssh/config`
  and agent. Never handles keys, passphrases or passwords.
- Binds listeners on `127.0.0.1` only. Discovered ports are limited to
  1024–32767 and are never bound when any local program already listens on
  that port, on any address (`LocalPorts.isTaken`, a wildcard bind without
  `SO_REUSEADDR`).
- Passes `StrictHostKeyChecking=accept-new`: first contact is accepted and
  pinned to `known_hosts`; a changed key is refused. The app's setting wins
  over a stricter user config for its own connections.
- In all-ports mode the remote machine chooses which ports appear on
  `localhost`, so it is trusted with the `localhost` origin, cookies included.
- Reads `~/.ssh/config` (Host aliases only), `tailscale status --json` (peer
  names and online state) and `ps` (the user's own `ssh -L` processes).
- Sends `SIGTERM` only to processes owned by the current user that are its
  own stale masters (same socket directory, not its children) or ones the
  user chose to stop.
- Writes `~/.config/tunnels/favourites.toml` and
  `~/Library/Application Support/Tunnels/`; control sockets live there in a
  `0700` directory.
- Has no network code of its own.

## Review checklist for a change in this area

1. Does any value from the remote (`ss`/`netstat` output, ssh stderr) reach an
   ssh argument, a file write or a `kill`? Only integers in the port range may.
2. Does an alias or host name become an ssh positional argument without
   validation? Names must not begin with `-`.
3. Does a discovered bind skip `isLocalPortTaken`?
4. Does a file write go outside the two directories above?
5. Does anything get logged that is not a port, an alias or ssh's own stderr?

## Reporting a vulnerability

1. Do not open a public issue.
2. Use the repository's private security advisory form:
   `https://github.com/MohammedEsafi/tunnels/security/advisories/new`.
3. Expect an answer within a week. Fixes ship as a new release with a note
   in `CHANGELOG.md`; credit is given unless the reporter prefers otherwise.
