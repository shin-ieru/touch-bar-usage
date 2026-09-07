#!/usr/bin/env bash
# Builds the Release .app and packages it as a ZIP with a SHA-256 checksum.
#
# ZIP rather than DMG deliberately: a DMG buys a prettier install for v0.1.0 at
# the cost of an extra tool and more that can go wrong, and `ditto` preserves the
# bundle's structure and any signature correctly.
#
# No user-specific paths; everything is relative to the repository root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_NAME="Touch Bar Usage"
APP="$ROOT/dist/$APP_NAME.app"
ARTIFACT="$ROOT/dist/Touch-Bar-Usage-v$VERSION-macOS.zip"

echo "==> Building Release v$VERSION"
# BUNDLE_BRANDED_ASSETS=0 keeps Anthropic's Clawd pose data out of the artifact.
# Handing it to other people would be redistribution, and its upstream publishes
# no licence. Distributed builds show the project's own fallback mark.
CONFIGURATION=release BUNDLE_BRANDED_ASSETS=0 "$ROOT/Scripts/make_app.sh"

if [ ! -d "$APP" ]; then
  echo "error: $APP was not produced" >&2
  exit 1
fi

# Guard against shipping a Debug build by mistake. Comparing binaries directly
# does not work — the bundler ad-hoc signs its copy — so the bundler records the
# configuration it used instead.
BUILT_CONFIGURATION="$(cat "$ROOT/dist/.build-configuration" 2>/dev/null || echo unknown)"
if [ "$BUILT_CONFIGURATION" != "release" ]; then
  echo "error: dist/ holds a '$BUILT_CONFIGURATION' build, refusing to package" >&2
  exit 1
fi

echo "==> Packaging"
rm -f "$ARTIFACT" "$ARTIFACT.sha256"
# `ditto` keeps resource forks, symlinks and signatures intact; `zip` does not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARTIFACT"

echo "==> Checksum"
( cd "$ROOT/dist" && shasum -a 256 "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256" )

echo
echo "Artifact: $ARTIFACT"
echo "Checksum: $ARTIFACT.sha256"
cat "$ARTIFACT.sha256"

echo
echo "==> Signature status"
# An ad-hoc signature satisfies its own designated requirement, so verifying is
# not enough — the question is whether a Developer ID signed it.
if codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "  Developer ID signed:"
  codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer ID|^TeamIdentifier" | sed 's/^/    /'
  echo "  Notarization is a separate step; see docs/release.md."
else
  echo "  AD-HOC signed only — no Developer ID certificate was used."
  echo "  Gatekeeper will block first launch; users must right-click > Open."
  echo "  See the Install section of the README."
fi

echo
echo "==> Bundled resources (must contain no third-party artwork)"
ls -1 "$APP/Contents/Resources" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
if [ -e "$APP/Contents/Resources/clawd-poses.json" ] || [ -e "$APP/Contents/Resources/claude-mascot.png" ]; then
  echo "error: branded artwork present in a distributable artifact" >&2
  exit 1
fi
