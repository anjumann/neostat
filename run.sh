#!/bin/bash
# Rebuild, replace any running instance, and launch the HUD.
set -euo pipefail
cd "$(dirname "$0")"
pkill -x NeoStat 2>/dev/null || true
./make-app.sh
open NeoStat.app
echo ">> NeoStat running. Quit via the X in the HUD, or: pkill -x NeoStat"
