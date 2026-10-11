---
name: tunnels-security
description: How to report a vulnerability in Tunnels privately, and the app's trust model: what it runs, binds, reads, writes and signals. Use when assessing a security report, reviewing a change that touches ssh arguments, ports, files or process control, or answering "is this safe" questions.
---

# Security

## When to use this

- You found or received a vulnerability report.
- A change touches ssh arguments, local ports, the favourites file, `ps`,
  `kill`, or the all-ports listing.

## Reporting

1. Do not open a public issue.
2. Use [GitHub security advisories](https://github.com/MohammedEsafi/tunnels/security/advisories/new)
   for a private report.
3. Expect an answer within a week. Fixes ship as a new release with a note in
   the changelog; credit is given unless you prefer otherwise.

## Trust model

What the app does, in security terms. A change that weakens a line here needs
a reason in the pull request.

- Runs `/usr/bin/ssh` as the current user with the user's own `~/.ssh/config`
  and agent. Never handles keys, passphrases or passwords.
- Binds listeners on `127.0.0.1` only. Discovered ports are limited to
  1024–32767 and are never bound when any local program already listens on
  that port, on any address (`LocalPorts.isTaken`, a wildcard bind without
  `SO_REUSEADDR`).
- Passes `StrictHostKeyChecking=accept-new` to every ssh call: a host seen for
  the first time is accepted and pinned to `known_hosts`; a changed key is
  refused. If the user's config says `ask` or `yes`, the app's setting wins
  for its own connections.
- In all-ports mode the remote machine chooses which ports appear on
  `localhost`. That means trusting the machine with the `localhost` origin,
  including cookies a browser holds for it.
- Reads `~/.ssh/config` (Host aliases only), `tailscale status --json` (peer
  names and online state) and `ps` (the user's own `ssh -L` processes).
- Sends `SIGTERM` only to processes owned by the current user that are either
  its own stale masters (same socket directory, not its children) or ones the
  user chose to stop.
- Writes `~/.config/tunnels/favourites.toml` and
  `~/Library/Application Support/Tunnels/`; control sockets live there in a
  `0700` directory.
- Has no network code of its own and makes no connections except through ssh.

## Checks when reviewing a change in this area

- Does any value from the remote (`ss`/`netstat` output, ssh stderr) reach an
  ssh argument, a file write or a `kill`? Only integers in the port range may.
- Does any alias or host name become an ssh positional argument without
  validation? Names must not begin with `-`.
- Does a discovered bind skip `isLocalPortTaken`?
- Does a file write go outside the two directories above?
