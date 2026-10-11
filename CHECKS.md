# Manual checks

Everything here was run on 10 Oct 2026 against a throwaway sshd on
127.0.0.1:2222 (user-space, key auth only) and a Python HTTP server on
127.0.0.1:18080, so no real machine was needed. The same script works on any
Mac with the command line tools.

## Local sshd fixture

```bash
D=/tmp/tunnels-sshd; rm -rf $D; mkdir -p $D; chmod 700 $D; cd $D
ssh-keygen -q -t ed25519 -N "" -f hostkey
ssh-keygen -q -t ed25519 -N "" -f userkey
cp userkey.pub authorized_keys
cat > sshd_config <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $D/hostkey
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile none
StrictModes no
EOF
cat > ssh_config <<EOF
Host localtest
  HostName 127.0.0.1
  Port 2222
  User $(whoami)
  IdentityFile $D/userkey
  IdentitiesOnly yes
  UserKnownHostsFile $D/known_hosts
EOF
/usr/sbin/sshd -f $D/sshd_config -E $D/sshd.log
python3 -m http.server 18080 --bind 127.0.0.1 &
```

## Core, no UI

```bash
TUNNELS_SSH_CONFIG=$D/ssh_config swift run tunnelsctl localtest 28080 18080 12
# in another shell while it holds:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:28080/     # 200
lsof -nP -iTCP:28080 -sTCP:LISTEN                                    # ssh on 127.0.0.1 only
```

Result: machine connected, forward active, HTTP 200 through the tunnel, no
ssh process and no listener left after the harness closed.

## App

```bash
mkdir -p /tmp/tunnels-xdg/tunnels
cat > /tmp/tunnels-xdg/tunnels/favourites.toml <<EOF
[[favourite]]
name = "web"
host = "localtest"
port = 28080
remote_port = 18080
EOF
TUNNELS_SSH_CONFIG=$D/ssh_config XDG_CONFIG_HOME=/tmp/tunnels-xdg TUNNELS_DEBUG=1 \
  build/Tunnels.app/Contents/MacOS/Tunnels
```

Checked, with the result seen:

| Check | Result |
|---|---|
| App runs background-only, no Dock icon, icon in menu bar | yes (`System Events` reports it as background only) |
| Favourites load, grouped by machine, switches off | yes |
| Turn favourites on: masters start, forwards active | yes, curl 200 through 28080 and 28081 |
| Kill a master (`pkill -f "ssh -N -M.* localtest$"`) | forward unreachable, "Retrying in N s", new master within ~3 s, curl 200 again |
| Unknown host | machine shows "Unknown host" with Retry now, forwards marked dropped, no retry loop |
| Favourites file with errors | orange problems row with line numbers and Open button |
| `ssh -N -L 3999:localhost:3999 -o ProxyCommand="sleep 600" dev-box` in Terminal | shows under dev-box as "Outside the app · ssh pid N" with Stop |
| Quit (menu item, ⌘Q, `kill -TERM`) | every master gets `-O exit`, no ssh left, state.json written |
| Relaunch | forwards that were on come back |
| Settings window | start at login toggle, favourites path with Open/Reveal, host count, per-machine logs |
| All ports on box-a (container without `ss`/`netstat`, so the /proc/net/tcp fallback) | 7777, 8080, 8081, 9999 forwarded within 10 s; `curl localhost:8081/index.json` answers from box-a |

## Still to check on a real machine

- Sleep the Mac with forwards open, wake: forwards return without a click.
- Switch Wi-Fi off for two minutes: one notification after the fifth failed retry.
- A host behind ProxyJump.
- "Start at login" after copying the app to /Applications.
