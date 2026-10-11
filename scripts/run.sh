#!/bin/bash
# Rebuild and relaunch the app for a manual check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bundle.sh" "${1:-debug}"
pkill -x Tunnels 2>/dev/null || true
# Let the old copy finish closing its ssh masters before the new one starts.
for _ in $(seq 1 50); do
  pgrep -x Tunnels >/dev/null || break
  sleep 0.1
done
open "$ROOT/build/Tunnels.app"
