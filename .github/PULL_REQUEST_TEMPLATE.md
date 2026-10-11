**What this changes and why**

**How it was checked**
- [ ] `swift build -Xswiftc -warnings-as-errors`, `swift test` and `swift-format lint --strict` pass
- [ ] Core change: a test with `FakeRunner` (a bug fix: one that failed first)
- [ ] User-visible change: tried against the Docker lab; README and `docs/TESTING.md` updated
- [ ] Commit messages follow `CONTRIBUTING.md`
