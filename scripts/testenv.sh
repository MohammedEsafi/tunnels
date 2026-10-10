#!/bin/bash
# A local lab for trying Tunnels: two ssh "machines" in Docker with services
# on several ports, plus a redis only reachable through them.
#
#   scripts/testenv.sh up       build, start, add Host blocks to ~/.ssh/config
#   scripts/testenv.sh down     stop, remove the Host blocks
#   scripts/testenv.sh status   what is running, what to try
#   scripts/testenv.sh ssh-add  load the lab key into the agent (optional)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/testenv"
KEY="$ENV/keys/tunnels_test"
KNOWN="$ENV/known_hosts"
CONFIG="$HOME/.ssh/config"
MARK_START="# >>> tunnels-test (managed by scripts/testenv.sh)"
MARK_END="# <<< tunnels-test"

docker_ok() { docker info >/dev/null 2>&1; }

ensure_key() {
  mkdir -p "$ENV/keys"
  if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "$KEY" -C "tunnels-test"
    echo "made lab key $KEY"
  fi
}

host_block() {
  local name=$1 port=$2
  cat <<EOF
Host $name
  HostName 127.0.0.1
  Port $port
  User tester
  IdentityFile $KEY
  IdentitiesOnly yes
  UserKnownHostsFile $KNOWN
  StrictHostKeyChecking accept-new
EOF
}

remove_block() {
  [ -f "$CONFIG" ] || return 0
  if grep -qF "$MARK_START" "$CONFIG"; then
    local tmp; tmp="$(mktemp)"
    awk -v s="$MARK_START" -v e="$MARK_END" '
      $0==s {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$CONFIG" > "$tmp"
    cat "$tmp" > "$CONFIG"
    rm -f "$tmp"
    echo "removed Host blocks from $CONFIG"
  fi
}

add_block() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$CONFIG"; chmod 600 "$CONFIG"
  remove_block >/dev/null
  {
    [ -s "$CONFIG" ] && [ -n "$(tail -c1 "$CONFIG")" ] && echo
    echo "$MARK_START"
    host_block box-a 2222
    echo
    host_block box-b 2223
    echo "$MARK_END"
  } >> "$CONFIG"
  echo "added Host box-a and box-b to $CONFIG"
}

case "${1:-status}" in
  up)
    docker_ok || { echo "Docker is not running. Open Docker Desktop and try again."; exit 1; }
    ensure_key
    rm -f "$KNOWN"
    (cd "$ENV" && docker compose up -d --build)
    add_block
    for i in $(seq 1 20); do
      ssh -o ConnectTimeout=2 -o BatchMode=yes box-a true 2>/dev/null && break
      sleep 1
    done
    "$0" status
    ;;
  down)
    (cd "$ENV" && docker compose down 2>/dev/null) || true
    remove_block
    ;;
  ssh-add)
    ensure_key
    ssh-add "$KEY"
    ;;
  status)
    echo "Containers:"
    (cd "$ENV" && docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null) || echo "  (docker not running)"
    echo
    for h in box-a box-b; do
      if ssh -o ConnectTimeout=2 -o BatchMode=yes "$h" true 2>/dev/null; then
        echo "ssh $h: ok"
      else
        echo "ssh $h: not reachable"
      fi
    done
    cat <<'EOF'

Things to try in Tunnels (type into the field, or pin them):
  box-a:8080            web page         -> open http://localhost:8080
  box-a:18081:8081      api on a different local port -> curl localhost:18081/index.json
  box-b:8080            same service, other machine   -> port clash with the first one (expected error)
  box-b:28080:8080      the fix: pick another local port
  box-a:7777            tcp echo         -> nc localhost 7777, type, it echoes
  box-a:16379:redis:6379  redis only reachable from inside -> redis-cli -p 16379 ping (or nc)
  box-a:9999            a port that accepts and never answers

Failure drills:
  docker compose -f testenv/docker-compose.yml stop box-a   -> forwards drop, app retries, then gives up
  docker compose -f testenv/docker-compose.yml start box-a  -> press the orange circle to retry
  ssh -N -L 3999:localhost:7777 box-b                       -> shows under box-b as started outside Tunnels
EOF
    ;;
  *)
    echo "usage: $0 up|down|status|ssh-add"; exit 2
    ;;
esac
