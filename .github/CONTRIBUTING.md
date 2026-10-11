# Contributing

The how-to lives in the repository's Claude Code skills under
[`.agents/skills/`](../.agents/skills): open the repo in Claude Code and ask,
or read the files directly. `contribute` has the steps, the commit
format and the house rules; `testing` says how to verify a change;
`design` says where code belongs.

The short version: no new dependencies; a core change comes with a test that
failed first; `swift build -Xswiftc -warnings-as-errors`, `swift test` and
`xcrun swift-format lint --strict --recursive Sources Tests` must pass;
commits are conventional (`fix: …`, lower case, imperative, under 72
characters); every user-visible change gets a line in `CHANGELOG.md`.

Contributions are licensed under the MIT licence in `LICENSE`.
