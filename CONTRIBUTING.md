# Contributing

Thanks for looking. Tunnels is small on purpose: one Swift package, no
dependencies, the system `ssh`. Changes that keep it that way are welcome.

## Setup

- macOS 14 or newer with the Xcode command line tools.
- `swift build`, `swift test`, `scripts/bundle.sh` and `scripts/run.sh` are all
  there is. The Docker lab in `docs/TESTING.md` gives you two ssh machines to
  try things against; it edits `~/.ssh/config` between markers and removes its
  block again on `down`.

## Before you open a pull request

- `swift build -Xswiftc -warnings-as-errors`, `swift test` and
  `xcrun swift-format lint --strict --recursive Sources Tests` pass. The
  `.swift-format` file in the repo is the style; `xcrun swift-format format -i`
  applies it.
- A change in `TunnelsCore` comes with a test, using `FakeRunner` rather than a
  real ssh. A bug fix starts with a test that fails.
- A change the user can see is checked against the lab, and the drill table in
  `docs/TESTING.md` gets a row if it is new behaviour.
- The README describes what the app does; if you changed that, change the README
  in the same pull request.
- No new dependencies, frameworks or layers without a discussion first.

## Commit messages

Conventional commits, lower case, imperative, under 72 characters:
`feat:`, `fix:`, `refactor:`, `perf:`, `test:`, `docs:`, `style:`, `build:`,
`ci:`, `chore:`. The body says why, not what. Example:

```
fix: exclude a discovered port by its remote number, not the local one

"Close and Forget" sent the local port, which only matches the remote
port while the machine has no offset.
```

## Style

- Comments explain intent, constraints and non-obvious decisions; they do not
  restate the code.
- Views read through `AppModel` and never touch the engine directly.
- The core never reads the environment or decides paths; the app passes them in.
- Mutations of the forward list go through the id-based `update`, never an
  index held across an `await`.

## Licence

By contributing you agree that your contribution is licensed under the MIT
licence in `LICENSE`, like the rest of the project. There is no contributor
agreement to sign.
