# Testing

## Automated

```bash
swift build -Xswiftc -warnings-as-errors
swift test
xcrun swift-format lint --strict --recursive Sources Tests
```

The core is tested with a scripted stand-in for ssh (`FakeRunner`): it records
every command, answers `-O check` while a fake master runs, ends the master on
`-O exit`, and can hold any command open (`Gate`) while the test changes
something else. `KnownDefectsTests` keeps one test per audited defect; a fix
removes the test's `XCTExpectFailure` wrapper. `CharacterizationTests` pins
behaviour the refactors must keep. The app target has no unit tests; its
behaviour is checked with the drills below.

## The Docker lab

```bash
scripts/testenv.sh up        # two ssh machines (box-a:2222, box-b:2223) and a redis
scripts/testenv.sh status    # what to try
scripts/testenv.sh down
```

`up` builds the containers, generates a key in `testenv/keys/` and adds Host
blocks for `box-a` and `box-b` to `~/.ssh/config` between
`# >>> tunnels-test` and `# <<< tunnels-test` markers; `down` removes exactly
that block and keeps a backup of the file. Each box serves 8080 (web), 8081
(api), 7777 (echo) and 9999 (accepts, never answers); redis is reachable from
inside the boxes only.

## Manual drills

Run the debug build with logging: `TUNNELS_DEBUG=1 build/Tunnels.app/Contents/MacOS/Tunnels`.

| Drill | Expected |
|---|---|
| Turn a favourite on | master starts, row blue, `curl localhost:<port>` answers |
| `pkill -f "ssh -N -M.* box-a$"` | rows orange, new master within a few seconds, rows blue; after a drop of ten seconds or more, a "box-a is back" notification |
| `docker compose -f testenv/docker-compose.yml stop box-a` | retries at 2, 4, 8, 16, 30 s, then "box-a is down"; `start box-a` and click the orange circle |
| Unknown host or a key not in the agent | machine failed, tooltip on the circle, no retry loop |
| All Ports on box-a | 7777, 8080, 8081, 9999 forwarded within ten seconds (`/proc/net/tcp` fallback, the boxes have no `ss`) |
| All Ports on box-b as well | box-b moves to +10000, one "ports moved" notification |
| `python3 -m http.server 8081 --bind 0.0.0.0` on the Mac, then All Ports on a box with 8081 | the box moves to an offset; `lsof -nP -iTCP:8081 -sTCP:LISTEN` shows python only |
| Close and Forget on a discovered row of an offset machine | the row goes and stays gone on the next scan; `exclude` holds the remote number |
| Switch a watched machine off during a scan | it stays off |
| `ssh -N -L 3999:localhost:7777 box-b` in a terminal | shows under box-b with a terminal icon; Stop (hover, right-click or VoiceOver) ends it |
| Quit (menu, ⌘Q, `kill -TERM`, `kill -INT`) | `pgrep -f "ssh -N -M"` is empty, `state.json` updated |
| `kill -9` the app, relaunch | old masters are gone, forwards come back |
| Open the app twice | the second copy exits at once |
| Escape with the panel open | panel closes; `TUNNELS_DEBUG` shows `panel hidden` |
| Escape inside Rename… or Change Ports… | the edit is cancelled, the panel stays |
| Sleep and wake, or Wi-Fi off and on | one debounced reconnect in the debug output |
| Open at login from `/Applications` | the toggle stays on after a logout; a pending approval shows a hint under the row |
| Deny the notification permission | a hint under the Notify row; nothing is posted |

## Snapshot harness

With `TUNNELS_SNAPSHOT=1` the app opens the real panel at the top-left of the
screen, holds it, then quits, so `screencapture -R 30,50,340,560 out.png` can
grab it and `TUNNELS_DEBUG` output can be checked. The app's own copy must
not be running, or the new one exits (single instance); `scripts/run.sh`
restarts it afterwards.

| Variable | Effect |
|---|---|
| `TUNNELS_DEBUG` | log to stderr |
| `TUNNELS_SSH_CONFIG` | use this ssh config instead of `~/.ssh/config` |
| `TUNNELS_SOCKET_DIR` | put control sockets here; also allows a second instance |
| `TUNNELS_SNAPSHOT` | open the panel after `TUNNELS_SNAPSHOT_DELAY` seconds (default 6), hold it `TUNNELS_SNAPSHOT_HOLD` seconds (default 4), then quit without saving state |
| `TUNNELS_SNAPSHOT_PAGE` | `settings` or `logs` |
| `TUNNELS_SNAPSHOT_LOG` | expand this machine on the logs page |
| `TUNNELS_SNAPSHOT_TURN_ON` | turn every favourite on at launch |
| `TUNNELS_SNAPSHOT_ALL` | put this machine in all-ports mode at launch |
| `TUNNELS_SNAPSHOT_EDITPORT` | open the port editor on this `host:local:remote` row |
| `TUNNELS_SNAPSHOT_SCRIPT` | timed steps, e.g. `all:box-b@2,exclude:box-b:8080@8,off:box-b@12,on:box-b@15,closeall@18,escape@20` |

The snapshot's last `snapshot:` log line lists every forward with its state,
which a script can grep.
