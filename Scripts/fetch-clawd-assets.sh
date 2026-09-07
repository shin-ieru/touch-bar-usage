#!/usr/bin/env bash
# Fetches Clawd pose data onto this machine and generates a local grid file.
#
# Clawd is Anthropic's character. The upstream pose library publishes no licence,
# so this repository redistributes none of it: only this script is tracked, and
# the generated output goes to a gitignored directory. See docs/branding.md.
#
# This is build/install-time behaviour. The app never fetches at runtime.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/GeneratedAssets/Clawd/clawd-poses.json"

echo "==> Generating Clawd poses"

if ! command -v node >/dev/null 2>&1; then
  echo "  node not found — skipping. The built-in fallback mark will be used."
  echo "  Install Node.js and re-run 'make assets' to enable Clawd."
  exit 0
fi

if node "$ROOT/Scripts/generate-clawd-poses.js" "$OUT"; then
  # Verify the output is real before declaring success.
  if [ -s "$OUT" ] && node -e "
      const d = require('$OUT');
      const n = Object.keys(d.poses || {}).length;
      if (!n) { process.exit(1); }
      for (const [k, g] of Object.entries(d.poses)) {
        if (g.length !== d.gridSize) { console.error('bad grid: ' + k); process.exit(1); }
      }
      console.log('  verified ' + n + ' poses, ' + d.gridSize + 'x' + d.gridSize);
  "; then
    echo "==> Clawd assets ready (gitignored, not redistributed)"
    exit 0
  fi
  echo "  generated file failed verification"
fi

# Graceful failure: keep whatever is already there, or fall back to the
# repository-safe mark. Never fail the build over the mascot.
echo "  could not generate Clawd poses — the built-in fallback mark will be used."
if [ -f "$OUT" ]; then
  echo "  (an earlier generated file is still present and will be used)"
fi
exit 0
