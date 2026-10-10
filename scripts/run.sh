#!/bin/bash
# Rebuild and relaunch the app for a manual check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bundle.sh" "${1:-debug}"
pkill -x Tunnels 2>/dev/null || true
open "$ROOT/build/Tunnels.app"
