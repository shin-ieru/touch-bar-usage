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
# Single source of truth for the marketing version; the packaging script reads
# the same file, so artifact names and Info.plist can never disagree.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
# Build number: the commit it was built from, which is more useful for a bug
# report than a counter someone has to remember to bump.
BUILD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"

# Build first. `--show-bin-path` only reports where the product *would* be, so
# without this the script silently depends on someone having built already —
# which works in a warm checkout and fails on a fresh clone.
swift build --package-path "$ROOT" -c "$CONFIGURATION"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/TouchBarUsage" "$APP/Contents/MacOS/TouchBarUsage"

# SwiftPM emits resources as a .bundle next to the binary; carry it along.
if [ -d "$BIN/TouchBarUsage_TouchBarUsage.bundle" ]; then
  cp -R "$BIN/TouchBarUsage_TouchBarUsage.bundle" "$APP/Contents/Resources/"
fi

# Locally resolved branded artwork — Clawd poses and any mascot override.
#
# These are for **local builds only**. Clawd is Anthropic's character and the
# upstream pose library publishes no licence, so bundling it into an artifact
# that is then handed to other people would be redistribution, which this project
# does not do. The release packager therefore sets BUNDLE_BRANDED_ASSETS=0 and
# ships the repository's own fallback mark instead.
#
# The Codex mark is unaffected: it is resolved at runtime from an OpenAI
# application already installed on the user's own machine, so nothing is
# redistributed either way.
BUNDLE_BRANDED_ASSETS="${BUNDLE_BRANDED_ASSETS:-1}"

if [ "$BUNDLE_BRANDED_ASSETS" = "1" ]; then
  if [ -f "$ROOT/GeneratedAssets/Clawd/clawd-poses.json" ]; then
    cp "$ROOT/GeneratedAssets/Clawd/clawd-poses.json" "$APP/Contents/Resources/clawd-poses.json"
    echo "  included locally generated Clawd poses (local build only)"
  else
    echo "  no Clawd poses found (run 'make assets') — using fallback mark"
  fi

  if [ -f "$ROOT/LocalAssets/claude-mascot.png" ]; then
    cp "$ROOT/LocalAssets/claude-mascot.png" "$APP/Contents/Resources/claude-mascot.png"
    echo "  included local mascot override (local build only)"
  fi
else
  echo "  branded assets excluded — distributable build uses the fallback mark"
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

# Record what this bundle was built from. The packaging script refuses to ship a
# Debug build, and comparing binaries directly does not work because the ad-hoc
# signature above rewrites the copy.
printf '%s\n' "$CONFIGURATION" > "$ROOT/dist/.build-configuration"

echo "Built $APP ($CONFIGURATION, v$VERSION, build $BUILD)"
