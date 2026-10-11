---
name: tunnels-contributing
description: The rules for changing Tunnels: setup, what must pass before a pull request, commit message format, code style and where things go. Use before starting any change to the repository and again before opening a pull request.
---

# Contributing

Tunnels is small on purpose: one Swift package, no dependencies, the system
`ssh`. Changes that keep it that way are welcome.

## When to use this

- Before you start a change: setup and the rules.
- Before you open a pull request: the checklist.

## Setup

1. macOS 14 or newer with the Xcode command line tools. Nothing else.
2. `swift build`, `swift test`, `scripts/bundle.sh` and `scripts/run.sh` are
   the whole toolchain.
3. For anything that talks to a machine, bring up the Docker lab described in
   [TESTING.md](TESTING.md). It edits `~/.ssh/config` between markers and
   removes its block on `down`.

## Before a pull request, in order

1. `swift build -Xswiftc -warnings-as-errors` passes.
2. `swift test` passes, twice if the change touches timing.
3. `xcrun swift-format lint --strict --recursive Sources Tests` passes;
   `xcrun swift-format format -i` fixes it.
4. A change in `TunnelsCore` comes with a test using `FakeRunner`; a bug fix
   starts with a test that failed first.
5. A user-visible change was tried against the lab, and
   [USAGE.md](USAGE.md) and the drill table in [TESTING.md](TESTING.md) say
   what it does now.
6. [CHANGELOG.md](CHANGELOG.md) has a line under Unreleased.
7. No new dependency, framework or layer without a discussion first.

## Commit messages

Conventional commits: `<type>: <description>`, lower case, imperative, under
72 characters. Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`,
`style`, `build`, `ci`, `chore`. The body says why and what changed in
behaviour, not how. No scope unless it adds clarity.

```
fix: exclude a discovered port by its remote number, not the local one

"Close and Forget" sent the local port, which only matches the remote
port while the machine has no offset.
```

## Style and placement

- Comments explain intent, constraints and non-obvious decisions. Delete a
  comment that restates the code.
- Views read through `AppModel` and never touch the engine directly.
- The core never reads the environment or decides paths; the app passes them
  in as `SSHOptions` and URLs.
- Mutations of the forward list go through the id-based `update`, never an
  index held across an `await`.
- No words on menu rows, no hover-only controls that a keyboard cannot reach,
  nothing in the menu bar but the glyph. See [DESIGN.md](DESIGN.md).

## Licence

By contributing you agree that your contribution is licensed under the MIT
licence in `LICENSE`, like the rest of the project. There is no contributor
agreement to sign.
