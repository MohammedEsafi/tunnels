---
name: tunnels-dev
description: Set up, build and run Tunnels locally: the toolchain, the build and bundle scripts, the Docker lab with two ssh machines, debug logging and the snapshot harness. Use when someone wants to run the app from source, try it against test machines, or capture what the panel shows.
---

# Developing Tunnels locally

## Prerequisites

- macOS 14 or newer with the Xcode command line tools. Nothing else: no
  Homebrew, no Xcode project, no third-party packages.
- Docker Desktop only for the lab below.

## Build and run

```bash
swift build                  # the package
scripts/bundle.sh            # release build -> build/Tunnels.app, signed ad hoc
scripts/bundle.sh debug      # debug build of the bundle
scripts/run.sh               # debug bundle, stop the running copy, relaunch
```

`run.sh` waits for the old copy to close its ssh connections before opening
the new one; the app refuses to run twice otherwise. Run the bundle rather
than `swift run Tunnels`: notifications and the login item need a bundle.

The version in the bundle comes from the nearest `v*` git tag; without one it
reads `0.0.0+<sha>`.

## Log what the app does

```bash
TUNNELS_DEBUG=1 build/Tunnels.app/Contents/MacOS/Tunnels
```

Logs go to stderr: every ssh line per machine, scans, panel shown/hidden,
notifications, favourites writes. Inside the app, Settings › Connection Logs
shows the per-machine ssh output.

## The Docker lab

```bash
scripts/testenv.sh up        # box-a:2222, box-b:2223 and a redis
scripts/testenv.sh status    # containers, ssh reachability, things to try
scripts/testenv.sh ssh-add   # load the lab key into the agent
scripts/testenv.sh down
```

- `up` builds the containers, generates a key in `testenv/keys/` (ignored by
  git), and adds Host blocks for `box-a` and `box-b` to `~/.ssh/config`
  between `# >>> tunnels-test` and `# <<< tunnels-test` markers. `down`
  removes exactly that block and keeps `~/.ssh/config.tunnels-backup`. The
  script refuses to touch the file if the markers are missing or duplicated.
- Each box serves 8080 (web page), 8081 (JSON api), 7777 (TCP echo) and 9999
  (accepts, never answers). Redis is reachable from inside the boxes only, so
  `box-a:16379:redis:6379` exercises a remote host behind the machine.
- The boxes have no `ss` or `netstat`, so all-ports mode uses the
  `/proc/net/tcp` fallback there.

Useful drills: `docker compose -f testenv/docker-compose.yml stop box-a` to
make a machine drop, `start box-a` to bring it back; `pkill -f "ssh -N -M.*
box-a$"` to kill one master; a local `python3 -m http.server 8081 --bind
0.0.0.0` to occupy a port the boxes also serve.

## Snapshot harness

With `TUNNELS_SNAPSHOT=1` the app opens the real panel at the top-left of the
screen, holds it, then quits without saving state. Capture it with
`screencapture -R 30,50,340,560 out.png`. Stop the normal copy first
(`pkill -x Tunnels` and wait for it to exit) or set `TUNNELS_SOCKET_DIR`;
`scripts/run.sh` brings the normal copy back afterwards.

| Variable | Effect |
|---|---|
| `TUNNELS_DEBUG` | log to stderr |
| `TUNNELS_SSH_CONFIG` | use this ssh config instead of `~/.ssh/config` |
| `TUNNELS_SOCKET_DIR` | control sockets here; also allows a second instance |
| `TUNNELS_SNAPSHOT` | open the panel after `TUNNELS_SNAPSHOT_DELAY` s (default 6), hold `TUNNELS_SNAPSHOT_HOLD` s (default 4), quit |
| `TUNNELS_SNAPSHOT_PAGE` | `settings` or `logs` |
| `TUNNELS_SNAPSHOT_LOG` | expand this machine on the logs page |
| `TUNNELS_SNAPSHOT_TURN_ON` | turn every favourite on at launch |
| `TUNNELS_SNAPSHOT_ALL` | watch this machine at launch |
| `TUNNELS_SNAPSHOT_EDITPORT` | open the port editor on this `host:local:remote` row |
| `TUNNELS_SNAPSHOT_SCRIPT` | timed steps: `all:box-b@2,exclude:box-b:8080@8,off:box-b@12,on:box-b@15,closeall@18,escape@20` |

The last `snapshot:` log line lists every forward with its state; grep it
rather than reading a screenshot when a script needs a yes or no.

## Where things are

```
Sources/TunnelsCore         the engine and the file formats, no UI
  Engine/                   ProcessRunner, SSHMaster, SSHOptions, ForwardController (+Discovery), Reconnector
  Formats/                  MiniTOML, Favourites (+Editing), FileWatcher, PersistedState
  Hosts/                    SSHConfig, Hosts (Tailscale), QuickOpen
  System/                   ExternalScanner, PortDiscovery, LocalPorts
Sources/Tunnels             the app: App/, Model/, Views/, Debug/
Sources/tunnelsctl          command-line harness for the core
Tests/TunnelsCoreTests      XCTest with a scripted stand-in for ssh
scripts/                    bundle.sh, run.sh, makeicon.swift, testenv.sh
testenv/                    the Docker lab
.agents/skills/             these skills; .claude/skills is a symlink to it
```
