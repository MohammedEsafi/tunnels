#!/bin/bash
# Build Tunnels.app from the Swift package. Needs only Xcode command line tools.
#   scripts/bundle.sh            release build  -> build/Tunnels.app
#   scripts/bundle.sh debug      debug build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Tunnels"
BUNDLE_ID="com.mohammedesafi.tunnels"
VERSION="0.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

# App icon: rendered from the SVG once, then reused until the SVG changes.
ICON="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICON" ] || [ "$ROOT/Resources/AppIcon.svg" -nt "$ICON" ]; then
  swift "$ROOT/scripts/makeicon.swift" "$ROOT/Resources/AppIcon.svg" "$ICON" >/dev/null
fi
cp "$ICON" "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal tool.</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$OUT/Contents/PkgInfo"

# Ad-hoc signature is enough for local use. Replace "-" with a Developer ID
# identity to distribute.
codesign --force --sign - --options runtime "$OUT" >/dev/null
echo "Built $OUT ($CONFIG)"
