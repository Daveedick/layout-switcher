#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Layout Switcher.app"
DEST="${1:-$HOME/Applications/Layout Switcher.app}"
if [[ ! -d "$APP" ]]; then echo "Build first: scripts/build.sh" >&2; exit 1; fi
if [[ -e "$DEST" ]]; then echo "Refusing to overwrite existing destination: $DEST" >&2; exit 2; fi
mkdir -p "$(dirname "$DEST")"
ditto "$APP" "$DEST"
echo "Installed $DEST (not launched; login service not registered)"
