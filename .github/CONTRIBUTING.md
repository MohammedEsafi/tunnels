# Contributing

How to make a change, and what must pass before a pull request, is in the
`contribute` skill:
[`.agents/skills/contribute/SKILL.md`](https://github.com/MohammedEsafi/tunnels/blob/main/.agents/skills/contribute/SKILL.md).
How to verify it is in
[`testing`](https://github.com/MohammedEsafi/tunnels/blob/main/.agents/skills/testing/SKILL.md),
and where code belongs is in
[`architecture`](https://github.com/MohammedEsafi/tunnels/blob/main/.agents/skills/architecture/SKILL.md).

The short version: no new dependencies; a core change comes with a test that
failed first; `swift build -Xswiftc -warnings-as-errors`, `swift test` and
`xcrun swift-format lint --strict --recursive Sources Tests` must pass;
commits are conventional (`fix: …`, lower case, imperative, under 72
characters); every user-visible change gets a line in `CHANGELOG.md`.

Contributions are licensed under the MIT licence in `LICENSE`.
