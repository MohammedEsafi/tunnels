# Contributing

The how-to lives in the repository's agent skills under
[`.agents/skills/`](https://github.com/MohammedEsafi/tunnels/blob/main/.agents/skills), one `SKILL.md` per task. Any agent
that reads that folder can use them (Claude Code does, through the
`.claude/skills` link); people can read the files directly. `contribute` has the steps, the commit
format and the house rules; `testing` says how to verify a change;
`architecture` says where code belongs.

The short version: no new dependencies; a core change comes with a test that
failed first; `swift build -Xswiftc -warnings-as-errors`, `swift test` and
`xcrun swift-format lint --strict --recursive Sources Tests` must pass;
commits are conventional (`fix: …`, lower case, imperative, under 72
characters); every user-visible change gets a line in `CHANGELOG.md`.

Contributions are licensed under the MIT licence in `LICENSE`.
