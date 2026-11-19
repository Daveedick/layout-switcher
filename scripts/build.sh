#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/swiftpm.sh build -c release
APP="$ROOT/dist/Layout Switcher.app"
BIN="$ROOT/.build/release/LayoutSwitcher"
for ARTWORK in Resources/AppIcon.icns Resources/AppIconDark.png Resources/MenuIcon.png Resources/MenuIcon@2x.png; do
  if [[ ! -s "$ROOT/$ARTWORK" ]]; then
    echo "Required icon resource is missing or empty: $ARTWORK" >&2
    exit 1
  fi
done
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/LayoutSwitcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIconDark.png "$APP/Contents/Resources/AppIconDark.png"
cp Resources/MenuIcon.png "$APP/Contents/Resources/MenuIcon.png"
cp Resources/MenuIcon@2x.png "$APP/Contents/Resources/MenuIcon@2x.png"
cp Resources/local.layout-switcher.agent.plist Resources/local.layout-switcher.watchdog.plist "$APP/Contents/Library/LaunchAgents/"
if [[ -d Resources/Licenses ]]; then ditto Resources/Licenses "$APP/Contents/Resources/Licenses"; fi
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchAgents/"*.plist
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
