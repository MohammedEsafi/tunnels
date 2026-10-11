---
name: tunnels-testing
description: How to verify a change to Tunnels: the automated checks, the fake ssh runner and its gate, the Docker lab, the manual drills for the app target, and the snapshot harness with its environment variables. Use before claiming any change works.
---

# Testing

Nothing counts as verified until the relevant check below has been run and its
output read.

## When to use this

- Before committing a change to `TunnelsCore` (run the suite, add a test).
- Before committing a user-visible change (run the drill that covers it).
- When a bug report needs reproducing.

## Automated checks

Run all three; CI runs the same and fails on any of them.

```bash
swift build -Xswiftc -warnings-as-errors
swift test
xcrun swift-format lint --strict --recursive Sources Tests
```

`xcrun swift-format format -i --recursive Sources Tests` applies the style.

## Writing a core test

- Use `FakeRunner` (Tests/TunnelsCoreTests/FakeRunner.swift), never real ssh.
  It records every call; by default `-O check` succeeds while a fake master
  runs and `-O exit` ends that master. Set `runner.script` to answer only the
  commands the test is about and return `nil` for the rest.
- Set `controller.localPortProbe = { _ in false }` in every fixture, so the
  machine running the tests does not influence them.
- To freeze an ssh command mid-flight, use `Gate` (TestSupport.swift):
  `runner.gate = { args in if args.contains("--") { await gate.wait() } }`,
  then `await waitUntil { gate.arrivals == 1 }`, change something, `gate.open()`,
  and `await waitUntil { runner.completed(containing: "--").count >= 1 }`.
- Wait for durable outcomes (`.connected`, `.failed`, a call count), not for
  transient states such as `.dropped(attempt: 1)` or `.pending`. When a
  transient state must be observed, give the reconnector a one-second first
  delay. Never use a fixed `Task.sleep` to wait for something to happen.
- A bug fix starts with a test that fails on the old code. Regression tests for
  audited defects live in `KnownDefectsTests.swift`; behaviour the refactors
  must keep is in `CharacterizationTests.swift`.
- Run `swift test` at least twice before committing a test that involves timing.

## The Docker lab

```bash
scripts/testenv.sh up        # box-a:2222, box-b:2223 and a redis
scripts/testenv.sh status    # what to try
scripts/testenv.sh down
```

`up` builds the containers, generates a key in `testenv/keys/`, and adds Host
blocks for `box-a` and `box-b` to `~/.ssh/config` between
`# >>> tunnels-test` and `# <<< tunnels-test` markers. `down` removes exactly
that block and leaves a backup at `~/.ssh/config.tunnels-backup`. Each box
serves 8080 (web), 8081 (api), 7777 (echo) and 9999 (accepts, never answers);
redis is reachable from inside the boxes only.

## Manual drills for the app target

The app has no unit tests; these cover it. Run the debug build with logging:

```bash
TUNNELS_DEBUG=1 build/Tunnels.app/Contents/MacOS/Tunnels
```

| Drill | Expected |
|---|---|
| Turn a favourite on | master starts, row blue, `curl localhost:<port>` answers |
| `pkill -f "ssh -N -M.* box-a$"` | rows orange, new master within seconds, rows blue; after a drop of ten seconds or more, a "box-a is back" notification |
| `docker compose -f testenv/docker-compose.yml stop box-a` | retries at 2, 4, 8, 16, 30 s, then "box-a is down"; `start box-a` and click the orange circle |
| Unknown host, or a key not in the agent | machine failed, tooltip on the circle, no retry loop |
| All Ports on box-a | 7777, 8080, 8081, 9999 forwarded within ten seconds |
| All Ports on box-b as well | box-b moves to +10000, one "ports moved" notification |
| `python3 -m http.server 8081 --bind 0.0.0.0` on the Mac, then All Ports on a box with 8081 | the box moves to an offset; `lsof -nP -iTCP:8081 -sTCP:LISTEN` shows python only |
| Close and Forget on a discovered row of an offset machine | the row goes and stays gone; `exclude` holds the remote number |
| Switch a watched machine off during a scan | it stays off |
| Stop box-a for a minute, let the app give up, then All Ports on box-a again | it reconnects |
| `ssh -N -L 3999:localhost:7777 box-b` in a terminal | shows under box-b with a terminal icon; Stop works by hover, right-click and VoiceOver |
| Quit (menu, ⌘Q, `kill -TERM`, `kill -INT`) | `pgrep -f "ssh -N -M"` is empty; `state.json` updated |
| `kill -9` the app, relaunch | old masters gone, forwards back |
| Open the app twice | the second copy exits at once |
| Escape with the panel open | panel closes; the log says `panel hidden` |
| Escape inside Rename… or Change Ports… | the edit is cancelled, the panel stays |
| Sleep and wake, or Wi-Fi off and on | one debounced reconnect in the log |
| Open at login from `/Applications` | the toggle stays on after a logout; a pending approval shows a hint |
| Deny the notification permission | a hint under the Notify row; nothing is posted |

## Snapshot harness

With `TUNNELS_SNAPSHOT=1` the app opens the real panel at the top-left of the
screen, holds it, then quits without saving state, so
`screencapture -R 30,50,340,560 out.png` can grab it and the log can be
checked. Stop the normal copy first (`pkill -x Tunnels`, then wait for it to
exit), or set `TUNNELS_SOCKET_DIR`; otherwise the new copy exits. `scripts/run.sh`
restarts the normal copy afterwards.

| Variable | Effect |
|---|---|
| `TUNNELS_DEBUG` | log to stderr |
| `TUNNELS_SSH_CONFIG` | use this ssh config instead of `~/.ssh/config` |
| `TUNNELS_SOCKET_DIR` | put control sockets here; also allows a second instance |
| `TUNNELS_SNAPSHOT` | open the panel after `TUNNELS_SNAPSHOT_DELAY` seconds (default 6), hold `TUNNELS_SNAPSHOT_HOLD` seconds (default 4), then quit |
| `TUNNELS_SNAPSHOT_PAGE` | `settings` or `logs` |
| `TUNNELS_SNAPSHOT_LOG` | expand this machine on the logs page |
| `TUNNELS_SNAPSHOT_TURN_ON` | turn every favourite on at launch |
| `TUNNELS_SNAPSHOT_ALL` | watch this machine at launch |
| `TUNNELS_SNAPSHOT_EDITPORT` | open the port editor on this `host:local:remote` row |
| `TUNNELS_SNAPSHOT_SCRIPT` | timed steps, e.g. `all:box-b@2,exclude:box-b:8080@8,off:box-b@12,on:box-b@15,closeall@18,escape@20` |

The last `snapshot:` log line lists every forward with its state; grep it in
a script instead of reading a screenshot.
