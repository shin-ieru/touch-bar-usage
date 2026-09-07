#!/usr/bin/env bash
# Assembles TouchBarUsage.app from the SwiftPM build product.
#
# The app must be a real bundle: the private Control Strip APIs and SMAppService
# both key off bundle identity, and LSUIElement keeps it out of the Dock.
# No user-specific paths — everything is relative to the repository root.
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Touch Bar Usage"
BUNDLE_ID="com.gabrielanyog.touchbarusage"
VERSION="0.1.0"
BUILD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"

BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/TouchBarUsage" "$APP/Contents/MacOS/TouchBarUsage"

# SwiftPM emits resources as a .bundle next to the binary; carry it along.
if [ -d "$BIN/TouchBarUsage_TouchBarUsage.bundle" ]; then
  cp -R "$BIN/TouchBarUsage_TouchBarUsage.bundle" "$APP/Contents/Resources/"
fi

# Locally generated Clawd poses, if `make assets` has been run. GeneratedAssets/
# is gitignored, so a clean checkout and CI simply ship without them and the app
# falls back to its own placeholder mark.
if [ -f "$ROOT/GeneratedAssets/Clawd/clawd-poses.json" ]; then
  cp "$ROOT/GeneratedAssets/Clawd/clawd-poses.json" "$APP/Contents/Resources/clawd-poses.json"
  echo "  included locally generated Clawd poses"
else
  echo "  no Clawd poses found (run 'make assets') — using fallback mark"
fi

# A developer's local mascot override takes precedence over Clawd.
# LocalAssets/ is gitignored, so this never affects a clean checkout or CI.
if [ -f "$ROOT/LocalAssets/claude-mascot.png" ]; then
  cp "$ROOT/LocalAssets/claude-mascot.png" "$APP/Contents/Resources/claude-mascot.png"
  echo "  included local mascot override"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TouchBarUsage</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Background utility: menu bar and Touch Bar only, no Dock icon. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed. Independent project, not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is sufficient for local development. The app requests no
# entitlements: no sandbox, no Accessibility, no Screen Recording, no
# Full Disk Access. Keychain access is granted per-item by the user's own prompt.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "warning: ad-hoc signing failed; the app may still run" >&2
}

echo "Built $APP"
