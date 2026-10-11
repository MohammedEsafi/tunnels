---
name: release
description: "Cut a release of Tunnels: what CI runs on every push, how to move the changelog, tag a version and let the release workflow publish the zip, and what users must do with an ad-hoc signed build. Use when asked to release, to tag, or to explain what happens on a push or a tag."
---

# Releasing Tunnels

## What runs on every push to main and every pull request

`.github/workflows/ci.yml` on a macOS runner, in order, stopping at the first
failure: print the toolchain, restore the build cache, build with warnings as
errors, run the tests, strict `swift-format` lint, `shellcheck` on the
scripts, `scripts/bundle.sh`, `codesign --verify` and `plutil -lint` on the
bundle, upload `Tunnels.app` as a run artifact (kept 90 days on the run's
page; not a release).

## Cut a release

1. Make sure the CI run on the commit to release is green.
2. In `CHANGELOG.md`, move the Unreleased lines under a new
   `## [X.Y.Z] — YYYY-MM-DD` heading and commit: `docs: changelog for X.Y.Z`.
3. Tag and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "Tunnels X.Y.Z"
   git push origin vX.Y.Z
   ```

4. `.github/workflows/release.yml` then checks out the tag, builds with
   warnings as errors, runs the tests, bundles, zips with `ditto` (keeps the
   signature), and creates a GitHub Release named after the tag with the zip
   attached and notes generated from the commits since the previous tag.
5. Check the Releases page. The bundle's version string is the tag without
   the `v`, from `git describe` in `scripts/bundle.sh`.

If a release is wrong, delete the GitHub Release and the tag, fix, and tag
again; the workflow has no replace mode.

## What users get

An ad-hoc signed, hardened-runtime build that Gatekeeper refuses on first
open: right-click › Open, or `xattr -dr com.apple.quarantine`. Removing that
step needs a Developer ID certificate and notarization, which the workflow
does not do yet; the signing line in `scripts/bundle.sh` is where the identity
would go.

## Versioning

Semantic versioning. A behaviour users notice is at least a minor bump; a
changed file format or removed feature is a major bump with a
`BREAKING CHANGE` note in the changelog.
