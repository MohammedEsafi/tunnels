---
name: contribute
description: Make a change to Tunnels the way the project expects: branch, implement within the design rules, test, write a conventional commit, update the changelog and open a pull request. Use when someone wants to add a feature, fix a bug, or push a change, and for any question about commit or pull request conventions.
---

# Contributing to Tunnels

Tunnels is small on purpose: one Swift package, no dependencies, the system
`ssh`. A change that keeps it that way is welcome; one that adds a dependency,
a framework or a layer needs a discussion first.

## Steps for a change

1. **Start from main**, up to date: `git switch -c <type>/<short-name>`.
2. **Read the rules** in the `design` skill before touching
   `Sources/TunnelsCore` or `Sources/Tunnels/App`.
3. **Write the failing test first** for a bug (see the `testing` skill).
   A change in `TunnelsCore` always comes with a test using `FakeRunner`.
4. **Implement** the smallest change that does the job. Comments explain
   intent and constraints, never restate the code.
5. **Run the checks**, all three, and read the output:
   `swift build -Xswiftc -warnings-as-errors`, `swift test`,
   `xcrun swift-format lint --strict --recursive Sources Tests`.
6. **Try it** against the Docker lab if the user can see the change, and add
   a drill row in the `testing` skill if the behaviour is new.
7. **Document**: a user-visible change updates the `usage` skill;
   every user-visible change gets a line under Unreleased in `CHANGELOG.md`
   (Security, Fixed, Added or Changed).
8. **Commit** in the format below, one logical change per commit.
9. **Push and open a pull request**. The template asks for what changed and
   why and the checklist above. CI must be green before review.

## Commit messages

`<type>: <description>`, lower case, imperative, under 72 characters, no
trailing period. Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`,
`style`, `build`, `ci`, `chore`. The body, after a blank line, says why and
what changed in behaviour. No scope unless it adds clarity. Breaking change:
`!` after the type or a `BREAKING CHANGE:` footer.

```
fix: exclude a discovered port by its remote number, not the local one

"Close and Forget" sent the local port, which only matches the remote
port while the machine has no offset; with an offset the wrong number
was written and the port came back on the next scan.
```

## House rules checked in review

- Views read through `AppModel` and never touch the engine directly.
- The core never reads the environment or decides paths; the app passes
  `SSHOptions` and URLs in.
- Mutations of the forward list go through the id-based `update`, never an
  index held across an `await`.
- No words on menu rows, no hover-only control a keyboard cannot reach,
  nothing in the menu bar but the glyph.
- No `try?` that hides a failure the user would want to know about.
- Tests wait for durable outcomes, not timing.

## Licence

Contributions are licensed under the MIT licence in `LICENSE`, like the rest
of the project. There is no contributor agreement.
