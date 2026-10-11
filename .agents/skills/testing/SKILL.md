---
name: testing
description: "Verify a change to Tunnels: run the build, tests and lint the way CI does, write a core test with the fake ssh runner and its gate, avoid timing flakes, and run the manual drills that cover the app target. Use before claiming any change works, when adding a test, or when reproducing a bug."
---

# Testing Tunnels

Nothing is verified until the relevant check has been run and its output read.
Report what ran and what it printed; never say a check passed without running
it.

## The three checks CI runs

```bash
swift build -Xswiftc -warnings-as-errors
swift test
xcrun swift-format lint --strict --recursive Sources Tests
```

`xcrun swift-format format -i --recursive Sources Tests` applies the style.
`swift test` takes about ten seconds; run it twice when a change touches
timing. `swift test --filter <SuiteName>` runs one suite.

## Writing a core test

1. Put it in `Tests/TunnelsCoreTests`. Regression tests for known defects go
   in `KnownDefectsTests.swift`; behaviour that must be preserved goes in
   `CharacterizationTests.swift`; otherwise the file named for the type.
2. Build the controller with `FakeRunner` and set
   `controller.localPortProbe = { _ in false }` so the test machine's own
   ports do not matter.
3. Script only the command the test is about:
   `runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: listing) : nil }`.
   Returning `nil` falls back to the defaults: `-O check` succeeds while a
   fake master runs, `-O exit` ends that master, everything else succeeds.
   `runner.masterExitsImmediately = (255, "Connection refused")` makes every
   start fail; `runner.masterConnects = false` makes starts hang on `check`.
4. To freeze an ssh command mid-flight use `Gate` from `TestSupport.swift`:

   ```swift
   let gate = Gate()
   runner.gate = { args in if args.contains("forward") { await gate.wait() } }
   Task { await self.controller.setForward(id: id, on: true) }
   await waitUntil { gate.arrivals == 1 }
   // change something while the add is in flight
   gate.open()
   await waitUntil { self.runner.completed(containing: "forward").count >= 1 }
   ```

5. Wait with `waitUntil { … }` for durable outcomes: `.connected`,
   `.failed`, `.off`, a call count, a callback having fired. Do not wait for
   transient states such as `.dropped(attempt: 1)` or `.pending`; if one must
   be observed, give the reconnector `delays = [1.0]` first. Never use a
   fixed `Task.sleep` to wait for something to happen; a short sleep after a
   completed call is acceptable only to let the main actor settle.
6. A bug fix starts with a test that fails on the old code. Run it, see it
   fail, then fix.
7. Use `makeTemporaryDirectory` and remove it in `tearDown`; call
   `await controller.shutdown()` in `tearDown` when a test started loops.

## What the fake runner records

`runner.calls` (every command, in order), `runner.calls(containing:)`,
`runner.completed(containing:)` (commands that have returned),
`runner.launches` and `runner.runningMasters` (fake master processes;
`simulateExit(code:)` makes one die).

## Manual drills for the app target

The app has no unit tests; the drills cover it. Run the debug bundle with
`TUNNELS_DEBUG=1` and the Docker lab up (see the `develop` skill).

| Drill | Expected |
|---|---|
| Turn a favourite on | master starts, row blue, `curl localhost:<port>` answers |
| `pkill -f "ssh -N -M.* box-a$"` | rows orange, new master within seconds, rows blue; after ten seconds or more down, a "box-a is back" notification |
| `docker compose -f testenv/docker-compose.yml stop box-a` | retries at 2, 4, 8, 16, 30 s, then "box-a is down"; `start box-a`, click the orange circle |
| Unknown host, or a key not in the agent | machine failed, tooltip on the circle, no retry loop |
| All Ports on box-a | 7777, 8080, 8081, 9999 forwarded within ten seconds |
| All Ports on box-b as well | box-b moves to +10000, one "ports moved" notification |
| `python3 -m http.server 8081 --bind 0.0.0.0` locally, then All Ports on a box with 8081 | the box moves to an offset; `lsof -nP -iTCP:8081 -sTCP:LISTEN` shows python only |
| Close and Forget on a discovered row of an offset machine | the row goes and stays gone; `exclude` holds the remote number |
| Switch a watched machine off during a scan | it stays off |
| Stop box-a for a minute, let the app give up, then All Ports on box-a again | it reconnects |
| `ssh -N -L 3999:localhost:7777 box-b` in a terminal | shows under box-b as a hollow circle with no switch; Stop works by right-click and VoiceOver |
| Quit (menu, ⌘Q, `kill -TERM`, `kill -INT`) | `pgrep -f "ssh -N -M"` is empty; `state.json` updated |
| `kill -9` the app, relaunch | old masters gone, forwards back |
| Open the app twice | the second copy exits at once |
| Escape with the panel open | panel closes; the log says `panel hidden` |
| Escape inside Rename… or Change Ports… | the edit is cancelled, the panel stays |
| Sleep and wake, or Wi-Fi off and on | one debounced reconnect in the log |
| Open at login from `/Applications` | the toggle stays on after a logout; a pending approval shows a hint |
| Deny the notification permission | a hint under the Notify row; nothing is posted |

For a scripted check, use the snapshot harness from the `develop` skill
and grep its `snapshot:` line.
